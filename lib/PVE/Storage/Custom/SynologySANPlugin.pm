package PVE::Storage::Custom::SynologySANPlugin;

# Proxmox VE storage plugin for Synology SAN Manager over iSCSI.
#
# One VM disk is one thin LUN on the NAS. No LVM layer and no shared LUN carved
# up locally, so DSM's own snapshots, clones and capacity act on the unit an
# operator thinks about.
#
# Everything array-facing lives in the Synology::* modules and every non-obvious
# decision there carries the measurement that produced it. The ones that shape
# THIS file:
#
#   * A device is never identified by its path. `mapping_index` is reused, so
#     `.../-lun-2` resolves to a different disk after an ordinary
#     detach-and-attach. `path()` returns the dm-uuid link and every activation
#     confirms the device against the kernel's WWID.
#   * Nothing on the NAS refuses a delete for dependency reasons — not even a
#     MAPPED LUN — so unmapping before deleting is entirely this file's job.
#   * Rollback is safe here: it leaves the LUN's uuid unchanged and keeps newer
#     snapshots. So `volume_rollback_is_possible` does NOT carry the refusal the
#     related projects need, and that is deliberate rather than an omission.
#   * A create that reports failure may have created the LUN anyway, which
#     `LUN::create` handles — but it is why `alloc_image` must not retry blindly.

use strict;
use warnings;

use PVE::Tools qw(run_command);
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use PVE::Storage::Custom::Synology::API;
use PVE::Storage::Custom::Synology::LUN;
use PVE::Storage::Custom::Synology::Target;
use PVE::Storage::Custom::Synology::Naming;
use PVE::Storage::Custom::Synology::ISCSI;
use PVE::Storage::Custom::Synology::Multipath;
use PVE::Storage::Custom::Synology::WwidState;
use PVE::Storage::Custom::Synology::Health;
use PVE::Storage::Custom::Synology::Deferred;

use base qw(PVE::Storage::Plugin);

my $LUN     = 'PVE::Storage::Custom::Synology::LUN';
my $MP      = 'PVE::Storage::Custom::Synology::Multipath';
my $ISCSI   = 'PVE::Storage::Custom::Synology::ISCSI';
my $NAMING  = 'PVE::Storage::Custom::Synology::Naming';
my $HEALTH  = 'PVE::Storage::Custom::Synology::Health';

# ---------------------------------------------------------------------------
# API version
# ---------------------------------------------------------------------------

# Negotiated, never hardcoded. PVE treats the two directions very differently:
# claiming HIGHER than the node's APIVER makes PVE reject the plugin outright
# and every storage of this type disappears from the node; claiming lower but
# in range only produces a warning on every load of PVE::Storage. PVE 9 raised
# APIVER twice inside its 9.1 point releases, so a fixed number is wrong
# somewhere by construction.
use constant APIVERSION_MIN => 10;
use constant APIVERSION_MAX => 15;   # get_identity. Raise only after implementing the delta.

sub api {
    my $ver = eval { PVE::Storage::APIVER() };
    # perl -c and the unit tests have no PVE::Storage loaded.
    return APIVERSION_MIN if !defined $ver;
    $ver = APIVERSION_MAX if $ver > APIVERSION_MAX;
    $ver = APIVERSION_MIN if $ver < APIVERSION_MIN;
    return $ver;
}

sub type { return 'synologysan' }

sub plugindata {
    return {
        content => [ { images => 1, rootdir => 1 }, { images => 1 } ],
        format  => [ { raw => 1 }, 'raw' ],

        # WITHOUT THIS THE DSM PASSWORD IS WRITTEN INTO /etc/pve/storage.cfg.
        #
        # That file is `root:www-data 0640`, and — worse — a property PVE does not
        # know is a secret is returned by `GET /storage/<id>` to any user holding
        # Datastore.Audit. A read-only auditor would have been handed a DSM
        # credential with SAN Manager rights.
        #
        # PVE has a first-class mechanism and this plugin was not using it.
        # `sensitive_properties` falls back to a hardcoded list —
        # `encryption-key keyring master-pubkey password` — when a plugin declares
        # nothing, and `syno-password` is not in it. So the omission failed
        # silently and in the least safe direction, which is the only reason it
        # survived fifteen releases.
        #
        # Declaring them here makes PVE strip them from the config and hand them
        # to the hooks in %sensitive instead; storing them is then this plugin's
        # job, in /etc/pve/priv (root only, and replicated to every node).
        'sensitive-properties' => {
            'syno-password'      => 1,
            'syno-chap-password' => 1,
            'syno-otp'           => 1,
            # A standing second-factor bypass. Exactly as sensitive as the
            # password, and it was being written to the same place.
            'syno-device-id'     => 1,
        },
    };
}

# ---------------------------------------------------------------------------
# The credential store
# ---------------------------------------------------------------------------
#
# /etc/pve/priv/storage/<storeid>.syno, which is where PVE's own CIFS, PBS and
# ESXi plugins keep theirs. Under /etc/pve so it replicates to every node — a
# shared storage is used from all of them — and inside priv, which the cluster
# filesystem serves to root only.

# A variable rather than `use constant`, and deliberately: a constant is folded
# into its call sites at compile time, so a test cannot point the store at a
# temporary directory — and a credential store with no test is not something to
# ship. Nothing in production ever assigns to this.
our $CRED_DIR = '/etc/pve/priv/storage';

