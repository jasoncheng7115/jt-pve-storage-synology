#!/usr/bin/perl
# The multipath layer. These are the rules that cost outages in the related
# projects, plus three findings specific to Synology.
use strict; use warnings; use Test::More; use lib 'lib';
use_ok('PVE::Storage::Custom::Synology::Multipath');
my $M = 'PVE::Storage::Custom::Synology::Multipath';
*dmp = \&PVE::Storage::Custom::Synology::Multipath::dm_uuid_path;

# --- the stable handle ------------------------------------------------------
# /dev/mapper/<wwid> does not exist on a node with user_friendly_names yes,
# which the test node has. This one always does.
is(dmp('3600140513a3cd1edf296d4d4bdb712da'),
   '/dev/disk/by-id/dm-uuid-mpath-3600140513a3cd1edf296d4d4bdb712da',
   'a WWID maps to its dm-uuid link, not to /dev/mapper/<wwid>');
is(dmp('3600140513A3CD1EDF296D4D4BDB712DA'),
   '/dev/disk/by-id/dm-uuid-mpath-3600140513a3cd1edf296d4d4bdb712da',
   'the link is lower case whatever the caller had');
is(dmp(undef), undef, 'undef in, undef out');
is(dmp(''), undef, 'an empty WWID yields no path');
is(dmp('not-a-wwid'), undef, 'a malformed WWID yields no path rather than a wrong one');
is(dmp('../../etc/passwd'), undef, 'a traversal attempt cannot become a device path');

# --- the drop-in, which is mandatory because DSM has no built-in entry ------
my $conf = PVE::Storage::Custom::Synology::Multipath::conf_content();
like($conf, qr/vendor\s+"SYNOLOGY"/, 'the vendor string as SCSI INQUIRY reports it');
like($conf, qr/product\s+"Storage"/, 'the product string');
like($conf, qr/prio\s+alua/, 'ALUA, because the device reports TPGS=1');
like($conf, qr/hardware_handler\s+"1 alua"/, 'and the handler multipath enables by itself');
like($conf, qr/no_path_retry\s+\d+/, 'no_path_retry is a NUMBER');
unlike($conf, qr/no_path_retry\s+queue/,
       'never queue — that is what the generic defaults give a Synology LUN, and it hangs');
unlike($conf, qr/dev_loss_tmo\s+infinity/, 'dev_loss_tmo is never infinity');
like($conf, qr/synology-multipath-config-version/, 'the file records its own version');
like(PVE::Storage::Custom::Synology::Multipath::conf_content(no_path_retry => 7), qr/no_path_retry\s+7/, 'the retry count is settable');

# The guard in the Makefile scans for this, but assert it here too: this string
# in generated content would flush every unused map on the node.
unlike($conf, qr/multipath\s+-F/, 'the drop-in cannot contain a node-wide flush');

# --- a device must be confirmed by the kernel, because mapping_index is reused
*isdev = \&PVE::Storage::Custom::Synology::Multipath::device_is_lun;
is(isdev('/dev/does-not-exist', '3600140500000000000000000000000000'), undef,
   'a device whose WWID cannot be read gives UNDEF, not 0 — "could not tell" is not "no"');
is(isdev('/dev/does-not-exist', undef), undef, 'without a WWID to compare, undef');

# --- map_is_gone must not report "gone" when it could not look ---------------
*gone = \&PVE::Storage::Custom::Synology::Multipath::map_is_gone;
ok(gone('3600140500000000000000000000000000'),
   'a WWID with no device present is reported gone');
is(gone('not-a-wwid'), undef,
   'an unusable WWID gives undef, not "gone" — a delete path must not conclude it looked');
eval { PVE::Storage::Custom::Synology::Multipath->conf_content(no_path_retry => 7) };
like($@, qr/functions, not methods/,
     'a method call is refused, because the shifted argument silently became a default');

# --- the sizes the kernel is presenting -------------------------------------
# /sys/block/<dev>/size is in 512-byte sectors whatever the disk's logical block
# size is. An unreadable size is undef and never 0: a resize that compared
# against 0 would conclude the map had already grown.
*devsize = \&PVE::Storage::Custom::Synology::Multipath::device_size_bytes;
*mapsize = \&PVE::Storage::Custom::Synology::Multipath::map_size_bytes;
is(devsize(undef), undef, 'no device, no size');
is(devsize('/dev/does-not-exist-here'), undef, 'a device that is not there has no size, not zero');
is(devsize('../../etc/passwd'), undef, 'a traversal attempt cannot be read as a size');
is(mapsize('not-a-wwid'), undef, 'an unusable WWID gives undef rather than a size');
is(mapsize('3600140500000000000000000000000000'), undef,
   'a WWID with no map present has no size');

# It must actually read a real one, or the undefs above prove only that the
# function always fails.
SKIP: {
    my ($real) = grep { -r "/sys/block/$_/size" }
                 map  { s{.*/}{}r }
                 glob('/sys/block/*');
    skip 'no block device on this machine to read', 2 if !defined $real;
    my $sz = devsize($real);
    ok(defined $sz, "a real device ($real) reports a size");
    is($sz % 512, 0, 'and it is expressed in bytes, converted from 512-byte sectors');
}

