#!/usr/bin/perl

# What the plugin claims it can do must match what it will actually do.
#
# `volume_has_feature` is a promise PVE acts on before it starts work. A yes it
# cannot honour does not produce a clean refusal — it produces a failure partway
# through an operation, with a message about whatever broke rather than about what
# was attempted.
#
# The concrete case: `copy => { snap => 1 }` was declared, `qm clone --full
# --snapshot <name>` asks for exactly that (PVE::API2::Qemu), and a yes sends PVE
# to `qemu-img convert` on `path($scfg, $volname, $storeid, $snapname)` — which
# dies, because a Synology LUN has no device at a snapshot. RBD can say yes; it
# addresses a snapshot directly as `pool/image@snap`. This storage cannot.
#
# So this file exists to keep the declaration and the implementation in the same
# place in someone's head. It reads the source, so it runs with no Proxmox VE.

use strict;
use warnings;
use Test::More;
use lib 'lib';

my $src = do {
    open(my $fh, '<', 'lib/PVE/Storage/Custom/SynologySANPlugin.pm')
        or BAIL_OUT('cannot read the plugin');
    local $/; <$fh>;
};

my ($block) = $src =~ /my \$features = \{(.*?)\n    \};/s;
ok($block, 'the feature table is where it is expected');

# Parse it into { feature => { key => 1 } } so the assertions are about meaning
# rather than about formatting.
my %declared;
while ($block =~ /^\s*(\w+)\s*=>\s*\{([^}]*)\}/mg) {
    my ($feature, $keys) = ($1, $2);
    $declared{$feature} = { map { $_ => 1 } ($keys =~ /(\w+)\s*=>\s*1/g) };
}

# --- the correction, and why it must not come back -------------------------

ok(!$declared{copy}{snap},
   'copy is NOT claimed for a snapshot: path() dies on a snapname, so a full'
 . ' clone from a snapshot would fail partway rather than be refused');

ok($declared{copy}{current}, 'copy of the current state is claimed');
ok($declared{copy}{base},    'and of a base');

# --- what IS supported for a snapshot --------------------------------------

ok($declared{clone}{snap},
   'clone from a snapshot IS claimed — clone_image takes $snap and uses'
 . ' clone_from_snapshot, which needs no device on the node');

ok($declared{clone}{current},
   'and clone of the current state, which RBD cannot do: DSM clones a LUN'
 . ' directly without needing a snapshot to hang it off');

# --- the invariant behind all of it ----------------------------------------
#
# Anything claimed with `snap` must not depend on **path()**, which refuses a
# snapname outright. This is checked as an explicit list so that adding a `snap`
# key forces someone to come back here.
#
# It used to say "path() or activate_volume", and the second half was wrong in a
# way that cost the `clone` capability: PVE's clone_vm activates the source with
# the snapname before cloning it, so a die in activate_volume refused the very
# operation the table promised. This assertion encoded that mistake and had to be
# corrected along with the code — which is the point of writing the invariant
# down as a test rather than as a comment.
my @snap_claimed = sort grep { $declared{$_}{snap} } keys %declared;
is_deeply(\@snap_claimed, ['clone', 'snapshot'],
          'only clone and snapshot are claimed for a snapshot')
    or diag('claimed with snap: ' . join(', ', @snap_claimed)
          . ' — anything new here must work without path(), which dies on a'
          . ' snapname, and must tolerate an activate_volume that does nothing');

like($src, qr/cannot be addressed at a snapshot/,
     'path() refuses a snapname, and must');

# --- rename and template, which are current-only ---------------------------
ok($declared{rename}{current} && !$declared{rename}{snap},
   'rename is current-only');
ok($declared{template}{current} && !$declared{template}{snap},
   'template is current-only');

# --- and the undef contract ------------------------------------------------
#
# volume_has_feature returns undef rather than 0 for an unsupported combination,
# which is what the base class does and what PVE tests for truth.
like($src, qr/return 1 if \$features->\{\$feature\}->\{\$key\};\s*\n\s*return undef;/,
     'an unsupported combination answers undef, not 0');


# --- the snapshot timestamp, which was asserted rather than measured --------
#
# `create_time` is believed to be epoch seconds. That is R-25 and it is still
# open: a LUN carries no create_time field at all, so it cannot be settled
# read-only, and the code comment claiming it had been "confirmed against the
# NAS's own clock" cited a measurement that exists nowhere in the register.
#
# Nothing in Proxmox VE 9 reads the value — Replication and QemuServer use the
# snapshot NAMES and a `parent` field — so a wrong unit breaks nothing today.
# Guarded anyway, because "nothing reads it yet" is not a property of the data.

