#!/usr/bin/perl

# Command.pm's bounds, and the one that was missing.
#
# This module exists because nothing may touch the kernel without a bound, and
# an audit on 2026-08-06 found a place where it broke its own rule:
# `sysfs_read_with_timeout` cleared its alarm and then reaped with
# `waitpid($pid, 0)`. Reaching that line needs EOF, which means the child had
# already flushed and was on its way to `_exit` — so it was safe by argument.
# But "the child must have exited by now" is the reasoning behind every hang
# this module was written to prevent.
#
# The test below is the demonstration, not the argument: a child that is STOPPED
# rather than dead has closed nothing and exited nothing, and `waitpid($pid, 0)`
# on it never returns. `_reap_bounded` gives up instead.

use strict;
use warnings;
use Test::More;
use POSIX ();
use lib 'lib';

require_ok('PVE::Storage::Custom::Synology::Command');
my $C = 'PVE::Storage::Custom::Synology::Command';

ok(defined &PVE::Storage::Custom::Synology::Command::_reap_bounded,
   '_reap_bounded exists — the unbounded waitpid on the success path is gone');

# No `waitpid($pid, 0)` may survive outside the one place that is still inside an
# armed alarm. Checked in the source, because a reap that blocks is invisible
# until the day it blocks.
{
    open(my $fh, '<', 'lib/PVE/Storage/Custom/Synology/Command.pm')
        or BAIL_OUT('cannot read Command.pm');
    my $src = do { local $/; <$fh> };
    close($fh);

    # Comments stripped first: this file's own comments mention the very thing
    # being counted, and a guard with a false positive is a guard people learn
    # to ignore.
    (my $code = $src) =~ s/^\s*#.*$//mg;
    my @blocking = ($code =~ /(waitpid\(\$pid,\s*0\))/g);
    is(scalar @blocking, 1,
       'exactly one blocking waitpid remains, the one inside run_cmd\'s alarm');
}

# The regression itself.
subtest 'a stopped child does not block the reap forever' => sub {
    my $pid = fork();
    BAIL_OUT('cannot fork') if !defined $pid;

    if ($pid == 0) {
        # Stop itself, then sleep. It is neither dead nor reapable, which is
        # exactly the state a blocking waitpid cannot survive.
        kill('STOP', $$);
        sleep 30;
        POSIX::_exit(0);
    }

    # Wait for it to actually reach the stopped state before timing anything,
    # or the test would measure the race and not the reap.
    my $ready = 0;
    for (1 .. 50) {
        my $st = do {
            open(my $s, '<', "/proc/$pid/stat") or last;
            my $l = <$s>; close($s); $l;
        };
        if (defined $st && $st =~ /\)\s+(\S)/ && $1 eq 'T') { $ready = 1; last }
        select(undef, undef, undef, 0.1);
    }

    if (!$ready) {
        kill('CONT', $pid); kill('KILL', $pid); waitpid($pid, 0);
        plan skip_all => 'could not get the child into a stopped state';
        return;
    }

    my $start = time();
    my $warning = '';
    {
        local $SIG{__WARN__} = sub { $warning .= $_[0] };
        PVE::Storage::Custom::Synology::Command::_reap_bounded($pid, 1);
    }
    my $took = time() - $start;

    cmp_ok($took, '<', 5, "gave up after ${took}s instead of blocking forever");
    like($warning, qr/had not exited/,
         'and said so, rather than returning as though it had reaped');

    # The child is still ours to clean up — _reap_bounded deliberately does not
    # signal, because on its real path the child has done its job.
    kill('CONT', $pid);
    kill('KILL', $pid);
    waitpid($pid, 0);
    ok(1, 'child cleaned up by the test, not by the reaper');
};

subtest 'an exited child is reaped promptly' => sub {
    my $pid = fork();
    BAIL_OUT('cannot fork') if !defined $pid;
    POSIX::_exit(0) if $pid == 0;

    my $start = time();
    my $warning = '';
    {
        local $SIG{__WARN__} = sub { $warning .= $_[0] };
        PVE::Storage::Custom::Synology::Command::_reap_bounded($pid, 2);
    }
    cmp_ok(time() - $start, '<', 2, 'returned without waiting out the bound');
    is($warning, '', 'and warned about nothing');
    is(waitpid($pid, POSIX::WNOHANG()), -1, 'the child really was reaped');
};

# is_block_device must answer undef — not false — when it cannot tell. A false
# here would let a destructive path proceed on "not a block device".
subtest 'is_block_device on a path that does not exist' => sub {
    my $r = PVE::Storage::Custom::Synology::Command::is_block_device(
        '/dev/there-is-no-such-device-here');
    ok(!$r, 'a missing path is not a block device');

    # And the guard that made this test fail the first time it was written:
    # called as a method the class name becomes the path, and the answer would
    # have been a silent, wrong "not a block device".
    my $err = '';
    eval { $C->is_block_device('/dev/anything'); 1 } or $err = $@;
    like($err, qr/functions, not methods/,
         'a method call is refused outright rather than answered wrongly');
};

done_testing();
