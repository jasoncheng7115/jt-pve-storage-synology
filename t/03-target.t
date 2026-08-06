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

done_testing();
