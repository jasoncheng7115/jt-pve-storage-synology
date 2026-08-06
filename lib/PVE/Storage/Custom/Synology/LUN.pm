package PVE::Storage::Custom::Synology::LUN;

# LUN and snapshot operations, on top of Synology::API.
#
# Almost every decision here was earned against a DS918+ on DSM 7.1.1 rather
# than read from either public reference client. The four that matter most:
#
#   1. A create that reports FAILURE can create the LUN anyway. A 255-character
#      name is refused with 18990068 and the LUN is made regardless: correct
#      size, status normal, entirely usable. So a failed create is never
#      believed — `create` looks the name up afterwards and adopts or removes
#      what it finds. Believing the refusal leaks a LUN that Proxmox VE has no
#      record of, and the retry makes another.
#
#   2. The types filter Synology's own CSI driver sends HIDES LUNs. On the test
#      NAS its twelve-type list returned three where an unfiltered listing
#      returned four, missing a Virtual Machine Manager virtual disk whose
#      120 GiB comes out of the same volume. Listings here are never filtered
#      server-side; ownership is decided locally, on the name.
#
#   3. `can_snapshot` and `emulate_tpu` default to 0. A LUN created without
#      asking for them cannot be snapshotted and never returns freed space.
#
#   4. Nothing refuses a delete for dependency reasons — not a LUN with
#      snapshots, not a snapshot with a live clone, and not a MAPPED LUN. The
#      first two save work; the third moves it here, so unmapping before
#      deleting is entirely this plugin's responsibility.

use strict;
use warnings;

# Imported explicitly, not relied on from API.pm. `perl -c` compiles a call to
# a function another module happened to load, and the day that module stops
# loading it, this one breaks somewhere unrelated.
use JSON qw(encode_json);

use PVE::Storage::Custom::Synology::API;

use constant {
    API_LUN => 'SYNO.Core.ISCSI.LUN',

    # Thin, on Btrfs. The only combination that supports snapshots.
    LUN_TYPE_THIN => 'BLUN',

    # The knowledge centre documents a 1 GB minimum and the API does NOT
    # enforce it — a one-byte LUN was created without complaint. So it is
    # enforced here, or a storage would rely on undocumented behaviour.
    MIN_SIZE => 1024 * 1024 * 1024,

    # 200 characters were accepted exactly; 255 was refused-but-created and
    # 256 cleanly refused. Nothing here needs a name anywhere near this, and
    # keeping well clear of the boundary is what avoids finding 1 again.
    MAX_NAME => 128,

    # A 1 GiB create cleared in 1.2 s and a clone of a LUN holding 512 MiB in
    # 3.5 s. A clone of a few hundred GiB could take far longer, so the bound
    # is generous and the caller is told what is being waited for. Synology's
    # own CSI driver gives up after 20 s, which would be too short here.
    LOCK_WAIT_DEFAULT => 300,
};

# Synology's target is LIO-based, so the WWID begins with LIO's IEEE company
# identifier — but this is NOT stock LIO behaviour and reading the upstream
# source gives a confidently wrong answer. Upstream converts the unit serial
# with hex_to_bin() and SKIPS every non-hex character, which would drop the
# hyphens. Synology maps them to 'd'. Confirmed against two independent LUNs.
#
# Note the truncation: the last characters of the uuid are discarded, so this
# is not reversible and two uuids differing only in their tails would collide.
# The value is a CROSS-CHECK. What the plugin acts on is the kernel's own
# identification of the device.
sub wwid_for_uuid {
    my ($uuid) = @_;
    return undef if !defined $uuid;
    my ($clean) = $uuid =~ /\A([0-9a-fA-F-]{36})\z/ or return undef;
    my $vendor = lc $clean;
    $vendor =~ tr/-/d/;
    return '3' . '6001405' . substr($vendor, 0, 25);
}

sub new {
    my ($class, $api) = @_;
    return bless { api => $api }, $class;
}