# Loading the plugin needs Proxmox VE, and CI runs with none — so the guard's
# behaviour is checked where PVE exists and its presence is checked everywhere.
SKIP: {
    skip 'no Proxmox VE on this machine', 8
        if !eval { require PVE::Storage::Custom::SynologySANPlugin; 1 };

    my $ep = \&PVE::Storage::Custom::SynologySANPlugin::_plausible_epoch;

    is($ep->(1786011363), 1786011363, 'a plausible epoch-seconds value passes through');
    is($ep->(1786011363000), 1786011363, 'milliseconds are converted, not rejected');

    is($ep->(0),      undef, 'zero is not a timestamp');
    is($ep->(12345),  undef, 'a small integer yields nothing rather than 1970');
    is($ep->(undef),  undef, 'undef in, undef out');
    is($ep->('abc'),  undef, 'a non-numeric value yields nothing');
    is($ep->('17e9'), undef, 'and so does something merely numeric-looking');
    is($ep->(1786011363000000), undef, 'microseconds are out of range and refused');
}

unlike($src, qr/confirmed against the NAS's own clock/,
       'the unmeasured claim is gone from the source');
like($src, qr/R-25, still open|R-25/,
     'and the open register item is named where the value is used');


# --- list_images must filter the way the base class filters ------------------
#
# PVE's own list_images applies the vmid filter only when NO $vollist was given:
# `next if !$vollist && defined($vmid) && ($owner ne $vmid)`. When the caller
# named exact volids it knows what it asked for. Applying both would leave a
# requested volid silently absent — the same fault class as R-9's quietly
# truncated listing, and the code that reads such a list decides what may be
# deleted.
#
# No caller in Proxmox VE 9 passes both, so this is a latent divergence rather
# than a live bug. It is asserted because the base guards it on purpose.
{
    # The filtering lives in `_images_from_luns`, not `list_images`. It was split
    # out so that a caller which already holds the LUN listing does not fetch it
    # again — an allocation used to make three separate `LUN list` calls. This test
    # was pinned to the old function name and had to follow the code.
    my ($li) = $src =~ /\nsub _images_from_luns \{(.*?)\n\}/s;
    ok($li, '_images_from_luns is there');
    like($li, qr/next if !\$vollist && defined \$vmid/,
         'the vmid filter is conditional on no vollist, as in the base class');
    unlike($li, qr/next if defined \$vmid && \$owner ne \$vmid;/,
           'and not applied unconditionally');
    like($li, qr/ctime\s*=>\s*undef/,
         'ctime is undef, honestly: a LUN carries no create_time field (R-25)');
}

# --- what a `snap` claim actually requires -----------------------------------
#
# The invariant used to be written as "anything claimed with `snap` must work
# without path() OR activate_volume, because both refuse a snapname". Half of
# that was wrong, and it cost the `clone` capability: PVE's clone_vm activates
# the source volumes WITH the snapname before cloning them —
# `activate_volumes($storecfg, $vollist, $snapname)` in API2/Qemu.pm — for a
# linked clone as much as a full one. A die there refused the whole operation,
# with a message telling the operator to clone it while they were cloning it.
#
# The corrected invariant: a `snap` claim must work without **path()**, and
# activate_volume must be a successful NO-OP for a snapname. deactivate_volume
# had always been one; activation was the missing half.
subtest 'activate_volume tolerates a snapname, path() still refuses one' => sub {
    my ($activate) = $src =~ /\nsub activate_volume \{(.*?)\n\}/s;
    ok(defined $activate, 'found activate_volume');

    unlike($activate, qr/die[^;]*snapshot cannot be activated/,
           'it no longer dies on a snapname — that broke clone-from-snapshot');
    like($activate, qr/return 1 if defined \$snapname/,
         'it returns success and does nothing, which is what there is to do');

    my ($deactivate) = $src =~ /\nsub deactivate_volume \{(.*?)\n\}/s;
    like($deactivate, qr/return 1 if defined \$snapname/,
         'and deactivate_volume is the same, so the pair is symmetric');

    # path() must keep refusing: a caller that needs a device AT a snapshot has
    # to fail loudly rather than be handed the current state's device.
    my ($path) = $src =~ /\nsub path \{(.*?)\n\}/s;
    ok(defined $path, 'found path');
    like($path, qr/\$snapname/,
         'path() still looks at the snapname rather than ignoring it');
};

done_testing();
