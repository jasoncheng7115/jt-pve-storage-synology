package PVE::Storage::Custom::Synology::Naming;

# Array object names, and the ownership gate.
#
# This module answers one question that matters more than the rest: **may this
# plugin delete this object?** Getting it wrong in the permissive direction
# destroys someone else's data, so the gate takes the storage id and not just
# the shape of a name — a prefix identifies the STORAGE, never the kind of
# object, and every disk on a storage passes a bare prefix test.
#
# The awkward part is Synology-specific and was measured: **`_` is not a legal
# character in a LUN name** (18990503), while a Proxmox VE storage id may
# contain one. So a storage id has to be folded before it can appear in a name,
# and folding is lossy: `syno_1` and `syno-1` both become `syno-1`. Two such
# storages on one NAS would share every name, each would list the other's
# disks, and the ownership gate would pass for both.
#
# That cannot be fixed inside the name. It is fixed at the moment the data is
# created, by refusing the second colliding storage in `on_add_hook` — which is
# why `fold_collides_with` exists here rather than only in the plugin.
#
# Snapshot names, by contrast, need no folding at all: DSM accepts underscores,
# spaces, `+`, `@`, leading digits and 64-character names in a snapshot name,
# storing every one of them exactly. PVE's snapshot names therefore pass
# straight through, and duplicates within one LUN are refused by DSM itself
# (18990513), so a name identifies a snapshot uniquely.

use strict;
use warnings;

# Everything here is a plain function, not a method. Calling one as
# `Naming->is_pve_managed_volume($name, $storeid)` shifts the arguments along
# and the gate then answers "not owned" for an object that IS owned — safe, but
# silently wrong, and a listing would simply come back empty with no error to
# explain it. Writing the tests caught exactly that, so it is now loud.
sub _not_a_method {
    my ($first) = @_;
    return if !defined $first;
    return if $first ne __PACKAGE__;
    die __PACKAGE__ . ": these are functions, not methods. Call"
      . " Naming::name(...) rather than Naming->name(...).\n";
}

use constant {
    # Marks the objects this plugin owns. Not sufficient on its own — see the
    # note above about a prefix identifying only the storage.
    PREFIX => 'pve',

    # Well clear of the 128 the LUN layer enforces and the ~200 DSM allows.
    MAX_STOREID_FOLD => 32,
};

# Characters DSM refuses in a LUN name, measured: `_`, space, `+`, `@`. Anything
# outside the legal set becomes a hyphen. Legal: letters, digits, `-`, `.`, `:`.
#
# `.` and `:` are legal on the NAS but are folded away too: a dot is how PVE
# marks a snapshot name it forbids users from typing, and a colon is the
# separator inside a volid. Keeping them out of a generated name means a
# generated name can never be confused with either.
sub fold_storeid {
    _not_a_method($_[0]);
    my ($storeid) = @_;
    return '' if !defined $storeid;
    my $s = lc $storeid;
    $s =~ s/[^a-z0-9-]/-/g;
    $s =~ s/-+/-/g;          # a run of illegal characters is one hyphen
    $s =~ s/\A-+//;
    $s =~ s/-+\z//;
    $s = substr($s, 0, MAX_STOREID_FOLD) if length($s) > MAX_STOREID_FOLD;
    $s =~ s/-+\z//;          # truncation must not leave a trailing hyphen
    return $s;
}

# Whether two storage ids would produce the same names on one NAS. `on_add_hook`
# uses this to refuse the second one: they are indistinguishable afterwards, and
# each could delete the other's disks.
sub fold_collides_with {
    _not_a_method($_[0]);
    my ($storeid, $other) = @_;
    return 0 if !defined $storeid || !defined $other;
    return 0 if $storeid eq $other;
    return fold_storeid($storeid) eq fold_storeid($other) ? 1 : 0;
}

