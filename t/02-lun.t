#!/usr/bin/perl
# The LUN layer's pure decisions. Every case is a measured DSM behaviour.

use strict;
use warnings;
use Test::More;

use lib 'lib';
use_ok('PVE::Storage::Custom::Synology::LUN');
my $L = 'PVE::Storage::Custom::Synology::LUN';

# --- the WWID derivation, on both samples measured against hardware --------
my $w = \&PVE::Storage::Custom::Synology::LUN::wwid_for_uuid;

is($w->('a1b2c3d4-5e6f-4a7b-8c9d-0e1f2a3b4c5d'), '36001405a1b2c3d4d5e6fd4a7bd8c9dd0',
   'the documented worked example');
is($w->('13a3cd1e-f296-4d4b-b712-a85c139f9dac'), '3600140513a3cd1edf296d4d4bdb712da',
   'the second hardware sample, confirmed against scsi_id on an attached LUN');
is(length($w->('13a3cd1e-f296-4d4b-b712-a85c139f9dac')), 33, 'a WWID is 33 characters');
is($w->('13A3CD1E-F296-4D4B-B712-A85C139F9DAC'), $w->('13a3cd1e-f296-4d4b-b712-a85c139f9dac'),
   'case in the uuid does not change the WWID');

# Stock LIO skips non-hex characters instead of mapping them, which would give
# a different answer. If this ever starts matching, the rule has been changed
# to the upstream one and is wrong for Synology.
isnt($w->('13a3cd1e-f296-4d4b-b712-a85c139f9dac'),
     '3' . '6001405' . substr('13a3cd1ef2964d4bb712a85c139f9dac', 0, 25),
     'the rule is Synology\'s, not upstream LIO\'s hyphen-skipping');

is($w->(undef), undef, 'undef in, undef out');
is($w->('not-a-uuid'), undef, 'a malformed uuid yields no WWID rather than a wrong one');
is($w->(''), undef, 'an empty string yields no WWID');

# --- name rules, measured: _ space + @ are refused with 18990503 ----------
my $ok = \&PVE::Storage::Custom::Synology::LUN::name_is_legal;

ok($ok->('vm-100-disk-0'),        'a hyphenated PVE-style name is legal');
ok($ok->('pve-syno1-vm-100-disk-0'), 'a prefixed name is legal');
ok($ok->('name.with.dots'),       'dots are legal, unlike on PowerVault');
ok($ok->('name:with:colons'),     'colons are legal');
ok($ok->('MixedCase123'),         'upper case and digits are legal');

ok(!$ok->('has_underscore'), 'UNDERSCORE is refused — a PVE storage id may contain one');
ok(!$ok->('has space'),      'a space is refused');
ok(!$ok->('has+plus'),       'a plus is refused');
ok(!$ok->('has@at'),         'an at sign is refused');
ok(!$ok->(''),               'an empty name is refused');
ok(!$ok->(undef),            'undef is refused');
ok(!$ok->('-leading-hyphen'),'a leading hyphen is refused, so a name cannot look like a flag');
ok(!$ok->('x' x 129),        'a name past the limit is refused HERE, not at the NAS');
ok($ok->('x' x 128),         'and the limit itself is accepted');

# The reason the limit is enforced locally: at 255 characters DSM refuses the
# create AND makes the LUN anyway.
eval { PVE::Storage::Custom::Synology::LUN::assert_name_legal('has_underscore') };
like($@, qr/underscore/, 'the refusal names the actual character DSM rejects');
eval { PVE::Storage::Custom::Synology::LUN::assert_name_legal('x' x 300) };
like($@, qr/longer than/, 'an over-long name is refused with the reason');

# --- constants that encode measured behaviour -----------------------------
is($L->LUN_TYPE_THIN, 'BLUN', 'thin on Btrfs is the only type with snapshots');
is($L->MIN_SIZE, 1024**3, 'the 1 GB minimum is enforced here because the API does not');
cmp_ok($L->MAX_NAME, '<', 255, 'the name limit stays well clear of the refused-but-created boundary');
cmp_ok($L->LOCK_WAIT_DEFAULT, '>', 20, "the lock wait exceeds the CSI driver's 20s, which is too short for a large clone");

done_testing();
