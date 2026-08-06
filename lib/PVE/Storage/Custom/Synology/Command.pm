package PVE::Storage::Custom::Synology::Command;

# Bounded external commands, bounded file tests, bounded sysfs.
#
# PORTED, ALMOST UNCHANGED, from jt-pve-storage-dellemc's Common::Multipath.
# This is the most hardware-punished code in the family and rewriting it from
# scratch would be throwing away the incidents that shaped it. Each comment
# below records the failure the code prevents; they are kept verbatim for that
# reason.
#
# The one rule behind all of it: nothing here touches the kernel without a
# bound, and a timeout protects the PARENT, never the kernel. A child stuck in
# uninterruptible sleep still holds whatever lock it took — so where an
# operation can hang for minutes inside the kernel, the answer is not to time
# it out but not to issue it.

use strict;
use warnings;

use Carp qw(croak);
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);
use POSIX ();

use Exporter qw(import);
our @EXPORT_OK = qw(
    run_cmd
    is_block_device
    sysfs_read_with_timeout
    sysfs_write_with_timeout
);

# ---------------------------------------------------------------------------
# Bounded file tests
# ---------------------------------------------------------------------------

# -b, bounded.
#
# A Perl file test is a stat(2), and stat on a path under /dev is not free:
# for a symlink it resolves the target first, and on a multipath device whose
# paths have all failed while queueing is still on, that lands in the same
# uninterruptible sleep that hangs vgs. Every device path this plugin touches
# is exactly that kind of path, so none of them may be tested unguarded.
#
# An outer alarm is preserved: alarm(0) returns what was left of it, and that
# is put back afterwards. Nesting alarms without doing this silently cancels
# the caller's own timeout, which is worse than the problem being solved.
sub is_block_device {
    my ($path, %opts) = @_;

    return 0 unless defined $path && length $path;

    my $timeout   = $opts{timeout} // 3;
    my $remaining = alarm(0);

    my $result = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($timeout);
        $result = (-b $path) ? 1 : 0;
        alarm(0);
    };
    alarm(0);

    if ($@) {
        warn "stat of $path did not return within ${timeout}s; treating it as"
           . " unusable\n";
        # undef, not 0: "the stat never came back" is not "this is not a block
        # device". Callers testing truth are unaffected; the ones that must
        # tell a timeout from a definite no check defined().
        $result = undef;
    }

    alarm($remaining) if $remaining;

    return $result;
}

# ---------------------------------------------------------------------------
# Bounded sysfs access
# ---------------------------------------------------------------------------

# Write to sysfs in a child process. Returns 1 on success, 0 on failure or
# timeout. The child is what may end up stuck in D state; the parent stays
# responsive either way.
sub sysfs_write_with_timeout {
    my ($path, $data, $timeout) = @_;
    $timeout //= 10;

    my $pid = fork();
    if (!defined $pid) {
        warn "fork failed for sysfs write to $path: $!\n";
        return 0;
    }

    if ($pid == 0) {
        eval {
            open(my $fh, '>', $path) or die "open: $!";
            print $fh $data;
            close($fh) or die "close: $!";
        };
        POSIX::_exit($@ ? 1 : 0);
    }

    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        my $res = waitpid($pid, POSIX::WNOHANG());
        return ($? >> 8) == 0 ? 1 : 0 if $res > 0;
        return 1 if $res < 0;
        select(undef, undef, undef, 0.1);
    }

    warn "sysfs write to $path timed out after ${timeout}s, killing child pid $pid\n";
    kill('KILL', $pid);
    my $reaped = waitpid($pid, POSIX::WNOHANG());
    warn "child pid $pid is in uninterruptible sleep and cannot be reaped\n"
        if $reaped == 0;

    return 0;
}

