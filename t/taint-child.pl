#!/usr/bin/perl -T

# THE CHILD OF t/13-taint.t, AND IT IS A SEPARATE FILE ON PURPOSE.
#
# `pvedaemon` is `#!/usr/bin/perl -T`, so the plugin's real environment is taint
# mode, and a test for it has to run under -T too. But `-T` cannot be turned on
# after Perl has started — `"-T" is on the #! line, it must also be used on the
# command line` — so a test file carrying that shebang depends on the harness
# noticing it and passing the switch through. Test::Harness does; whether every
# version on every distribution does is not something this project can check,
# and a test that silently does not run is worse than no test.
#
# So the parent runs THIS with an explicit `-T` on the command line, and reads
# the results back. The switch is then a fact about how it was invoked rather
# than a hope about how it was interpreted.
#
# Output: one line per case, `ok <name>` or `not ok <name>\t<why>`.

use strict;
use warnings;
use lib 'lib';

$ENV{PATH} = '/usr/sbin:/sbin:/usr/bin:/bin';
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

my @results;
sub result { my ($ok, $name, $why) = @_;
    push @results, ($ok ? "ok $name" : "not ok $name\t" . ($why // '')) }
sub done { print "$_\n" for @results; exit 0 }

require Scalar::Util;
require PVE::Storage::Custom::Synology::Command;
my $C = 'PVE::Storage::Custom::Synology::Command';

result(${^TAINT} ? 1 : 0, 'running under -T',
       'the switch did not reach this process, so nothing below proves anything');

# Tainted the way a sysfs read taints: from OUTSIDE the program. Assigning to
# %ENV and reading it back does NOT taint, and the first version of this test
# did exactly that — it passed while proving nothing.
my $tainted = do {
    open(my $fh, '<', '/proc/sys/kernel/ostype') or die "cannot read ostype: $!";
    my $v = <$fh>; close($fh); chomp $v if defined $v; $v;
};
result(Scalar::Util::tainted($tainted) ? 1 : 0, 'the fixture is genuinely tainted');

# What the resolver found, reported whether or not it worked: when every command
# case fails at once the question is always "was the program found at all", and
# the answer belongs in the output rather than in the next debugging cycle.
{
    my $echo = $C->can('tool_path')->('echo');
    my @dirs = grep { -d $_ } @PVE::Storage::Custom::Synology::Command::TOOL_DIRS;
    result(defined $echo, "tool_path('echo') resolves",
           'got ' . (defined $echo ? $echo : 'undef')
           . '; directories present: ' . (join(' ', @dirs) || 'none'));
}

# The regression: before the fix this died inside IPC::Open3, sixty seconds into
# a retry loop, having reached multipathd exactly zero times.
{
    my ($out) = eval { $C->can('run_cmd')->([ 'echo', $tainted ], timeout => 10) };
    my $err = $@;
    result(!$err, 'a tainted argument reaches the command', $err);
    result((($out // '') eq "$tainted\n") ? 1 : 0,
           'and arrives unchanged', "got: " . ($out // 'undef'));
}

# Untainting VALIDATES. A value this plugin could not have produced is refused,
# not turned into a different value and run anyway.
for my $bad ("map;rm -rf /", "map\nname", "map name", 'map$(id)', "map`id`", "map'x'") {
    my $err = '';
    eval { $C->can('run_cmd')->([ 'echo', $bad ], timeout => 10); 1 } or $err = $@;
    (my $shown = $bad) =~ s/\n/\\n/g;
    result(($err =~ /refusing to run/) ? 1 : 0, "refused: $shown", $err);
}

# And the shapes this plugin really does produce all pass.
for my $good ('360014057244bc85d823fd4838da56fdc', 'mpatha',
              '/dev/disk/by-id/dm-uuid-mpath-3600140500', '/sys/block/dm-0/size',
              '--flushbufs', '-m', 'session', '--rescan',
              'iqn.2000-01.com.synology:nas2.Target-1.abc', '1073741824') {
    my ($out) = eval { $C->can('run_cmd')->([ 'echo', $good ], timeout => 10) };
    result((($out // '') eq "$good\n") ? 1 : 0, "passes through: $good",
           $@ || "got: " . ($out // 'undef'));
}

# No PATH at all, which is what a PVE daemon actually has.
{
    local %ENV = (%ENV);
    delete $ENV{PATH};
    my ($out, $err2, $rc) = eval { $C->can('run_cmd')->([ 'echo', 'ok' ], timeout => 10) };
    result((!$@ && ($out // '') eq "ok\n") ? 1 : 0,
           'a command resolves and runs with no PATH in the environment', $@);
}

# --- the other half of taint mode: FILE operations ---------------------------
#
# run_cmd untaints what reaches a command. `open` for writing, `unlink`, `mkdir`
# and `rename` are restricted just as hard, and a storeid reaches a filename in
# four places. All four sanitised with s///, which does not untaint — only a
# capture does. Three of the four died with "Insecure dependency in unlink",
# and they are the paths `pvesm add` and `pvesm set` take from the GUI.
require PVE::Storage::Custom::Synology::Naming;
my $fc = \&PVE::Storage::Custom::Synology::Naming::filename_component;

result((!defined $fc->(undef)) ? 1 : 0, 'no storeid, no component');
result((!defined $fc->('')) ? 1 : 0, 'an empty storeid yields nothing');
result((!defined $fc->('...')) ? 1 : 0, 'a component that sanitises away is undef');
result((($fc->('syno-nas2') // '') eq 'syno-nas2') ? 1 : 0, 'an ordinary id passes through');
result((($fc->('syno nas/2') // '') eq 'syno_nas_2') ? 1 : 0,
       'anything outside the set becomes an underscore');
result((($fc->('../../etc/shadow') // '') !~ m{/}) ? 1 : 0,
       'a traversal leaves no separator to traverse with');
result((!Scalar::Util::tainted($fc->($tainted))) ? 1 : 0,
       'the RESULT is untainted, which s/// alone never achieved');
result(Scalar::Util::tainted($tainted) ? 1 : 0,
       'while the input still is, so the untainting is the function\'s');

if (eval { require PVE::Tools; 1 }) {
    require PVE::Storage::Custom::Synology::WwidState;
    require PVE::Storage::Custom::SynologySANPlugin;
    require PVE::Storage::Custom::Synology::API;

    my $dir = "/tmp/syno-taint-$$";
    mkdir $dir;
    no warnings 'once';
    local $PVE::Storage::Custom::SynologySANPlugin::CRED_DIR = "$dir/cred";

    my $ok = eval {
        PVE::Storage::Custom::SynologySANPlugin->_write_creds($tainted, { password => 'x' }); 1 };
    result($ok, 'writing a credential file with a tainted storeid', $@);

    $ok = eval { PVE::Storage::Custom::SynologySANPlugin->_delete_creds($tainted); 1 };
    result($ok, 'deleting it', $@);

    $ok = eval { PVE::Storage::Custom::Synology::API->clear_credential_latch($tainted); 1 };
    result($ok, 'clearing the credential latch', $@);

    $ok = eval { PVE::Storage::Custom::Synology::WwidState->new($tainted)->file; 1 };
    result($ok, 'building the WWID state path', $@);

    unlink glob("$dir/cred/*");
    rmdir "$dir/cred";
    rmdir $dir;
}

done();
