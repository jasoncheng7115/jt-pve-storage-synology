package PVE::Storage::Custom::Synology::Multipath;

# dm-multipath, for Synology LUNs.
#
# The rules inherited from the related projects, which cost real outages there:
#
#   * `multipath -F` (capital F) is NEVER generated. It flushes every unused map
#     on the node, including other vendors' storage and an operator's own
#     hand-built maps. Only ever one named map at a time. `make
#     check-multipath-flush` fails the build on any occurrence.
#   * Flush only after `multipathd disablequeueing map` and
#     `dmsetup message <map> 0 fail_if_no_path`. With queueing on and every path
#     down, a flush waits forever for I/O that can never complete.
#   * `no_path_retry` is a number, never `queue`. `dev_loss_tmo` is never
#     `infinity`.
#   * `multipathd reconfigure` is NODE-WIDE and is permitted in exactly one
#     place: after this plugin's own conf.d drop-in changed. It is never used to
#     make a device appear.
#
# And three that are specific to Synology, all measured on a DS918+:
#
#   1. **`/dev/mapper/<wwid>` cannot be assumed to exist.** The test node runs
#      `user_friendly_names yes`, so multipath named the map `mpathc`. The
#      related projects return `/dev/mapper/<wwid>` from `path()`; here that
#      path is simply absent. `/dev/disk/by-id/dm-uuid-mpath-<wwid>` is always
#      there, and it is what this module hands out. Setting
#      `user_friendly_names no` globally would rename OTHER vendors' maps.
#   2. **There is no built-in multipath entry for Synology** — `multipathd show
#      config` contains no SYNOLOGY stanza at all — so the drop-in below is
#      mandatory rather than tuning. Without it the generic defaults apply, and
#      on the test node those include `no_path_retry "queue"`.
#   3. **`mapping_index` is reused**, so a by-path device name is a hint for
#      finding a candidate and never proof of which LUN it is. Every device is
#      confirmed by the kernel's own WWID before it is used.

use strict;
use warnings;

use PVE::Storage::Custom::Synology::Command qw(
    run_cmd is_block_device sysfs_read_with_timeout
);

# Everything here is a function, not a method. This module and Naming have both
# been called as `Module->function(...)` while being written, and the shifted
# arguments do not error — they quietly produce a default. In Naming that made
# the ownership gate answer "not owned"; here it silently ignored a
# no_path_retry the caller had set. Twice is a pattern, so both modules say so.
sub _not_a_method {
    my ($first) = @_;
    return if !defined $first || $first ne __PACKAGE__;
    die __PACKAGE__ . ": these are functions, not methods. Call"
      . " Multipath::name(...) rather than Multipath->name(...).\n";
}

use constant {
    # Measured from a LUN attached to a node: SCSI INQUIRY reports vendor
    # 'SYNOLOGY' (8 bytes) and product 'Storage' padded to 16. multipath
    # matches these as regular expressions, so the padding is not written here.
    VENDOR  => 'SYNOLOGY',
    PRODUCT => 'Storage',

    CONF_DIR  => '/etc/multipath/conf.d',
    CONF_FILE => '/etc/multipath/conf.d/jt-pve-storage-synology.conf',

    # Bumped whenever the drop-in's content changes, so an upgrade can tell
    # whether the file on disk is this version's.
    CONF_VERSION => 1,
};

# ---------------------------------------------------------------------------
# The configuration drop-in
# ---------------------------------------------------------------------------

sub conf_content {
    _not_a_method($_[0]);
    my (%opt) = @_;
    my $no_path_retry = $opt{no_path_retry} // 18;
    my $version = CONF_VERSION;
    my $vendor  = VENDOR;
    my $product = PRODUCT;

    # `no_path_retry` is a NUMBER. `queue` is what the generic defaults give a
    # Synology LUN on a node with no entry for it, and with queueing on, losing
    # every path is an unkillable hang rather than an I/O error.
    #
    # The device advertises TPGS=1 (implicit ALUA), which is why multipath
    # enables `hwhandler='1 alua'` by itself; `prio alua` and
    # `path_grouping_policy group_by_prio` follow from that and are what a
    # dual-controller UC model would need.
    return <<"EOF";
# jt-pve-storage-synology drop-in
# synology-multipath-config-version: $version
#
# Generated. Do not edit: this file is rewritten when the plugin's
# configuration changes.
#
# multipathd ships no built-in entry for Synology, so without this stanza a
# Synology LUN falls back to the generic defaults — which include
# no_path_retry "queue", and queueing forever is not a failure mode anyone can
# recover from without a reboot.
devices {
    device {
        vendor                  "$vendor"
        product                 "$product"
        path_grouping_policy    group_by_prio
        prio                    alua
        path_checker            tur
        hardware_handler        "1 alua"
        failback                immediate
        rr_weight               uniform
        no_path_retry           $no_path_retry
        fast_io_fail_tmo        5
        dev_loss_tmo            60
    }
}
EOF
}