sub _cred_file {
    my ($class, $storeid) = @_;
    # The storeid reaches a filesystem path, so it is sanitised rather than
    # trusted: a storage id carrying `../` must not choose the file. PVE's own
    # id rules are stricter than this, but the check costs nothing and this is
    # the one place where being wrong writes a credential somewhere else.
    (my $safe = $storeid // '') =~ s/[^A-Za-z0-9_.-]/_/g;
    $safe =~ s/\A\.+//;
    return undef if !length $safe;
    return "$CRED_DIR/$safe.syno";
}

sub _read_creds {
    my ($class, $storeid) = @_;
    my $file = $class->_cred_file($storeid) or return {};
    my %c;
    open(my $fh, '<', $file) or return {};
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /\A\s*(?:#|\z)/;
        my ($k, $v) = split(/=/, $line, 2);
        next if !defined $k || !defined $v;
        # Only keys this plugin writes. A stray line is not an instruction.
        next if $k !~ /\A(?:password|chap-password|otp|device-id)\z/;
        $c{$k} = $v;
    }
    close($fh);
    return \%c;
}

sub _write_creds {
    my ($class, $storeid, $creds) = @_;
    my $file = $class->_cred_file($storeid)
        or die "storage '$storeid': the storage id cannot be used in a filename\n";

    # Nothing to keep: remove the file rather than leaving an empty one, so
    # "no credential stored" and "an empty credential" are not the same state.
    my %keep = map { $_ => $creds->{$_} }
               grep { defined $creds->{$_} && length $creds->{$_} } keys %$creds;
    if (!%keep) {
        unlink $file;
        return;
    }

    mkdir $CRED_DIR;
    my $body = join('', map { "$_=$keep{$_}\n" } sort keys %keep);
    ## no critic (ValuesAndExpressions::ProhibitLeadingZeros)
    # 0600 is a file mode and octal is the only readable way to write one.
    # The policy stays on everywhere else, where a leading zero IS a bug.
    PVE::Tools::file_set_contents($file, $body, 0600);
    return;
}

sub _delete_creds {
    my ($class, $storeid) = @_;
    my $file = $class->_cred_file($storeid) or return;
    unlink $file;
    return;
}

# The credentials for one storage: the private file first, then the config, so a
# storage added by an earlier version keeps working.
#
# Fifteen releases wrote the password into storage.cfg. Refusing to read it would
# break every existing installation on upgrade, so it is read and the operator is
# told once how to move it — and any `pvesm set` on the storage moves it
# automatically, because on_update_hook_full deletes it from the config.
sub _creds {
    my ($class, $storeid, $scfg) = @_;
    my $c = $class->_read_creds($storeid);

    my %map = (
        'password'      => 'syno-password',
        'chap-password' => 'syno-chap-password',
        'otp'           => 'syno-otp',
        'device-id'     => 'syno-device-id',
    );
    my $from_config = 0;
    for my $k (keys %map) {
        next if defined $c->{$k} && length $c->{$k};
        my $v = $scfg->{ $map{$k} };
        next if !defined $v || !length $v;
        $c->{$k} = $v;
        $from_config = 1 if $k eq 'password' || $k eq 'device-id';
    }

    PVE::Storage::Custom::Synology::Health::warn_once_for($storeid, 'plaintext-cred',
        "storage '$storeid': the DSM credential is still stored in"
      . " /etc/pve/storage.cfg, where it is readable by www-data and returned by"
      . " the API to any user with Datastore.Audit. Run"
      . " `pvesm set $storeid --syno-password <password>` once to move it into"
      . " /etc/pve/priv, which is root-only.\n") if $from_config;

    return $c;
}

# PVE consults this in parse_config and forces `shared 1`. A LUN on a NAS is
# reachable from every node by construction.
push @PVE::Storage::Plugin::SHARED_STORAGE, 'synologysan';

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

sub properties {
    return {
        'syno-portal' => {
            description => "DSM management address. A comma-separated list is"
                         . " tried in order and rotated on failure — use the"
                         . " cluster IP for Synology HA, or both controller"
                         . " addresses for a UC model.",
            type => 'string',
        },
        'syno-port' => {
            description => "DSM port.",
            type => 'integer', minimum => 1, maximum => 65535, default => 5001,
        },
        'syno-username' => {
            description => "DSM account. Do not use the primary admin account;"
                         . " see docs/DSM-ACCOUNT.md.",
            type => 'string',
        },
        'syno-password' => {
            description => "Password for the DSM account.",
            type => 'string',
        },
        'syno-otp' => {
            description => "One-time code, for an account with two-factor"
                         . " authentication. Needed once: the device token DSM"
                         . " issues is stored and this option can then be"
                         . " removed.",
            type => 'string', optional => 1,
        },
        'syno-device-id' => {
            description => "Device token from an earlier one-time-code login."
                         . " Set automatically; treat it as a credential.",
            type => 'string', optional => 1,
        },
        'syno-location' => {
            description => "DSM volume that holds the LUNs, e.g. /volume1."
                         . " Must be Btrfs: a thin LUN only supports snapshots"
                         . " on Btrfs.",
            type => 'string',
        },
        'syno-protocol' => {
            description => "SAN protocol. Only iSCSI is implemented; the option"
                         . " exists so that adding another one later does not"
                         . " require a new storage type.",
            type => 'string', enum => [ 'iscsi' ], default => 'iscsi',
        },
        'syno-target-mode' => {
            description => "'shared' puts every LUN of this storage on one"
                         . " target, which is the default because a NAS allows"
                         . " far fewer targets than LUNs. 'per-volume' isolates"
                         . " each disk but caps the storage at the target limit.",
            type => 'string', enum => [ 'shared', 'per-volume' ], default => 'shared',
        },
        'syno-iqn-prefix' => {
            description => "Prefix for generated target IQNs.",
            type => 'string', default => 'iqn.2000-01.com.synology:', optional => 1,
        },
        'syno-chap-username' => {
            description => "CHAP username. DSM has no per-host LUN masking this"
                         . " project has been able to verify, so CHAP is the"
                         . " access control it relies on.",
            type => 'string', optional => 1,
        },
        'syno-chap-password' => {
            description => "CHAP password.",
            type => 'string', optional => 1,
        },
        'syno-ssl-verify' => {
            description => "Verify the DSM certificate. Off by default because"
                         . " DSM ships a self-signed one and a default nobody"
                         . " can use protects nobody.",
            type => 'boolean', default => 0,
        },
        'syno-tls-ca' => {
            description => "CA certificate file, for syno-ssl-verify.",
            type => 'string', optional => 1,
        },
        'syno-data-portals' => {
            description => "iSCSI data addresses, comma-separated. Defaults to"
                         . " the management address. Two portals on one subnet"
                         . " need iface binding to be genuinely redundant.",
            type => 'string', optional => 1,
        },
        'syno-status-timeout' => {
            description => "Timeout in seconds for the health path, which runs"
                         . " every few seconds per node.",
            type => 'integer', minimum => 1, maximum => 60, default => 5,
        },
        'syno-min-free' => {
            description => "Refuse to allocate when the DSM volume has less"
                         . " than this many GiB free. Thin LUNs can overcommit"
                         . " a volume, and a full Btrfs volume affects every VM"
                         . " on it.",
            type => 'integer', minimum => 0, default => 10,
        },
        'syno-no-path-retry' => {
            description => "multipath no_path_retry. A number, never 'queue':"
                         . " queueing turns the loss of every path into a hang"
                         . " nothing can recover from.",
            type => 'integer', minimum => 1, maximum => 200, default => 18,
        },
    };
}

sub options {
    return {
        'syno-portal'         => { fixed => 1 },
        'syno-username'       => { fixed => 1 },
        'syno-password'       => { optional => 0 },
        'syno-location'       => { fixed => 1 },
        'syno-port'           => { optional => 1 },
        'syno-otp'            => { optional => 1 },
        'syno-device-id'      => { optional => 1 },
        'syno-protocol'       => { optional => 1 },
        'syno-target-mode'    => { optional => 1 },
        'syno-iqn-prefix'     => { optional => 1 },
        'syno-chap-username'  => { optional => 1 },
        'syno-chap-password'  => { optional => 1 },
        'syno-ssl-verify'     => { optional => 1 },
        'syno-tls-ca'         => { optional => 1 },
        'syno-data-portals'   => { optional => 1 },
        'syno-status-timeout' => { optional => 1 },
        'syno-min-free'       => { optional => 1 },
        'syno-no-path-retry'  => { optional => 1 },
        nodes    => { optional => 1 },
        shared   => { optional => 1 },
        disable  => { optional => 1 },
        content  => { optional => 1 },
        format   => { optional => 1 },
        bwlimit  => { optional => 1 },
    };
}

# ---------------------------------------------------------------------------
# Clients
# ---------------------------------------------------------------------------

sub _api {
    my ($class, $storeid, $scfg, %opt) = @_;
    # The credentials never come from $scfg directly any more: they live in
    # /etc/pve/priv, and $scfg is only the fallback for a storage written by a
    # version that did not know that. A hook that has just been handed a new
    # password passes it in as `creds`, because it is not on disk yet.
    my $c = $opt{creds} // $class->_creds($storeid, $scfg);
    return PVE::Storage::Custom::Synology::API->new(
        portals    => $scfg->{'syno-portal'},
        port       => $scfg->{'syno-port'},
        username   => $scfg->{'syno-username'},
        password   => $c->{password},
        otp        => $c->{otp},
        device_id  => $c->{'device-id'},
        ssl_verify => $scfg->{'syno-ssl-verify'},
        tls_ca     => $scfg->{'syno-tls-ca'},
        storeid    => $storeid,
        # The health path gets the short timeout and one attempt: the next poll
        # is the retry, and PVE runs status() for every storage in sequence.
        status     => $opt{status},
        timeout    => $opt{status} ? ($scfg->{'syno-status-timeout'} // 5) : undef,
    );
}

sub _lun { return PVE::Storage::Custom::Synology::LUN->new($_[1]) }
sub _tgt { return PVE::Storage::Custom::Synology::Target->new($_[1]) }
sub _state { return PVE::Storage::Custom::Synology::WwidState->new($_[1]) }

sub _location { return $_[1]->{'syno-location'} }

sub _data_portals {
    my ($class, $scfg) = @_;
    my $p = $scfg->{'syno-data-portals'} // $scfg->{'syno-portal'};
    return [ grep { length } split /\s*,\s*/, ($p // '') ];
}

# One target for the whole storage in `shared` mode. The name is derived from
# the storage id so two storages on one NAS never share a target — and it is
# looked up by NAME, never by an IQN derived from the current hostname: a
# target's IQN embeds the hostname it was CREATED with, and the test NAS carries
# targets with two different ones because it was renamed.
sub _target_name {
    my ($class, $storeid, $scfg, $volname) = @_;
    my $prefix = PVE::Storage::Custom::Synology::Naming::prefix_for($storeid);
    return $prefix . '-tgt' if ($scfg->{'syno-target-mode'} // 'shared') eq 'shared';
    my $leaf = PVE::Storage::Custom::Synology::Naming::leaf_of($volname);
    return "$prefix-tgt-$leaf";
}

# The CHAP secret, from the credential store.
#
# It must NOT be read from $scfg: `syno-chap-password` is a sensitive property, so
# PVE strips it from the configuration — `$scfg->{'syno-chap-password'}` is undef
# on any storage added by 0.5.3~beta1 or later. Both CHAP call sites did read it
# from there, and because Target::ensure and ISCSI::login both fall back to
# `$opt{chap_password} // ''`, the result was not a failure but an **empty CHAP
# secret** on the target and on the node. Authentication that appears configured
# and protects nothing is worse than none.
#
# Introduced by moving the credentials, and found by auditing the change rather
# than by running it — which is the only reason it is not in a release.
sub _chap_password {
    my ($class, $storeid, $scfg) = @_;
    return $class->_creds($storeid, $scfg)->{'chap-password'};
}

sub _ensure_target {
    my ($class, $api, $storeid, $scfg, $volname) = @_;
    my $tgt = $class->_tgt($api);
    return $tgt->ensure(
        name          => $class->_target_name($storeid, $scfg, $volname),
        iqn_prefix    => $scfg->{'syno-iqn-prefix'},
        chap_user     => $scfg->{'syno-chap-username'},
        chap_password => $class->_chap_password($storeid, $scfg),
    );
}

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------

# The only place a constraint on the DATA can be enforced, rather than
# discovered later. Everything refused here would otherwise surface at the
# first snapshot, or never.
sub on_add_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;

    # The credentials arrive HERE, not in $scfg: PVE strips every property named
    # in `sensitive-properties` out of the config before writing it.
    my %creds = (
        'password'      => $sensitive{'syno-password'},
        'chap-password' => $sensitive{'syno-chap-password'},
        'otp'           => $sensitive{'syno-otp'},
        'device-id'     => $sensitive{'syno-device-id'},
    );
    die "storage '$storeid': syno-password is required\n"
        if !defined $creds{password} || !length $creds{password};

    # A storage id that folds onto another one's prefix is indistinguishable
    # from it on the NAS: each would list the other's disks and the ownership
    # gate would pass for both. It cannot be fixed in a name, so it is refused
    # at the moment the data is created.
    my $cfg = eval { PVE::Storage::config() };
    if ($cfg && ref $cfg->{ids} eq 'HASH') {
        for my $other (sort keys %{ $cfg->{ids} }) {
            next if $other eq $storeid;
            my $o = $cfg->{ids}{$other};
            next if ($o->{type} // '') ne 'synologysan';
            next if !PVE::Storage::Custom::Synology::Naming::fold_collides_with($storeid, $other);
            # Only a collision on the SAME NAS and volume actually collides.
            next if ($o->{'syno-portal'} // '') ne ($scfg->{'syno-portal'} // '');
            next if ($o->{'syno-location'} // '') ne ($scfg->{'syno-location'} // '');
            die "storage '$storeid' cannot be added: its name folds to the same"
              . " LUN prefix as the existing storage '$other' on the same NAS"
              . " and volume, because DSM does not accept every character a"
              . " Proxmox VE storage id may contain. Each would list and could"
              . " delete the other's disks. Choose a name that differs by more"
              . " than punctuation.\n";
        }
    }

    my $api = $class->_api($storeid, $scfg, creds => \%creds);
    PVE::Storage::Custom::Synology::Health::assert_usable($api,
        location => $class->_location($scfg));

    # A one-time code is good once. Capture the device token DSM issues so the
    # operator never types another, and drop the code.
    if (my $token = $api->take_device_token) {
        $creds{'device-id'} = $token;
        delete $creds{otp};
        print "storage '$storeid': stored the device token DSM issued, so the"
            . " one-time code is not needed again. It is a standing"
            . " second-factor bypass and is kept in /etc/pve/priv with the"
            . " password.\n";
    }

    $api->logout;

    # LAST. Every check that can refuse has passed, so nothing is written for a
    # storage that is not going to exist — the same ordering rule the
    # activate_storage path follows.
    $class->_write_creds($storeid, \%creds);
    return;
}

# The target belongs to the STORAGE, not to any one disk, so it is removed when
# the storage is — not by free_image, which would tear it out from under every
# other disk on the same storage.
sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;

    # The credential outlives the storage unless something removes it, and a
    # stored DSM password belonging to a storage that no longer exists is the
    # worst of both: nothing uses it and nobody is looking after it. So it goes
    # whatever happens below — including when the NAS cannot be reached, which is
    # the path that used to return early and leave it.
    my $cleanup = PVE::Storage::Custom::Synology::Deferred->new(sub {
        $class->_delete_creds($storeid);
        PVE::Storage::Custom::Synology::API::clear_credential_latch(undef, $storeid);
    });

    my $api = eval { $class->_api($storeid, $scfg) } or return;
    my $tgt = $class->_tgt($api);
    my $prefix = eval { PVE::Storage::Custom::Synology::Naming::prefix_for($storeid) };
    return if !defined $prefix;

    my $targets = eval { $tgt->list } // [];
    for my $t (@$targets) {
        my $name = $t->{name} // '';
        # Only this storage's own targets, and only if nothing is still mapped
        # to them: a target with LUNs on it is not ours to remove, whatever its
        # name suggests.
        next if index($name, "$prefix-tgt") != 0;
        if (@{ $t->{mapped_luns} // [] }) {
            warn "storage '$storeid': leaving target '$name' in place — it still"
               . " has LUNs mapped to it.\n";
            next;
        }

        # THIS NODE's session first. Removing the target on the NAS while a node
        # is still logged in leaves that node with a session and a node record
        # pointing at something that no longer exists — which is what the first
        # `pvesm remove` produced. Other nodes clean up in deactivate_storage.
        $class->_detach_target($storeid, $scfg, $t->{iqn});

        eval { $tgt->delete($t->{target_id}) };
        warn "storage '$storeid': could not remove target '$name': $@" if $@;
    }
    eval { $api->logout };
    return;
}

# PVE calls _full when the plugin's api() is 13 or higher, and it hands over the
# LIVE config hash — the one that is written immediately afterwards. That is what
# makes the migration possible: a plaintext password left in storage.cfg by an
# earlier version can be moved into /etc/pve/priv and deleted from the config by
# any `pvesm set` on the storage.
sub on_update_hook_full {
    my ($class, $storeid, $scfg, $opts, $delete, $sensitive) = @_;
    $sensitive //= {};

    my $creds = $class->_update_creds($storeid, $scfg, $sensitive, $delete);

    # Strip anything an older version left in the config. $scfg is written by the
    # caller after this returns, so deleting here is what actually removes it.
    delete $scfg->{$_} for qw(syno-password syno-chap-password syno-otp syno-device-id);

    my %merged = (%$scfg, %{ $opts // {} });
    $class->_revalidate($storeid, \%merged, $creds);
    return;
}

# The pre-13 form, kept because api() is negotiated and a node can be older.
sub on_update_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;
    my $creds = $class->_update_creds($storeid, $scfg, \%sensitive, undef);
    $class->_revalidate($storeid, $scfg, $creds);
    return;
}

# Merge what was just supplied over what is already stored, so an update that
# does not resend the password keeps it.
sub _update_creds {
    my ($class, $storeid, $scfg, $sensitive, $delete) = @_;

    my $creds = $class->_creds($storeid, $scfg);

    my %map = (
        'syno-password'      => 'password',
        'syno-chap-password' => 'chap-password',
        'syno-otp'           => 'otp',
        'syno-device-id'     => 'device-id',
    );
    while (my ($prop, $key) = each %map) {
        next if !exists $sensitive->{$prop};
        my $v = $sensitive->{$prop};
        # PVE puts an explicitly deleted property in here as undef.
        if (!defined $v || !length $v) { delete $creds->{$key} } else { $creds->{$key} = $v }
    }
    for my $prop (@{ $delete // [] }) {
        delete $creds->{ $map{$prop} } if $map{$prop};
    }

    return $creds;
}

sub _revalidate {
    my ($class, $storeid, $scfg, $creds) = @_;

    my $api = $class->_api($storeid, $scfg, creds => $creds);
    PVE::Storage::Custom::Synology::Health::assert_usable($api,
        location => $class->_location($scfg));
    if (my $token = $api->take_device_token) {
        $creds->{'device-id'} = $token;
        delete $creds->{otp};
    }
    $api->logout;

    # After the checks, as in on_add_hook.
    $class->_write_creds($storeid, $creds);

    # A configuration change is the operator having had a chance to fix things,
    # so the credential latch and the once-only warnings both reset.
    PVE::Storage::Custom::Synology::API::clear_credential_latch($storeid);
    PVE::Storage::Custom::Synology::Health::clear_warnings($storeid);
    return;
}

# ---------------------------------------------------------------------------
# Names and paths
# ---------------------------------------------------------------------------

# Element 1 is the LEAF, so a linked clone reports vm-101-disk-0 and not
# base-100-disk-0/vm-101-disk-0. That is what RBDPlugin does, and
# PVE::Storage::storage_migrate builds the target volume name out of this
# element when a disk moves to a storage of another type.
sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m{^((base-(\d+)-\S+)/)?((base)?(vm)?-(\d+)-\S+)$}) {
        my ($basename, $basevmid, $leaf, $isbase, $vmid) = ($2, $3, $4, $5, $7);
        return ('images', $leaf, $vmid, $basename, $basevmid,
                $isbase ? 1 : 0, 'raw');
    }

    die "unable to parse Synology volume name '$volname'\n";
}

# $scfg->{storage} is always undef — PVE's storage config hash does not carry
# the storage id — so this cannot be implemented and every base method that
# would reach it is overridden. Dying with an actionable message beats
# returning a path that is silently wrong.
sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;
    die "a Synology LUN has no filesystem path. This is a bug in the caller:"
      . " use path() with the storage id.\n";
}

# The dm-uuid link, NOT /dev/mapper/<wwid>.
#
# On a node with `user_friendly_names yes` — which the test node has — multipath
# names the map mpathX and /dev/mapper/<wwid> does not exist at all. The related
# projects return that path; here it would simply be absent. The dm-uuid link is
# always present, whatever naming policy the node's administrator chose.
sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    die "a Synology LUN cannot be addressed at a snapshot: roll back to it, or"
      . " clone it into a new disk.\n" if defined $snapname;

    # $vmid, not the leaf name: the second element is the OWNER.
    my ($vtype, $leaf, $vmid) = $class->parse_volname($volname);
    my $api  = $class->_api($storeid, $scfg);
    my $lun  = $class->_lun($api);
    my $name = PVE::Storage::Custom::Synology::Naming::lun_name($storeid, $volname);

    my $obj = $lun->get($name)
        or die "storage '$storeid': there is no LUN named '$name' on the NAS\n";
    $api->logout;

    my $wwid = PVE::Storage::Custom::Synology::LUN::wwid_for_uuid($obj->{uuid});
    my $path = PVE::Storage::Custom::Synology::Multipath::dm_uuid_path($wwid)
        or die "storage '$storeid': could not derive a device path for '$name'\n";

    # ($path, $vmid, $vtype) — what RBDPlugin and ZFSPoolPlugin return, and what
    # PVE actually consumes. `qm destroy` calls path() in list context and
    # compares the second element against the VM id NUMERICALLY:
    #
    #     return if !$path || !$owner || ($owner != $vmid);
    #
    # Returning the leaf name there made that comparison "vm-9999-disk-0" != 9999,
    # so PVE returned early and never called vdisk_free — every `qm destroy`
    # silently LEAKED its LUN, with nothing but a numeric warning to show for it.
    return wantarray ? ($path, $vmid, $vtype) : $path;
}

# The base implementation runs `qemu-img info` on filesystem_path, which cannot
# exist here — so without this override `qm create` with an EXISTING volume dies
# before it starts, and the message points at filesystem_path rather than at the
# real cause. Found by running `qm create --scsi0 <existing volid>`; the stack
# named PVE::Storage::Plugin::volume_size_info.
#
# Answered from the NAS, which is the authority on a LUN's size anyway.
sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::Synology::Naming::lun_name($storeid, $volname);
    my $obj = eval { $lun->get($name) };
    my $err = $@;
    eval { $api->logout };

    die "storage '$storeid': could not read the size of '$name' — $err" if $err;
    die "storage '$storeid': there is no LUN named '$name' on the NAS\n" if !$obj;

    my $size = $obj->{size};
    # ($size, $format, $used, $parent, $ctime). `used` comes from
    # allocated_size, which over-reports for a reflink — it is the closest thing
    # the NAS offers and PVE only displays it.
    return wantarray ? ($size, 'raw', $obj->{allocated_size}, undef, undef) : $size;
}

# LVM and RBD override these; the base answers () unless $scfg->{path} is set,
# which silently refuses every disk move to another storage type, `pvesm
# export`/`import` and remote migration before any plugin code runs.
sub volume_export_formats { return ('raw+size') }
sub volume_import_formats { return ('raw+size') }

# The base implementation is gated on `$scfg->{path}`, which a block storage
# never sets — so it would refuse every export while `volume_export_formats`
# above promises `raw+size`. That mismatch breaks a disk move to another storage
# type with a message about a format rather than about a path, which is the kind
# of error nobody can act on.
#
# Found by a systematic sweep of the base class for methods that reach
# `filesystem_path` or `$scfg->{path}`, prompted by volume_size_info doing
# exactly this.
sub volume_export {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot,
        $base_snapshot, $with_snapshots) = @_;

    die "storage '$storeid': only raw+size can be exported (asked for"
      . " '$format')\n" if $format ne 'raw+size';
    die "storage '$storeid': a Synology LUN cannot be exported together with"
      . " its snapshots\n" if $with_snapshots;
    die "storage '$storeid': exporting from a snapshot is not supported — roll"
      . " back to it, or clone it into a disk of its own first\n"
        if defined $snapshot || defined $base_snapshot;

    my $path = $class->path($scfg, $volname, $storeid);
    my $size = $class->volume_size_info($scfg, $storeid, $volname);

    PVE::Storage::Plugin::write_common_header($fh, $size);
    run_command([ 'dd', "if=$path", 'bs=4k', 'status=none' ],
        output => '>&' . fileno($fh));
    return;
}

sub volume_import {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot,
        $base_snapshot, $with_snapshots, $allow_rename) = @_;

    die "storage '$storeid': only raw+size can be imported (offered"
      . " '$format')\n" if $format ne 'raw+size';
    die "storage '$storeid': a Synology LUN cannot be imported together with"
      . " its snapshots\n" if $with_snapshots;

    my ($vtype, $leaf, $vmid) = $class->parse_volname($volname);
    my $size = PVE::Storage::Plugin::read_common_header($fh);

    # The disk has to exist before anything can be written into it, and it is
    # created at the size the stream declares — rounded UP, never down: a volume
    # smaller than the source gets filled and then fails.
    my $name = $class->alloc_image($storeid, $scfg, $vmid, 'raw', $leaf,
        int(($size + 1023) / 1024));

    my $ok = eval {
        $class->activate_volume($storeid, $scfg, $name);
        my $path = $class->path($scfg, $name, $storeid);
        run_command([ 'dd', "of=$path", 'bs=4k', 'conv=fsync', 'status=none' ],
            input => '<&' . fileno($fh));
        1;
    };
    if (!$ok) {
        my $err = $@;
        # Cleanup on failure: a half-written disk PVE does not know about is
        # worse than a failed import.
        eval { $class->free_image($storeid, $scfg, $name, 0) };
        die "storage '$storeid': import of '$name' failed and it was removed"
          . " again: $err";
    }

    return "$storeid:$name";
}

# Refused rather than left to a base implementation that would reach for a
# filesystem path. DSM has no rename for a snapshot, and pretending otherwise
# would lose the mapping between what PVE lists and what the NAS holds.
sub rename_snapshot {
    my ($class, $scfg, $storeid, $volname, $source_snap, $target_snap) = @_;
    die "storage '$storeid': a Synology LUN snapshot cannot be renamed.\n";
}

# Neither is meaningful for a block storage, and both would otherwise reach for
# `$scfg->{path}` and produce an error about a directory.
sub get_subdir {
    my ($class, $scfg, $vtype) = @_;
    # No storeid is passed to this one, so the message stays generic rather than
    # inventing a name for the storage.
    die "a Synology LUN storage has no directories, so '$vtype' has no path.\n";
}

sub prune_backups {
    my ($class, $scfg, $storeid, $keep, $vmid, $type, $dryrun, $logfunc) = @_;
    die "storage '$storeid': this storage holds disks, not backups.\n";
}

# PVE::LXC::Config freezes a container's mountpoints only when this is true, and
# a container's root is mounted on this host while the NAS snapshots it.
# ZFSPlugin, the other external-appliance plugin, answers 1 as well.
sub volume_snapshot_needs_fsfreeze { return 1 }

sub get_identity {
    my ($class, $scfg, $storeid) = @_;
    my $api = $class->_api($storeid, $scfg, status => 1);
    my $uuid = eval { PVE::Storage::Custom::Synology::Health::node_uuid($api) };
    eval { $api->logout };
    # Pinned to the NAS's own uuid rather than to an address, because an address
    # can be re-pointed at a different NAS.
    return $uuid ? "synologysan:$uuid:" . ($class->_location($scfg) // '')
                 : "synologysan:" . ($scfg->{'syno-portal'} // '') . ":"
                   . ($class->_location($scfg) // '');
}

# ---------------------------------------------------------------------------
# Storage-level operations
# ---------------------------------------------------------------------------

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    my $api = $class->_api($storeid, $scfg, status => 1);
    my @r = PVE::Storage::Custom::Synology::Health::status(
        $api, $class->_lun($api), location => $class->_location($scfg));
    eval { $api->logout };
    return @r;
}

# Runs every few seconds per node per storage, sequentially with every other
# storage. It must be cheap and idempotent on the no-change path, and — the rule
# that cost a related project an incident — **nothing may change node state
# before every check that could refuse the storage has passed.**
sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    die "storage '$storeid': open-iscsi is not usable on this node"
      . " (iscsiadm did not answer)\n"
        if !PVE::Storage::Custom::Synology::ISCSI::is_available();

    # Only now may the node be touched. The drop-in is written before anything
    # is mapped, because without it a Synology LUN falls back to multipath's
    # generic defaults — and those include no_path_retry "queue".
    my $changed = PVE::Storage::Custom::Synology::Multipath::write_conf(
        no_path_retry => $scfg->{'syno-no-path-retry'});
    # The one permitted node-wide reconfigure, and only when the file changed:
    # multipathd has no per-file reload. Never on a timer.
    PVE::Storage::Custom::Synology::Multipath::reload_config() if $changed;

    return 1;
}

# Called per node. Logs this node out of the storage's targets once nothing of
# ours is left on it — which is how a node OTHER than the one that ran
# on_delete_hook stops holding a session to a target that has been removed.
sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $state = eval { $class->_state($storeid) } or return 1;
    my $tracked = eval { $state->tracked } // {};
    # Something is still attached here; leaving is not this call's business.
    return 1 if %$tracked;

    my $prefix = eval { PVE::Storage::Custom::Synology::Naming::prefix_for($storeid) };
    return 1 if !defined $prefix;

    # Match on the IQN this plugin generates for its own targets. A session to
    # anything else on the same NAS is not ours to end.
    for my $s (@{ PVE::Storage::Custom::Synology::ISCSI::sessions() }) {
        next if index($s->{iqn}, "$prefix-tgt") < 0;
        $class->_detach_target($storeid, $scfg, $s->{iqn});
    }
    return 1;
}

# Log out of one target on this node and forget its node record. One target at a
# time: `--logoutall` would drop every other storage's sessions.
sub _detach_target {
    my ($class, $storeid, $scfg, $iqn) = @_;
    return if !defined $iqn;

    for my $portal (@{ $class->_data_portals($scfg) }) {
        next if !PVE::Storage::Custom::Synology::ISCSI::has_session($iqn, $portal);
        eval { PVE::Storage::Custom::Synology::ISCSI::logout($iqn, $portal) };
        warn "storage '$storeid': could not log out of $iqn at $portal: $@" if $@;
    }
    # The record goes too, so nothing on this node points at a target that may
    # no longer exist.
    for my $portal (@{ $class->_data_portals($scfg) }) {
        eval { PVE::Storage::Custom::Synology::ISCSI::node_delete($iqn, $portal) };
    }
    return;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $luns = $lun->list(location => $class->_location($scfg));
    eval { $api->logout };

    my $res = [];
    for my $l (@$luns) {
        # Ownership, decided locally on the name and WITH the storage id. A
        # prefix identifies the storage, never the kind of object.
        my $volname = PVE::Storage::Custom::Synology::Naming::volname_from_lun_name(
            $l->{name}, $storeid) or next;

        my (undef, undef, $owner) = eval { $class->parse_volname($volname) };
        next if !defined $owner;
        next if defined $vmid && $owner ne $vmid;

        my $volid = "$storeid:$volname";
        if ($vollist) {
            next if !grep { $_ eq $volid } @$vollist;
        }

        push @$res, {
            volid  => $volid,
            format => 'raw',
            size   => $l->{size},
            # `allocated_size` counts blocks shared with a reflink, so it
            # over-reports. It is still the closest thing to "used".
            used   => $l->{allocated_size},
            vmid   => $owner,
            ctime  => undef,
        };
    }
    return $res;
}

# ---------------------------------------------------------------------------
# Volume lifecycle
# ---------------------------------------------------------------------------

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "storage '$storeid': only raw disks are supported (asked for '$fmt')\n"
        if defined $fmt && $fmt ne 'raw';

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);

    # `pvesm alloc` passes an EMPTY STRING when no name is given, not undef, so
    # `//=` never fires and the LUN name comes out as just the prefix. Found by
    # running the actual command.
    $name = undef if defined $name && !length $name;
    $name //= $class->find_free_diskname($storeid, $scfg, $vmid, $fmt);

    # Thin LUNs can overcommit the DSM volume, and PVE has no way to express
    # over-subscription — so a full Btrfs volume, which takes every VM on it
    # with it, has to be prevented here.
    my $min_free = ($scfg->{'syno-min-free'} // 10) * 1024 ** 3;
    if ($min_free > 0) {
        # (total, AVAILABLE, used, active) — PVE's order, not the intuitive one.
        my (undef, $avail, undef, $active) =
            PVE::Storage::Custom::Synology::Health::status($api, undef,
                location => $class->_location($scfg));
        die "storage '$storeid': the NAS is not answering; not allocating\n"
            if !$active;
        die "storage '$storeid': the DSM volume has only "
          . sprintf('%.1f', $avail / 1024 ** 3) . " GiB free and syno-min-free"
          . " is " . ($scfg->{'syno-min-free'} // 10) . " GiB. A thin LUN can"
          . " overcommit the volume, and a full Btrfs volume affects every VM"
          . " on it.\n" if $avail < $min_free;
    }

    my $lunname = PVE::Storage::Custom::Synology::Naming::lun_name($storeid, $name);

    # LUN::create looks the name up after ANY failure, because a create that
    # reports failure can have created the LUN anyway.
    my $obj = $lun->create(
        name        => $lunname,
        size        => $size * 1024,          # PVE passes KiB
        location    => $class->_location($scfg),
        description => "Proxmox VE $storeid / VM $vmid",
    );

    # Map it while we still hold the handle. Cleanup on failure unmaps before it
    # deletes: a volume deleted while still mapped leaves every node it was
    # mapped to with a device that answers nothing.
    my $ok = eval {
        my $t = $class->_ensure_target($api, $storeid, $scfg, $name);
        $lun->map_to_targets($obj->{uuid}, [ $t->{target_id} ]);
        1;
    };
    if (!$ok) {
        my $err = $@;
        eval {
            my $t = $class->_tgt($api)->find_by_name(
                $class->_target_name($storeid, $scfg, $name));
            $lun->unmap_from_targets($obj->{uuid}, [ $t->{target_id} ]) if $t;
        };
        eval { $lun->delete($obj->{uuid}) };
        eval { $api->logout };
        die "storage '$storeid': created LUN '$lunname' but could not map it,"
          . " so it was removed again: $err";
    }

    $lun->warn_if_near_lun_limit;
    eval { $api->logout };
    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::Synology::Naming::lun_name($storeid, $volname);

    # The ownership gate, with the storeid. Never delete anything that is not
    # provably this storage's.
    die "storage '$storeid': refusing to delete '$name', which this storage"
      . " does not own\n"
        if !PVE::Storage::Custom::Synology::Naming::is_pve_managed_volume($name, $storeid);

    my $obj = $lun->get($name);
    if (!defined $obj) {
        # ABSENT, established by a lookup that succeeded. `get` dies rather than
        # returning undef when it could not ask, which is the distinction that
        # matters: returning success here makes PVE drop the disk from the VM
        # configuration, and if the NAS was merely unreachable the LUN stays on
        # it with nothing pointing at it.
        eval { $api->logout };
        return undef;
    }

    my $uuid = $obj->{uuid};
    my $wwid = PVE::Storage::Custom::Synology::LUN::wwid_for_uuid($uuid);

    # A destructive path must not proceed on "could not tell". is_device_in_use
    # answers 1 / 0 / undef, and undef means something inside it could not
    # establish an answer — most importantly `fuser`, which is the only check
    # that sees a running QEMU holding the device open with no mount and no
    # holder. Verified against a real VM booted from a Synology LUN.
    $class->_assert_not_in_use($storeid, $wwid, 'delete');

    # The slave list is captured BEFORE anything is torn down: once the map is
    # flushed there is nothing left to ask which sd devices belonged to it.
    my $slaves = PVE::Storage::Custom::Synology::Multipath::slaves_of_map($wwid);

    # Local device first, while the mapping still exists to find it by.
    $class->_detach_local($storeid, $scfg, $wwid);

    # Then unmap everywhere. The NAS will happily delete a mapped LUN, leaving
    # every node that had it with a device that answers nothing — so this is not
    # optional politeness.
    my $tgt = $class->_tgt($api);
    my @ids = map { $_->{target_id} } @{ $tgt->list };
    eval { $lun->unmap_from_targets($uuid, \@ids) };

    # This plugin's own snapshots, before the LUN. The NAS does not require it —
    # snapshots go with their LUN — but leaving a user's own snapshots alone
    # means only ours are removed, and ours are identified by taken_by.
    for my $s (@{ $lun->snapshot_list($uuid) }) {
        eval { $lun->snapshot_delete($s->{uuid}) };
    }

    $lun->delete($uuid);

    # Now the residual paths. Deleting the LUN on the NAS does not make its
    # device disappear here — the iSCSI session is still up, so each sd node
    # survives as a DEAD device and multipathd re-adds a map for it. Without
    # this a stale map is left behind for a LUN that no longer exists, which is
    # exactly what the first end-to-end run through pvesm produced.
    PVE::Storage::Custom::Synology::ISCSI::remove_sd_device($_) for @$slaves;

    # And flush again, because the map may have been recreated between the first
    # flush and the delete.
    $class->_detach_local($storeid, $scfg, $wwid);

    # Only once the LUN is verifiably gone.
    $class->_state($storeid)->untrack($wwid);

    eval { $api->logout };
    return undef;
}

sub find_free_diskname {
    my ($class, $storeid, $scfg, $vmid, $fmt, $add_fmt_suffix) = @_;
    my $imgs = $class->list_images($storeid, $scfg, undef, undef, {});
    my @names = map { (split m{:}, $_->{volid}, 2)[1] } @$imgs;
    return PVE::Storage::Plugin::get_next_vm_diskname(
        \@names, $storeid, $vmid, $fmt, $scfg, $add_fmt_suffix);
}

# ---------------------------------------------------------------------------
# Attaching
# ---------------------------------------------------------------------------

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache, $hints) = @_;

    die "storage '$storeid': a snapshot cannot be activated; roll back to it or"
      . " clone it\n" if defined $snapname;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::Synology::Naming::lun_name($storeid, $volname);

    my $obj = $lun->get($name)
        or die "storage '$storeid': there is no LUN named '$name' on the NAS\n";
    my $uuid = $obj->{uuid};
    my $wwid = PVE::Storage::Custom::Synology::LUN::wwid_for_uuid($uuid);

    my $t = $class->_ensure_target($api, $storeid, $scfg, $volname);
    my $tgt = $class->_tgt($api);
    $lun->map_to_targets($uuid, [ $t->{target_id} ])
        if !$tgt->is_lun_mapped($t->{target_id}, $uuid);

    my $index = $tgt->mapped_luns($t->{target_id})->{$uuid};
    die "storage '$storeid': the NAS does not report a mapping index for"
      . " '$name'\n" if !defined $index;

    eval { $api->logout };

    my $found;
    for my $portal (@{ $class->_data_portals($scfg) }) {
        my $had_session = PVE::Storage::Custom::Synology::ISCSI::has_session(
            $t->{iqn}, $portal);

        PVE::Storage::Custom::Synology::ISCSI::login($t->{iqn}, $portal,
            chap_user     => $scfg->{'syno-chap-username'},
            chap_password => $class->_chap_password($storeid, $scfg));

        # A login discovers the LUNs mapped at that moment. This LUN was mapped
        # afterwards if the session already existed — which is every allocation
        # after the first — so the session has to be rescanned or no device ever
        # appears. One session, never `-m session --rescan`, which would rescan
        # every other vendor's storage on this node too.
        PVE::Storage::Custom::Synology::ISCSI::rescan_session($t->{iqn}, $portal)
            if $had_session;

        my $cand = PVE::Storage::Custom::Synology::ISCSI::by_path_for(
            $portal, $t->{iqn}, $index);
        my $dev = PVE::Storage::Custom::Synology::ISCSI::wait_for_by_path($cand);
        next if !defined $dev;

        # THE CHECK. mapping_index is reused, so the path that led here proves
        # nothing: a stale device for a detached disk would sit at the same
        # path. Only the kernel's own identification decides, and "could not
        # tell" is not "yes".
        my $is = PVE::Storage::Custom::Synology::Multipath::device_is_lun($dev, $wwid);
        if (!defined $is) {
            warn "storage '$storeid': could not read the WWID of $dev, so it"
               . " cannot be confirmed as '$name'; ignoring it\n";
            next;
        }
        if (!$is) {
            warn "storage '$storeid': $dev is NOT '$name' — the NAS reuses"
               . " mapping indexes and this is a stale device. Ignoring it.\n";
            next;
        }

        # The map has to be made to exist, not hoped for: on a node with
        # `find_multipaths yes` a single-path device gets NO map, and the path
        # this plugin returns would point at nothing. Found by adding a second
        # node whose policy differed from the first's.
        PVE::Storage::Custom::Synology::Multipath::ensure_map($wwid, $dev);
        PVE::Storage::Custom::Synology::Multipath::claim_path($dev);
        $found = $dev;
    }

    die "storage '$storeid': no device for '$name' appeared on this node after"
      . " logging in to $t->{iqn}\n" if !defined $found;

    $class->_state($storeid)->track($wwid, $volname);

    # The map is what path() hands out, so its absence is a failure and not a
    # detail — a VM would be started against a path that is not there.
    die "storage '$storeid': the device for '$name' is present but multipath"
      . " built no map for it. Check `find_multipaths` in"
      . " /etc/multipath.conf on this node, and that"
      . " /etc/multipath/wwids contains $wwid.\n"
        if !PVE::Storage::Custom::Synology::Multipath::ensure_map($wwid, $found,
               timeout => 20);

    return 1;
}

