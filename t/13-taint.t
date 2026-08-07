#!/usr/bin/perl -T

# THIS FILE RUNS UNDER -T, AND THAT IS THE ENTIRE POINT OF IT.
#
# `pvedaemon` is `#!/usr/bin/perl -T`. Every operation an operator starts from
# the web interface therefore runs in taint mode, and Perl refuses to `exec`
# with a tainted argument:
#
#   Insecure dependency in exec while running with -T switch at IPC/Open3.pm
#
# Nothing in this project reproduced that for the whole life of the plugin,
# because every hardware test was driven from `qm`, `pvesm` or `pvesh` — and all
# three are plain `#!/usr/bin/perl`, with no -T. The bug was reported from the
# web interface twice before the difference was noticed, and the second time was
# in a verification run that claimed to be testing "the API path".
#
# The map name is what found it: it is read from /sys/block/dm-N/dm/name, which
# taints it, and it goes straight into `multipathd resize map <name>`.
#
# So this file exists to make the daemon's environment reachable from `make
# test`. Adding a case to any other test file does NOT cover this — the shebang
# is the fixture.

use strict;
use warnings;
use Test::More;
use lib 'lib';

# Taint mode rejects an insecure PATH before it rejects anything else, so this
# has to be set before the first command runs. It is the harness's own hygiene,
# not the module's; the module sets its own PATH from literals.
$ENV{PATH} = '/usr/sbin:/sbin:/usr/bin:/bin';
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

use_ok('PVE::Storage::Custom::Synology::Command');
my $C = 'PVE::Storage::Custom::Synology::Command';

ok(${^TAINT}, 'this file really is running under -T — without that it proves nothing');

# THE FIXTURE HAS TO BE TAINTED THE WAY THE REAL VALUE IS, which means reading
# it from a file. The first version of this test assigned to %ENV and read it
# back — and a value this process wrote itself is NOT tainted, so the test
# passed while proving nothing. Perl taints what comes from OUTSIDE the program.
#
# /proc/sys/kernel/ostype stands in for /sys/block/dm-N/dm/name: same kind of
# read, same taint, and it exists on every node this could run on.
my $tainted = do {
    open(my $fh, '<', '/proc/sys/kernel/ostype') or die "cannot read ostype: $!";
    my $v = <$fh>;
    close($fh);
    chomp $v if defined $v;
    $v;
};

require Scalar::Util;
ok(Scalar::Util::tainted($tainted),
   'the fixture is genuinely tainted, so this test can fail for the real reason');

# The regression. Before the fix this died inside IPC::Open3 with "Insecure
# dependency in exec", 60 seconds into a retry loop, having reached multipathd
# exactly zero times.
subtest 'a tainted argument reaches the command instead of dying' => sub {
    # `echo` as the vehicle, not `sh -c '...'`: the allowlist refuses a shell
    # snippet, correctly, and the first version of this test was written with
    # one — so it failed for its own reason rather than the module's.
    my ($out, $err, $rc) = eval {
        $C->can('run_cmd')->([ 'echo', $tainted ], timeout => 10);
    };
    my $died = $@;
    is($died, '', 'no "Insecure dependency" — the argument was untainted on the way through')
        or diag("died with: $died");
    is($out, "$tainted\n", 'and the command received the value unchanged');
};

# Untainting must VALIDATE, not strip. A value this plugin could not have
# produced is refused outright: turning it into a different value and running
# the command anyway is worse than stopping.
subtest 'a value this plugin never produces is refused, not sanitised' => sub {
    for my $bad ("map;rm -rf /", "map\nname", "map name", 'map$(id)', "map`id`", "map'x'") {
        my $err = '';
        eval { $C->can('run_cmd')->([ 'echo', $bad ], timeout => 10); 1 } or $err = $@;
        my $shown = $bad =~ s/\n/\\n/gr;
        like($err, qr/refusing to run/, "refused: '$shown'");
    }
};

subtest 'the ordinary shapes this plugin does produce all pass' => sub {
    my @good = (
        '360014057244bc85d823fd4838da56fdc',            # a WWID
        'mpatha',                                        # a friendly map name
        '/dev/disk/by-id/dm-uuid-mpath-3600140500',      # a device path
        '/sys/block/dm-0/size',                          # a sysfs path
        '--flushbufs', '-m', 'session', '--rescan',      # flags
        'iqn.2000-01.com.synology:nas2.Target-1.abc',    # an IQN
        '1073741824',                                    # a size
    );
    for my $g (@good) {
        my ($out) = $C->can('run_cmd')->([ 'echo', $g ], timeout => 10);
        is($out, "$g\n", "passed through unchanged: $g");
    }
};

# The other half of the daemon environment: no PATH at all. tool_path must not
# consult it, and exec must not be reached with a relative program name.
subtest 'a command still resolves and runs with no PATH in the environment' => sub {
    local %ENV = (%ENV);
    delete $ENV{PATH};
    my ($out, $err, $rc) = $C->can('run_cmd')->([ 'echo', 'ok' ], timeout => 10);
    is($rc, 0, 'it ran');
    is($out, "ok\n", 'and produced its output');
};

done_testing();