# --- grow_map: the udev race that made a resize fail silently ----------------
# multipathd answers `resize map` from its own udev view of a path. Right after
# the sysfs rescan that view is stale, so it finds the sizes equal, reports
# SUCCESS and leaves the map short. Measured on host-108 on 2026-08-07.
{
    no warnings 'redefine', 'once';
    my $M = 'PVE::Storage::Custom::Synology::Multipath';
    my @resize_calls;
    local *PVE::Storage::Custom::Synology::Multipath::resize_map =
        sub { push @resize_calls, $_[0]; return 1 };

    # The map is already big enough: nothing is asked of multipathd at all.
    local *PVE::Storage::Custom::Synology::Multipath::map_size_bytes = sub { 100 };
    my $r = $M->can('grow_map')->('wwid', 'mpatha', 100, ['/dev/sda'], timeout => 0);
    ok($r->{ok}, 'a map already at the requested size succeeds');
    is(scalar @resize_calls, 0, 'and multipathd is not asked to do anything');

    # The paths are still short. Asking multipathd now is the no-op that
    # reported success, so it is not asked.
    @resize_calls = ();
    local *PVE::Storage::Custom::Synology::Multipath::map_size_bytes = sub { 50 };
    local *PVE::Storage::Custom::Synology::Multipath::device_size_bytes = sub { 50 };
    $r = $M->can('grow_map')->('wwid', 'mpatha', 100, ['/dev/sda'], timeout => 0);
    is($r->{ok}, 0, 'a map that stayed short is NOT reported as grown');
    is($r->{paths_ready}, 0, 'and the caller is told the paths were the reason');
    is(scalar @resize_calls, 0, 'multipathd is not asked while a path is still short');

    # The paths caught up but the map did not follow: that is multipathd's
    # problem to be told about, and the distinction changes the advice given.
    @resize_calls = ();
    local *PVE::Storage::Custom::Synology::Multipath::device_size_bytes = sub { 100 };
    $r = $M->can('grow_map')->('wwid', 'mpatha', 100, ['/dev/sda'], timeout => 0);
    is($r->{ok}, 0, 'a map that will not grow is still a failure');
    is($r->{paths_ready}, 1, 'reported as the map lagging, not the paths');
    ok(scalar @resize_calls > 0, 'and multipathd was asked, once the paths were ready');

    # A size that cannot be read is never success — that is the whole shape of
    # this project's safety rule in one line.
    local *PVE::Storage::Custom::Synology::Multipath::map_size_bytes = sub { undef };
    $r = $M->can('grow_map')->('wwid', 'mpatha', 100, ['/dev/sda'], timeout => 0);
    is($r->{ok}, 0, 'an unreadable map size is not "big enough"');
    is($r->{size}, undef, 'and it is reported as unknown rather than as a number');

    # multipathd could not be RUN. That is not the map declining to grow, and
    # reporting it as such is what happened for a whole 60-second retry loop:
    # three hundred failures, no output, and an error blaming the map.
    {
        my @tried;
        local *PVE::Storage::Custom::Synology::Multipath::map_size_bytes = sub { 50 };
        local *PVE::Storage::Custom::Synology::Multipath::device_size_bytes = sub { 100 };
        local *PVE::Storage::Custom::Synology::Multipath::resize_map = sub {
            push @tried, $_[0];
            return 0;
        };
        local *PVE::Storage::Custom::Synology::Multipath::last_resize_error =
            sub { "'multipathd' was not found in /usr/sbin, /sbin" };
        my $f = $M->can('grow_map')->('wwid', 'mpatha', 100, ['/dev/sda'],
                                      timeout => 30, pause => 0);
        is($f->{ok}, 0, 'a command that could not run is not success');
        like($f->{cmd_error}, qr/multipathd.*not found/,
             'and the caller is told WHY, not just that the map is short');
        is(scalar @tried, 1,
           'it stops after the first failure — retrying a missing binary for'
           . ' 30s is 30s spent not telling anyone');
    }

    # The map catches up on a later poll, which is the real-world case: the
    # first ask is the no-op, the second lands after udev has caught up.
    my @sizes = (50, 50, 100);
    local *PVE::Storage::Custom::Synology::Multipath::map_size_bytes =
        sub { @sizes > 1 ? shift @sizes : $sizes[0] };
    $r = $M->can('grow_map')->('wwid', 'mpatha', 100, ['/dev/sda'],
                               timeout => 5, pause => 0);
    ok($r->{ok}, 'a map that catches up on a retry succeeds');
    is($r->{size}, 100, 'and reports the size it ended up at');
}

# --- the cache helpers are THREE-valued, and the middle case broke rollback ---
#
# PVE requires a VM to be STOPPED before a disk rollback, and a stopped VM has
# been deactivated — so the device is gone from this node and there is nothing
# to flush. That is the safest state there is. Returning a bare 0 for it made it
# indistinguishable from "the flush failed", and every rollback from a clean
# stop was refused by the guard added one release earlier.
{
    my $M = 'PVE::Storage::Custom::Synology::Multipath';
    is($M->can('flush_device_cache')->('3600140500000000000000000000000000'), undef,
       'no device on this node: undef, not 0 — there is nothing to flush');
    is($M->can('invalidate_device_cache')->('3600140500000000000000000000000000'), undef,
       'and the same for the invalidation after a rollback');
    is($M->can('flush_device_cache')->('not-a-wwid'), undef,
       'an unusable WWID resolves to no device rather than to a failure');
}

# The plugin must read them with `defined` first. Checked in the source, because
# the bug was a bare negation and a bare negation compiles perfectly.
{
    open(my $fh, '<', 'lib/PVE/Storage/Custom/SynologySANPlugin.pm')
        or BAIL_OUT('cannot read the plugin');
    my $src = do { local $/; <$fh> };
    close($fh);
    (my $code = $src) =~ s/^\s*#.*$//mg;   # strip comments: they discuss this
    unlike($code, qr/!\s*PVE::Storage::Custom::Synology::Multipath::(?:flush|invalidate)_device_cache/,
           'no call site bare-negates a three-valued cache helper');
}

done_testing();
