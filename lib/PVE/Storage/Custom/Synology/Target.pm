package PVE::Storage::Custom::Synology::Target;

# iSCSI targets and the LUN-to-target mapping.
#
# Three measured facts shape this module:
#
#   1. `max_sessions` DEFAULTS TO 1, and a target left at 1 admits exactly one
#      node. A storage a Proxmox VE cluster shares is unusable until it is 0,
#      and the second node's failure looks like a fabric problem rather than a
#      configuration one. Every target created here is created with 0.
#
#   2. `mapping_index` IS REUSED. Unmap the middle of three and the next LUN
#      mapped takes the freed index, so `.../-lun-2` resolves to a different
#      disk after an ordinary detach-and-attach. A device path is therefore not
#      an identity, and nothing here hands one out as though it were.
#
#   3. A target's IQN embeds the NAS hostname AS IT WAS WHEN THE TARGET WAS
#      CREATED. The test NAS carries targets with two different hostnames
#      because it was renamed. So an IQN is never derived from the current
#      hostname and then compared against existing targets — targets are found
#      by name, and their IQN is read from the answer.

use strict;
use warnings;

use PVE::Storage::Custom::Synology::API;

# Identifiers reach DSM as JSON strings. A bare number is refused with
# 18990710, and the refusal is easy to mistake for "no such target".
my $id = \&PVE::Storage::Custom::Synology::API::json_string;

use constant {
    API_TARGET => 'SYNO.Core.ISCSI.Target',

    # Unlimited. See note 1.
    MAX_SESSIONS_UNLIMITED => 0,

    # DSM's own prefix. A target's IQN must be globally unique, and this is the
    # form SAN Manager itself produces.
    IQN_PREFIX => 'iqn.2000-01.com.synology:',
};

sub new {
    my ($class, $api) = @_;
    return bless { api => $api }, $class;
}

sub api { return $_[0]->{api} }

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

sub list {
    my ($self) = @_;

    my $r = $self->api->call(API_TARGET, 'list',
        additional => '["mapped_lun","connected_sessions"]');

    if (!$r->{success}) {
        my $why = $r->{transport}
            // PVE::Storage::Custom::Synology::API::error_text($r->{error});
        die "storage '" . $self->api->storeid . "': could not list targets — $why\n";
    }

    my $t = $r->{data}{targets};
    die "storage '" . $self->api->storeid . "': the target listing was not a list\n"
        if ref $t ne 'ARRAY';

    return [ grep { ref $_ eq 'HASH' } @$t ];
}

