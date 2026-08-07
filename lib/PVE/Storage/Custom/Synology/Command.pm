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
    tool_path
    safe_path
);

# ---------------------------------------------------------------------------
# Bounded file tests
# ---------------------------------------------------------------------------

# THE THIRD MODULE OF THIS SHAPE, so it gets the same guard.
#
# These are functions, not methods. Naming and Multipath were both called as
# `Module->function(...)` at some point, the arguments shifted by one, and
# nothing errored — the ownership gate answered "not owned" for an object that
# WAS owned, and a caller's `no_path_retry` was silently ignored. Here the
# failure would be quieter still: `Command->is_block_device($dev)` binds the
# class name to $path, so a real device is reported as **not a block device**,
# and %opts gets an odd number of elements. A safety check that answers the
# wrong question is worse than one that dies.
sub _not_a_method {
    my ($first) = @_;
    return if !defined $first;
    return if $first ne __PACKAGE__;
    die __PACKAGE__ . ": these are functions, not methods. Call"
      . " Command::is_block_device(...) rather than"
      . " Command->is_block_device(...).\n";
}

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
    _not_a_method($_[0]);
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
    _not_a_method($_[0]);
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
    _not_a_method($_[0]);
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

    # A bounded reap, not `waitpid($pid, 0)`. The alarm was cleared four lines
    # up, so a blocking wait here has nothing protecting it — and this module's
    # rule is that NOTHING touches the kernel without a bound, with no exception
    # for a path that looks safe. It does look safe: EOF means the child already
    # flushed and reached `_exit`. But "the child must have exited by now" is the
    # same reasoning that put every other hang in this file, and a child that is
    # merely stopped rather than dead would block this forever.
    _reap_bounded($pid);
    return length($content) ? $content : undef;
}

