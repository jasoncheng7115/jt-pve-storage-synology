#!/usr/bin/perl
# The multipath layer. These are the rules that cost outages in the related
# projects, plus three findings specific to Synology.
use strict; use warnings; use Test::More; use lib 'lib';
use_ok('PVE::Storage::Custom::Synology::Multipath');
my $M = 'PVE::Storage::Custom::Synology::Multipath';
*dmp = \&PVE::Storage::Custom::Synology::Multipath::dm_uuid_path;

# --- the stable handle ------------------------------------------------------
# /dev/mapper/<wwid> does not exist on a node with user_friendly_names yes,
# which the test node has. This one always does.
is(dmp('3600140513a3cd1edf296d4d4bdb712da'),
   '/dev/disk/by-id/dm-uuid-mpath-3600140513a3cd1edf296d4d4bdb712da',
   'a WWID maps to its dm-uuid link, not to /dev/mapper/<wwid>');
is(dmp('3600140513A3CD1EDF296D4D4BDB712DA'),
   '/dev/disk/by-id/dm-uuid-mpath-3600140513a3cd1edf296d4d4bdb712da',
   'the link is lower case whatever the caller had');
is(dmp(undef), undef, 'undef in, undef out');
is(dmp(''), undef, 'an empty WWID yields no path');
is(dmp('not-a-wwid'), undef, 'a malformed WWID yields no path rather than a wrong one');
is(dmp('../../etc/passwd'), undef, 'a traversal attempt cannot become a device path');

# --- the drop-in, which is mandatory because DSM has no built-in entry ------
my $conf = PVE::Storage::Custom::Synology::Multipath::conf_content();
like($conf, qr/vendor\s+"SYNOLOGY"/, 'the vendor string as SCSI INQUIRY reports it');
like($conf, qr/product\s+"Storage"/, 'the product string');
like($conf, qr/prio\s+alua/, 'ALUA, because the device reports TPGS=1');
like($conf, qr/hardware_handler\s+"1 alua"/, 'and the handler multipath enables by itself');
like($conf, qr/no_path_retry\s+\d+/, 'no_path_retry is a NUMBER');
unlike($conf, qr/no_path_retry\s+queue/,
       'never queue — that is what the generic defaults give a Synology LUN, and it hangs');
unlike($conf, qr/dev_loss_tmo\s+infinity/, 'dev_loss_tmo is never infinity');
like($conf, qr/synology-multipath-config-version/, 'the file records its own version');
like(PVE::Storage::Custom::Synology::Multipath::conf_content(no_path_retry => 7), qr/no_path_retry\s+7/, 'the retry count is settable');

# The guard in the Makefile scans for this, but assert it here too: this string
# in generated content would flush every unused map on the node.
unlike($conf, qr/multipath\s+-F/, 'the drop-in cannot contain a node-wide flush');

# --- a device must be confirmed by the kernel, because mapping_index is reused
*isdev = \&PVE::Storage::Custom::Synology::Multipath::device_is_lun;
is(isdev('/dev/does-not-exist', '3600140500000000000000000000000000'), undef,
   'a device whose WWID cannot be read gives UNDEF, not 0 — "could not tell" is not "no"');
is(isdev('/dev/does-not-exist', undef), undef, 'without a WWID to compare, undef');

# --- map_is_gone must not report "gone" when it could not look ---------------
*gone = \&PVE::Storage::Custom::Synology::Multipath::map_is_gone;
ok(gone('3600140500000000000000000000000000'),
   'a WWID with no device present is reported gone');
is(gone('not-a-wwid'), undef,
   'an unusable WWID gives undef, not "gone" — a delete path must not conclude it looked');
eval { PVE::Storage::Custom::Synology::Multipath->conf_content(no_path_retry => 7) };
like($@, qr/functions, not methods/,
     'a method call is refused, because the shifted argument silently became a default');

done_testing();