# `get` accepts a target NAME as well as an id — Synology's CSI driver relies
# on it. Returns undef for absent, dies for unreachable.
sub get {
    my ($self, $handle) = @_;
    return undef if !defined $handle || !length $handle;

    my $r = $self->api->call(API_TARGET, 'get',
        target_id  => $id->($handle),
        additional => '["mapped_lun","connected_sessions"]');

    if ($r->{success}) {
        my $t = $r->{data}{target};
        return undef if ref $t ne 'HASH';
        # A lookup by name must answer about that name.
        if ($handle !~ /\A\d+\z/) {
            return undef if ($t->{name} // '') ne $handle;
        }
        return $t;
    }

    # DSM has no documented "no such target" code, so absence is established
    # the only way that proves it: a LISTING that succeeds without the target
    # in it. An error message never proves absence — and neither does a lookup
    # that failed for some other reason.
    #
    # This fallback searched by name only, so a lookup BY ID that failed fell
    # through to "not found" and every mapping check silently answered no. That
    # is the confusion between "could not ask" and "the answer is no" that this
    # project exists to avoid, found in its own code by driving it at hardware.
    my $listing = eval { $self->list };
    if (!$@ && ref $listing eq 'ARRAY') {
        for my $t (@$listing) {
            return $t if ($t->{name} // '') eq $handle;
            return $t if defined $t->{target_id} && "$t->{target_id}" eq "$handle";
        }
        return undef;   # the listing worked and it is genuinely not there
    }

    my $why = $r->{transport}
        // PVE::Storage::Custom::Synology::API::error_text($r->{error});
    die "storage '" . $self->api->storeid . "': could not look up target"
      . " '$handle' — $why\n";
}

sub find_by_name {
    my ($self, $name) = @_;
    for my $t (@{ $self->list }) {
        return $t if ($t->{name} // '') eq $name;
    }
    return undef;
}

# ---------------------------------------------------------------------------
# Creating
# ---------------------------------------------------------------------------

# The IQN is generated once, at creation, and read back from the NAS from then
# on — see note 3. `$suffix` should be stable for the storage, not for a node.
sub build_iqn {
    my ($prefix, $suffix) = @_;
    $prefix //= IQN_PREFIX;
    my $iqn = $prefix . $suffix;
    # The CSI driver's substitutions, which are its own scars: an IQN's
    # grammar is narrow and DSM will not take these characters.
    $iqn =~ s/_/-/g;
    $iqn =~ s/\+/p/g;
    $iqn =~ tr/A-Z/a-z/;
    $iqn =~ s/[^a-z0-9.:\-]//g;
    # RFC 3720 caps an IQN at 223 bytes; Synology's own client uses 128.
    $iqn = substr($iqn, 0, 128) if length($iqn) > 128;
    return $iqn;
}

# Idempotent: a target that already exists is returned, not re-created. Both a
# duplicate-name refusal and a successful create end in the same lookup,
# because two nodes may reach this at the same moment.
# Refuse BEFORE the NAS does, for the target ceiling.
#
# Irrelevant while `shared` is the default target mode — one target per storage — and
# that is precisely WHY it is the default: in `per-volume` mode there is a target per
# disk, and `max_iscsitrgs` is **128** on the test NAS against a LUN ceiling of 256.
# So per-volume mode caps the storage at half the disks the LUNs would allow, and it
# does so by failing a target creation with a number rather than saying why.
#
# Like the snapshot ceiling, this was read from the NAS by `limits()` and consumed by
# nothing, while CLAUDE.md named it as one of the three that bite.
#
# The count is of EVERY target on the NAS, not this storage's: the ceiling is
# per-NAS and includes the owner's own targets.
sub assert_room_for_target {
    my ($self, %opt) = @_;

    my $max = $self->api->limits->{targets};
    return 1 if !defined $max;

    my $have = defined $opt{count} ? $opt{count} : scalar @{ $self->list };
    return 1 if $have < $max;

    die "storage '" . $self->api->storeid . "': the NAS already has $have iSCSI"
      . " targets, which is this model's maximum ($max). With"
      . " syno-target-mode=per-volume each disk needs its own target, so this"
      . " ceiling is reached at half the number of disks the LUN limit allows —"
      . " syno-target-mode=shared uses one target for the whole storage and is the"
      . " default for this reason. The count includes targets this storage does not"
      . " own.\n";
}

sub ensure {
    my ($self, %opt) = @_;

    my $name = $opt{name};
    die "a target needs a name\n" if !defined $name || !length $name;

    # Check and create both live inside the same path deliberately: PVE runs
    # allocations in parallel and check-then-create is not atomic.
    # ONE listing, used for the lookup and for the ceiling count. `find_by_name`
    # does its own `list`, so calling both would fetch the same data twice — the
    # lesson the allocation path had to learn about `cluster_lock_storage`.
    my $all = $self->list;
    my ($existing) = grep { ($_->{name} // '') eq $name } @$all;
    if ($existing) {
        $self->ensure_multi_session($existing);
        $self->reconcile_chap($existing, %opt);
        return $existing;
    }

    # Only on the create path: an existing target costs nothing and the listing
    # above has already been fetched, so the count comes from it.
    $self->assert_room_for_target(count => scalar @$all)
        if !$opt{skip_limit_check};

    my %p = (
        name         => $name,
        iqn          => $opt{iqn} // build_iqn($opt{iqn_prefix}, $name),
        auth_type    => 0,
        user         => '',
        password     => '',
        # Note 1. Not a tuning choice: at the default of 1 a second node cannot
        # log in at all.
        max_sessions => MAX_SESSIONS_UNLIMITED,
    );

    # DSM has no per-host LUN masking this project has been able to verify, so
    # CHAP is the only access control it can rely on. auth_type 1 is one-way.
    if (defined $opt{chap_user} && length $opt{chap_user}) {
        # `// ''` used to stand here, and it turned a missing secret into an EMPTY
        # one — access control that appears configured and protects nothing. That
        # is strictly worse than no CHAP, because nobody goes looking for it.
        # There is no safe default for a shared secret, so this refuses.
        die "storage '" . $self->api->storeid . "': syno-chap-username is set but"
          . " there is no CHAP secret. Set syno-chap-password, or unset the"
          . " username — a target with an empty secret accepts anyone while"
          . " reporting that CHAP is on.\n"
            if !defined $opt{chap_password} || !length $opt{chap_password};

        $p{auth_type} = 1;
        $p{user}      = $opt{chap_user};
        $p{password}  = $opt{chap_password};
    }

    my $r = $self->api->call(API_TARGET, 'create', %p);

    if (!$r->{success}) {
        my $code = $r->{error};
        # 18990744 is a duplicate name: another node created it between the
        # lookup above and this call. That is success, not a collision.
        if (!defined $code || $code != 18990744) {
            my $why = $r->{transport}
                // PVE::Storage::Custom::Synology::API::error_text($code);
            die "storage '" . $self->api->storeid . "': could not create target"
              . " '$name' — $why\n";
        }
    }

    # Whether it was made here or by another node, read it back: a create that
    # reports success is not a handle, and on this NAS a create that reports
    # failure is not proof of absence either.
    my $t = $self->find_by_name($name);
    die "storage '" . $self->api->storeid . "': target '$name' was reported"
      . " created but cannot be found\n" if !$t;

    $self->ensure_multi_session($t);
    return $t;
}

# A target created by hand in SAN Manager will be at max_sessions 1, and the
# symptom is that exactly one node can use the storage. Fix it rather than
# fail, but only when it is actually wrong.
# CHAP on a target that already exists.
#
# `ensure` used to configure CHAP only on the path that CREATES the target, and
# every other path returned the existing one untouched. So an operator adding CHAP
# to a storage that already had a target got no error and no CHAP: `auth_type`
# stayed 0 on the NAS while the configuration said otherwise. Measured on hardware
# — `pvesm set --syno-chap-username` succeeded, the next activation refused
# nothing, and the target still reported `auth_type=0`.
#
# That is worse than the empty-secret bug it was found next to, because there is
# nothing at all to notice: no warning, no failure, and a configuration that reads
# as though access control is on.
#
# Two things this must NOT do:
#
#   * Send a `set` on every call. This runs on the allocate and activate paths, so
#     it compares first and only writes when the array disagrees. `auth_type` and
#     `user` come back in the listing that was already fetched, so the no-change
#     path costs nothing.
#   * Decide anything from the secret. The NAS does not return it, so a CHANGED
#     password is invisible here. `_revalidate` in the plugin pushes it
#     unconditionally after `on_update_hook`, which is the one moment a new secret
#     is known — this reconciles the parts the array will actually report.
sub reconcile_chap {
    my ($self, $target, %opt) = @_;
    return if ref $target ne 'HASH';

    my $want_user = $opt{chap_user};
    my $want_on   = defined $want_user && length $want_user ? 1 : 0;

    if ($want_on && (!defined $opt{chap_password} || !length $opt{chap_password})) {
        die "storage '" . $self->api->storeid . "': syno-chap-username is set but"
          . " there is no CHAP secret. Set syno-chap-password, or unset the"
          . " username — a target with an empty secret accepts anyone while"
          . " reporting that CHAP is on.\n";
    }

    my $have_on   = ($target->{auth_type} // 0) ? 1 : 0;
    my $have_user = $target->{user} // '';

    return if $have_on == $want_on
           && (!$want_on || $have_user eq $want_user);

    # Turning CHAP OFF reduces access control, so it is never silent even though
    # it is what the operator asked for. Leaving it on would be worse: the target
    # would demand a secret the node no longer sends, and every login would fail.
    warn "storage '" . $self->api->storeid . "': removing CHAP from target"
       . " '$target->{name}' because syno-chap-username is no longer set.\n"
        if $have_on && !$want_on;

    $self->set_chap($target->{target_id}, $want_on ? $want_user : undef,
                    $want_on ? $opt{chap_password} : undef);
    return;
}

# Write the CHAP settings to a target. Separate from reconcile_chap because the
# plugin's update hook calls it unconditionally: a changed secret cannot be
# detected by comparison, since the NAS never returns one.
sub set_chap {
    my ($self, $target_id, $user, $password) = @_;
    die "a target id is required to set CHAP\n" if !defined $target_id;

    my $on = defined $user && length $user ? 1 : 0;
    die "storage '" . $self->api->storeid . "': refusing to set CHAP on target"
      . " $target_id with an empty secret\n"
        if $on && (!defined $password || !length $password);

    $self->api->call_ok(API_TARGET, 'set',
        target_id => PVE::Storage::Custom::Synology::API::json_string($target_id),
        auth_type => $on,
        user      => $on ? $user : '',
        password  => $on ? $password : '',
        _what     => ($on ? "enabling CHAP on target $target_id"
                          : "removing CHAP from target $target_id"),
    );
    return 1;
}

sub ensure_multi_session {
    my ($self, $target) = @_;
    return 1 if ($target->{max_sessions} // 1) == MAX_SESSIONS_UNLIMITED;

    $self->api->call_ok(API_TARGET, 'set',
        target_id    => $id->($target->{target_id}),
        max_sessions => MAX_SESSIONS_UNLIMITED,
        _what        => "allowing multiple sessions on target '$target->{name}'",
    );
    $target->{max_sessions} = MAX_SESSIONS_UNLIMITED;
    return 1;
}

sub delete {
    my ($self, $target_id) = @_;

    my $r = $self->api->call(API_TARGET, 'delete', target_id => $id->($target_id));
    return 1 if $r->{success};

    # Absence is proved by a listing, never by an error message.
    my $still = eval { $self->get($target_id) };
    return 1 if !$@ && !defined $still;

    my $why = $r->{transport}
        // PVE::Storage::Custom::Synology::API::error_text($r->{error});
    die "storage '" . $self->api->storeid . "': could not delete target"
      . " $target_id — $why\n";
}

# ---------------------------------------------------------------------------
# Mapping
# ---------------------------------------------------------------------------

# uuid => mapping_index for everything on this target.
#
# The index is returned because the by-path device name contains it, and NOT
# because it identifies anything: it is reused (note 2). Use it to find a
# candidate device, then confirm that device by the kernel's WWID before
# touching it.
sub mapped_luns {
    my ($self, $target) = @_;
    $target = $self->get($target) if !ref $target;
    return {} if !$target;

    my %map;
    for my $m (@{ $target->{mapped_luns} // [] }) {
        next if ref $m ne 'HASH';
        next if !defined $m->{lun_uuid};
        $map{ $m->{lun_uuid} } = $m->{mapping_index};
    }
    return \%map;
}

sub is_lun_mapped {
    my ($self, $target, $lun_uuid) = @_;
    return exists $self->mapped_luns($target)->{$lun_uuid} ? 1 : 0;
}

sub connected_session_count {
    my ($self, $target) = @_;
    $target = $self->get($target) if !ref $target;
    return 0 if !$target;
    return scalar @{ $target->{connected_sessions} // [] };
}

1;