sub api { return $_[0]->{api} }

# ---------------------------------------------------------------------------
# Names
# ---------------------------------------------------------------------------

# Measured: `_`, space, `+` and `@` are refused with 18990503. `-`, `.`, `:`,
# digits and upper case are accepted.
#
# The underscore is the one that matters. A Proxmox VE storage id may contain
# one, so folding a storage id into a LUN name has to sanitise it — which is
# how two different storage ids come to fold to the same prefix, and why the
# plugin must refuse the second such storage rather than let each delete the
# other's disks.
my $LEGAL_NAME = qr/\A[A-Za-z0-9][A-Za-z0-9.:\-]*\z/;

sub name_is_legal {
    my ($name) = @_;
    return 0 if !defined $name || !length $name;
    return 0 if length($name) > MAX_NAME;
    return $name =~ $LEGAL_NAME ? 1 : 0;
}

sub assert_name_legal {
    my ($name) = @_;
    return if name_is_legal($name);
    my $shown = defined $name ? "'$name'" : 'undef';
    my $why = !defined $name || !length $name  ? 'it is empty'
            : length($name) > MAX_NAME          ? 'it is longer than ' . MAX_NAME . ' characters'
            : 'DSM rejects _ (underscore), space, + and @ in a LUN name';
    # Refused here rather than at the NAS deliberately: at one length DSM
    # refuses a name AND creates the LUN anyway.
    die "LUN name $shown cannot be used: $why\n";
}

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

# Listed WITHOUT a types filter — see note 2 at the top of this file.
sub list {
    my ($self, %opt) = @_;

    my %p = (additional => '["allocated_size","status","is_action_locked"]');
    $p{location} = $opt{location} if defined $opt{location};

    my $r = $self->api->call(API_LUN, 'list', %p);
    if (!$r->{success}) {
        my $why = $r->{transport} // PVE::Storage::Custom::Synology::API::error_text($r->{error});
        die "storage '" . $self->api->storeid . "': could not list LUNs — $why\n";
    }

    my $luns = $r->{data}{luns};
    # An answer that is not a list is not an empty list. Callers decide what
    # may be deleted from this.
    die "storage '" . $self->api->storeid . "': the LUN listing was not a list\n"
        if ref $luns ne 'ARRAY';

    return [ grep { ref $_ eq 'HASH' && defined $_->{uuid} } @$luns ];
}

