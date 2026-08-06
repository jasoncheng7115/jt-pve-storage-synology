#!/usr/bin/perl
# The transport's decisions, tested without a NAS. Each case is a fact
# established against a DS918+ on DSM 7.1.1, not a guess about DSM.

use strict;
use warnings;
use Test::More;

use lib 'lib';
use_ok('PVE::Storage::Custom::Synology::API');
my $C = 'PVE::Storage::Custom::Synology::API';

# --- error classification -------------------------------------------------
ok($C->can('error_text'), 'error_text exists');
like(PVE::Storage::Custom::Synology::API::error_text(105), qr/105/, 'code is in the text');
like(PVE::Storage::Custom::Synology::API::error_text(105), qr/CSRF/i,
     '105 names the anti-CSRF token, because it reads as a permission problem and is not one');
like(PVE::Storage::Custom::Synology::API::error_text(18990068), qr/MAY EXIST/i,
     '18990068 warns that the object may exist despite the failure');
is(PVE::Storage::Custom::Synology::API::error_text(undef), 'no error', 'undef is not an error');
like(PVE::Storage::Custom::Synology::API::error_text(999999), qr/undocumented/,
     'an unknown code is reported as undocumented rather than guessed at');

# A session that expired is routine; a credential that was refused is not.
for my $c (105, 106, 119) {
    ok(PVE::Storage::Custom::Synology::API::is_session_expired($c), "$c is a session expiry");
}
for my $c (400, 402, 403, 404) {
    ok(PVE::Storage::Custom::Synology::API::is_credential_error($c), "$c is a credential refusal");
    ok(!PVE::Storage::Custom::Synology::API::is_session_expired($c), "$c is not treated as an expiry");
}
ok(!PVE::Storage::Custom::Synology::API::is_credential_error(18990531),
   'a missing LUN is not a credential problem');
ok(!PVE::Storage::Custom::Synology::API::is_credential_error(undef), 'undef is not a credential error');

# --- JSON parameter encoding ---------------------------------------------
# The SAN APIs all report requestFormat=JSON: a string is quoted, a number bare.
my $enc = \&PVE::Storage::Custom::Synology::API::_encode_value;
is($enc->('pvetest-a'), '"pvetest-a"', 'a string is quoted');
is($enc->('1073741824'), '1073741824', 'an integer is left bare');
is($enc->(1073741824), '1073741824', 'a numeric scalar is left bare');
is($enc->('[1,2]'), '[1,2]', 'already-encoded JSON is passed through');
is($enc->('{"a":1}'), '{"a":1}', 'a JSON object is passed through');
is($enc->('true'), 'true', 'a boolean is not quoted into a string');
is($enc->('/volume1'), '"/volume1"', 'a path is a string and must be quoted');
like($enc->('a"b'), qr/\\"/, 'an embedded quote is escaped rather than breaking the body');

# --- identifiers must reach DSM as JSON strings ---------------------------
# `target_id` sent as a bare 4 is refused with 18990710. That refusal was
# initially mistaken for "no such target", because the lookup's fallback
# searched by name only and a lookup by id fell through to "not found" — so
# every mapping check silently answered no. Both halves are covered here.
my $js = \&PVE::Storage::Custom::Synology::API::json_string;
is($js->(4), '"4"', 'a numeric id is quoted, or DSM answers 18990710');
is($js->('4'), '"4"', 'a stringy id is quoted too');
is($js->('pvetest-tA'), '"pvetest-tA"', 'a name is quoted');
is($enc->($js->(4)), '"4"', 'an already-quoted value is not double-encoded');
like(PVE::Storage::Custom::Synology::API::error_text(18990710), qr/JSON string/,
     '18990710 says what the caller did wrong, since it reads like "no such object"');

# --- construction ---------------------------------------------------------
my $api = $C->new(portals => '192.0.2.10, 192.0.2.11', username => 'u',
                  password => 'p', storeid => 'syno1');
is_deeply($api->{portals}, ['192.0.2.10','192.0.2.11'], 'a comma-separated portal list is split');
is($api->storeid, 'syno1', 'the storage id is carried for error messages');
is($api->{timeout}, 30, 'the default timeout');

my $st = $C->new(portals => ['192.0.2.10'], username => 'u', password => 'p', status => 1);
is($st->{timeout}, 5, 'the health path gets a short timeout so one dead NAS cannot hold up pvesm status');

eval { $C->new(portals => '', username => 'u', password => 'p') };
like($@, qr/no management address/, 'an empty portal list is refused at construction');

# --- the Auto Block latch -------------------------------------------------
# DSM blocks an address for a day after three failed logins in five minutes,
# and PVE polls every ten seconds. A refused credential must never be retried.
my $latched = $C->new(portals => ['192.0.2.10'], username => 'u', password => 'p',
                      storeid => 'syno1');
$latched->{credential_refused} = '400 (invalid credentials)';
eval { $latched->login };
like($@, qr/not retrying/, 'a latched credential refusal refuses to try again');
like($@, qr/blocks an address/, 'and it says why, so the operator does not just re-enable it');

# --- portal rotation ------------------------------------------------------
my $rot = $C->new(portals => ['a','b'], username => 'u', password => 'p');
$rot->{sid} = 'session-from-a';
is($rot->_portal, 'a', 'starts on the first portal');
ok($rot->_rotate_portal, 'rotation happens when there is somewhere to rotate to');
is($rot->_portal, 'b', 'and moves to the next');
is($rot->{sid}, undef, 'rotating drops the session, which belonged to the old address');

my $one = $C->new(portals => ['only'], username => 'u', password => 'p');
ok(!$one->_rotate_portal, 'a single portal does not rotate, so a dead NAS fails fast');

done_testing();
