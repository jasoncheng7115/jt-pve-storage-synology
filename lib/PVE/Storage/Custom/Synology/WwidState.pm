package PVE::Storage::Custom::Synology::WwidState;

# Per-node tracking of the WWIDs this node has claimed.
#
# Why this exists at all: `free_image` must clean up the local device before the
# LUN is deleted on the NAS, and after the LUN is gone there is nothing left to
# ask which device belonged to it. So the mapping is written down while it is
# still knowable.
#
# It is also what makes an orphan answerable. A node that was rebooted, or that
# lost a `deactivate_volume` to a crash, keeps a multipath map for a LUN nobody
# uses. Without a record there is no way to tell that map from one belonging to
# another storage — and `mapping_index` reuse means the device path certainly
# cannot say.
#
# The rules this file obeys, all inherited:
#
#   * `flock` is always `LOCK_EX | LOCK_NB` inside a bounded retry loop. A
#     blocking lock here would hang `pvesm status` for every storage on the node.
#   * A corrupt state file must not be able to make an unattended path do
#     anything destructive: every entry is validated on read, and an entry that
#     does not parse is dropped rather than acted on.
#   * State is per node and per storage. Two storages on one node never share a
#     file, and nothing here is ever consulted about another node.

use strict;
use warnings;

use PVE::Storage::Custom::Synology::Naming;

use Fcntl qw(:flock O_RDWR O_CREAT);

use constant {
    # Survives a reboot: an orphan from before the reboot is exactly the case
    # this is for.
    DIR => '/var/lib/jt-pve-storage-synology',
    LOCK_TRIES => 20,
};

sub new {
    my ($class, $storeid) = @_;
    die "a state file needs a storage id\n" if !defined $storeid || !length $storeid;

    # Sanitised and untainted in one place — see Naming::filename_component for
    # why the untainting is not optional under pvedaemon's -T.
    my $safe = PVE::Storage::Custom::Synology::Naming::filename_component($storeid);
    die "storage id '$storeid' cannot be used in a filename\n" if !defined $safe;

    return bless {
        storeid => $storeid,
        file    => DIR . "/$safe.wwids",
    }, $class;
}

sub file { return $_[0]->{file} }

sub _ensure_dir {
    my ($self) = @_;
    return 1 if -d DIR;
    mkdir DIR, 0700;
    return -d DIR ? 1 : 0;
}

# LOCK_EX | LOCK_NB in a bounded loop. Never a blocking lock.
sub _with_lock {
    my ($self, $code) = @_;
    return $code->({}) if !$self->_ensure_dir;

    my $fh;
    if (!open($fh, '+>>', $self->{file})) {
        warn "storage '$self->{storeid}': cannot open $self->{file}: $!\n";
        return $code->({});
    }

    my $locked = 0;
    for (1 .. LOCK_TRIES) {
        if (flock($fh, LOCK_EX | LOCK_NB)) { $locked = 1; last }
        select(undef, undef, undef, 0.1);
    }
    if (!$locked) {
        close($fh);
        warn "storage '$self->{storeid}': could not lock $self->{file} within"
           . " a second; skipping the state update rather than waiting\n";
        return $code->({});
    }

    my $state = $self->_read_locked($fh);
    my ($result, $changed) = $code->($state);
    $self->_write_locked($fh, $state) if $changed;

    flock($fh, LOCK_UN);
    close($fh);
    return $result;
}

sub _read_locked {
    my ($self, $fh) = @_;
    my %state;
    seek($fh, 0, 0);
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /\A\s*(?:#|\z)/;
        # wwid<TAB>volname<TAB>epoch. Anything else is corruption and is
        # dropped: an unattended reaper reads this, and a malformed entry must
        # not become an instruction.
        my ($wwid, $volname, $when) = split /\t/, $line, 3;
        next if !defined $wwid  || $wwid !~ /\A3[0-9a-f]{10,}\z/;
        next if !defined $volname || $volname !~ /\A[A-Za-z0-9._\/-]{1,128}\z/;
        $when = 0 if !defined $when || $when !~ /\A\d+\z/;
        $state{$wwid} = { volname => $volname, when => $when };
    }
    return \%state;
}

sub _write_locked {
    my ($self, $fh, $state) = @_;
    my $tmp = $self->{file} . ".tmp.$$";
    if (!open(my $out, '>', $tmp)) {
        warn "storage '$self->{storeid}': cannot write $tmp: $!\n";
        return 0;
    } else {
        print $out "# jt-pve-storage-synology: WWIDs claimed by this node\n";
        for my $wwid (sort keys %$state) {
            printf $out "%s\t%s\t%d\n", $wwid,
                $state->{$wwid}{volname}, $state->{$wwid}{when};
        }
        if (!close($out)) {
            warn "storage '$self->{storeid}': cannot write $tmp: $!\n";
            unlink $tmp;
            return 0;
        }
    }
    rename($tmp, $self->{file})
        or warn "storage '$self->{storeid}': cannot install $self->{file}: $!\n";
    return 1;
}

# ---------------------------------------------------------------------------
# The interface
# ---------------------------------------------------------------------------

sub track {
    my ($self, $wwid, $volname) = @_;
    return 0 if !defined $wwid || $wwid !~ /\A3[0-9a-f]{10,}\z/;
    return $self->_with_lock(sub {
        my ($state) = @_;
        $state->{ lc $wwid } = { volname => ($volname // '?'), when => time };
        return (1, 1);
    });
}

# Called only once the device is verifiably gone. Untracking a WWID whose device
# is still present would lose the only record of what has to be cleaned up.
sub untrack {
    my ($self, $wwid) = @_;
    return 0 if !defined $wwid;
    return $self->_with_lock(sub {
        my ($state) = @_;
        my $had = delete $state->{ lc $wwid };
        return ($had ? 1 : 0, $had ? 1 : 0);
    });
}

sub tracked {
    my ($self) = @_;
    return $self->_with_lock(sub {
        my ($state) = @_;
        return ({ %$state }, 0);
    });
}

sub is_tracked {
    my ($self, $wwid) = @_;
    return 0 if !defined $wwid;
    return exists $self->tracked->{ lc $wwid } ? 1 : 0;
}

sub volname_for {
    my ($self, $wwid) = @_;
    return undef if !defined $wwid;
    my $e = $self->tracked->{ lc $wwid };
    return $e ? $e->{volname} : undef;
}

# WWIDs this node holds that the NAS no longer has a LUN for.
#
# `$live` MUST be a complete set. A caller that could not read the NAS passes
# undef and gets nothing back — an incomplete listing would name every live
# volume as an orphan, and this list feeds cleanup.
sub orphans {
    my ($self, $live) = @_;
    return [] if ref $live ne 'HASH';
    my $tracked = $self->tracked;
    return [ grep { !$live->{$_} } sort keys %$tracked ];
}

1;