sub prefix_for {
    _not_a_method($_[0]);
    my ($storeid) = @_;
    my $fold = fold_storeid($storeid);
    die "storage id '" . ($storeid // '') . "' contains no character that can"
      . " appear in a Synology LUN name\n" if !length $fold;
    return PREFIX . '-' . $fold;
}

# A PVE disk name: vm-100-disk-0, base-100-disk-1, and the vm-100-cloudinit
# form. Deliberately anchored with \z and not $ — `$` also matches before a
# trailing newline, so "vm-100-disk-0\n" would resolve to the same object.
my $PVE_DISK = qr/\A(?:vm|base)-(\d+)-(?:disk|cloudinit|state)-?(\w*)\z/;

sub is_pve_disk_name {
    _not_a_method($_[0]);
    my ($name) = @_;
    return 0 if !defined $name;
    return $name =~ $PVE_DISK ? 1 : 0;
}

# PVE hands a linked clone's volname as `base-100-disk-0/vm-101-disk-0`. The
# LEAF is the object on the array; the part before the slash is its parent, and
# it is not part of this object's name.
sub leaf_of {
    _not_a_method($_[0]);
    my ($volname) = @_;
    return undef if !defined $volname;
    my @parts = split m{/}, $volname;
    return $parts[-1];
}

sub lun_name {
    _not_a_method($_[0]);
    my ($storeid, $volname) = @_;
    my $leaf = leaf_of($volname);
    die "cannot build a LUN name from an empty volume name\n"
        if !defined $leaf || !length $leaf;
    die "'$leaf' is not a Proxmox VE disk name\n" if !is_pve_disk_name($leaf);
    return prefix_for($storeid) . '-' . $leaf;
}

# THE OWNERSHIP GATE.
#
# Takes the storage id, not merely a name that looks like some PVE plugin's.
# Both halves are required: the prefix says which storage, and the remainder
# must be a PVE disk name — otherwise every object on the NAS whose name starts
# with the prefix would qualify, including ones this plugin did not create.
sub is_pve_managed_volume {
    _not_a_method($_[0]);
    my ($name, $storeid) = @_;
    return 0 if !defined $name || !defined $storeid;

    my $prefix = eval { prefix_for($storeid) };
    return 0 if !defined $prefix;

    return 0 if index($name, "$prefix-") != 0;

    my $leaf = substr($name, length($prefix) + 1);
    return is_pve_disk_name($leaf) ? 1 : 0;
}

# The reverse: what PVE calls the object whose LUN has this name. Returns undef
# for anything this storage does not own, so a listing can filter with it.
sub volname_from_lun_name {
    _not_a_method($_[0]);
    my ($name, $storeid) = @_;
    return undef if !is_pve_managed_volume($name, $storeid);
    my $prefix = prefix_for($storeid);
    return substr($name, length($prefix) + 1);
}

# Temporary objects this plugin creates and must be able to remove unattended.
# Named so that they are unmistakably ours AND unmistakably not a VM disk: a
# reaper that accepted anything with the storage's prefix would accept every
# disk on the storage.
sub temp_name {
    _not_a_method($_[0]);
    my ($storeid, $purpose, $token) = @_;
    $purpose //= 'tmp';
    $purpose =~ s/[^a-z0-9]//g;
    $token   //= '';
    $token   =~ s/[^A-Za-z0-9]//g;
    return prefix_for($storeid) . '-tmp-' . $purpose . ($token ? "-$token" : '');
}

sub is_temp_name {
    _not_a_method($_[0]);
    my ($name, $storeid) = @_;
    return 0 if !defined $name || !defined $storeid;
    my $prefix = eval { prefix_for($storeid) };
    return 0 if !defined $prefix;
    return index($name, "$prefix-tmp-") == 0 ? 1 : 0;
}

# Snapshot names pass through unchanged — see the note at the top of this file.
# The only thing checked is that PVE gave us something usable, because a name
# is how a snapshot is found again (DSM refuses a duplicate within one LUN with
# 18990513, so a name is unique where it matters).
sub snapshot_name {
    _not_a_method($_[0]);
    my ($snapname) = @_;
    die "a snapshot needs a name\n" if !defined $snapname || !length $snapname;
    # PVE's own limit. DSM accepted 64 characters and more, so this is PVE's
    # constraint being respected rather than the array's being approached.
    die "snapshot name '$snapname' is longer than 40 characters\n"
        if length($snapname) > 40;
    return $snapname;
}

1;
