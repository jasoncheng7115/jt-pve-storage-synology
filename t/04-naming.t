#!/usr/bin/perl
# Naming and the ownership gate. The gate decides what may be DELETED, so the
# hostile cases matter more than the happy ones.
use strict; use warnings; use Test::More; use lib 'lib';
use_ok('PVE::Storage::Custom::Synology::Naming');
my $N = 'PVE::Storage::Custom::Synology::Naming';
*fold = \&PVE::Storage::Custom::Synology::Naming::fold_storeid;
*owned = \&PVE::Storage::Custom::Synology::Naming::is_pve_managed_volume;
*lunname = \&PVE::Storage::Custom::Synology::Naming::lun_name;

# --- folding: underscore is illegal in a LUN name, storage ids may have one --
is(fold('syno1'), 'syno1', 'a simple id is unchanged');
is(fold('syno_1'), 'syno-1', 'underscore folds to a hyphen, because DSM refuses it');
is(fold('SYNO1'), 'syno1', 'folding is lower case');
is(fold('syno.1'), 'syno-1', 'a dot folds away, so a name cannot look like a PVE snapshot marker');
is(fold('syno:1'), 'syno-1', 'a colon folds away, so a name cannot look like a volid separator');
is(fold('a__b'), 'a-b', 'a run of illegal characters becomes one hyphen');
is(fold('_lead_'), 'lead', 'leading and trailing hyphens are trimmed');
cmp_ok(length(fold('x' x 100)), '<=', 32, 'a long id is truncated');
unlike(fold('x' x 31 . '_y'), qr/-\z/, 'truncation never leaves a trailing hyphen');

# --- the collision this folding creates, and which on_add_hook must refuse ---
ok(PVE::Storage::Custom::Synology::Naming::fold_collides_with('syno_1', 'syno-1'), 'syno_1 and syno-1 collide');
ok(PVE::Storage::Custom::Synology::Naming::fold_collides_with('syno.1', 'syno:1'), 'a dot and a colon collide');
ok(!PVE::Storage::Custom::Synology::Naming::fold_collides_with('syno1', 'syno2'), 'different ids do not');
ok(!PVE::Storage::Custom::Synology::Naming::fold_collides_with('syno1', 'syno1'), 'an id does not collide with itself');

# --- building names ---------------------------------------------------------
is(lunname('syno1', 'vm-100-disk-0'), 'pve-syno1-vm-100-disk-0', 'a disk name');
is(lunname('syno_1', 'vm-100-disk-0'), 'pve-syno-1-vm-100-disk-0', 'with a folded id');
is(lunname('syno1', 'base-100-disk-0'), 'pve-syno1-base-100-disk-0', 'a template');
# A linked clone's volname carries its parent. The object on the array is the leaf.
is(lunname('syno1', 'base-100-disk-0/vm-101-disk-0'), 'pve-syno1-vm-101-disk-0',
   'a linked clone is named for its LEAF, not its parent');
ok(PVE::Storage::Custom::Synology::LUN::name_is_legal(lunname('syno_1','vm-100-disk-0')),
   'a generated name is always legal on DSM')
    if eval { require PVE::Storage::Custom::Synology::LUN; 1 };

eval { lunname('syno1', 'not-a-disk') };
like($@, qr/not a Proxmox VE disk name/, 'a name that is not a PVE disk is refused');
eval { lunname('syno1', '') };
like($@, qr/empty/, 'an empty volname is refused');

# --- THE OWNERSHIP GATE -----------------------------------------------------
ok(owned('pve-syno1-vm-100-disk-0', 'syno1'), 'our own disk is ours');
ok(owned('pve-syno1-base-100-disk-0', 'syno1'), 'our own template is ours');

# The storage id is required, and it is what stops one storage deleting another's.
ok(!owned('pve-syno2-vm-100-disk-0', 'syno1'), "another storage's disk is NOT ours");
ok(!owned('pve-syno1-vm-100-disk-0', 'syno2'), 'and the check is symmetric');
ok(!owned('pve-syno1-vm-100-disk-0', undef), 'without a storage id nothing is owned');
ok(!owned(undef, 'syno1'), 'an undefined name is not owned');

