#!/usr/bin/perl
use strict; use warnings; use Test::More; use lib 'lib';
use_ok('PVE::Storage::Custom::Synology::Target');
my $T = 'PVE::Storage::Custom::Synology::Target';

# max_sessions defaults to 1 on DSM, and one session is one node.
is($T->MAX_SESSIONS_UNLIMITED, 0, 'a shared target must allow unlimited sessions');
is($T->IQN_PREFIX, 'iqn.2000-01.com.synology:', "DSM's own IQN prefix");

my $b = \&PVE::Storage::Custom::Synology::Target::build_iqn;
is($b->(undef, 'pve-syno1'), 'iqn.2000-01.com.synology:pve-syno1', 'the plain form');
is($b->(undef, 'pve_syno1'), 'iqn.2000-01.com.synology:pve-syno1', 'underscore becomes a hyphen');
is($b->(undef, 'pve+syno1'), 'iqn.2000-01.com.synology:pvepsyno1', 'plus becomes p');
is($b->(undef, 'PVE-Syno1'), 'iqn.2000-01.com.synology:pve-syno1', 'an IQN is lower case');
unlike($b->(undef, 'a b@c'), qr/[ @]/, 'characters an IQN cannot carry are dropped');
cmp_ok(length($b->(undef, 'x' x 400)), '<=', 128, 'an over-long IQN is truncated, as the CSI driver does');

# mapped_luns must survive every shape a bad answer can take, because what it
# returns decides which device a node goes looking for.
my $t = bless { api => undef }, $T;
is_deeply($t->mapped_luns({ mapped_luns => [] }), {}, 'no mappings is an empty map');
is_deeply($t->mapped_luns({}), {}, 'a target with no mapped_luns key is not a crash');
is_deeply($t->mapped_luns({ mapped_luns => [ { lun_uuid => 'u1', mapping_index => 1 },
                                             { lun_uuid => 'u2', mapping_index => 3 } ] }),
          { u1 => 1, u2 => 3 }, 'indexes are read per uuid');
is_deeply($t->mapped_luns({ mapped_luns => [ 'nonsense', { no_uuid => 1 } ] }), {},
          'rows that are not mappings are skipped rather than killing the caller');
ok($t->is_lun_mapped({ mapped_luns => [ { lun_uuid => 'u1', mapping_index => 1 } ] }, 'u1'),
   'a mapped LUN is reported mapped');
ok(!$t->is_lun_mapped({ mapped_luns => [] }, 'u1'), 'an unmapped LUN is not');
is($t->connected_session_count({ connected_sessions => [ {}, {} ] }), 2, 'sessions are counted');
is($t->connected_session_count({}), 0, 'a target with no session list has none');


# --- the target ceiling, which was read from the NAS and never used ----------
#
# `max_iscsitrgs` is 128 on the test NAS against a LUN ceiling of 256. Irrelevant
# while `shared` is the default target mode — and that is exactly WHY it is the
# default: `per-volume` needs a target per disk, so it caps the storage at half the
# disks the LUNs would allow, and it does so by failing a create with a number.
#
# limits() read it and nothing consumed it, while CLAUDE.md named it as one of the
# three ceilings that bite. Same shape as WwidState::orphans.

{
    package CeilAPI;
    sub new { my ($c,%o)=@_; bless { n=>$o{n}, max=>$o{max}, sent=>[] }, $c }
    sub storeid { 'ceil' }
    sub limits { { luns=>undef, targets=>$_[0]->{max}, snapshots_per_lun=>undef } }
    sub call {
        my ($s,$api,$method,%p)=@_;
        push @{$s->{sent}}, $method;
        return { success=>1, data=>{ targets=>[ map { { name=>"t$_", target_id=>$_ } } 1..$s->{n} ] } }
            if $method eq 'list';
        return { success=>1, data=>{ target_id=>999 } };
    }
    sub call_ok { my $s=shift; return $s->call(@_)->{data} }
}

my $T = 'PVE::Storage::Custom::Synology::Target';

# At the ceiling, a NEW target is refused before anything is sent.
{
    my $api = CeilAPI->new(n => 128, max => 128);
    my $tg  = $T->new($api);
    my $err = '';
    eval { $tg->ensure(name => 'brand-new-tgt') } or $err = $@;
    like($err, qr/already has 128 iSCSI\s+targets/,
         'a new target is refused at the ceiling');
    like($err, qr/per-volume/,
         'and the message explains why per-volume mode reaches it first');
    ok(!grep({ $_ eq 'create' } @{ $api->{sent} }),
       'nothing was created — the refusal precedes the request');
}

# Below the ceiling it proceeds.
{
    my $api = CeilAPI->new(n => 5, max => 128);
    my $err = '';
    eval { $T->new($api)->ensure(name => 'brand-new-tgt') } or $err = $@;
    unlike($err, qr/maximum/, 'below the ceiling it is not refused');
}

# An EXISTING target must not be refused, however full the NAS is: nothing is
# being created, so the ceiling does not apply.
{
    my $api = CeilAPI->new(n => 128, max => 128);
    my $err = '';
    eval { $T->new($api)->ensure(name => 't7') } or $err = $@;
    unlike($err, qr/maximum/,
           'an existing target is returned even at the ceiling');
}

# undef means the NAS did not say, which is never "no limit" and never a refusal.
{
    my $api = CeilAPI->new(n => 9999, max => undef);
    my $err = '';
    eval { $T->new($api)->ensure(name => 'brand-new-tgt') } or $err = $@;
    unlike($err, qr/maximum/,
           'when the NAS does not report a ceiling, the guard stands down');
}

# One listing BEFORE the create, serving both the lookup and the count.
#
# There is a second `list` afterwards and it is not waste: it reads the target back
# to verify it exists, because a create that reports success is not believed here.
# The first version of this test asserted a single listing and failed on correct
# code — the assertion has to name which listing it means.
{
    my $api = CeilAPI->new(n => 3, max => 128);
    eval { $T->new($api)->ensure(name => 'brand-new-tgt') };
    my @sent = @{ $api->{sent} };
    my $before = 0;
    for my $c (@sent) { last if $c eq 'create'; $before++ if $c eq 'list' }
    is($before, 1, 'exactly one listing before the create, for lookup and count');
    is($sent[0], 'list',   'the listing comes first');
    is($sent[1], 'create', 'then the create — nothing between them');
}


done_testing();