# Returns 1 if the file changed and multipathd therefore has to be told.
sub write_conf {
    _not_a_method($_[0]);
    my (%opt) = @_;
    my $want = conf_content(%opt);

    my $have = '';
    if (-e CONF_FILE) {
        open(my $fh, '<', CONF_FILE) or die "cannot read " . CONF_FILE . ": $!\n";
        local $/;
        $have = <$fh> // '';
        close($fh);
    }
    return 0 if $have eq $want;

    mkdir CONF_DIR if !-d CONF_DIR;
    my $tmp = CONF_FILE . ".tmp.$$";
    open(my $fh, '>', $tmp) or die "cannot write $tmp: $!\n";
    print $fh $want;
    close($fh) or die "cannot write $tmp: $!\n";
    rename($tmp, CONF_FILE) or die "cannot install " . CONF_FILE . ": $!\n";

    return 1;
}

# NODE-WIDE. The only place it is allowed, and only when the drop-in actually
# changed — multipathd has no per-file reload. Never on a timer, and never to
# make a device appear.
sub reload_config {
    _not_a_method($_[0]);
    my (%opt) = @_;
    eval { run_cmd([ 'multipathd', 'reconfigure' ], timeout => 30) };
    warn "multipathd reconfigure failed: $@" if $@;
    return 1;
}

# ---------------------------------------------------------------------------
# Finding a map from a WWID
# ---------------------------------------------------------------------------

# The stable handle. Present whatever the node's user_friendly_names setting
# is, which /dev/mapper/<wwid> is not.
sub dm_uuid_path {
    _not_a_method($_[0]);
    my ($wwid) = @_;
    return undef if !defined $wwid || $wwid !~ /\A[0-9a-f]{10,}\z/i;
    return '/dev/disk/by-id/dm-uuid-mpath-' . lc($wwid);
}

# The map's device-mapper name (mpathc, or the wwid, or an alias — whatever the
# node's policy produced). Read from the link rather than assumed.
sub map_name_for_wwid {
    _not_a_method($_[0]);
    my ($wwid) = @_;
    my $link = dm_uuid_path($wwid) or return undef;

    # A glob and a file test under /dev are both stat(2) on a path that may be
    # a dead multipath device, so both are bounded.
    my $target = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(5);
        my $t = readlink($link);
        alarm(0);
        $t;
    };
    alarm(0);
    return undef if !defined $target;

    my ($dm) = $target =~ m{([^/]+)\z} or return undef;   # e.g. dm-9
    my $name = sysfs_read_with_timeout("/sys/block/$dm/dm/name", 3);
    return undef if !defined $name;
    chomp $name;
    return length($name) ? $name : undef;
}

# What a caller should open. Returns undef when the map is not there — which is
# an answer, not an error.
sub device_path_for_wwid {
    _not_a_method($_[0]);
    my ($wwid) = @_;
    my $link = dm_uuid_path($wwid) or return undef;
    my $ok = is_block_device($link);
    # undef means the stat never came back. That is NOT "no device": returning
    # a path nobody could confirm is how a caller writes to the wrong thing.
    return undef if !defined $ok || !$ok;
    return $link;
}

# ---------------------------------------------------------------------------
# Confirming a device really is the LUN that was asked for
# ---------------------------------------------------------------------------

# `mapping_index` is reused, so the by-path name that led here proves nothing.
# The kernel's own identification is what decides.
sub wwid_of_device {
    _not_a_method($_[0]);
    my ($dev) = @_;
    return undef if !defined $dev || !length $dev;

    my ($base) = $dev =~ m{([^/]+)\z};
    if (defined $base) {
        my $w = sysfs_read_with_timeout("/sys/block/$base/device/wwid", 3);
        if (defined $w) {
            chomp $w;
            # 'naa.6001405...' — the same identifier multipath uses with a
            # leading 3 instead of the naa. prefix.
            if ($w =~ /naa\.([0-9a-f]+)/i) {
                return '3' . lc($1);
            }
        }
    }

    for my $prog ('/lib/udev/scsi_id', '/usr/lib/udev/scsi_id') {
        next if !-x $prog;
        my $out = eval { run_cmd([ $prog, '-g', '-u', '-d', $dev ],
                                 timeout => 10, allow_nonzero => 1) };
        next if !defined $out;
        chomp $out;
        return lc($out) if $out =~ /\A3[0-9a-f]+\z/i;
    }

    return undef;
}

