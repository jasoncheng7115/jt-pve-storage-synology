package PVE::Storage::Custom::Synology::ISCSI;

# iscsiadm: node records, sessions, portals, and finding a candidate device.
#
# The decision that shapes this module: **`iscsiadm -m discovery` is never
# used.** A SendTargets discovery against a DSM portal creates a node record for
# EVERY target on that NAS — including the operator's own, and including one
# that a Proxmox Backup Server is already using. On a node where
# `node.startup = automatic` those records would then be logged in to at boot,
# which is a Proxmox VE node attaching itself to storage nobody asked it to
# attach to.
#
# So a node record is created directly, for one target and one portal, with
# `-o new`. It costs one extra call and it cannot touch anything else. This was
# not theoretical: the test NAS has three targets belonging to its owner, one of
# them in use, and the first manual attach of this project deliberately avoided
# discovery for exactly this reason.
#
# Two further things measured on the test NAS:
#
#   * The by-path name contains the target's `mapping_index`, and that index is
#     REUSED. So by-path finds a CANDIDATE device and never identifies one:
#     every device goes through Multipath::device_is_lun before it is used.
#   * Both of the NAS's data addresses were on one subnet, where Linux sends
#     both sessions out of whichever interface the route table prefers — giving
#     two sessions over one link and a map that looks redundant and is not. An
#     `iface` per portal is the fix, and it is a node-side one.

use strict;
use warnings;

use PVE::Storage::Custom::Synology::Command qw(run_cmd is_block_device);

use constant {
    PORT => 3260,
    # A node record this plugin created is never logged in to by anything but
    # this plugin. PVE activates a volume when it wants it.
    STARTUP => 'manual',
};