# A prefix identifies the STORAGE, never the kind of object. Both halves needed.
ok(!owned('pve-syno1-something-else', 'syno1'),
   'the prefix alone is not enough — the remainder must be a PVE disk name');
ok(!owned('pve-syno1-', 'syno1'), 'a bare prefix owns nothing');
ok(!owned('pve-syno1', 'syno1'), 'the prefix without a separator owns nothing');

# Hostile shapes.
ok(!owned('LUN-1', 'syno1'), "a user's own LUN is never ours");
ok(!owned('vdisk.a7b02ea3-c56b.2.0', 'syno1'), 'a Virtual Machine Manager disk is never ours');
ok(!owned('xpve-syno1-vm-100-disk-0', 'syno1'), 'the prefix must be at the start');
ok(!owned("pve-syno1-vm-100-disk-0\n", 'syno1'),
   'a trailing newline does not resolve to the same object — anchored with \z, not $');
# The folding collision, seen from the gate's side: this is why the second
# colliding storage is refused at add time rather than handled here.
ok(owned('pve-syno-1-vm-100-disk-0', 'syno_1'), 'a folded id owns its own disks');
ok(owned('pve-syno-1-vm-100-disk-0', 'syno-1'),
   'and so does the id it collides with — which is exactly why on_add_hook refuses it');

# --- reverse mapping --------------------------------------------------------
is(PVE::Storage::Custom::Synology::Naming::volname_from_lun_name('pve-syno1-vm-100-disk-0', 'syno1'), 'vm-100-disk-0',
   'a LUN name maps back to a volname');
is(PVE::Storage::Custom::Synology::Naming::volname_from_lun_name('LUN-1', 'syno1'), undef,
   'a foreign LUN maps back to nothing, so a listing filters cleanly');

# --- temporary objects ------------------------------------------------------
my $tmp = PVE::Storage::Custom::Synology::Naming::temp_name('syno1', 'clone', 'abc123');
like($tmp, qr/\Apve-syno1-tmp-clone/, 'a temp name is unmistakably ours');
ok(PVE::Storage::Custom::Synology::Naming::is_temp_name($tmp, 'syno1'), 'and recognised as temporary');
ok(!owned($tmp, 'syno1'),
   'a temp object is NOT a VM disk — an unattended reaper must not accept one as a disk');
ok(!PVE::Storage::Custom::Synology::Naming::is_temp_name('pve-syno1-vm-100-disk-0', 'syno1'), 'a real disk is not temporary');
ok(!PVE::Storage::Custom::Synology::Naming::is_temp_name($tmp, 'syno2'), "another storage's temp object is not ours");

# --- snapshot names pass through unchanged ----------------------------------
# Measured: DSM stores _, space, +, @ and a leading digit in a snapshot name
# exactly, so PVE's names need no folding at all.
is(PVE::Storage::Custom::Synology::Naming::snapshot_name('before_upgrade'), 'before_upgrade',
   'an underscore survives in a snapshot name, unlike in a LUN name');
is(PVE::Storage::Custom::Synology::Naming::snapshot_name('snap-1.2'), 'snap-1.2', 'punctuation survives');
eval { PVE::Storage::Custom::Synology::Naming::snapshot_name('x' x 41) };
like($@, qr/40 characters/, "PVE's own 40-character limit is respected");
eval { PVE::Storage::Custom::Synology::Naming::snapshot_name('') };
like($@, qr/needs a name/, 'an empty snapshot name is refused');

# Calling a function as a method used to shift the arguments and make the
# ownership gate answer "not owned" silently. It now says so.
eval { PVE::Storage::Custom::Synology::Naming->is_pve_managed_volume('pve-syno1-vm-100-disk-0', 'syno1') };
like($@, qr/functions, not methods/, 'a method call is refused loudly rather than answering wrongly');

done_testing();
