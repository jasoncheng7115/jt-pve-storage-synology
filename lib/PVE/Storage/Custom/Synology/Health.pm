package PVE::Storage::Custom::Synology::Health;

# What `status()` answers, and how an outage is reported.
#
# `status()` runs roughly every ten seconds, per node, per storage, and PVE runs
# them sequentially — so anything slow here delays every other storage on the
# node. Two rules follow, and both are inherited:
#
#   * The health path uses the short-timeout, single-attempt client. The next
#     poll is the retry.
#   * **No per-object call.** Capacity comes from one volume read; the LUN count
#     from one listing. (objects × nodes) requests every ten seconds is what
#     collapses a management interface.
#
# And one that is specific to Synology, measured: **capacity can never be
# computed by summing `allocated_size`.** A clone is a reflink — one of a LUN
# holding 512 MiB reported 512 MiB allocated while consuming zero bytes of the
# volume — so the shared blocks are counted for both LUNs and a template with
# twenty linked clones would appear to consume twenty times what it does. The
# volume's own `size_free_byte` is the only honest number.
#
# There is a second reason the numbers here are not the whole story, and it is
# why `lun_pressure` exists: this storage's real ceiling may be the LUN COUNT
# rather than space. A NAS with 10 TB free and 256 of 256 LUNs is full, and PVE
# has no way to express that — `pvesm status` would show terabytes available.

use strict;
use warnings;

use PVE::Storage::Custom::Synology::API;

# A storage whose NAS cannot be reached must report inactive quickly and say why
# once, not on every poll. PVE stops polling a storage it has marked inactive,
# so a consecutive-failure counter would never fire — the report has to happen
# on the first failure.
my %warned;

sub _warn_once {
    my ($key, $msg) = @_;
    return if $warned{$key};
    $warned{$key} = 1;
    warn $msg;
}

sub clear_warnings {
    my ($storeid) = @_;
    delete $warned{$_} for grep { /\A\Q$storeid\E:/ } keys %warned;
    return;
}