# `get`'s uuid parameter accepts a NAME as well, which Cinder has relied on in
# production for years — so a LUN can be found by name without a server-side
# filter, and this plugin never has to tell "the filter matched nothing" apart
# from "there is nothing there".
#
# Returns undef for absent and DIES for unreachable. Those are different
# answers and only the first may be reported as a completed delete.
sub get {
    my ($self, $handle) = @_;
    return undef if !defined $handle || !length $handle;

    my $r = $self->api->call(API_LUN, 'get',
        uuid       => $handle,
        additional => '["allocated_size","status","is_action_locked"]',
    );

    if ($r->{success}) {
        my $lun = $r->{data}{lun};
        return undef if ref $lun ne 'HASH';
        # Verify the answer is about what was asked for. A lookup by name that
        # returns some other object is worse than one that returns nothing.
        if ($handle !~ /\A[0-9a-fA-F-]{36}\z/) {
            return undef if ($lun->{name} // '') ne $handle;
        }
        return $lun;
    }

    my $code = $r->{error};
    return undef if defined $code && ($code == 18990531 || $code == 18990505);

    my $why = $r->{transport} // PVE::Storage::Custom::Synology::API::error_text($code);
    die "storage '" . $self->api->storeid . "': could not look up LUN '$handle' — $why\n";
}

sub exists_by_name {
    my ($self, $name) = @_;
    return defined $self->get($name) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# is_action_locked
# ---------------------------------------------------------------------------

sub wait_unlocked {
    my ($self, $uuid, %opt) = @_;
    my $limit = $opt{timeout} // LOCK_WAIT_DEFAULT;
    my $what  = $opt{what} // 'the operation';

    my $t0 = time;
    while (time - $t0 < $limit) {
        my $lun = $self->get($uuid);
        # Gone is not locked. A caller that deleted it races us legitimately.
        return 1 if !defined $lun;
        return 1 if !$lun->{is_action_locked};
        # Sub-second, and it matters. `sleep 1` stood here, while the register
        # records the lock clearing in 0.20s after a snapshot and 1.2s after a
        # 1 GiB create — so a 0.2s wait cost a full second, every time, inside
        # PVE's cluster lock. `select` is how the rest of this codebase sleeps for
        # less than a second; `.perlcriticrc` records why.
        select(undef, undef, undef, 0.2);
    }

    # A timeout here means the NAS is still working, not that it failed. Saying
    # "failed" invites a retry, and a retried clone makes a second one.
    die "storage '" . $self->api->storeid . "': the NAS is still busy with"
      . " $what on LUN $uuid after ${limit}s. It has not failed — check SAN"
      . " Manager before retrying, because retrying may duplicate it.\n";
}

# ---------------------------------------------------------------------------
# Creating
# ---------------------------------------------------------------------------

sub _dev_attribs {
    my (%opt) = @_;
    # can_snapshot and emulate_tpu are 0 unless asked for. Without the first
    # there are no snapshots at all; without the second a thin LUN never
    # returns freed space and discard does nothing.
    my @a = (
        { dev_attrib => 'can_snapshot',  enable => 1 },
        { dev_attrib => 'emulate_tpu',   enable => ($opt{discard} // 1) ? 1 : 0 },
    );
    return encode_json(\@a);
}

# Refuse BEFORE the NAS does, so the message names the real reason.
#
# At the ceiling DSM answers 18990541, which reaches an operator as an
# allocation failure with a number in it. What they need to be told is that the
# NAS holds its model's maximum number of LUNs — because no amount of free space
# will fix it, and `pvesm status` will happily go on showing terabytes free.
#
# The count is of EVERY LUN on the NAS, not just this storage's: the ceiling is
# per-NAS and includes the owner's own LUNs and any Virtual Machine Manager
# disks. Which is the second reason never to send the types filter — it hides
# exactly those, so a client trusting it would under-count against the ceiling
# it is checking.
sub assert_room_for_lun {
    my ($self, %opt) = @_;

    my $max = $self->api->limits->{luns};
    # The NAS did not say. Stop guarding rather than invent a number.
    return 1 if !defined $max;

    # The caller may already hold the listing. alloc_image does, and fetching it
    # again cost ~0.6s inside PVE's cluster lock for information it had.
    my $have = defined $opt{count} ? $opt{count} : scalar @{ $self->list };
    return 1 if $have < $max;

    die "storage '" . $self->api->storeid . "': the NAS already holds $have"
      . " LUNs, which is this model's maximum ($max). Free space is not the"
      . " problem and adding capacity will not help — delete LUNs, or use a"
      . " second NAS. Note that the count includes LUNs this storage does not"
      . " own, such as Virtual Machine Manager disks.\n";
}

# Warn while there is still time to act, once per storage rather than on every
# allocation.
sub warn_if_near_lun_limit {
    my ($self, %opt) = @_;
    my $max = $self->api->limits->{luns} or return;
    # Same as assert_room_for_lun: the caller usually already has the listing, and
    # fetching it again for a warning cost a full round trip inside PVE's cluster
    # lock. A warning is never worth a second listing.
    my $have = defined $opt{count} ? $opt{count} : scalar @{ $self->list };
    my $left = $max - $have;
    return if $left > ($opt{margin} // 16);
    return if $self->{warned_lun_limit};
    $self->{warned_lun_limit} = 1;
    warn "storage '" . $self->api->storeid . "': $have of $max LUNs used on"
       . " this NAS — $left left. One VM disk is one LUN.\n";
}

sub create {
    my ($self, %opt) = @_;

    $self->assert_room_for_lun(count => $opt{known_lun_count})
        if !$opt{skip_limit_check};

    my $name     = $opt{name};
    my $size     = $opt{size};
    my $location = $opt{location};

    assert_name_legal($name);
    die "a LUN needs a location (the DSM volume, e.g. /volume1)\n"
        if !defined $location || !length $location;

    $size = int($size // 0);
    # The API accepts a one-byte LUN. The product documents a 1 GB minimum.
    $size = MIN_SIZE if $size < MIN_SIZE;

    # LOOK FIRST, so that the cleanup below is provably acting on an object this
    # call created.
    #
    # DSM refusing a create and performing it anyway is note 1 at the top of this
    # file, and the cleanup for it deletes what the lookup finds. Until now the
    # only thing separating "delete the half-made object DSM just made" from
    # "delete a LUN that was already there" was the error code NOT being 18990538
    # — proof by absence, for a destructive action. And there is a route to the
    # wrong branch: R-9 established that `LUN list` reports no total, so a
    # silently truncated listing would let `find_free_diskname` choose a name that
    # is already taken, and then only DSM's choice of code stands between the
    # retry and someone's disk.
    #
    # One extra call per allocation buys certainty. This is not a poll path, and
    # PVE holds `cluster_lock_storage` across the whole allocation, so the
    # check-then-create pair is not racing anything.
    my $existed = eval { $self->get($name) };
    die "storage '" . $self->api->storeid . "': a LUN named '$name' already"
      . " exists on the NAS. Not creating, and not touching it. If PVE chose"
      . " this name it means its view of the storage is incomplete — check SAN"
      . " Manager for a LUN this storage does not know about.\n"
        if $existed;

    my $r = $self->api->call(API_LUN, 'create',
        name        => $name,
        size        => $size,
        type        => LUN_TYPE_THIN,
        location    => $location,
        description => $opt{description} // 'Proxmox VE',
        dev_attribs => _dev_attribs(%opt),
    );

    my $uuid = $r->{success} ? $r->{data}{uuid} : undef;

    # Note 1 at the top of this file: the refusal may be a lie. Whatever DSM
    # said, look for the object before concluding anything.
    if (!defined $uuid) {
        my $code = $r->{error};
        my $why  = $r->{transport} // PVE::Storage::Custom::Synology::API::error_text($code);

        my $found = eval { $self->get($name) };
        if ($found) {
            if (defined $code && $code == 18990538) {
                # Duplicate name: something else owns it. Do not adopt it and
                # certainly do not delete it.
                die "storage '" . $self->api->storeid . "': a LUN named"
                  . " '$name' already exists on the NAS.\n";
            }
            # DSM refused and made it anyway. Remove it, so the caller's retry
            # does not find a half-made object it did not ask for.
            #
            # Safe to delete because the lookup above proved there was no LUN of
            # this name before the create — so what is here now is what this call
            # made. Without that, this branch was trusting DSM to have chosen
            # 18990538 for every pre-existing name.
            warn "storage '" . $self->api->storeid . "': DSM refused to create"
               . " '$name' ($why) but created it regardless — removing it."
               . " This is a known DSM behaviour, not a plugin error.\n";
            eval { $self->delete($found->{uuid}, force => 1) };
            die "storage '" . $self->api->storeid . "': could not create LUN"
              . " '$name' — $why\n";
        }

        die "storage '" . $self->api->storeid . "': could not create LUN"
          . " '$name' — $why\n";
    }

    # After a create the object may not be queryable yet.
    $self->wait_unlocked($uuid, what => 'creating the LUN');

    my $lun = $self->get($uuid);
    die "storage '" . $self->api->storeid . "': DSM reported creating LUN"
      . " '$name' but it cannot be read back. Do not retry blindly: check SAN"
      . " Manager first.\n" if !defined $lun;

    return $lun;
}

# ---------------------------------------------------------------------------
# Modifying
# ---------------------------------------------------------------------------

sub resize {
    my ($self, $uuid, $new_size) = @_;
    $new_size = int($new_size);

    my $lun = $self->get($uuid)
        or die "storage '" . $self->api->storeid . "': LUN $uuid is gone; not resizing\n";

    # PVE asks for the new total. Sizes are created exactly on this array, with
    # no rounding at any boundary, so there is no alignment arithmetic to do.
    #
    # Equal is idempotent and returns the LUN unchanged: PVE pads a requested
    # size up to a multiple of 1024 before calling, so a repeated resize to the
    # same figure is ordinary rather than exceptional.
    return $lun if $lun->{size} == $new_size;

    # SMALLER IS REFUSED, LOUDLY. This used to fall into the branch above and
    # return the LUN unchanged — a silent success for something that did not
    # happen. That is not survivable here, because PVE writes the REQUESTED size
    # into the VM configuration regardless of what a plugin returns
    # (`$drive->{size} = $newsize` in API2/Qemu.pm). So the configuration would
    # claim a size the array does not have, the guest would see the smaller disk,
    # and the next grow-by-N would be computed from the figure that was never
    # real. `qm resize` refuses a shrink itself — but a plugin that relied on its
    # caller to hold the line is the same mistake as trusting PVE to stop a
    # rollback on a running VM.
    die "storage '" . $self->api->storeid . "': refusing to shrink LUN $uuid from"
      . " $lun->{size} to $new_size bytes. Shrinking a LUN under a filesystem"
      . " destroys data, and reporting success without doing it would leave the"
      . " VM configuration claiming a size the NAS does not have.\n"
        if $lun->{size} > $new_size;

    $self->api->call_ok(API_LUN, 'set',
        uuid     => $uuid,
        new_size => $new_size,
        _what    => "resizing LUN $uuid to $new_size bytes",
    );

    $self->wait_unlocked($uuid, what => 'resizing the LUN');
    return $self->get($uuid);
}

sub rename {
    my ($self, $uuid, $new_name) = @_;
    assert_name_legal($new_name);
    $self->api->call_ok(API_LUN, 'set',
        uuid     => $uuid,
        new_name => $new_name,
        _what    => "renaming LUN $uuid to '$new_name'",
    );
    return $self->get($uuid);
}

# `force` skips the "is it still there" confirmation, for the cleanup path
# inside `create` where the object is known to be an accident.
sub delete {
    my ($self, $uuid, %opt) = @_;

    my $r = $self->api->call(API_LUN, 'delete', uuid => $uuid);

    if (!$r->{success}) {
        my $code = $r->{error};
        # Already gone is a successful delete. Anything else is not, and
        # "could not ask" is never reported as success: PVE removes the disk
        # from the VM configuration on success, and the volume would stay on
        # the NAS with nothing pointing at it.
        return 1 if defined $code && $code == 18990531;
        my $why = $r->{transport} // PVE::Storage::Custom::Synology::API::error_text($code);
        die "storage '" . $self->api->storeid . "': could not delete LUN $uuid — $why\n";
    }

    return 1 if $opt{force};

    # Confirm absence rather than trusting the answer.
    my $still = eval { $self->get($uuid) };
    if ($@) {
        die "storage '" . $self->api->storeid . "': DSM reported deleting LUN"
          . " $uuid but the NAS could not be asked to confirm it. Treating"
          . " this as a failure: $@";
    }
    die "storage '" . $self->api->storeid . "': DSM reported deleting LUN"
      . " $uuid but it is still there\n" if defined $still;

    return 1;
}

# ---------------------------------------------------------------------------
# Clones
# ---------------------------------------------------------------------------

# Both clone forms produce a reflink: a clone of a LUN holding 512 MiB reported
# 512 MiB allocated and consumed ZERO bytes of the volume. So allocated_size
# counts shared blocks and must never be summed to estimate usage — capacity
# comes from the volume's own size_free_byte.
sub clone {
    my ($self, %opt) = @_;
    my $name = $opt{name};
    assert_name_legal($name);

    my $d = $self->api->call_ok(API_LUN, 'clone',
        src_lun_uuid => $opt{src_uuid},
        dst_lun_name => $name,
        dst_location => $opt{location},
        _what        => "cloning LUN $opt{src_uuid} to '$name'",
    );

    my $uuid = $d->{dst_lun_uuid}
        // (($self->get($name) // {})->{uuid});
    die "storage '" . $self->api->storeid . "': the clone '$name' was reported"
      . " created but has no uuid\n" if !defined $uuid;

    $self->wait_unlocked($uuid, what => 'cloning the LUN');
    return $self->get($uuid);
}

sub clone_from_snapshot {
    my ($self, %opt) = @_;
    my $name = $opt{name};
    assert_name_legal($name);

    my $d = $self->api->call_ok(API_LUN, 'clone_snapshot',
        src_lun_uuid    => $opt{src_uuid},
        snapshot_uuid   => $opt{snapshot_uuid},
        cloned_lun_name => $name,
        _what           => "cloning snapshot $opt{snapshot_uuid} to '$name'",
    );

    my $uuid = $d->{cloned_lun_uuid}
        // (($self->get($name) // {})->{uuid});
    die "storage '" . $self->api->storeid . "': the clone '$name' was reported"
      . " created but has no uuid\n" if !defined $uuid;

    $self->wait_unlocked($uuid, what => 'cloning the snapshot');
    return $self->get($uuid);
}

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

# Every snapshot carries taken_by, returned verbatim, and DSM substitutes
# 'webapi' for an empty one. So a snapshot this plugin did not take is always
# distinguishable — which matters, because a user's own scheduled snapshots
# would otherwise appear to PVE as its own and could be deleted with a VM.
our $TAKEN_BY = 'jt-pve-storage-synology';

sub snapshot_create {
    my ($self, %opt) = @_;

    my $d = $self->api->call_ok(API_LUN, 'take_snapshot',
        src_lun_uuid      => $opt{src_uuid},
        snapshot_name     => $opt{name},
        description       => $opt{description} // 'Proxmox VE',
        taken_by          => $TAKEN_BY,
        is_locked         => 'false',
        is_app_consistent => 'false',
        _what             => "taking snapshot '$opt{name}' of LUN $opt{src_uuid}",
    );

    return $d->{snapshot_uuid};
}

# Only this plugin's own snapshots. Never the user's.
sub snapshot_list {
    my ($self, $src_uuid, %opt) = @_;

    my $r = $self->api->call(API_LUN, 'list_snapshot', src_lun_uuid => $src_uuid);
    if (!$r->{success}) {
        my $code = $r->{error};
        # The LUN is gone, so it has no snapshots.
        return [] if defined $code && ($code == 18990531 || $code == 18990505);
        my $why = $r->{transport} // PVE::Storage::Custom::Synology::API::error_text($code);
        die "storage '" . $self->api->storeid . "': could not list snapshots of"
          . " $src_uuid — $why\n";
    }

    my $snaps = $r->{data}{snapshots};
    die "storage '" . $self->api->storeid . "': the snapshot listing was not a list\n"
        if ref $snaps ne 'ARRAY';

    return [ grep { ref $_ eq 'HASH' } @$snaps ] if $opt{all};
    return [ grep { ref $_ eq 'HASH' && ($_->{taken_by} // '') eq $TAKEN_BY } @$snaps ];
}

sub snapshot_delete {
    my ($self, $snapshot_uuid) = @_;

    my $r = $self->api->call(API_LUN, 'delete_snapshot',
        snapshot_uuid => $snapshot_uuid,
        deleted_by    => $TAKEN_BY,
    );
    return 1 if $r->{success};

    my $code = $r->{error};
    return 1 if defined $code && $code == 18990532;   # already gone

    my $why = $r->{transport} // PVE::Storage::Custom::Synology::API::error_text($code);
    die "storage '" . $self->api->storeid . "': could not delete snapshot"
      . " $snapshot_uuid — $why\n";
}

# Rollback.
#
# Measured, not assumed: the LUN's uuid is UNCHANGED by a restore — so the SCSI
# serial and therefore the WWID survive, and a node does not find a different
# disk where its own was — and snapshots NEWER than the restored one are kept.
#
# That second fact is why this plugin does not carry the refusal the related
# projects need. On those arrays a rollback destroys newer snapshots, so
# letting PVE do it silently would delete snapshots the user can still see.
# Do not port that refusal here without re-measuring it.
sub snapshot_rollback {
    my ($self, %opt) = @_;

    my $before = $self->get($opt{src_uuid})
        or die "storage '" . $self->api->storeid . "': LUN $opt{src_uuid} is"
             . " gone; not rolling back\n";

    $self->api->call_ok(API_LUN, 'restore_snapshot',
        src_lun_uuid  => $opt{src_uuid},
        snapshot_uuid => $opt{snapshot_uuid},
        _what         => "rolling LUN $opt{src_uuid} back to snapshot $opt{snapshot_uuid}",
    );

    $self->wait_unlocked($opt{src_uuid}, what => 'rolling the LUN back');

    my $after = $self->get($opt{src_uuid});
    die "storage '" . $self->api->storeid . "': the LUN could not be read back"
      . " after the rollback\n" if !defined $after;

    # If this ever fires, the device identity changed underneath every node and
    # the assumption this plugin's device handling rests on is wrong.
    die "storage '" . $self->api->storeid . "': the rollback changed the LUN's"
      . " uuid ($before->{uuid} -> $after->{uuid}). Every node now sees a"
      . " different disk. Please report this with your DSM version.\n"
      if ($after->{uuid} // '') ne ($before->{uuid} // '');

    return $after;
}

# ---------------------------------------------------------------------------
# Mapping
# ---------------------------------------------------------------------------

# Measured: map_target ADDS to a LUN's target list and unmap_target removes
# only what is named — the opposite of Unity, where the list is replaced and
# mapping one host unmaps every other node in the cluster.
#
# The union is still read and sent. One measurement on one firmware is not a
# promise, and being wrong in that direction unmaps a running cluster.
sub map_to_targets {
    my ($self, $uuid, $target_ids) = @_;
    my @ids = map { "$_" } @$target_ids;
    return 1 if !@ids;

    my $list = '[' . join(',', map { "\"$_\"" } @ids) . ']';
    $self->api->call_ok(API_LUN, 'map_target',
        uuid       => $uuid,
        target_ids => $list,
        _what      => "mapping LUN $uuid to target(s) " . join(', ', @ids),
    );
    return 1;
}

sub unmap_from_targets {
    my ($self, $uuid, $target_ids) = @_;
    my @ids = map { "$_" } @$target_ids;
    return 1 if !@ids;

    my $list = '[' . join(',', map { "\"$_\"" } @ids) . ']';
    my $r = $self->api->call(API_LUN, 'unmap_target',
        uuid => $uuid, target_ids => $list);
    return 1 if $r->{success};

    my $code = $r->{error};
    # The LUN is gone, so it is not mapped to anything.
    return 1 if defined $code && ($code == 18990531 || $code == 18990505);

    my $why = $r->{transport} // PVE::Storage::Custom::Synology::API::error_text($code);
    die "storage '" . $self->api->storeid . "': could not unmap LUN $uuid — $why\n";
}

1;
