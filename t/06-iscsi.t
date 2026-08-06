#!/usr/bin/perl
# The iSCSI layer's pure logic and its parser. The parser matters: open-iscsi
# ships translations, and one written against English matches nothing on a
# zh_TW node — silently. The command runner pins LC_ALL=C for that reason.
use strict; use warnings; use Test::More; use lib 'lib';
use_ok('PVE::Storage::Custom::Synology::ISCSI');
my $I = 'PVE::Storage::Custom::Synology::ISCSI';
*ps = \&PVE::Storage::Custom::Synology::ISCSI::portal_string;
*bp = \&PVE::Storage::Custom::Synology::ISCSI::by_path_for;

is($I->PORT, 3260, 'the iSCSI port');
is($I->STARTUP, 'manual',
   'a node record this plugin creates is never logged in to at boot behind PVE');

# --- portal strings ---------------------------------------------------------
is(ps('192.0.2.10'), '192.0.2.10:3260', 'a bare address gains the default port');
is(ps('192.0.2.10', 3261), '192.0.2.10:3261', 'an explicit port is used');
is(ps('192.0.2.10:3299'), '192.0.2.10:3299',
   'a portal that already carries a port is not given a second one');
is(ps(undef), undef, 'undef in, undef out');
is(ps(''), undef, 'an empty portal yields nothing');

# --- by-path is a CANDIDATE, never an identity ------------------------------
# mapping_index is reused: unmap the middle of three and the next LUN mapped
# takes the freed index, so this exact path can resolve to a different disk.
is(bp('192.0.2.10', 'iqn.2000-01.com.synology:x', 1),
   '/dev/disk/by-path/ip-192.0.2.10:3260-iscsi-iqn.2000-01.com.synology:x-lun-1',
   'the by-path name is built the way the kernel names it');
is(bp('192.0.2.10', 'iqn.x', 0), '/dev/disk/by-path/ip-192.0.2.10:3260-iscsi-iqn.x-lun-0',
   'index 0 is a valid index, not a missing one');
is(bp('192.0.2.10', 'iqn.x', undef), undef, 'without an index there is no path');
is(bp(undef, 'iqn.x', 1), undef, 'without a portal there is no path');

# --- the session parser -----------------------------------------------------
# Fed the exact shape `iscsiadm -m session` produced on the test node.
{
    no warnings 'redefine';
    local *PVE::Storage::Custom::Synology::ISCSI::_iscsiadm = sub {
        return (<<'OUT', '', 0);
tcp: [1] 192.168.1.198:3260,1026 iqn.1992-08.com.netapp:sn.959bf:vs.2 (non-flash)
tcp: [3] 192.168.1.118:3260,1 iqn.2000-01.com.synology:pvetest.wwid (non-flash)
OUT
    };
    my $s = PVE::Storage::Custom::Synology::ISCSI::sessions();
    is(scalar @$s, 2, 'both sessions are parsed');
    is($s->[1]{sid}, '3', 'the session id');
    is($s->[1]{portal}, '192.168.1.118:3260', 'the portal, with the group id stripped');
    is($s->[1]{iqn}, 'iqn.2000-01.com.synology:pvetest.wwid', 'the IQN');
    ok(PVE::Storage::Custom::Synology::ISCSI::has_session(
           'iqn.2000-01.com.synology:pvetest.wwid', '192.168.1.118'),
       'our own session is found');
    ok(!PVE::Storage::Custom::Synology::ISCSI::has_session('iqn.nope', '192.168.1.118'),
       'a target with no session is not found');
    ok(!PVE::Storage::Custom::Synology::ISCSI::has_session(
           'iqn.2000-01.com.synology:pvetest.wwid', '10.0.0.1'),
       'the right IQN at the wrong portal is not a session');
    # Another vendor's session must never be mistaken for ours.
    ok(PVE::Storage::Custom::Synology::ISCSI::has_session(
           'iqn.1992-08.com.netapp:sn.959bf:vs.2', '192.168.1.198'),
       "and another vendor's session is reported under its own IQN only");
}

# Garbage in the session table must not produce phantom sessions.
{
    no warnings 'redefine';
    local *PVE::Storage::Custom::Synology::ISCSI::_iscsiadm = sub {
        return ("iscsiadm: No active sessions.\n", '', 21);
    };
    is_deeply(PVE::Storage::Custom::Synology::ISCSI::sessions(), [],
              'no sessions parses as none, not as one');
    ok(PVE::Storage::Custom::Synology::ISCSI::is_available(),
       'exit 21 means "no sessions", not "iscsiadm is broken"');
}

done_testing();
