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

like($detach, qr/map_is_gone/,
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

# --- the three-valued contract, broken inside a fix and caught by running it ---
#
# `map_is_gone` returns 1 / 0 / undef, where undef is "the stat never came back".
# `_detach_local`'s residual-path removal was first written as
# `if (!map_is_gone($wwid))`, which reads undef as "still there" and deletes the
# sd devices on a state nothing had established.
#
# It was not theoretical. On hardware, `qm stop` followed by `qm rollback` failed
# with "no device ... appeared on this node after logging in": the devices had been
# deleted on an undef, and the rescan did not recover them in time. Rule 12 broken
# inside a fix for a different bug, and only a real run showed it.
{
    my $mp = do {
        open(my $fh, '<', 'lib/PVE/Storage/Custom/Synology/Multipath.pm')
            or BAIL_OUT('cannot read Multipath');
        local $/; <$fh>;
    };
    my ($gone) = $mp =~ /\nsub map_is_gone \{(.*?)\n\}/s;
    ok($gone, 'map_is_gone is parseable');
    like($gone, qr/return undef if !defined \$link/,
         'it answers undef for a WWID it could not even ask about');
    like($gone, qr/return undef if !defined \$ok/,
         'and undef when the stat did not come back');
}

unlike($detach, qr/if \(!PVE::Storage::Custom::Synology::Multipath::map_is_gone/,
       'the bare negation of a three-valued answer is gone');
like($detach, qr/defined \$gone && !\$gone/,
     'and the destructive branch requires a DEFINITE "still there"');
like($detach, qr/rule 12/,
     'with the rule it broke named, so the next reader knows why it is written'
   . ' this way');

# --- stale tracking after a crash, which is not an orphan --------------------
#
# A hard-reset node never runs `deactivate_volume`, so its tracking file keeps an
# entry for a LUN that is no longer attached — while the LUN itself still exists,
# so `orphans` correctly does not report it. Measured: pve2 was hard-reset with a
# VM running, came back with no map and no session, and a tracking entry nothing
# would ever have removed.
#
# Not dangerous — every consumer re-checks for a device — but a record that says
# this node holds something it does not, and `deactivate_storage` reads a
# non-empty tracking file as "still in use".

like($reap, qr/STALE TRACKING/, 'the crash case is handled separately from orphans');
like($reap, qr/a tracking entry left by a crash/,
     'and reported as what it is, not as an orphan');

# It must use the three-valued check, not the one that collapses undef.
{
    my ($stale) = $reap =~ /STALE TRACKING(.*?)for my \$wwid \(\@\{ \$state->orphans/s;
    ok($stale, 'the stale-tracking block is parseable');
    like($stale, qr/map_is_gone/,
         'it asks map_is_gone, which distinguishes "gone" from "could not tell"');
    # Comments stripped first. The block's own comment NAMES device_path_for_wwid
    # in order to explain why it is not used, and a check that cannot tell code
    # from the comment about the code is the fifth false positive of this shape in
    # this project. Strip, then assert.
    (my $stale_code = $stale) =~ s/^\s*#.*$//mg;
    unlike($stale_code, qr/device_path_for_wwid/,
           'and NOT device_path_for_wwid, which collapses both into undef —'
         . ' untracking on that would repeat the bug this file already records');
    like($stale, qr/next if !defined \$gone \|\| !\$gone/,
         'so only a confirmed "gone" untracks anything');
}

done_testing();
