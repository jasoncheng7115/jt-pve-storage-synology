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

# --- the per-model ceiling --------------------------------------------------
# A DS918+ reports max_iscsiluns 256, not the 512 on the specification sheet.
# The plugin refuses before the NAS does, so the message names the real reason
# rather than arriving as error 18990541.
{
    package FakeAPI;
    sub new { my ($c,%o)=@_; bless {%o}, $c }
    sub storeid { 'syno1' }
    sub limits { $_[0]->{limits} }
    sub call { my $s=shift; return { success => 1, data => { luns => $s->{luns} } } }
}
my $at_limit = PVE::Storage::Custom::Synology::LUN->new(
    FakeAPI->new(limits => { luns => 3 },
                 luns => [ map { { uuid => "u$_", name => "n$_" } } 1..3 ]));
eval { $at_limit->assert_room_for_lun };
like($@, qr/maximum \(3\)/, 'at the ceiling the refusal names the model maximum');
like($@, qr/Free space is not the problem/,
     'and says free space will not help, because pvesm status will show plenty');
like($@, qr/Virtual Machine Manager/,
     "and warns the count includes LUNs this storage does not own");

my $room = PVE::Storage::Custom::Synology::LUN->new(
    FakeAPI->new(limits => { luns => 10 },
                 luns => [ map { { uuid => "u$_", name => "n$_" } } 1..3 ]));
ok($room->assert_room_for_lun, 'below the ceiling it proceeds');

# A NAS that does not report a ceiling must not have one invented for it.
my $unknown = PVE::Storage::Custom::Synology::LUN->new(
    FakeAPI->new(limits => { luns => undef },
                 luns => [ map { { uuid => "u$_", name => "n$_" } } 1..999 ]));
ok($unknown->assert_room_for_lun,
   'an unreported ceiling stops the guard rather than becoming a guessed number');


# --- resize: shrink must be refused, not silently declined ----------------
#
# `resize` used to short-circuit on `$lun->{size} >= $new_size`, which made a
# shrink request return the LUN unchanged — a success for something that did not
# happen. PVE writes the REQUESTED size into the VM configuration regardless of
# what a plugin returns (`$drive->{size} = $newsize` in API2/Qemu.pm), so the
# configuration would have claimed a size the NAS does not have.

{
    package MockAPI;
    sub new { my ($c,%o)=@_; bless { calls => [], %o }, $c }
    sub storeid { 'mock' }
    sub call_ok {
        my ($self, $api, $method, %p) = @_;
        push @{ $self->{calls} }, [ $method, \%p ];
        return { };
    }
    sub call { my $s = shift; return { success => 1, data => {} } }
}
{
    package MockLUN;
    our @ISA = ('PVE::Storage::Custom::Synology::LUN');
    sub new { my ($c,%o)=@_; bless { api => MockAPI->new, size => $o{size} }, $c }
    sub api { $_[0]->{api} }
    sub get { return { uuid => 'u-1', size => $_[0]->{size} } }
    sub wait_unlocked { return 1 }
}

my $shrink = MockLUN->new(size => 10 * 1024 ** 3);
eval { $shrink->resize('u-1', 5 * 1024 ** 3) };
like($@, qr/refusing to shrink/,
     'a smaller size is refused rather than reported as done');
like($@, qr/claiming a size the NAS does not have/,
     'and the refusal says why it matters, not just that it is refused');
is(scalar @{ $shrink->api->{calls} }, 0,
   'nothing was sent to the NAS — the refusal precedes the request');

my $same = MockLUN->new(size => 10 * 1024 ** 3);
my $r = eval { $same->resize('u-1', 10 * 1024 ** 3) };
is($@, '', 'an equal size is not an error');
is(scalar @{ $same->api->{calls} }, 0,
   'and is idempotent: PVE pads a request up to a multiple of 1024, so asking'
   . ' twice for the same figure is ordinary');

my $grow = MockLUN->new(size => 10 * 1024 ** 3);
eval { $grow->resize('u-1', 20 * 1024 ** 3) };
my @sent = @{ $grow->api->{calls} };
is(scalar @sent, 1, 'growing sends exactly one call');
is($sent[0][0], 'set', 'via set');
is($sent[0][1]{new_size}, 20 * 1024 ** 3, 'with the requested total, not a delta');


# --- create: the delete-on-refusal path must prove the object is new ------
#
# DSM refusing a create and doing it anyway is a measured behaviour, and the
# cleanup deletes what a lookup finds. Until the pre-check was added, the only
# thing separating "delete what DSM just made" from "delete a LUN that was
# already there" was the error code not being 18990538 — proof by absence, for a
# destructive action.

{
    package MockCreateAPI;
    sub new { my ($c,%o)=@_; bless { calls=>[], %o }, $c }
    sub storeid { 'mock' }
    sub limits { { luns => undef } }        # the NAS did not say -> no ceiling guard
    sub call {
        my ($self, $api, $method, %p) = @_;
        push @{ $self->{calls} }, $method;
        return $self->{create_answer} if $method eq 'create';
        return { success => 1, data => {} };
    }
    sub call_ok { my $s=shift; $s->call(@_); return {} }
}
{
    package MockCreateLUN;
    our @ISA = ('PVE::Storage::Custom::Synology::LUN');
    sub new {
        my ($c,%o)=@_;
        bless { api => MockCreateAPI->new(create_answer => $o{create_answer}),
                existing => $o{existing}, deleted => [] }, $c;
    }
    sub api { $_[0]->{api} }
    sub get {
        my ($self, $key) = @_;
        return $self->{existing};
    }
    sub delete { my ($s,$u,%o)=@_; push @{ $s->{deleted} }, $u; return 1 }
    sub wait_unlocked { 1 }
    sub deleted { $_[0]->{deleted} }
}

# A name that is already taken is refused before anything is sent.
my $taken = MockCreateLUN->new(
    existing      => { uuid => 'someone-elses', name => 'pve-s-vm-1-disk-0' },
    create_answer => { success => 1, data => { uuid => 'new' } },
);
eval { $taken->create(name => 'pve-s-vm-1-disk-0', size => 2*1024**3, location => '/volume1') };
like($@, qr/already\s+exists on the NAS/,
     'an existing name is refused before the create is attempted');
is_deeply($taken->api->{calls}, [],
     'and no create was ever sent — the refusal precedes the request')
    or diag('calls: ' . join(',', @{ $taken->api->{calls} }));
is_deeply($taken->deleted, [],
     'crucially: someone else\'s LUN of that name is NOT deleted');

done_testing();