# Reap a child that is expected to have finished. Bounded, and it does NOT
# signal: the caller has already read the child's output to EOF, so killing it
# would be killing something that did its job.
sub _reap_bounded {
    my ($pid, $seconds) = @_;
    return if !$pid;

    my $deadline = time() + ($seconds // 2);
    while (time() < $deadline) {
        return if waitpid($pid, POSIX::WNOHANG()) != 0;
        select(undef, undef, undef, 0.05);
    }

    warn "child pid $pid closed its output but had not exited after 2s;"
       . " leaving it to init rather than blocking\n";
    return;
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

# ---------------------------------------------------------------------------
# EVERY COMMAND IS RESOLVED TO AN ABSOLUTE PATH, BECAUSE A PVE DAEMON HAS NO PATH
# ---------------------------------------------------------------------------
#
# Measured on host-108, 2026-08-07: `/proc/<pid>/environ` for **pvestatd,
# pvedaemon, pveproxy and pve-ha-lrm** contains no `PATH` variable at all, and
# nothing in the whole PVE tree sets one at runtime. `exec` then falls back to
# the C library's default, which is `/bin:/usr/bin` — and every tool this plugin
# runs lives in `/usr/sbin`.
#
# So the SAME operation succeeded or failed according to who started it. A
# resize from `qm resize` on a login shell worked, because a login shell has
# /usr/sbin on its PATH. The identical resize from the web interface ran in a
# pvedaemon worker, where `multipathd` could not be executed at all — open3 died
# with "exec of multipathd resize map ... failed: No such file or directory",
# the caller's eval swallowed it, and the operation reported a map that had not
# grown rather than a command that had never run.
#
# PVE's own plugins have always written absolute paths and this is why:
# ISCSIPlugin has `/usr/bin/iscsiadm`, LVMPlugin has `/sbin/vgs`. The two places
# in this plugin that already resolved a path by hand — `_fuser` and `scsi_id`
# in Multipath — were the shape of the answer, applied to two commands out of
# five. Doing it here means nothing can be added later that forgets.
#
# /usr/sbin first: on a merged-/usr Debian the /sbin entries are symlinks into
# it, and naming the real directory keeps the resolved path stable.
our @TOOL_DIRS = qw(/usr/sbin /sbin /usr/bin /bin /usr/local/sbin /usr/local/bin);

# Only successes are cached. A negative answer must not be remembered, or a node
# where the operator installs the missing package goes on failing until every
# daemon is restarted.
my %TOOL_PATH;

sub tool_path {
    my ($name) = @_;
    return undef if !defined $name || !length $name;
    return $name if $name =~ m{/};      # already a path; the caller chose it
    return $TOOL_PATH{$name} if defined $TOOL_PATH{$name} && -x $TOOL_PATH{$name};

    for my $dir (@TOOL_DIRS) {
        my $p = "$dir/$name";
        # An ordinary file test on a path under /usr or /bin, never under /dev,
        # so rule 10's uninterruptible-stat hazard does not apply here.
        next if !-f $p || !-x $p;
        return $TOOL_PATH{$name} = $p;
    }
    return undef;
}

# ---------------------------------------------------------------------------
# TAINT MODE, WHICH IS NOT OPTIONAL: pvedaemon IS `#!/usr/bin/perl -T`
# ---------------------------------------------------------------------------
#
# So every value this plugin reads from a file, a socket or the environment is
# tainted, and Perl refuses to `exec` with a tainted argument:
#
#   Insecure dependency in exec while running with -T switch at IPC/Open3.pm
#
# The map name is the one that found this. It comes from
# /sys/block/dm-N/dm/name — a file read, therefore tainted — and goes straight
# into `multipathd resize map <name>`. `slaves_of_map` had the answer already:
# it takes the device name from what a regex MATCHED rather than from what it
# read, and its comment calls that "the taint discipline and the correctness
# check in one". Applied there and nowhere else. The third time in this module
# that the right pattern existed and covered a minority of the call sites.
#
# Untainting here rather than at each source is deliberate, and it is safe for a
# reason specific to how these commands are run: the list form of `exec` never
# involves a shell, so there is no metacharacter to escape and the only question
# is whether the bytes are ones this plugin could legitimately have produced.
# The allowlist answers exactly that question, and anything outside it is a
# refusal rather than a silent strip — a value this plugin did not construct has
# no business reaching a command, and turning it into a different value would be
# worse than stopping.
#
# WWIDs, device names, map names, sysfs paths, sizes and iscsiadm's own flags
# all fit. A newline, a NUL, a quote, a backtick, a `$` or a space does not.
my $ARG_OK = qr{\A[A-Za-z0-9_./:=,+\@%^-]*\z};

sub _untaint_arg {
    my ($arg, $prog) = @_;
    $prog = defined $prog ? $prog : 'a command';
    croak "Command failed: '$prog' was given an undefined argument"
        if !defined $arg;

    # The captured value is the untainted one. Matching without capturing would
    # leave the original tainted, which is the mistake that makes a validating
    # untaint look like it worked.
    if ($arg =~ /($ARG_OK)/) {
        return $1;
    }

    croak "Command failed: refusing to run '$prog' with the argument '$arg'."
        . " It contains a character this plugin never produces, so it did not"
        . " come from anywhere trustworthy.";
}

# The subset of @TOOL_DIRS that taint mode will accept in $ENV{PATH}: present,
# and not writable by group or other. Recomputed each call rather than cached —
# it is six stats, and a directory's mode is exactly the kind of node-local fact
# this project has been caught assuming twice today.
sub safe_path {
    my @ok;
    for my $dir (@TOOL_DIRS) {
        my @st = stat($dir) or next;
        next if !-d _;
        next if $st[2] & 0o022;      # group- or world-writable
        push @ok, $dir;
    }
    return join(':', @ok);
}

sub _run_cmd {
    _not_a_method($_[0]);
    my ($cmd, %opts) = @_;

    my $timeout = $opts{timeout} // 30;
    my ($stdout, $stderr) = ('', '');
    my $err = gensym;
    my $pid;

    my @argv = @{ $cmd // [] };
    croak "Command failed: no command given" if !@argv;
    @argv = map { _untaint_arg($_, $argv[0]) } @argv;
    my $prog = tool_path($argv[0]);
    # Loud, and named. "not installed" and "not on the PATH of whoever started
    # this daemon" are the same symptom to the caller, and both are worth the
    # same sentence: the tool is not runnable from here.
    croak "Command failed: '$argv[0]' was not found in "
        . join(', ', @TOOL_DIRS)
        . ". Install the package that provides it (open-iscsi and"
        . " multipath-tools between them provide all of them)."
        if !defined $prog;
    $argv[0] = $prog;

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

        # For anything the child itself execs. The absolute path above is what
        # makes THIS command run; this is so a helper it spawns does not hit the
        # same wall. Under -T it is also mandatory rather than defensive: Perl
        # refuses to exec with a tainted or relative $ENV{PATH}, and insists the
        # four variables below are unset.
        #
        # SAFE directories only, and that word is taint mode's, not an opinion.
        # Perl refuses to exec when ANY directory in $ENV{PATH} is writable by
        # group or other:
        #
        #   Insecure directory in $ENV{PATH} while running with -T switch
        #
        # Setting PATH to the full search list was added as belt and braces and
        # was itself the next failure: on a GitHub runner /usr/local/bin is
        # group-writable, and every command in the suite died on a line that
        # existed only to be careful. A node with a relaxed /usr/local would
        # have done the same to a real operation from pvedaemon or vzdump.
        local $ENV{PATH} = safe_path();
        local @ENV{qw(IFS CDPATH ENV BASH_ENV)};
        delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

        $pid = open3(my $in, my $out, $err, @argv);
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