# Does NOT unmap on the NAS. Other nodes of the cluster share the target, and a
# migration deactivates on the source while the destination is using it.
sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    return 1 if defined $snapname;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::Synology::Naming::lun_name($storeid, $volname);
    my $obj = eval { $lun->get($name) };
    eval { $api->logout };
    return 1 if !$obj;

    my $wwid = PVE::Storage::Custom::Synology::LUN::wwid_for_uuid($obj->{uuid});
    $class->_detach_local($storeid, $scfg, $wwid);
    return 1;
}

# Refuse a destructive operation unless the device is provably unused.
sub _assert_not_in_use {
    my ($class, $storeid, $wwid, $what) = @_;
    return if !defined $wwid;

    my $path = PVE::Storage::Custom::Synology::Multipath::device_path_for_wwid($wwid);
    # No device on this node means nothing here is using it.
    return if !defined $path;

    my $in_use = PVE::Storage::Custom::Synology::Multipath::is_device_in_use($path);

    die "storage '$storeid': refusing to $what this disk — could not establish"
      . " whether anything on this node is using $path. That is not the same as"
      . " 'nothing is', and this operation destroys data. Check with"
      . " 'fuser -vm $path' and try again.\n" if !defined $in_use;

    die "storage '$storeid': refusing to $what this disk — $path is IN USE on"
      . " this node. Stop whatever is using it first ('fuser -vm $path' will"
      . " say what).\n" if $in_use;

    return;
}