# Read a sysfs/proc file in a child process. Returns the content, or undef on
# timeout or failure.
sub sysfs_read_with_timeout {
    my ($path, $timeout) = @_;
    $timeout //= 5;

    pipe(my $read_fh, my $write_fh) or do {
        warn "pipe failed for sysfs read of $path: $!\n";
        return undef;
    };

    my $pid = fork();
    if (!defined $pid) {
        warn "fork failed for sysfs read of $path: $!\n";
        close($read_fh);
        close($write_fh);
        return undef;
    }

    if ($pid == 0) {
        close($read_fh);
        eval {
            open(my $fh, '<', $path) or die "open: $!";
            local $/;
            my $data = <$fh>;
            close($fh);
            print $write_fh ($data // '');
        };
        close($write_fh);
        POSIX::_exit($@ ? 1 : 0);
    }

    close($write_fh);
    my $content = '';

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($timeout);
        while (1) {
            my $buf;
            my $bytes = sysread($read_fh, $buf, 65536);
            last if !defined($bytes) || $bytes == 0;
            $content .= $buf;
        }
        alarm(0);
    };
    my $timed_out = $@;
    alarm(0);
    close($read_fh);

    if ($timed_out) {
        warn "sysfs read of $path timed out after ${timeout}s, killing child pid $pid\n";
        kill('KILL', $pid);
        waitpid($pid, POSIX::WNOHANG());
        return undef;
    }

    waitpid($pid, 0);
    return length($content) ? $content : undef;
}

sub _reap_timed_out_child {
    my ($pid, $cmd) = @_;
    return unless $pid;

    for my $sig ('TERM', 'KILL') {
        kill($sig, $pid);
        my $deadline = time() + 2;
        while (time() < $deadline) {
            my $res = waitpid($pid, POSIX::WNOHANG());
            return if $res != 0;
            select(undef, undef, undef, 0.1);
        }
    }

    warn "child pid $pid for '@{$cmd // []}' did not die after TERM+KILL"
       . " (likely uninterruptible sleep in the kernel); leaving it to init\n";
}

sub _run_cmd {
    my ($cmd, %opts) = @_;

    my $timeout = $opts{timeout} // 30;
    my ($stdout, $stderr) = ('', '');
    my $err = gensym;
    my $pid;

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($timeout);

        # The output of some of these is parsed, and util-linux tools ship
        # translations: a node running in another language answers with
        # another language. Pin the child to C so what comes back is what the
        # parsers were written against. This is not hypothetical here — the
        # nodes this plugin is written for are as likely to run zh_TW as en_US.
        local $ENV{LC_ALL} = 'C';
        local $ENV{LANG}   = 'C';

        $pid = open3(my $in, my $out, $err, @$cmd);
        close($in);

        # Read both streams: a full stderr pipe would otherwise deadlock the
        # child while we wait on stdout.
        my $sel = IO::Select->new($out, $err);
        while (my @ready = $sel->can_read()) {
            for my $fh (@ready) {
                my $buf;
                my $bytes = sysread($fh, $buf, 8192);
                if (!defined($bytes) || $bytes == 0) {
                    $sel->remove($fh);
                    next;
                }
                if ($fh == $out) { $stdout .= $buf } else { $stderr .= $buf }
            }
        }

        waitpid($pid, 0);
        alarm(0);
    };

    if ($@) {
        alarm(0);
        my $error = $@;
        _reap_timed_out_child($pid, $cmd);
        croak "Command timed out after ${timeout}s: @$cmd" if $error eq "timeout\n";
        croak "Command failed: $error";
    }

    my $exit_code = $? >> 8;

    if ($exit_code != 0 && !$opts{ignore_errors} && !$opts{allow_nonzero}) {
        croak "Command failed (exit $exit_code): @$cmd\nstderr: $stderr";
    }

    return wantarray ? ($stdout, $stderr, $exit_code) : $stdout;
}

# The public name. `_run_cmd` stays as the internal one so the ported body
# above reads exactly as it does in the project it came from.
sub run_cmd { return _run_cmd(@_) }

1;
