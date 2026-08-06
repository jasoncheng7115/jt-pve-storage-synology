#!/usr/bin/perl

# The orphan reaper, and the two things that made it necessary.
#
# MEASURED on a three-node cluster on 2026-08-06. A running VM was live-migrated
# pve1 -> pve2 -> pve3 and destroyed on pve3. Proxmox VE's only
# `deactivate_volumes` call during migration is inside
# `sync_offline_local_volumes`, so for a SHARED storage the source node is never
# told anything happened. pve3 cleaned up correctly; **pve1 and pve2 were each
# left holding a multipath map and a tracking entry for a LUN that no longer
# existed.**
#
# Two defects behind that:
#
#   1. `WwidState::orphans` was written for exactly this case, documented at
#      length, and called from nowhere. Dead code standing in for a fix.
#   2. `_detach_local` could not flush such a map. When the LUN is deleted from
#      another node, this node's iSCSI session is still up, so each sd node
#      survives as a dead device and multipathd rebuilds a map over it.
#      `free_image` removed those residual paths and flushed again; `_detach_local`
#      did not. The same work written twice, and only one copy correct — the
#      reaper's first real run reported "flush incomplete" because of it.

use strict;
use warnings;
use Test::More;
use lib 'lib';

my $src = do {
    open(my $fh, '<', 'lib/PVE/Storage/Custom/SynologySANPlugin.pm')
        or BAIL_OUT('cannot read the plugin');
    local $/; <$fh>;
};

# --- the mechanism is actually wired up now --------------------------------

like($src, qr/sub reap_orphans/, 'reap_orphans exists');
like($src, qr/\$state->orphans\(/,
     'and it calls WwidState::orphans, which had no caller at all before');

{
    my $ws = do {
        open(my $fh, '<', 'lib/PVE/Storage/Custom/Synology/WwidState.pm')
            or BAIL_OUT('cannot read WwidState');
        local $/; <$fh>;
    };
    like($ws, qr/sub orphans/, 'WwidState::orphans is still there');
    like($ws, qr/return \[\] if ref \$live ne 'HASH'/,
         'and refuses to answer from anything but a complete hash — a partial'
       . ' listing would name every live volume an orphan');
}

# --- the safety contract, which is the whole of it -------------------------

my ($reap) = $src =~ /\nsub reap_orphans \{(.*?)\n\}\n/s;
ok($reap, 'the body is parseable');

like($reap, qr/die .*could not read the LUN list; not reaping anything/,
     'a failed NAS read is fatal, not an empty listing: an empty listing would'
   . ' make everything an orphan and this list feeds a flush');

like($reap, qr/if \(!defined \$in_use\)/,
     'undef from is_device_in_use is handled separately from false');
like($reap, qr/refusing rather than guessing/,
     'and skipped — a safety check that cannot answer must not answer "safe"');
like($reap, qr/if \(\$in_use\)/, 'a device in use is skipped too');

# The order matters: the in-use check must precede the flush, not follow it.
my $iu = index($reap, 'is_device_in_use');
my $fl = index($reap, '_detach_local');
ok($iu >= 0 && $fl >= 0 && $iu < $fl,
   'the in-use check comes BEFORE anything is torn down');

# Dry run must be the safe default at the tool level.
{
    my $tool = do {
        open(my $fh, '<', 'bin/pve-syno-reap') or BAIL_OUT('cannot read the tool');
        local $/; <$fh>;
    };
    like($tool, qr/dry_run => !\$remove/,
         'the tool passes dry_run unless --remove was given');
    unlike($tool, qr/dry_run\s*=>\s*0\b/,
           'and never hardcodes acting');
    like($tool, qr/--remove/, 'the option is documented in its own usage');
}

# --- _detach_local must handle the residual-path case ----------------------

my ($detach) = $src =~ /\nsub _detach_local \{(.*?)\n\}\n/s;
ok($detach, '_detach_local is parseable');

like($detach, qr/slaves_of_map/,
     'the slave list is captured before the flush — afterwards there is nothing'
   . ' left to ask which sd devices belonged to the map');

like($detach, qr/if \(!PVE::Storage::Custom::Synology::Multipath::map_is_gone/,
     'and the residual-path removal is conditional on the flush having FAILED');

like($detach, qr/remove_sd_device/, 'it removes the residual paths');

# The capture must precede the first flush, or it captures nothing.
my $cap = index($detach, 'slaves_of_map');
my $first_flush = index($detach, 'flush_map');
ok($cap >= 0 && $first_flush >= 0 && $cap < $first_flush,
   'captured BEFORE the first flush');

# And it must not do this on the healthy path: an ordinary VM stop should not
# force a rediscovery it does not need.
like($detach, qr/Only on the failure path/,
     'the conditional is deliberate and says so');

# --- and the claim that was false, in three places ------------------------
#
# "PVE calls deactivate_storage when it is finished with the storage on this
# node" was written into this file and is untrue: nothing in the whole
# /usr/share/perl5/PVE tree calls it. The sibling NetApp plugin had already found
# and corrected the identical claim.
# The phrase still occurs — inside the comment that QUOTES it in order to correct
# it. A blunt `unlike` could not tell an assertion from a quotation of one, which
# is the false-positive pattern this project has now met four times. So the check
# is that every occurrence sits next to its own refutation.
for my $line (grep { /PVE calls deactivate_storage/ } split /\n/, $src) {
    my $i = index($src, $line);
    my $window = substr($src, $i, 400);
    like($window, qr/which is simply untrue|was wrong|not true/,
         'the claim only appears where it is being refuted');
}
like($src, qr/NOTHING IN PROXMOX VE CALLS THIS FUNCTION/,
     'and is replaced by what was actually measured');
like($src, qr/pve-syno-reap.*is/s,
     'with the real cleanup path named');

done_testing();