# Remove the local device for one WWID. One named map, never a node-wide flush.
sub _detach_local {
    my ($class, $storeid, $scfg, $wwid) = @_;
    return if !defined $wwid;

    my $map = PVE::Storage::Custom::Synology::Multipath::map_name_for_wwid($wwid);
    if (defined $map) {
        PVE::Storage::Custom::Synology::Multipath::flush_map($map);
    }

    # Untracked only when the device is verifiably gone: map_is_gone answers
    # undef for "could not tell", and that must not be read as gone.
    my $gone = PVE::Storage::Custom::Synology::Multipath::map_is_gone($wwid);
    $class->_state($storeid)->untrack($wwid) if defined $gone && $gone;
    return;
}

# ---------------------------------------------------------------------------
# Resize, snapshots, clones
# ---------------------------------------------------------------------------

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running, $snapname) = @_;

    die "storage '$storeid': a snapshot cannot be resized\n" if defined $snapname;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::Synology::Naming::lun_name($storeid, $volname);
    my $obj = $lun->get($name)
        or die "storage '$storeid': there is no LUN named '$name'\n";

    # Sizes are created exactly on this array — no alignment arithmetic needed.
    my $new = $lun->resize($obj->{uuid}, $size);
    eval { $api->logout };

    # Then refresh what this node already has. A per-device rescan and a map
    # resize — never a host scan, which discovers new devices rather than
    # refreshing existing ones.
    my $wwid = PVE::Storage::Custom::Synology::LUN::wwid_for_uuid($obj->{uuid});
    my $map = PVE::Storage::Custom::Synology::Multipath::map_name_for_wwid($wwid);
    if (defined $map) {
        # The SLAVES carry the new size up to the map. Rescanning the map itself
        # does nothing — /sys/block/dm-N has no device/rescan — and that is
        # exactly the mistake that made a resize succeed on the NAS while the
        # node went on reporting the old size.
        my $slaves = PVE::Storage::Custom::Synology::Multipath::slaves_of_map($wwid);
        PVE::Storage::Custom::Synology::ISCSI::rescan_device($_) for @$slaves;
        PVE::Storage::Custom::Synology::Multipath::resize_map($map);
    }

    return $new->{size};
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::Synology::Naming::lun_name($storeid, $volname);
    my $obj = $lun->get($name) or die "storage '$storeid': no LUN '$name'\n";

    # Flush BEFORE the snapshot, or it records what reached the NAS rather than
    # what the guest believes it wrote.
    my $wwid = PVE::Storage::Custom::Synology::LUN::wwid_for_uuid($obj->{uuid});
    PVE::Storage::Custom::Synology::Multipath::flush_device_cache($wwid);

    $lun->snapshot_create(
        src_uuid    => $obj->{uuid},
        name        => PVE::Storage::Custom::Synology::Naming::snapshot_name($snap),
        description => "Proxmox VE $storeid",
    );
    eval { $api->logout };
    return 1;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;
    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::Synology::Naming::lun_name($storeid, $volname);
    my $obj = $lun->get($name);
    if (!$obj) { eval { $api->logout }; return 1 }

    # THE OWNERSHIP GATE, explicitly, on the LUN as well as the snapshot.
    #
    # The snapshot whitelist below already refuses a snapshot this plugin did not
    # take, and a snapshot this plugin took implies a LUN this plugin owns — but
    # that is two hops of reasoning guarding an operation that OVERWRITES a disk.
    # Rule: a prefix identifies the STORAGE, never the kind of object, so the
    # object gets its own check.
    die "storage '$storeid': refusing to delete a snapshot of '$name', which this storage does not"
      . " own\n"
        if !PVE::Storage::Custom::Synology::Naming::is_pve_managed_volume($name, $storeid);


    # Only this plugin's own snapshots are visible here, so a user's scheduled
    # snapshot cannot be deleted by a VM operation.
    my ($found) = grep { ($_->{name} // '') eq $snap } @{ $lun->snapshot_list($obj->{uuid}) };
    if (!$found) { eval { $api->logout }; return 1 }

    $lun->snapshot_delete($found->{uuid});
    eval { $api->logout };
    return 1;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::Synology::Naming::lun_name($storeid, $volname);
    my $obj = $lun->get($name) or die "storage '$storeid': no LUN '$name'\n";

    # THE OWNERSHIP GATE, explicitly, on the LUN as well as the snapshot.
    #
    # The snapshot whitelist below already refuses a snapshot this plugin did not
    # take, and a snapshot this plugin took implies a LUN this plugin owns — but
    # that is two hops of reasoning guarding an operation that OVERWRITES a disk.
    # Rule: a prefix identifies the STORAGE, never the kind of object, so the
    # object gets its own check.
    die "storage '$storeid': refusing to roll back '$name', which this storage does not"
      . " own\n"
        if !PVE::Storage::Custom::Synology::Naming::is_pve_managed_volume($name, $storeid);


    my ($found) = grep { ($_->{name} // '') eq $snap } @{ $lun->snapshot_list($obj->{uuid}) };
    die "storage '$storeid': '$name' has no snapshot named '$snap' taken by this"
      . " plugin\n" if !$found;

    my $wwid = PVE::Storage::Custom::Synology::LUN::wwid_for_uuid($obj->{uuid});

    # A rollback OVERWRITES the disk, so it is as destructive as a delete and
    # takes the same guard. PVE stops a rollback on a running VM at a higher
    # level, but a plugin that relied on that would be trusting a caller it does
    # not control.
    $class->_assert_not_in_use($storeid, $wwid, 'roll back');

    # FLUSH BEFORE. Dirty pages written back after the NAS has restored the
    # snapshot would land pre-rollback content on top of it, and the result looks
    # like a rollback that half worked.
    PVE::Storage::Custom::Synology::Multipath::flush_device_cache($wwid);

    # LUN::snapshot_rollback verifies afterwards that the uuid did not change —
    # if it ever does, the device identity moved underneath every node.
    $lun->snapshot_rollback(src_uuid => $obj->{uuid}, snapshot_uuid => $found->{uuid});

    # INVALIDATE AFTER. Demonstrated on this project: reading the device straight
    # after a successful rollback returned the OLD bytes until the cache was
    # dropped. Without this a guest goes on seeing pre-rollback data from cache.
    PVE::Storage::Custom::Synology::Multipath::invalidate_device_cache($wwid);

    eval { $api->logout };
    return 1;
}

# Deliberately NOT overridden to refuse a rollback past newer snapshots.
#
# The related projects must refuse it: on those arrays a rollback destroys the
# newer snapshots, so letting PVE do it silently would delete snapshots the user
# can still see. Measured here: restoring to the oldest of three left all three
# in place, and the LUN's uuid was unchanged. Do not port that refusal without
# re-measuring it.
sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap, $blockers) = @_;
    return 1;
}

# Answered from the NAS. The base implementation runs `qemu-img info` on
# filesystem_path, which does not exist here.
sub volume_snapshot_info {
    my ($class, $scfg, $storeid, $volname) = @_;
    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::Synology::Naming::lun_name($storeid, $volname);
    my $obj = $lun->get($name);
    my $info = {};
    if ($obj) {
        for my $s (@{ $lun->snapshot_list($obj->{uuid}) }) {
            next if !defined $s->{name};
            $info->{ $s->{name} } = {
                id => $s->{uuid},
                # `create_time` is BELIEVED to be epoch seconds and that is R-25,
                # still open. This comment used to say "confirmed against the NAS's
                # own clock", and no measurement of it exists anywhere in the
                # register — which is the one thing this project does not allow a
                # comment to do. A LUN carries no create_time field at all, so it
                # cannot be settled read-only; it needs a snapshot taken and read
                # back against the NAS's clock.
                #
                # Nothing in Proxmox VE 9 reads this value — Replication and
                # QemuServer use the snapshot NAMES and a `parent` field — so a
                # wrong unit would break nothing today. It is guarded anyway,
                # because "nothing reads it yet" is not a property of the data.
                timestamp => _plausible_epoch($s->{create_time}),
            };
        }
    }
    eval { $api->logout };
    return $info;
}

# A timestamp PVE could act on, or none at all.
#
# Reporting a wrong one is worse than reporting nothing: a snapshot dated 1970 or
# the year 58000 sorts to an end of the list and looks like a real answer.
# Milliseconds are converted rather than rejected, because that is the one wrong
# unit an API of this shape actually produces.
sub _plausible_epoch {
    my ($v) = @_;
    return undef if !defined $v || $v !~ /\A[0-9]+\z/;

    # 2001-09-09 .. 2065-01-24. Wide enough that a clock set badly still passes,
    # narrow enough that a millisecond value cannot.
    return $v + 0 if $v >= 1_000_000_000 && $v <= 3_000_000_000;

    # Milliseconds.
    my $s = int($v / 1000);
    return $s if $s >= 1_000_000_000 && $s <= 3_000_000_000;

    return undef;
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $src = PVE::Storage::Custom::Synology::Naming::lun_name($storeid, $volname);
    my $obj = $lun->get($src) or die "storage '$storeid': no LUN '$src'\n";

    my $target = $class->find_free_diskname($storeid, $scfg, $vmid, 'raw');
    my $dst = PVE::Storage::Custom::Synology::Naming::lun_name($storeid, $target);

    # Both clone forms are reflinks, so a linked clone is genuinely cheap.
    if (defined $snap) {
        my ($found) = grep { ($_->{name} // '') eq $snap }
                           @{ $lun->snapshot_list($obj->{uuid}) };
        die "storage '$storeid': '$src' has no snapshot '$snap'\n" if !$found;
        $lun->clone_from_snapshot(src_uuid => $obj->{uuid},
            snapshot_uuid => $found->{uuid}, name => $dst);
    } else {
        $lun->clone(src_uuid => $obj->{uuid}, name => $dst,
            location => $class->_location($scfg));
    }

    eval { $api->logout };

    my ($base) = $volname =~ m{^(base-\d+-\S+)};
    return $base ? "$base/$target" : $target;
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    my ($vtype, $leaf, $vmid, $basename, $basevmid, $isBase) =
        $class->parse_volname($volname);
    die "storage '$storeid': '$volname' is already a template\n" if $isBase;

    my $newname = $leaf;
    $newname =~ s/^vm-/base-/;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $old = PVE::Storage::Custom::Synology::Naming::lun_name($storeid, $leaf);
    my $new = PVE::Storage::Custom::Synology::Naming::lun_name($storeid, $newname);

    my $obj = $lun->get($old) or die "storage '$storeid': no LUN '$old'\n";
    $lun->rename($obj->{uuid}, $new);
    eval { $api->logout };

    return $newname;
}

sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);

    my (undef, $leaf) = $class->parse_volname($source_volname);
    $target_volname //= $class->find_free_diskname($storeid, $scfg, $target_vmid, 'raw');

    my $old = PVE::Storage::Custom::Synology::Naming::lun_name($storeid, $leaf);
    my $new = PVE::Storage::Custom::Synology::Naming::lun_name($storeid, $target_volname);

    my $obj = $lun->get($old) or die "storage '$storeid': no LUN '$old'\n";
    die "storage '$storeid': a LUN named '$new' already exists\n"
        if $lun->get($new);

    $lun->rename($obj->{uuid}, $new);
    eval { $api->logout };
    return "$storeid:$target_volname";
}

# Nothing here decides base vs current by looking at the volname STRING:
# `base-100-disk-0/vm-101-disk-0` starts with `base-` and is a linked clone, and
# reading it that way answered "no" to snapshot and rename for every linked
# clone on the storage in a related project.
sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running, $opts) = @_;

    my (undef, undef, undef, $basename, undef, $isBase) =
        eval { $class->parse_volname($volname) };
    return 0 if $@;

    my $features = {
        snapshot   => { current => 1, snap => 1 },

        # `clone` with a snapshot IS supported: clone_image takes $snap and uses
        # clone_from_snapshot, and the result is a reflink that costs nothing.
        # `current` is supported too, which RBD cannot do — DSM clones a LUN
        # directly, without needing a snapshot to hang the clone off.
        clone      => { base => 1, current => 1, snap => 1 },
        template   => { current => 1 },

        # NO `snap` HERE, and that is a correction rather than an omission.
        #
        # `copy` means PVE reads the source data itself — `qm clone --full
        # --snapshot <name>` asks for exactly this (API2/Qemu.pm), and a yes sends
        # it to `qemu-img convert` on `path($scfg, $volname, $storeid, $snapname)`.
        # That call DIES: a Synology LUN has no device at a snapshot, so there is
        # nothing to read from until the snapshot is cloned or rolled back. RBD can
        # say yes because it addresses a snapshot directly as `pool/image@snap`.
        #
        # Declaring it made PVE start an operation and fail partway, with a message
        # about addressing rather than about the operation. Saying no here makes it
        # refuse up front with "Full clone feature is not supported for a snapshot
        # of ...", which an operator can act on — and the action is a linked clone,
        # which this storage does support.
        copy       => { base => 1, current => 1 },
        sparseinit => { base => 1, current => 1 },
        rename     => { current => 1 },
    };

    my $key = defined $snapname ? 'snap' : ($isBase ? 'base' : 'current');
    return 1 if $features->{$feature}->{$key};
    return undef;
}

1;