# The check every caller must pass before touching a device. Returns 1, 0, or
# **undef** for "could not establish" — and undef must never be treated as yes.
sub device_is_lun {
    _not_a_method($_[0]);
    my ($dev, $wwid) = @_;
    return undef if !defined $wwid;
    my $found = wwid_of_device($dev);
    return undef if !defined $found;
    return lc($found) eq lc($wwid) ? 1 : 0;
}

# The sd devices underneath a map.
#
# These are what carry a new size up to the map: rescanning the MAP itself does
# nothing, because /sys/block/dm-N has no device/rescan — and a rescan helper
# that silently returns 0 for a missing file makes that look like it worked. A
# resize appeared to succeed on the NAS while the node went on seeing the old
# size.
#
# Also what a delete path needs: the slave list has to be captured BEFORE the
# map is flushed, because afterwards there is nothing left to ask.
sub slaves_of_map {
    my ($wwid) = @_;
    _not_a_method($_[0]) if @_ && defined $_[0] && $_[0] eq __PACKAGE__;

    my $link = dm_uuid_path($wwid) or return [];
    my $target = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(5);
        my $t = readlink($link);
        alarm(0);
        $t;
    };
    alarm(0);
    return [] if !defined $target;

    my ($dm) = $target =~ m{([^/]+)\z} or return [];

    # Bounded together with the file tests that follow it, not just the glob.
    my @slaves = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(5);
        my @s = glob("/sys/block/$dm/slaves/*");
        alarm(0);
        @s;
    };
    alarm(0);

    my @devs;
    for my $entry (@slaves) {
        # The name used is the one the match RETURNED, not the one read from the
        # directory: it is the taint discipline and the correctness check in one.
        my ($name) = $entry =~ m{/([a-z0-9]+)\z} or next;
        push @devs, "/dev/$name";
    }
    return \@devs;
}

# ---------------------------------------------------------------------------
# Acting on ONE map
# ---------------------------------------------------------------------------

sub claim_path {
    _not_a_method($_[0]);
    my ($sd) = @_;
    return 0 if !defined $sd || $sd !~ /\A[a-z0-9]+\z/;
    # One named path. Not a node-wide reconfigure, which is how a related
    # project came to reconfigure another vendor's storage every few minutes
    # while looking for a disk of its own.
    eval { run_cmd([ 'multipathd', 'add', 'path', $sd ],
                   timeout => 20, allow_nonzero => 1) };
    return $@ ? 0 : 1;
}

sub resize_map {
    _not_a_method($_[0]);
    my ($name) = @_;
    return 0 if !defined $name || !length $name;
    # Refreshes an existing map's size. NOT a host scan: a scan discovers new
    # devices, it does not refresh the ones already there.
    eval { run_cmd([ 'multipathd', 'resize', 'map', $name ],
                   timeout => 30, allow_nonzero => 1) };
    return $@ ? 0 : 1;
}

# Remove ONE map, named. Never every unused map on the node.
sub flush_map {
    _not_a_method($_[0]);
    my ($name, %opt) = @_;
    return 0 if !defined $name || !length $name;

    # Stop queueing first, or the flush waits forever for I/O that can never
    # complete once the paths are gone.
    eval { run_cmd([ 'multipathd', 'disablequeueing', 'map', $name ],
                   timeout => 15, allow_nonzero => 1) };
    eval { run_cmd([ 'dmsetup', 'message', $name, '0', 'fail_if_no_path' ],
                   timeout => 15, allow_nonzero => 1) };

    my ($out, $err, $rc) = eval {
        run_cmd([ 'multipath', '-f', "/dev/mapper/$name" ],
                timeout => 30, allow_nonzero => 1);
    };
    my $failure = $@;

    # Measured: after fail_if_no_path, multipathd may have removed the map
    # already, and `multipath -f` then answers "device not found". That is
    # success. Treating it as an error is how a delete path reports a failure
    # for work that is complete.
    my $text = join(' ', grep { defined } ($out, $err, $failure));
    return 1 if $text =~ /device not found|map not found/i;

    return 0 if $failure;
    return ($rc // 0) == 0 ? 1 : 0;
}

# Is the map gone? Confirmed, not assumed.
sub map_is_gone {
    _not_a_method($_[0]);
    my ($wwid) = @_;

    # An unusable WWID was never asked about, so nothing is known about it.
    # Returning "gone" here would let a delete path conclude the device had
    # been cleaned up when it had not even looked.
    my $link = dm_uuid_path($wwid);
    return undef if !defined $link;

    my $ok = is_block_device($link);
    # undef is "the stat never came back", which is also not "gone".
    return undef if !defined $ok;
    return $ok ? 0 : 1;
}

1;