sub _iscsiadm {
    my (@args) = @_;
    # allow_nonzero throughout: iscsiadm's exit codes carry meaning that the
    # callers below interpret, and "already logged in" is not a failure.
    my ($out, $err, $rc) = run_cmd([ 'iscsiadm', @args ],
        timeout => 60, allow_nonzero => 1);
    return ($out // '', $err // '', $rc // 0);
}

sub is_available {
    my ($out, $err, $rc) = eval { _iscsiadm('-m', 'session') };
    return 0 if $@;
    # 21 is "no active sessions", which means iscsiadm works fine.
    return ($rc == 0 || $rc == 21) ? 1 : 0;
}

sub portal_string {
    my ($portal, $port) = @_;
    return undef if !defined $portal || !length $portal;
    return $portal if $portal =~ /:\d+\z/ && $portal !~ /\]\z/;
    return $portal . ':' . ($port // PORT);
}

# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------

# [ { portal, iqn, sid }, ... ]. Parsed from `-m session`, whose output is
# pinned to C by the command runner — util-linux and open-iscsi ship
# translations, and a parser written against English matches nothing on a zh_TW
# node. Silently.
sub sessions {
    my ($out) = _iscsiadm('-m', 'session');
    my @s;
    for my $line (split /\n/, $out) {
        # tcp: [3] 192.0.2.10:3260,1 iqn.2000-01.com.synology:x (non-flash)
        next if $line !~ /^\s*\w+:\s*\[(\d+)\]\s+(\S+?),\S*\s+(\S+)/;
        push @s, { sid => $1, portal => $2, iqn => $3 };
    }
    return \@s;
}

sub has_session {
    my ($iqn, $portal) = @_;
    my $want = portal_string($portal);
    for my $s (@{ sessions() }) {
        next if $s->{iqn} ne $iqn;
        return 1 if !defined $want;
        return 1 if $s->{portal} eq $want;
    }
    return 0;
}

# ---------------------------------------------------------------------------
# Node records
# ---------------------------------------------------------------------------

# Created directly. See the note at the top of this file about why discovery is
# never used.
sub node_add {
    my ($iqn, $portal, %opt) = @_;
    my $p = portal_string($portal, $opt{port}) or die "no portal given\n";

    my @iface = $opt{iface} ? ('-I', $opt{iface}) : ();

    my (undef, $err, $rc) = _iscsiadm('-m', 'node', '-T', $iqn, '-p', $p, @iface, '-o', 'new');
    # An existing record is the desired state, not an error.
    if ($rc != 0 && $err !~ /already exists/i) {
        # Matching the text is a last resort here and only to tolerate a
        # duplicate: iscsiadm has no distinct code for it. The next call
        # settles whether the record is really there.
        my ($chk) = _iscsiadm('-m', 'node', '-T', $iqn, '-p', $p);
        die "could not create an iSCSI node record for $iqn at $p: $err"
            if $chk !~ /\Q$iqn\E/;
    }

    # Never automatic: a record this plugin created must not be logged in to at
    # boot behind PVE's back.
    _iscsiadm('-m', 'node', '-T', $iqn, '-p', $p, @iface,
             '-o', 'update', '-n', 'node.startup', '-v', STARTUP);

    # A number, never a value that queues forever. This is the session-level
    # equivalent of the multipath rule.
    if (defined $opt{replacement_timeout}) {
        _iscsiadm('-m', 'node', '-T', $iqn, '-p', $p, @iface, '-o', 'update',
                 '-n', 'node.session.timeo.replacement_timeout',
                 '-v', $opt{replacement_timeout});
    }

    if (defined $opt{chap_user} && length $opt{chap_user}) {
        for my $pair ([ 'node.session.auth.authmethod', 'CHAP' ],
                      [ 'node.session.auth.username', $opt{chap_user} ],
                      [ 'node.session.auth.password', $opt{chap_password} // '' ]) {
            _iscsiadm('-m', 'node', '-T', $iqn, '-p', $p, @iface,
                     '-o', 'update', '-n', $pair->[0], '-v', $pair->[1]);
        }
    }

    return 1;
}

# One target, one portal. Never `-m node --logoutall`, which would drop every
# other storage's sessions on the node.
sub node_delete {
    my ($iqn, $portal, %opt) = @_;
    my $p = portal_string($portal, $opt{port}) or return 0;
    my @iface = $opt{iface} ? ('-I', $opt{iface}) : ();
    my (undef, undef, $rc) = _iscsiadm('-m', 'node', '-T', $iqn, '-p', $p,
                                       @iface, '-o', 'delete');
    return $rc == 0 ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Login and logout
# ---------------------------------------------------------------------------

sub login {
    my ($iqn, $portal, %opt) = @_;
    my $p = portal_string($portal, $opt{port}) or die "no portal given\n";

    return 1 if has_session($iqn, $p);

    node_add($iqn, $p, %opt);

    my @iface = $opt{iface} ? ('-I', $opt{iface}) : ();
    my ($out, $err, $rc) = _iscsiadm('-m', 'node', '-T', $iqn, '-p', $p,
                                     @iface, '--login');

    return 1 if $rc == 0;
    # 15 is "already logged in", which is the state being asked for.
    return 1 if $rc == 15;
    # Whatever iscsiadm said, the session table is the authority.
    return 1 if has_session($iqn, $p);

    die "could not log in to $iqn at $p: " . ($err || $out || "exit $rc") . "\n";
}

# Logs out of ONE target at ONE portal. A caller that wants a device gone must
# deal with the multipath map first — see Multipath::flush_map — because
# logging out from under a live map leaves the map with no paths.
sub logout {
    my ($iqn, $portal, %opt) = @_;
    my $p = portal_string($portal, $opt{port});
    my @where = defined $p ? ('-p', $p) : ();
    my @iface = $opt{iface} ? ('-I', $opt{iface}) : ();

    my (undef, undef, $rc) = _iscsiadm('-m', 'node', '-T', $iqn, @where,
                                       @iface, '--logout');
    return 1 if $rc == 0;
    # Gone already is the desired state.
    return 1 if !has_session($iqn, $p);
    return 0;
}

# Rescan ONE session, for LUNs mapped after it was established.
#
# A login discovers the LUNs mapped at that moment. Map another LUN to the same
# target afterwards — which is what every allocation after the first does — and
# no device appears until the session is rescanned. The first end-to-end run
# through `pvesm` missed this because every earlier test logged in fresh.
#
# `-m node -T <iqn> -p <portal> -R`, never `-m session --rescan`: the latter
# rescans EVERY session on the node, including other vendors' storage.
sub rescan_session {
    my ($iqn, $portal, %opt) = @_;
    my $p = portal_string($portal, $opt{port}) or return 0;
    return 0 if !has_session($iqn, $p);

    my @iface = $opt{iface} ? ('-I', $opt{iface}) : ();
    my (undef, undef, $rc) = _iscsiadm('-m', 'node', '-T', $iqn, '-p', $p,
                                       @iface, '--rescan');
    return $rc == 0 ? 1 : 0;
}

# ---------------------------------------------------------------------------
# ifaces, for two portals on one subnet
# ---------------------------------------------------------------------------

# Without this, Linux sends both sessions out of whichever interface the route
# table prefers: two sessions over one physical link, and a multipath map that
# looks redundant while having a single point of failure. Measured on the test
# NAS, whose two data addresses are on one subnet.
sub ensure_iface {
    my ($name, $nic) = @_;
    return 0 if !defined $name || $name !~ /\A[A-Za-z0-9_.-]+\z/;

    my ($out) = _iscsiadm('-m', 'iface');
    if ($out !~ /^\Q$name\E\s/m) {
        my (undef, $err, $rc) = _iscsiadm('-m', 'iface', '-I', $name, '-o', 'new');
        return 0 if $rc != 0 && $err !~ /already exists/i;
    }

    if (defined $nic && length $nic) {
        _iscsiadm('-m', 'iface', '-I', $name, '-o', 'update',
                 '-n', 'iface.net_ifacename', '-v', $nic);
    }
    return 1;
}

# ---------------------------------------------------------------------------
# Finding a candidate device
# ---------------------------------------------------------------------------

# The by-path name, which is where a device for this LUN would appear.
#
# `mapping_index` is REUSED, so this locates a candidate and proves nothing
# about which LUN it is. Confirm with Multipath::device_is_lun before use.
sub by_path_for {
    my ($portal, $iqn, $mapping_index, %opt) = @_;
    my $p = portal_string($portal, $opt{port}) or return undef;
    return undef if !defined $iqn || !defined $mapping_index;
    return "/dev/disk/by-path/ip-$p-iscsi-$iqn-lun-$mapping_index";
}

# Waits for the candidate to appear, bounded. Returns the resolved device node,
# or undef — never a path nobody confirmed exists.
sub wait_for_by_path {
    my ($path, %opt) = @_;
    my $limit = $opt{timeout} // 20;
    return undef if !defined $path;

    my $deadline = time + $limit;
    while (time <= $deadline) {
        # is_block_device is bounded: a stat on a path under /dev can land in
        # the same uninterruptible sleep that hangs vgs.
        my $ok = is_block_device($path);
        if (defined $ok && $ok) {
            my $target = eval {
                local $SIG{ALRM} = sub { die "timeout\n" };
                alarm(5);
                my $t = readlink($path);
                alarm(0);
                $t;
            };
            alarm(0);
            return $path if !defined $target;
            my ($dev) = $target =~ m{([^/]+)\z};
            return defined $dev ? "/dev/$dev" : $path;
        }
        select(undef, undef, undef, 0.25);
    }
    return undef;
}

# Tell the kernel to forget one dead sd device.
#
# Needed because deleting the LUN on the NAS does NOT make its device disappear
# here: the iSCSI session is still up, so the sd node survives as a dead device
# and multipathd re-adds a map for it. Flushing the map before the delete is
# therefore not enough on its own — the residual path has to go too, or a stale
# map is left behind for a LUN that no longer exists.
sub remove_sd_device {
    my ($dev) = @_;
    return 0 if !defined $dev;
    my ($base) = $dev =~ m{([^/]+)\z} or return 0;
    return 0 if $base !~ /\A[a-z]+[0-9]*\z/;

    my $path = "/sys/block/$base/device/delete";
    return 0 if !-w $path;

    require PVE::Storage::Custom::Synology::Command;
    return PVE::Storage::Custom::Synology::Command::sysfs_write_with_timeout($path, '1', 10);
}

# Ask the kernel to re-read one device's capacity after a resize.
#
# NOT a host scan: a scan discovers new devices, it does not refresh the ones
# already there — and writing to a scan file has cost 600 seconds of D-state
# per write on a RAID controller in a related project.
sub rescan_device {
    my ($dev) = @_;
    return 0 if !defined $dev;
    my ($base) = $dev =~ m{([^/]+)\z} or return 0;
    return 0 if $base !~ /\A[a-z0-9]+\z/;

    my $path = "/sys/block/$base/device/rescan";
    # A missing rescan file means this is not an sd device — most likely a
    # multipath MAP was passed instead of one of its slaves. Returning 0 quietly
    # made a resize look as though it had propagated when it had not.
    if (!-w $path) {
        warn "cannot rescan $dev: $path is not writable. A multipath map has no"
           . " rescan file — pass its slave devices instead.\n";
        return 0;
    }

    require PVE::Storage::Custom::Synology::Command;
    return PVE::Storage::Custom::Synology::Command::sysfs_write_with_timeout($path, '1', 10);
}

1;