# Returns **($total, $available, $used, $active)** in bytes — PVE's own order,
# which is what `PVE::Storage::Plugin::status` returns and NOT the intuitive
# one. Getting it backwards showed the NAS's free space in the Used column, and
# worse: `syno-min-free` then compared against used space, so the guard meant to
# stop a Btrfs volume filling up was reading the wrong number entirely. Only
# running `pvesm status` against the real NAS made it visible — the shape was
# plausible and every unit test passed.
#
# Dies for nothing: an unreachable NAS is reported as inactive, because that is
# what PVE does with the answer, and a die here would make `pvesm status` fail
# for every storage on the node rather than one.
sub status {
    my ($api, $lun, %opt) = @_;
    my $location = $opt{location};
    my $storeid  = $api->storeid;

    my $vol = eval {
        $api->call_ok('SYNO.Core.Storage.Volume', 'get',
            volume_path => PVE::Storage::Custom::Synology::API::json_string($location),
            _what       => "reading the DSM volume $location");
    };
    if (!$vol || $@) {
        my $why = $@ || 'no answer';
        chomp $why;
        _warn_once("$storeid:unreachable",
            "storage '$storeid': the NAS did not answer — $why\n");
        return (0, 0, 0, 0);
    }

    my $v = $vol->{volume};
    if (ref $v ne 'HASH' || !defined $v->{size_total_byte}) {
        _warn_once("$storeid:novolume",
            "storage '$storeid': the NAS answered but described no volume at"
          . " '$location'. Check that the DSM volume still exists.\n");
        return (0, 0, 0, 0);
    }

    my $total = int($v->{size_total_byte} // 0);
    my $free  = int($v->{size_free_byte}  // 0);
    my $used  = $total - $free;

    # A read-only volume is not usable, whatever its free space says.
    if ($v->{readonly}) {
        _warn_once("$storeid:readonly",
            "storage '$storeid': the DSM volume '$location' is READ ONLY."
          . " Nothing can be allocated on it.\n");
        return ($total, 0, $used, 0);
    }

    my $st = $v->{status} // '';
    if ($st ne 'normal') {
        _warn_once("$storeid:volstatus",
            "storage '$storeid': the DSM volume '$location' reports status"
          . " '$st' rather than normal.\n");
    }

    # Btrfs is not a preference: snapshots exist only for a thin LUN on Btrfs.
    my $fs = $v->{fs_type} // '';
    if ($fs ne 'btrfs') {
        _warn_once("$storeid:fstype",
            "storage '$storeid': the DSM volume '$location' is '$fs', not"
          . " btrfs. Snapshots and clones are not available on it.\n");
    }

    # Reported, not deducted: PVE has one number for available space and it
    # should stay the truth about space. The count is what a warning is for.
    lun_pressure($api, $lun, $storeid);

    return ($total, $free, $used, 1);
}

# Warn as the LUN ceiling approaches. One VM disk is one LUN, and no amount of
# free space answers this — so an operator who only ever looks at `pvesm status`
# would get no notice at all.
sub lun_pressure {
    my ($api, $lun, $storeid) = @_;
    return if !$lun;

    my $max = eval { $api->limits->{luns} } or return;

    my $luns = eval { $lun->list };
    return if !$luns;
    my $have = scalar @$luns;
    my $left = $max - $have;

    if ($left <= 0) {
        _warn_once("$storeid:lunfull",
            "storage '$storeid': the NAS holds $have LUNs, this model's maximum"
          . " ($max). No further disks can be created however much space is"
          . " free. The count includes LUNs this storage does not own.\n");
    } elsif ($left <= 16) {
        _warn_once("$storeid:lunnear",
            "storage '$storeid': $have of $max LUNs used on this NAS — $left"
          . " left. One VM disk is one LUN.\n");
    }
    return;
}

# The preconditions that make a storage usable at all, checked when it is added
# rather than discovered at the first snapshot.
#
# A model can run DSM 7.2 and still not support what is needed, and a version
# check would not say why — so this asks the NAS what it can do.
sub assert_usable {
    my ($api, %opt) = @_;
    my $storeid  = $api->storeid;
    my $location = $opt{location};

    my $d = $api->system_define;

    my $fw = ($api->call_ok('SYNO.Core.System', 'info', type => 'firmware',
                            _what => 'reading the DSM version') // {})->{firmware_ver} // '';

    # Two chassis with a floating address are fine. Two controllers in one are
    # implemented but unverified, so they get a warning and not a refusal —
    # claiming otherwise would be the one thing this project will not do.
    if ($fw =~ /DSM\s+UC/) {
        warn "storage '$storeid': this is a dual-controller model ($fw)."
           . " Support for it is implemented from Synology's own CSI logic but"
           . " has NOT been verified on hardware. Please report how it behaves.\n";
    }

    for my $pair ([ support_iscsi_target => 'iSCSI target' ],
                  [ supportsnapshot      => 'snapshots' ],
                  [ support_storage_mgr  => 'Storage Manager' ]) {
        next if ($d->{ $pair->[0] } // '') eq 'yes';
        die "storage '$storeid': this NAS reports that it does not support"
          . " $pair->[1] ($pair->[0] is not 'yes'). That is a property of the"
          . " model, not of the DSM version.\n";
    }

    my $vol = $api->call_ok('SYNO.Core.Storage.Volume', 'get',
        volume_path => PVE::Storage::Custom::Synology::API::json_string($location),
        _what       => "reading the DSM volume $location");
    my $v = $vol->{volume};
    die "storage '$storeid': there is no DSM volume at '$location'. Use a path"
      . " such as /volume1, as SAN Manager shows it.\n" if ref $v ne 'HASH';

    my $fs = $v->{fs_type} // '';
    die "storage '$storeid': the DSM volume '$location' is '$fs'. This plugin"
      . " requires **btrfs**, because a thin LUN only supports snapshots and"
      . " restore on a Btrfs volume — refused now rather than at your first"
      . " snapshot.\n" if $fs ne 'btrfs';

    die "storage '$storeid': the DSM volume '$location' is read only.\n"
        if $v->{readonly};

    return 1;
}

# The NAS's own identity, for `get_identity` and for refusing a second storage
# that would collide. Pinned to this rather than to the address, because an
# address can be re-pointed at a different NAS.
sub node_uuid {
    my ($api) = @_;
    my $d = eval {
        $api->call_ok('SYNO.Core.ISCSI.Node', 'list',
            _what => 'reading the NAS identity');
    };
    return undef if !$d || ref $d->{nodes} ne 'ARRAY' || !@{ $d->{nodes} };
    return $d->{nodes}[0]{uuid};
}

1;
