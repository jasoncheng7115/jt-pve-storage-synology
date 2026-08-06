# Testing and verification

This page has two jobs: to say **what has actually been verified and what has
not**, and to give the test plan that moves things from the second list to the
first.

It is kept honest deliberately. A storage plugin that quietly guesses is worse
than one that refuses, so every array-facing fact carries where it came from,
and anything that could not be established says so.

---

## Source tiers

| Tier | Source | What it proves |
|---|---|---|
| 1 | **Real hardware** | Behaviour. The only tier that answers "did that really delete?" |
| 2 | **Synology's own CSI driver** (`SynologyOpenSource/synology-csi`) | That an API exists and roughly how it is called |
| 2 | **OpenStack Cinder's Synology driver** | The same, independently — and it knows things the CSI driver does not |
| 3 | **Synology Knowledge Center / SAN Manager specifications** | Product limits |
| 4 | **DSM Login Web API Guide** | Login and API discovery only. It documents no SAN API at all |
| — | Guessing | Not a tier. Not allowed in the code |

The two tier-2 sources **disagree with each other**, and where they do, the
disagreement is the interesting part. Session handling is the clearest case:
see "How a session is carried" below.

---

## Test hardware

| | |
|---|---|
| Model | DS918+ |
| DSM | 7.1.1-42962 Update 9 |
| Volume | `/volume1`, **Btrfs**, 14301.5 GiB total |
| Reported ceilings | **`max_iscsiluns` 256, `max_iscsitrgs` 128**, `max_snapshot_per_lun` 256 — the model's own numbers, not the 512/256 on the specification sheet |
| Target implementation | `iscsi_target_type` = `lio4x` |
| Note | A **production** NAS, also running Virtual Machine Manager. Write tests were run on a dedicated `pvetest-` prefix with the owner's agreement; every object created was deleted and the NAS confirmed back to its original contents |

**What has been run:** read-only probing, write tests on a dedicated name
prefix, and one attach of a LUN to a Proxmox VE node — which is where the WWID
derivation and the multipath behaviour below come from. The module layer
(`Synology::API`, `::LUN`, `::Target`, `::Naming`, `::Multipath`, `::Command`,
`::ISCSI`) has been driven end to end against this hardware. **The PVE plugin
itself is not written**, so nothing here has been exercised through `pvesm`.

---

## Verified on hardware (2026-08-06)

Everything down to the `dev_attribs` table was read-only. The sections marked
as write tests below were run on a dedicated `pvetest-` name prefix, with the
owner's agreement, and every object created was deleted afterwards and the
array confirmed back to its original contents.

### How a session is carried — the two reference clients disagree, and one is wrong here

| Carrier | Result on DSM 7.1.1 |
|---|---|
| `_sid` form parameter (what Cinder sends) | **119, SID not found — every call fails** |
| `Cookie: id=<sid>` header (what the CSI driver sends) | works |

And the cookie is **not** set by the server: the login answers with the sid in
the body and no `Set-Cookie` at all, so the client has to construct the cookie
itself. A cookie jar stays empty and everything then fails with 119, which
looks like a broken login and is not one.

This plugin sends both carriers.

### Security settings that change the design

| Setting | Value | Consequence |
|---|---|---|
| `enable_csrf_protection` | **true** | Every request must echo the login's `SynoToken`, or the NAS answers **105 (insufficient permission)** — which reads exactly like a privilege problem. **Neither reference client sends it**, so neither works on a NAS configured this way |
| Auto Block | **on: 3 attempts / 5 min → 1 day** | A wrong password would lock a node out of the NAS for a day in about thirty seconds of normal polling. See `DSM-ACCOUNT.md` |
| `timeout` | **15 minutes** | Session expiry is a normal event, not an error. Re-login on 105/106/119 is the ordinary path |
| `skip_ip_checking` | false | A session is bound to its client IP; nodes necessarily have their own |

### LUN fields, as the NAS actually reports them

```
allocated_size  block_size  create_from  description  dev_attribs
dev_attribs_bitmap  dev_config  dev_qos  direct_io_pattern
flashcache_id  flashcache_status  is_action_locked  location
lun_id  name  restored_time  size  status  type  type_str  uuid
vpd_unit_sn
```

Three of these matter more than the rest, and **no public client reads any of
them**:

- **`vpd_unit_sn` is the LUN's uuid, character for character.** That is the
  SCSI VPD unit serial number, which is what a Linux WWID is built from. It
  means a LUN can be matched to a device by the kernel's own identification of
  it, instead of only by the path it was discovered on. Both reference clients
  use `/dev/disk/by-path` and nothing else.
- **`restored_time` exists**, which is evidence that restoring a LUN from a
  snapshot is a real, recorded operation — see the register's R-1.
- `lun_id` and a target's `mapping_index` are **different numbers**.
  `mapping_index` starts at **1**, not 0.

### How a LUN's uuid becomes a Linux WWID

Read from a host that had a LUN attached:

```
scsi-36001405a1b2c3d4d5e6fd4a7bd8c9dd0 -> sdg
VENDOR=SYNOLOGY  MODEL=Storage
SERIAL=a1b2c3d4-5e6f-4a7b-8c9d-0e1f2a3b4c5d     <- the LUN's uuid, unchanged
```

The relation is deterministic:

```
WWID = "3" + "6001405" + (the uuid with "-" replaced by "d", first 25 characters)
```

`6001405` is Linux-IO's IEEE company identifier, so Synology's target is
LIO-based — **but this is not stock LIO behaviour.** Upstream's
`spc_gen_naa_6h_vendor_specific()` converts the serial with `hex_to_bin()` and
**skips** any character that is not hex, which would give
`36001405a1b2c3d45e6f4a7b8c9d0e1f2` — and that is not what the NAS produces.
Synology maps the hyphen to `d` rather than dropping it. Reading the upstream
source would have given a confidently wrong answer here; only hardware gave the
right one.

Three consequences:

1. The WWID can be computed **before the device appears**, so a multipath map
   can be pinned deterministically and a node can tell whether the device it
   found is the LUN it asked for — instead of trusting the path it was
   discovered on.
2. **The last 11 characters of the uuid are discarded.** The WWID is therefore
   not a lossless function of the uuid, it cannot be inverted, and two uuids
   differing only in their tail would collide. With random uuids that is
   negligible, but the rule stands: the computed value is a **cross-check**,
   and the kernel's own identification is what decides.
3. The two strings a multipath `conf.d` drop-in needs are
   `vendor "SYNOLOGY"` and `product "Storage"`. **Neither is available from the
   NAS API** — they are SCSI INQUIRY responses. Guessing them wrong makes the
   drop-in silently ineffective, and an ineffective `no_path_retry` means
   queueing forever when every path is gone.

**One sample does not prove a rule.** The rule above reproduces one observed
WWID exactly, which is enough to act on as a cross-check and not enough to rely
on. The predicted WWIDs of two further LUNs are recorded privately, to be
checked the first time a test LUN is attached — and if the rule turns out to be
wrong, this section changes and the plugin keeps reading the WWID from the
kernel, which it does regardless.

If you attach a Synology LUN on any DSM version, this is a five-second
contribution:

```bash
# uuid from SAN Manager or the probe; WWID from the host that has it attached
ls -l /dev/disk/by-id/ | grep -i 6001405
```

### A filter that is not merely unverified, but verified to be incomplete

Synology's CSI driver lists LUNs with an explicit twelve-type filter
(`BLOCK`, `FILE`, `THIN`, `ADV`, `SINK`, `CINDER`, …, `BLUN`, `BLUN_THICK`, …).
On the test NAS, that filter returned **3 LUNs where the unfiltered listing
returned 4**. The hidden one:

```
type 295, VDISK_BLUN, 120 GiB — a Virtual Machine Manager virtual disk
```

Its 120 GiB comes out of the same volume as everything else, so a client
trusting that filter under-counts provisioned space by that much and cannot see
the object at all.

**So this project never sends the types filter.** It lists unfiltered and
matches locally on the name, which is the only ownership test it trusts anyway.
The probe now runs both listings and reports what the filter would have hidden,
because the next DSM may hide a different type.

This is the general rule made concrete: a listing this plugin asked to filter
must be checked to have filtered, and "nothing there" and "filtered out" are
indistinguishable in the answer.

### A create that reports failure can create the LUN anyway

Reproduced deterministically. A LUN name of exactly **255 characters** is
refused with error **18990068** — and the LUN is created regardless: full name,
correct size, `status: normal`, entirely usable. At 256 characters the refusal
is clean (**18990503**, an illegal name) and nothing is made.

```
create, 255-char name  ->  REFUSED 18990068
                       ->  ... and 1 new LUN is on the array
create, 256-char name  ->  REFUSED 18990503, nothing created
```

**So a failed create must never be believed on its own.** After any create
failure the plugin looks the name up, and either adopts what it finds or
deletes it. Without that, every such failure leaks a LUN that Proxmox VE has no
record of: the space is gone, nothing points at it, and the next attempt makes
another one.

This is why the name limit is also enforced **before** the request is sent
rather than left to the NAS to reject.

### Rollback is safe here, and that was not a given

`restore_snapshot` takes **`src_lun_uuid` and `snapshot_uuid`**. Sending the
snapshot alone is refused with **18990508**, so the LUN must be named too.

Three things were measured, and all three had to come out this way for a
rollback to be shippable at all:

| Question | Answer |
|---|---|
| Does the LUN's uuid change? | **No.** So the SCSI serial and the WWID are unchanged, and a node does not suddenly see a different disk |
| Do snapshots newer than the one restored survive? | **Yes.** Restoring to the oldest of three left all three in place |
| Is it recorded? | `restored_time` goes from 0 to the epoch second of the restore |

The second answer is worth dwelling on, because the related projects had to
**refuse** a rollback past newer snapshots — on those arrays the newer ones are
destroyed, and a plugin that let PVE do it silently would delete snapshots the
user could still see. Here nothing is destroyed, so
`volume_rollback_is_possible` does not need that restriction and a storage can
be rolled back repeatedly.

### Snapshots and clones have no dependency chain

Every other array in this family refuses to delete an object something else
depends on, and both of those refusals have been the source of real defects.
Synology refuses neither:

| Attempted | Result |
|---|---|
| Delete a LUN that has snapshots | **Allowed.** The snapshots go with it — `list_snapshot` on the deleted uuid answers 18990531, so nothing is orphaned |
| Delete the snapshot a clone was made from | **Allowed**, and the clone stays `normal` and usable |
| Delete a LUN that is **mapped to a target** | **Allowed** |

So the dependency-purging the related projects need is unnecessary — but the
third row moves work onto the plugin instead: **nothing stops a mapped LUN being
deleted**, so unmapping before deleting is entirely this plugin's
responsibility. A LUN deleted while still mapped leaves every node that had it
with a device that answers nothing.

### A clone from a snapshot is thin

`clone_snapshot` produces a `BLUN` with `allocated_size: 0` — space-efficient,
so linked clones and templates are genuinely cheap rather than full copies.

### `mapping_index` is reused, so a device path is not an identity

```
map three LUNs to one target      -> indexes 1, 2, 3
unmap the middle one              -> indexes 1, 3
map a fourth LUN                  -> indexes 1, 2, 3   <- the new LUN took index 2
```

**The freed index is handed to the next LUN.** A node holding a stale device for
`...-iscsi-<iqn>-lun-2` would find that path now resolves to a completely
different LUN. This is the "wrote to the wrong disk" class of fault, and it is
reachable by ordinary use: detach a disk, attach another.

Both public reference clients identify devices by `/dev/disk/by-path` and
nothing else. **On this array that is not safe.** It is why the WWID derivation
above is load-bearing rather than a convenience: a device is accepted only once
the kernel's own identification of it matches the LUN that was asked for.

### Mapping adds, and unmapping is surgical

| Call | Behaviour |
|---|---|
| `map_target` with one target, on a LUN already mapped elsewhere | **Adds.** The existing mapping survives |
| `unmap_target` with one target | Removes **only** that one |

This is the opposite of Unity's `hostAccess`, where the list is replaced and
sending one host unmaps every other node in the cluster. Here per-node mapping
is safe as written. The plugin still reads the current list and sends the union,
because a behaviour that has been measured once on one firmware is not a promise.

### Concurrency and sessions

- **Sixteen simultaneous creates all succeeded**, in 15 s, and the array's
  contents matched what the API reported — no lost or duplicated LUN. The ~1 s
  per create suggests DSM serialises internally, which would explain why
  Cinder's driver wraps every request in a process-wide lock, but nothing here
  required that lock for correctness.
- **A second login on the same account does not evict the first.** Both sids
  work simultaneously, so a cluster of nodes sharing one account will not knock
  each other out — which error 107, "session interrupted by a duplicate login",
  had made a real worry.

### The kernel side, confirmed on a second sample

A 2 GiB thin LUN was mapped to a purpose-made target and attached to a Proxmox
VE node. The WWID rule derived from the first sample predicted the answer
exactly:

```
LUN uuid            13a3cd1e-f296-4d4b-b712-a85c139f9dac
predicted WWID      3600140513a3cd1edf296d4d4bdb712da
scsi_id -g -u       3600140513a3cd1edf296d4d4bdb712da     <- identical
/sys/.../device/wwid  naa.600140513a3cd1edf296d4d4bdb712da
```

Two independent samples with unrelated uuids now agree, so the derivation is
usable as a cross-check. The kernel's answer is still what decides.

What the device reports of itself:

| | |
|---|---|
| Vendor | `SYNOLOGY` (8 bytes) |
| Product | `Storage` (16 bytes, space-padded — `Storage         `) |
| Revision | `4.0` |
| `TPGS` | **1** — the device advertises implicit ALUA |

### The multipath findings, which change how a device is addressed

**There is no built-in multipath configuration for Synology.** `multipathd show
config` contains no `SYNOLOGY` entry at all, so the `conf.d` drop-in this plugin
ships is not a tuning nicety — without it the device falls back to the generic
defaults, and on the test node those include `no_path_retry "queue"`, which is
precisely the setting that turns the loss of every path into an unkillable hang.

**`/dev/mapper/<wwid>` cannot be assumed to exist.** The test node has
`user_friendly_names yes`, so multipath named the map `mpathc`. The related
projects return `/dev/mapper/<wwid>` from `path()`, and here that path would
simply not be there. What *is* always there is the dm-uuid link:

```
/dev/disk/by-id/dm-uuid-mpath-3600140513a3cd1edf296d4d4bdb712da -> ../../dm-9
```

So a device is addressed by that, or by resolving the map name from the WWID —
never by assuming a naming policy the node's administrator chose. Setting
`user_friendly_names no` globally would rename **other vendors'** maps on the
same node, which this project does not do.

Also worth knowing: **`/dev/disk/by-id/scsi-*` did not appear at all** for the
attached device on this node, though it did on another host with the same LUN
type. It is not a reliable handle either.

And when tearing a map down, `multipath -f` may answer **"device not found"**
because `fail_if_no_path` has already caused multipathd to remove it. That is
success, not an error.

### Clone timings, and why `allocated_size` must not be used for capacity

A clone of a LUN holding 512 MiB of real data:

| | |
|---|---|
| `is_action_locked` cleared after | **3.5 s** (0.0 s for an empty LUN) |
| The clone's reported `allocated_size` | **512 MiB** |
| Space actually consumed on `/volume1` | **0 bytes** |

So the clone is a **reflink**: the blocks are shared, and `allocated_size`
counts them for both LUNs. **Summing `allocated_size` over-reports usage, and by
an unbounded amount** — a template with twenty linked clones would appear to
consume twenty times what it does. Capacity therefore comes from the volume's
own `size_free_byte`, never from adding up LUNs, which is what `status()` does.

A snapshot of the same LUN completed in **0.20 s** regardless of its contents.

**Space is reclaimed lazily.** After deleting a LUN that had 512 MiB written to
it, the volume's free space had not moved several minutes later. Nothing is
lost — Btrfs returns it in its own time — but a plugin that expected free space
to rise immediately after a delete would draw the wrong conclusion, and a
`syno-min-free` guard must not be surprised by it.

### R-14: a non-administrator could not even log in

A freshly created non-administrator account was refused at the login itself with
**402**, before any SAN API could be tried — so this run could not distinguish
"cannot reach the SAN APIs" from "cannot log in to DSM at all". Narrowing it
further needs the DSM application privilege granted by hand in the interface,
and that is one login attempt per try against an **Auto Block policy of three
failures in five minutes for a one-day block**, so it was left alone
deliberately. The practical guidance in `DSM-ACCOUNT.md` is unchanged: the
account has to be an administrator, and everything else should be taken away
from it.

Two incidental findings from that attempt, both worth keeping:

- Passing `expired=now` to `SYNO.Core.User` `create` produces an account that
  exists and cannot log in. The symptom is a 402 that reads like a permission
  problem — a parameter whose meaning was guessed, quietly creating a broken
  account.
- `SYNO.Core.User` `set` with `expired=never` **reported success and changed
  nothing.** Another API answer that cannot be taken at face value.

### Two nodes, and one limitation that is PVE's shape rather than a bug

Verified on a two-node cluster (`pc-pve1` on kernel 7.0.2, `pc-pve2` on 7.0.14,
so not a clone of each other):

| | |
|---|---|
| Both nodes report the storage `active` with identical capacity | yes |
| `shared` is forced to 1 without appearing in `storage.cfg` | yes |
| **Two DSM sessions on one account, from two IPs, at once** | yes — R-13 answered in a real cluster: they coexist, nothing is evicted |
| Two iSCSI sessions on one target with `max_sessions = 0` | yes, both listed by the NAS |
| Both nodes read the same bytes from the same LUN | yes |
| Offline migration | 2 s, no disk copy |
| **Live migration** | **3 ms downtime**, and the source node released the device as the destination took it |
| Data intact after two migrations | yes, same sha256 |
| Snapshot taken while the VM was live, then rolled back | yes, data correct |

#### `find_multipaths` is a per-node policy, and it decides whether a map exists

This is the finding that only a second node could produce. `pc-pve1` had
`find_multipaths no`, so multipath built a map for every device and everything
worked. `pc-pve2` had `find_multipaths yes`, which builds a map **only** for a
device with two or more paths, or one whose WWID is already in
`/etc/multipath/wwids`. With a single portal there was therefore **no map at
all** — session up, by-path device present, and the path this plugin hands out
pointing at nothing.

So the plugin no longer hopes for a map. It runs `multipath -a <wwid>`, which
appends exactly one WWID to that file, then asks for the map by WWID, and
**fails the activation** if it still does not appear rather than starting a VM
against a path that is not there. Never `multipath -A`, and never `-w`/`-W`,
which rewrite the file and would drop other vendors' entries.

#### Removing a shared storage leaves the other nodes' sessions behind

`on_delete_hook` runs on **one** node — the one where `pvesm remove` was typed.
It removes the target and releases that node's session. The other nodes are never
told.

**And `deactivate_storage` will not save you, because nothing calls it.** Verified
across the whole `/usr/share/perl5/PVE` tree on Proxmox VE 9: only the dispatcher
in `Storage.pm` and the per-plugin implementations exist, and neither `pvestatd`
nor the API ever invokes it. This project's own earlier text claimed that disabling
a storage made "each node deactivate on its next poll" — that was wrong, and the
sibling NetApp plugin had already found and corrected the identical claim.

So the leftover — a dead session and a failed map pointing at a target that no
longer exists — is **operator territory**, and the procedure below is the real one
rather than a formality:

```bash
# 1. On EVERY node, while the storage still exists in the configuration:
pve-syno-reap --storage <storage>            # dry run, shows what is left
pve-syno-reap --storage <storage> --remove   # then act

# 2. Only then, on one node:
pvesm remove <storage>
```

`pve-syno-reap` exists because of what a three-node run showed: a VM
live-migrated pve1 → pve2 → pve3 and destroyed on pve3 left **pve1 and pve2 each
holding a multipath map and a tracking entry for a LUN that no longer existed**.
PVE's only `deactivate_volumes` call during migration is inside
`sync_offline_local_volumes`, so for a shared storage the source node is never
told. The tool defaults to a dry run, never touches a device that is in use, and
skips — rather than assumes — anything whose state it cannot establish.

If a session is still left on a node after the storage is gone from the
configuration, the tool can no longer find it, and it is manual:

```bash
multipathd disablequeueing map <map>
dmsetup message <map> 0 fail_if_no_path
multipath -f /dev/mapper/<map>
iscsiadm -m node -T <iqn> -p <portal> --logout
iscsiadm -m node -T <iqn> -p <portal> -o delete
```

### Real multipath, at last — and Auto Block, which I triggered

Everything before this was single-path. With both of the NAS's addresses as data
portals:

```
mpathl (36001405...) dm-9 SYNOLOGY,Storage
size=1.0G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
`-+- policy='service-time 0' prio=50 status=active
  |- 6:0:0:1 sdc 8:32 active ready running     <- via 192.0.2.10
  `- 7:0:0:1 sdd 8:48 active ready running     <- via 192.0.2.11
```

**Failover, with continuous reads running throughout.** One portal was blocked at
the node with `nft`:

| | |
|---|---|
| The blocked path | `failed faulty offline` within ~15 s |
| The surviving path | stayed `active ready running` |
| **Reads that failed** | **0 of 60** |
| Recovery after unblocking | reinstated automatically in ~10 s |

`path_checker tur`, `failback immediate` and `polling_interval 5` — the drop-in
doing exactly what it is for.

**A management outage does not take the data with it.** Blocking only DSM's port
5001 and leaving 3260 alone: the storage reported `inactive`, the other storages
on the node were unaffected, `pvesm status` grew by about one
`syno-status-timeout` and no more, the warning appeared **once** rather than on
every poll, the disk stayed readable, and it recovered by itself when unblocked.

#### The credential latch did not work, and finding out cost a real block

A rejected credential must be tried **once**. The latch was an instance field —
and the plugin builds a new API object for every call, so it died with the
object. Three polls would have been three failed logins.

It is now a file under `/run`, and verified: across five polls, exactly one
attempt reached the NAS and the other four refused locally.

**But the test itself tripped Auto Block**, and that is worth recording as
plainly as possible:

```
from the tested node:  login -> 407   (IP blocked)
from another node:      login -> OK   (the block is per source address)
the iSCSI data path:    unaffected — existing sessions and I/O continued
```

Three failed logins in five minutes blocks that address for **a day**. The
protection now works; the demonstration of why it is needed was not a
simulation. If it happens: **Control Panel → Security → Account → Auto Block →
Allow/Block List**, and remove the address. The data path keeps working
throughout, which is exactly what makes it easy to miss.

**Removing the entry restores access immediately** — confirmed by a single login
from the blocked node afterwards, which succeeded. There is no need to wait out
`expire_day`, and no restart of anything on the NAS or the node is involved.

### Name rules

| | |
|---|---|
| Length | 200 characters accepted exactly. 255 refused-but-created, 256+ cleanly refused. The exact ceiling between 200 and 255 was not pinned because nothing here needs a name that long |
| Legal | `-` hyphen, `.` dot, `:` colon, upper case, digits |
| **Refused** (18990503) | **`_` underscore**, space, `+`, `@` |

**The underscore matters.** A Proxmox VE storage id may contain one, and the
related projects fold a storage id into the array object's name — so the folding
here cannot use `_`, and a storage id containing one has to be sanitised to
something legal. That reintroduces the collision the related projects hit, where
two different storage ids fold to the same prefix and each can then see and
delete the other's disks, so the check that refuses the second such storage is
not optional on this array.

### Size granularity: there is none, and the documented minimum is not enforced

Every size asked for was created **exactly**, with no rounding at any boundary:

```
1 GiB + 1 byte, 1 GiB - 1 byte, 1 GiB + 512, 3 GiB + 12345   all exact
100 MiB   exact          1 byte   exact
```

That is simpler than every other array in this family — no alignment arithmetic
is needed. But note the second half: the knowledge centre documents a **1 GB
minimum LUN size** and **the API does not enforce it**. A one-byte LUN was
created without complaint. So the minimum is the plugin's to enforce, and a
storage that accepted a tiny disk would be relying on undocumented behaviour.

### `is_action_locked` after a create

Cleared after **1.2 s** for a 1 GiB thin LUN, and a delete issued immediately
after the create — with no wait at all — succeeded. So the lock is not a
blanket gate on the next operation; it has to be polled where it matters
(cloning) rather than assumed everywhere.

### `dev_attribs` — the real key names

Read from an existing LUN:

| Key | Value on a thick LUN | Meaning |
|---|---|---|
| `emulate_3pc` | 1 | XCOPY / third-party copy |
| `emulate_tpws` | 1 | WRITE SAME |
| `emulate_caw` | 1 | ATS / Compare and Write |
| **`emulate_tpu`** | **0** | **UNMAP / discard — space reclamation** |
| `emulate_fua_write` | 0 | |
| `emulate_sync_cache` | 0 | |
| **`can_snapshot`** | **0** | whether snapshots are possible at all |

This changes how a LUN must be created: `can_snapshot=1` and `emulate_tpu=1`
have to be sent explicitly, or you get a LUN that cannot be snapshotted and
never returns freed space. **The CSI driver takes `dev_attribs` entirely from
its caller and defaults nothing; Cinder sends none at all.** Neither could
have told us this — the hardware did.

### Targets

`max_sessions` **defaults to 1**, and a target left at 1 admits exactly one
node. Any target a PVE cluster shares must be set to 0.

A target's IQN embeds the NAS hostname **as it was when the target was
created** — the test NAS has targets carrying two different hostnames because
it was renamed. So an IQN must never be derived from the current hostname and
then compared against existing targets.

### API surface

1184 APIs advertised. All SAN APIs are on `entry.cgi`, all `requestFormat=JSON`
(**every parameter must be JSON-encoded**), all v1 only:
`SYNO.Core.ISCSI.{LUN,Target,Node,Host,FCTarget,Lunbkp,Replication,VMware}`,
`SYNO.Core.Storage.{Volume,Pool,iSCSILUN}`. `SYNO.API.Auth` is v1-7.

`SYNO.Core.ISCSI.Host` — the IQN access-control object — **exists and answers**
(`{"hosts":[]}`). Neither reference client knows it is there.

There is no `SYNO.San.Nvme.*` on this model, so it has no NVMe-of support.

---

### The production-readiness battery, and the cost of holding a cluster-wide lock

`cluster_lock_storage` serialises every allocation on a storage **across the whole
cluster**. So the time one allocation takes is the time every other node waits, and
under fifteen concurrent allocations from three nodes one of them failed on the
lock wait.

Measured, then fixed:

| Per allocation | Before | After |
|---|---|---|
| Wall clock | 3.6 s | **2.16 s** |
| DSM sessions opened | 2 | **1** |
| HTTP requests | 17 | **12** |
| Full `LUN list` calls | **3** | **1** |

Three listings for one allocation, at ~0.6 s each on a NAS holding **seven** LUNs —
and that listing grows with every LUN on the NAS, not just this storage's, because
the types filter is never sent. Where they came from:

- `find_free_diskname` → `list_images`, which **opens its own DSM session**: a
  second login, a second API discovery and a second logout, all inside the lock
- `assert_room_for_lun` → another listing, for a count
- `warn_if_near_lun_limit` → another listing, for a warning

`alloc_image` now fetches it once and passes it to all three. `find_free_diskname`
takes an optional listing; every other caller behaves exactly as the base class
does. And `wait_unlocked` polled with `sleep 1` while the register records the lock
clearing in **0.20 s** — so a fifth of a second cost a whole one, on every create
and every snapshot, inside the lock. It polls at 0.2 s now.

Fifteen concurrent allocations from three nodes then completed in 37 s with no
failures and no duplicate names.

#### A three-valued answer negated, in a fix for a different bug

`_detach_local`'s new residual-path removal was written
`if (!map_is_gone($wwid))`. `map_is_gone` returns **1 / 0 / undef**, where undef is
"the stat never came back" — so a bare negation reads "could not tell" as "still
there" and **deletes the sd devices on a state nothing had established.**

Not theoretical. `qm stop` followed by `qm rollback` failed with:

```
storage 'pvesyno': no device for 'pve-pvesyno-vm-9990-disk-0' appeared on this
node after logging in to iqn.2000-01.com.synology:pve-pvesyno-tgt
```

The devices had been removed on an undef and the rescan did not recover them in
time. Rule 12 broken inside a fix written the same hour, and only running it showed
it. The branch now requires `defined $gone && !$gone`.

#### The rest of the battery

| Test | Result |
|---|---|
| 15 concurrent allocations, three nodes | 37 s, 15/15, no duplicates |
| `qm move_disk` to `local-lvm` and back | both directions, guest booted from the moved-back disk |
| Snapshot of a **running** guest, then rollback | guest boots and sees the pre-snapshot content |
| DSM management port blocked, guest doing I/O | `inactive` in 6.3 s, warned **once**, **0 I/O errors in the guest**, recovered on the first poll after unblocking |
| `syno-min-free` above the NAS's free space | allocation refused, with the figures |
| 1 MiB requested | 1 GiB created — the documented minimum the API does not enforce |

### Backup, a real guest, and three nodes — the run that closed the last gaps

Everything before this was `pvesm` and `dd`. This was a cirros guest booting from a
Synology LUN, backed up three ways, restored, migrated across three nodes and
rebooted. No KVM on any node, so all of it under TCG emulation.

| | |
|---|---|
| Import (`qm importdisk`, 112 MiB) | 8 s |
| Guest boot from the LUN | mounted `sda1`, **resized the filesystem to fill the LUN**, reached a login prompt |
| `vzdump --mode snapshot` (live) | 13 s, 36 MB archive, `resuming VM again` after the QMP backup started |
| `vzdump --mode stop` | 19 s, VM stopped and restarted correctly |
| `vzdump --mode suspend` | 15 s, resumed after 1 s |
| `qmrestore` to a new VMID on the same storage | 1 GiB read, 94.7 % sparse |
| Restored guest booted, payload `md5` | **identical to the original** |
| Live migration pve1 → pve2 | downtime **5 ms** |
| Live migration pve2 → pve3 | downtime **87 ms**, `/proc/uptime` 405 s — continuous through both |
| Guest reboot | payload intact |
| Three nodes, one shared storage | all three `active`, all three authenticated from the replicated credential |

`/etc/pve/priv/storage/` replicates: a file written on pve1 appeared on pve2 and
pve3 within seconds at mode `0600`. That was the load-bearing assumption of the
credential change and it had not been checked until now.

#### Two defects, and the second was the same work written twice

**`WwidState::orphans` had no caller.** It was written for the case below,
documented at length, and invoked from nowhere — dead code standing in for a fix.

The case: a VM live-migrated pve1 → pve2 → pve3 and destroyed on pve3 left
**pve1 and pve2 each holding a multipath map and a tracking entry for a LUN that no
longer existed.** PVE's only `deactivate_volumes` call during migration is inside
`sync_offline_local_volumes`, so for a shared storage the source node is never
told. That is PVE's shape, not a bug in it — but a block-device plugin has
per-node state, and one dead map accumulates per LUN per node that ever saw it.

**And `_detach_local` could not clean it up.** When the LUN is deleted from another
node, this node's iSCSI session is still up, so each `sd` node survives as a dead
device and multipathd rebuilds a map over it — `failed faulty running`, one path,
pointing at nothing. `free_image` captured the slaves, flushed, removed the
residual paths and flushed again. `_detach_local` stopped at the first flush. The
same procedure written twice, and only one copy correct; the reaper's first real
run reported **`flush incomplete`** and the map stayed. It now removes residual
paths when — and only when — a flush has failed, so an ordinary VM stop is
unchanged.

With both fixed, `pve-syno-reap --remove` cleared the dead map on pve1 and pve2
and left the live LUN, the running VM and the node's NetApp maps untouched.

#### Nothing in Proxmox VE calls `deactivate_storage`

Verified across the whole `/usr/share/perl5/PVE` tree: only the dispatcher in
`Storage.pm` and the per-plugin implementations exist. Neither `pvestatd` nor the
API invokes it.

So this project's own instruction that `pvesm set --disable 1` makes "each node
deactivate on its next poll" was **false**, and a code comment written the same
afternoon claiming PVE calls it "when it is finished with the storage on this node"
was false too. The sibling NetApp plugin had already found and corrected the
identical claim — a family lesson this project failed to import rather than a new
discovery. Per-node cleanup is operator territory, and `pve-syno-reap` is the path.

### The hardware run of this session's own changes, which found four more

The credential move, the session release, the shrink refusal and the feature
correction had all been unit-tested and none had been driven against the NAS. The
first minute of doing so found a release-blocker.

**`pvesm add` could not work at all in 0.5.3~beta1 or 0.5.4~beta1.**

```
# pvesm add synologysan pvesyno --syno-password '...' ...
missing value for required option 'syno-password'
```

`extract_sensitive_params` removes every sensitive property from the parameters
**before** `check_config` validates them — PVE does them in that order. So by the
time the required-option check ran, the password it was looking for had already
been taken out. A sensitive property must be declared `optional => 1`, and the
plugin enforces its presence itself; PVE's own CIFS plugin does exactly this. No
unit test could have caught it, because the fault is in the interaction between
two PVE stages.

**CHAP was applied only when the target was created.** Measured: `pvesm set
--syno-chap-username` succeeded, the next activation refused nothing, and the
target still reported `auth_type=0` on the NAS. An operator adding CHAP to an
existing storage got no error and no access control — worse than the empty-secret
fault it was found next to, because there is nothing at all to notice. `ensure`
now reconciles CHAP against what the array reports, and the update hook pushes the
secret to **every** target the storage owns, because in `per-volume` mode there is
one per disk.

**A CHAP username with no secret was accepted and merely warned about.** Refusal
must precede the state change, so it is refused now — and `pvesm set` leaves the
configuration untouched.

**Validating against `$scfg` in the update hook is wrong.** PVE applies `$delete`
*after* the hook returns, so `$scfg` still holds a property the operator is
removing while the credential store has already honoured the deletion.
`pvesm set --delete syno-chap-username,syno-chap-password` refused itself. The
hook now computes the effective configuration — current, minus deletions, plus new
values — which is what PVE will write.

Then everything else was re-verified end to end: allocate, activate, a
block-level rollback (`sha256` before = after, with an 8 MiB random pattern zeroed
in between), a clone from the snapshot, twelve consecutive failed operations to
exercise the `DESTROY` logout with no session exhaustion, free, disable, remove.
**The NAS ended with its original four LUNs and three targets and no `pve-`
anything**, and the node with no map, no session, no node record and no drop-in.

#### `multipath -w` reports success and does nothing

Found while checking the one leftover: `/etc/multipath/wwids` keeps a line per LUN
ever attached, and nothing removes it.

| | Documented | Measured |
|---|---|---|
| `multipath -w <wwid>` | "Remove the WWID for the specified device from the WWIDs file" | prints `wwid '<...>' removed` and **changes nothing** with multipathd running. The file's mtime moved and its content did not |
| `multipathd del wwid <wwid>` | — | `fail` |
| `multipath -W` | "Reset the WWIDs file to only include the current multipath devices" | **not run and never will be.** The test node's file holds 334 entries, **319 of them NetApp's** |

So the plugin does not remove them, deliberately, and does not claim to. That is
the third external tool in this project to report success for work it did not do,
after DSM's refused-but-created create and the plugin's own silent shrink.

The residue is harmless for a checkable reason rather than by hope: a WWID is
derived from the LUN's uuid, so a stale entry can only ever match the LUN it came
from, which is deleted. It is not a route to the wrong disk.

### The audit's third pass: a fix that broke CHAP, and a claim nobody had measured

Two of the three findings here are about the *previous* pass. That is the point of
running the audit again after changing things.

**Moving the credentials broke CHAP, silently and in the worst direction.** Making
`syno-chap-password` a sensitive property means PVE strips it from the config — so
`$scfg->{'syno-chap-password'}` became undef. Both CHAP call sites were still
reading it from there, and both consumers ended in `$opt{chap_password} // ''`. So
the result was not a failure: it was an **empty CHAP secret**, written to the
target on the NAS and into the node's iSCSI record. Access control that reports
itself as configured and admits anyone. There is one accessor now, and neither
consumer accepts a missing secret — there is no safe default for a shared secret,
so both refuse.

**`copy => { snap => 1 }` was a promise the plugin could not keep.** `qm clone
--full --snapshot <name>` asks PVE for the `copy` feature with a snapshot name;
a yes sends it to `qemu-img convert` on `path($scfg, $volname, $storeid,
$snapname)`, which dies — a Synology LUN has no device at a snapshot until it is
cloned or rolled back. RBD can say yes because it addresses `pool/image@snap`
directly. So PVE began an operation and failed partway, reporting a problem with
addressing rather than with what was asked. Saying no makes it refuse up front
with something actionable, and the action — a linked clone from the snapshot — is
supported.

`t/11-features.t` now parses the feature table and asserts that only `clone` and
`snapshot` are claimed for a snapshot, so adding a `snap` key forces someone back
to the two refusals that make the claim safe.

**R-25 was recorded as measured and never was.** The comment on the snapshot
timestamp said `create_time` had been "confirmed against the NAS's own clock". No
such measurement exists in this register. It cannot be settled read-only either:
**a LUN carries no `create_time` field at all**, so it needs a snapshot taken and
read back.

Nothing in Proxmox VE 9 reads the value — `Replication` and `QemuServer` use the
snapshot *names* and a `parent` field — so a wrong unit would break nothing today.
It is guarded regardless: a value outside 2001–2065 yields no timestamp rather
than one dated 1970, and a millisecond value is converted. Reporting a wrong
timestamp is worse than reporting none, because it looks like an answer.

### The audit's second pass: four more, and where the credentials were

The first pass looked at bounds and guards. The second followed the data, and the
worst finding was not in the plugin's logic at all.

| Found | Consequence |
|---|---|
| **`syno-password` was written into `/etc/pve/storage.cfg`** | that file is `root:www-data 0640`, and a property PVE does not know is a secret is returned by `GET /storage/<id>` to any user with `Datastore.Audit`. A read-only auditor could read a DSM credential with SAN Manager rights. `syno-device-id` — a standing 2FA bypass — was stored the same way |
| **Nine methods leaked a DSM session on their error paths** | twenty build an API object, nine have a `die` before the `logout`. R-13 established a second login does not evict the first, so they accumulated: one per failed attempt |
| **A shrink was silently declined, not refused** | PVE writes the *requested* size into the VM configuration whatever the plugin returns, so the configuration would claim a size the NAS does not have |
| **The delete-on-refusal cleanup proved nothing** | it deleted what a lookup found, and the only thing separating that from a pre-existing LUN was the error code not being 18990538 |

The credential one is the instructive one, because of **why** it was silent.
`PVE::Storage::Plugin::sensitive_properties` falls back to a hardcoded list when a
plugin declares nothing — `encryption-key keyring master-pubkey password` — and
`syno-password` is not in it. A prefixed property name defeats the default, in the
least safe direction, with no warning at any layer. Verified directly against
PVE's own machinery rather than by reading:

```
PVE reports sensitive for synologysan: syno-chap-password syno-device-id
                                       syno-otp syno-password
handed to the hook in %sensitive:      syno-device-id, syno-password
written into storage.cfg:              syno-location, syno-portal, syno-username
```

They now live in `/etc/pve/priv/storage/<storage>.syno`, 0600. **Anyone upgrading
must treat the old value as disclosed** — moving a secret that `www-data` could
read is not the same as protecting it.

### The third module of this shape, and the prediction that came true

`CLAUDE.md` had said: if a third module of functions-not-methods appears, give it
the same guard. `Command` was that module and the guard was missing. It surfaced
the moment its first test was written, because `$C->is_block_device($path)` is
the natural thing to write:

```
Odd number of elements in hash assignment at Command.pm line 50.
```

Perl bound the class name to `$path` and the remaining argument to `%opts`. The
function then answered **"not a block device"** for a device that exists — and
the audit line "`-b` on a `/dev` path goes through `is_block_device`" would still
have read as satisfied.

This is the worst form of the bug in this family so far. `Naming`'s shifted call
refused something it should have allowed; `Multipath`'s ignored a setting this
one **answers a safety question wrongly, quietly, in the direction of acting.**

### R-10 narrows: the only schedules on this NAS cannot reach a LUN's snapshot list

Read-only, from the node DSM was not blocking. The question was whether a user's
**scheduled** snapshots appear in `list_snapshot` and could therefore be deleted
or rolled back to by a VM operation.

| What was asked | Answer |
|---|---|
| `SYNO.Core.ISCSI.LUN.Snapshot.Schedule` | **error 102 — no such API.** LUN snapshot scheduling is not a separate endpoint on DSM 7.1.1 |
| `SYNO.Core.TaskScheduler list` | 4 tasks, 2 of them snapshot-related and enabled — both **share** snapshots (`Share [photo] Snapshot`, `Share [homes] Snapshot`) |
| `list_snapshot` on each of the four LUNs already on the NAS | **0 snapshots on all four**, so no foreign `taken_by` sample was available |

A shared-folder snapshot is a different object from a LUN snapshot and cannot
appear in a LUN's snapshot list, so on this NAS the hazard is not reachable at
all. What remains unmeasured is a LUN snapshot schedule created through Snapshot
Replication, which needs that package configured against a LUN this plugin owns.

**It does not gate anything, because the filter is a whitelist.**
`snapshot_list` keeps only snapshots whose `taken_by` equals this plugin's own
marker — so an unknown origin is excluded by default rather than needing to be
recognised. A blacklist would have had to be told about every kind of snapshot
DSM can produce; this one does not.

### The audit run that found two things

Run mechanically over the whole tree rather than by reading. Most of the
checklist was already clean — `decoded_content` is always `charset => 'none'`,
no decision is made on message text, no `-b` on a `/dev` path bypasses the
bounded helper, no password reaches a URL, `LC_ALL=C` is pinned in the one place
commands are run. Two were not:

- **An unbounded `waitpid` on a success path.** `sysfs_read_with_timeout` cleared
  its alarm and then reaped with `waitpid($pid, 0)`. Reaching it requires EOF,
  which means the child had already flushed and was on its way to `_exit` — so it
  is safe by argument. But "the child must have exited by now" is the reasoning
  behind every other hang this module exists to prevent, and a child merely
  stopped rather than dead would block it forever. It is a bounded reap now, with
  no signal: the child did its job.
- **The ownership gate was in `free_image` only.** `volume_snapshot_rollback`
  **overwrites a disk** and was relying on the `taken_by` whitelist — sound, since
  a snapshot this plugin took implies a LUN it owns, but that is inference where
  the rule asks for a check. Both snapshot paths now call
  `is_pve_managed_volume($name, $storeid)` directly.

## Not verified

Nothing in this list is acted on by code. Where a plugin decision depends on
one, the plugin refuses rather than assumes.

### Needs a write on hardware

| # | Question | Why it matters |
|---|---|---|
| R-1 | ~~The method name, its parameters, and whether a rollback is safe~~ **FULLY ANSWERED: `restore_snapshot(src_lun_uuid, snapshot_uuid)`.** The LUN uuid is unchanged, snapshots newer than the restored one survive, and `restored_time` records it | Rollback is therefore shippable, and `volume_rollback_is_possible` does **not** need the refusal the related projects require. Sending the snapshot alone is refused with 18990508 |
| R-2 | ~~Does `unmap_target` replace a LUN's target list or add to it~~ **ANSWERED: `map_target` ADDS, `unmap_target` removes only what is named.** The union is still sent, because one measurement on one firmware is not a promise | If it replaced, unmapping one node could unmap all of them — which is what Unity does |
| R-3 | ~~LUN name length limit and legal characters~~ **ANSWERED.** 200 accepted; `_`, space, `+`, `@` refused; a 255-char name is **refused-but-created** | See the write-test sections above. The underscore refusal changes how a storage id is folded into a name |
| R-4 | ~~Size granularity~~ **ANSWERED: exact at every size, no rounding.** But the documented 1 GB minimum is **not enforced by the API**, so the plugin enforces it | Getting less than was asked for means a filesystem that fills and then fails. Here the risk inverts: nothing stops a nonsensically small LUN |
| R-5 | ~~The Linux WWID a LUN's `vpd_unit_sn` becomes~~ **ANSWERED and confirmed on two independent samples.** `WWID = "3" + "6001405" + uuid with `-`→`d`, first 25 chars`, verified against `scsi_id` on an attached LUN | Decides how a node identifies its device. Still a cross-check only: the kernel's own answer is what the plugin acts on |
| R-6 | ~~Whether a LUN with snapshots refuses deletion, and a snapshot with a clone~~ **ANSWERED: neither refuses, and nor does a MAPPED LUN.** Snapshots go with their LUN and are not orphaned | No dependency purging is needed — but unmap-before-delete becomes entirely the plugin's responsibility |
| R-7 | ~~Whether a clone is thin or a full copy~~ **ANSWERED: thin.** `clone_snapshot` gives a `BLUN` with `allocated_size: 0` | Linked clones and templates are genuinely cheap |
| R-8 | ~~How long `is_action_locked` stays set~~ **ANSWERED:** 1.2 s after a 1 GiB create, 0.0 s cloning an empty LUN, **3.5 s cloning a LUN holding 512 MiB**, and 0.20 s for a snapshot of any size. An immediate delete after a create succeeds anyway | A large clone can outlast a naive wait — the CSI driver's own bound is 20 s, which a clone of a few hundred GiB could exceed |
| R-9 | ~~Whether `LUN list` has a server-side cap~~ **PARTLY ANSWERED: `offset`/`limit` are ignored and no total is reported.** So the listing returns everything it has — and nothing in the answer proves that | **A silently truncated listing reads as "this is everything"**, and the code that reads it decides what may be deleted. With no total to check against, only a second read can catch a short answer |
| R-10 | **NARROWED, see above:** the only enabled schedules on the test NAS are SHARE snapshots, which structurally cannot appear in a LUN's snapshot list, and `SYNO.Core.ISCSI.LUN.Snapshot.Schedule` does not exist. **PARTLY ANSWERED:** every snapshot carries `taken_by`, and this plugin's own marker comes back verbatim, so filtering is possible. Whether DSM's *scheduled* snapshots appear in `list_snapshot` still needs a schedule configured | If they do, PVE would show a user's scheduled snapshots as its own and could delete them |
| R-11 | ~~`mapping_index` ceiling per target, and whether it is reused~~ **ANSWERED: it IS reused.** A freed index goes to the next LUN mapped | This is the "wrote to the wrong disk" fault, reachable by detaching one disk and attaching another. It is why device identity comes from the kernel's WWID and never from a path. The ceiling itself is still unmeasured |
| R-12 | ~~Whether DSM tolerates concurrent requests~~ **ANSWERED: sixteen simultaneous creates all succeeded** and the array matched what the API reported. ~1 s each suggests internal serialisation | Cinder wraps every request in a process-wide lock; nothing here needed it for correctness |
| R-13 | ~~Whether a second login on one account evicts the first~~ **ANSWERED: it does not.** Both sessions work simultaneously | Error 107 had made this a real worry for a cluster sharing one account |

### Needs a non-administrator account

| # | Question |
|---|---|
| R-25 | **The unit of a snapshot's `create_time`.** Believed to be epoch seconds; asserted in a code comment as "confirmed against the NAS's own clock" until 2026-08-06, when the audit found no measurement behind it. **It cannot be settled read-only: a LUN carries no `create_time` field at all**, so it needs a snapshot taken and read back against the NAS's clock. Nothing in Proxmox VE 9 reads the value, and the plugin now yields no timestamp rather than an implausible one |
| R-14 | The minimum DSM privileges. The probe ran as an administrator, so it proved "an administrator can" and not "a non-administrator cannot". See `DSM-ACCOUNT.md` |

### Supported by design, unverified — needs hardware this project does not have

Both of Synology's high-availability arrangements are implemented. Neither has
been run. The plugin **warns** on a shape it cannot verify rather than refusing
it, and will not claim otherwise until someone reports a run.

| # | Question |
|---|---|
| R-15 | **Synology HA (SHA)**: does the HA cluster IP behave as a single management address across a failover, and does `SYNO.Core.ISCSI.Node`'s uuid — which this plugin uses as the storage's identity — survive one? If the uuid changes on failover, pinning a storage to it would break the storage rather than protect it |
| R-16 | **UC / SA dual-controller models** (`firmware_ver` containing `DSM UC`): both controllers have their own management address and there is no floating one. `SYNO.Core.Network.Interface` accepts `relay_node=node0`/`node1` to enumerate the peer — on the single-controller test NAS both answer with the same interfaces, so the mechanism is harmless where it is not needed. **Implemented from Synology's own CSI logic; unverified.** The open questions are the ones a chassis answers: whether a LUN is owned by one controller, and whether a target's portals differ per controller — which together decide whether a node reaches its disk after a failover |

---

## The test plan

### Stage 1 — static, no NAS

```bash
make release-check
```

Syntax, unit tests, the same suite as CI runs it, version consistency, the
node-wide multipath guard, and the credential-in-a-URL guard.

### Stage 2 — adverse and hostile, no NAS

Ported from the related projects, because each case there is a defect that
reached a release:

- A server that accepts and never answers, stops mid-body, replies 200 with
  HTML, closes without a response, logs in without returning a sid. Every case
  must fail **quickly**, name the storage, and never hang.
- A create that fails with 5xx is sent exactly **once**.
- Hostile input: storage ids with path traversal and shell metacharacters,
  size alignment at every boundary, sixteen-way concurrent allocation.
- Parsers fed missing, renamed and wrongly typed fields — every field name
  must fail safe rather than be acted on.

### Stage 3 — read-only against a real DSM

```bash
bin/pve-syno-api-probe --host <nas> --user <account>
```

Creates nothing, deletes nothing, logs out after itself. Safe against a
production NAS. Confirm: the API set, a Btrfs volume with free space, the LUN
and target listings, `dev_attribs`, and whether this DSM has anti-CSRF on.

Optionally, and only with the owner's agreement:

```bash
bin/pve-syno-api-probe --host <nas> --user <account> --probe-methods
```

This asks which snapshot-restore method names exist, by naming a LUN and
snapshot uuid the NAS has never issued — so a method that exists can only
refuse, and the refusal code proves it is there. It is opt-in because the
names being sent are destructive ones, even though nothing they could act on
is real. **This is how R-1 gets answered.**

### Stage 4 — writes, on storage nobody minds

**Preconditions.** A dedicated DSM volume, or at minimum a dedicated name
prefix; the owner's explicit agreement; and a list of the LUNs that must not be
touched. Every step reversible.

1. Create a thin LUN with `can_snapshot=1`, `emulate_tpu=1`. Read back `type`,
   `size`, `dev_attribs` — answers R-3, R-4.
2. Create one with a deliberately over-long name, and one with an odd size.
3. Map it to a target with `max_sessions=0`; log in from one node; read
   `/dev/disk/by-id`, `/sys/block/sdX/device/wwid` — **answers R-5**.
4. Map a second and third LUN to the same target; unmap the middle one; map a
   fourth — answers R-2 and R-11.
5. Snapshot, list, clone from snapshot, read `allocated_size` — R-7, R-10.
6. Try to delete a LUN that has a snapshot; try to delete a snapshot that has
   a clone — R-6.
7. Resize; watch `is_action_locked` throughout — R-8.
8. Sixteen concurrent creates from one node, then from two — R-12.
9. Delete everything created, and confirm the NAS is as it was.

### Stage 5 — cluster

- Two nodes logged in to one shared target simultaneously.
- Both nodes' sessions alive at once on one account — **R-13**.
- A VM migrated between nodes with its disk on the storage.
- `pvesm status` timing on every node while one is doing a clone.

### Stage 5b — multipath with only one NAS

**Multipath on a Synology has nothing to do with dual controllers.** A
single-controller model provides multiple paths by having **more than one
network portal**, and a two-NIC NAS is enough for a genuine two-path map.

On the test NAS, read from `SYNO.Core.Network.Interface`:

| Interface | Address | Speed | Status |
|---|---|---|---|
| `ovs_eth0` | 192.0.2.10 (static) | 1000 | connected |
| `ovs_eth1` | 192.0.2.11 (**DHCP**) | 1000 | connected |

That is two paths available already. Three things have to be right first:

1. **`max_sessions = 0` on the target.** The default is 1, and one session is
   one path — so a target left at its default cannot be multipathed at all,
   let alone shared between nodes.
2. **A static address on the second interface.** A data portal on DHCP will
   move, and a path whose address changes is a path that disappears. Give it a
   static address or a permanent reservation.
3. **Both addresses are on one subnet here, and that is the awkward part.**
   Linux will happily send both sessions out of whichever interface the route
   table prefers, so you get two sessions over one physical link and a map that
   looks redundant and is not. Bind each session to its own interface
   explicitly:

   ```bash
   iscsiadm -m iface -I path0 --op=new
   iscsiadm -m iface -I path0 --op=update -n iface.net_ifacename -v <nic0>
   iscsiadm -m iface -I path1 --op=new
   iscsiadm -m iface -I path1 --op=update -n iface.net_ifacename -v <nic1>

   iscsiadm -m discovery -t st -p 192.0.2.10 -I path0
   iscsiadm -m discovery -t st -p 192.0.2.11 -I path1
   iscsiadm -m node -T <target-iqn> -I path0 --login
   iscsiadm -m node -T <target-iqn> -I path1 --login

   multipath -ll        # expect one map, two paths, both active ready running
   ```

   Two separate subnets or VLANs is the cleaner arrangement and worth doing if
   the switch allows it. DSM can also put VLAN sub-interfaces on a single
   physical port, which yields two portal addresses over one cable — enough to
   exercise every code path, though obviously not real redundancy.

**Testing failover without touching the NAS.** Drop one portal from the node
and watch the map, rather than pulling a cable or disabling a NAS interface:

```bash
nft add table inet mptest
nft add chain inet mptest out '{ type filter hook output priority 0; }'
nft add rule inet mptest out ip daddr 192.0.2.11 tcp dport 3260 drop

multipath -ll        # that path must go failed, I/O must continue
nft delete table inet mptest      # and it must come back
```

What to confirm: I/O continues throughout; the map recovers when the rule is
removed; `no_path_retry` is a number so that losing **every** path fails
instead of queueing forever; and nothing the plugin does during the outage
touches another storage's maps.

**If a second path is genuinely impossible** — a one-NIC model — say so rather
than pretending. A single-path map still exercises map creation, WWID pinning,
resize and flush, but the failover paths remain untested, and that belongs in
this document rather than in a release note.

### Stage 6 — failure injection

- A storage pointed at an unroutable address: the other storages stay
  `active`, `pvesm status` grows by about the timeout and no more.
- The NAS's management interface pulled mid-operation.
- A deliberately wrong password: **exactly one login attempt**, and the storage
  reports that it needs a human. Auto Block must not trip.
- The DSM volume filled to under 1 GB free: allocation refused with a message
  that says why.
- multipathd stopped; a path dropped mid-write.

### Stage 7 — live, on the node

Install the built package, and diff `pvesm status` across the install. Nothing
else may change state. Confirm the other storages on the node — this plugin is
developed on a node that also runs the NetApp and Pure Storage plugins — are
undisturbed, and that no other vendor's multipath maps were touched.

---

## Reporting

If you run any of this on your own NAS, the results are worth more than
anything on this page — particularly a model or DSM version that is not the one
above, and particularly R-1. Model, DSM version, volume filesystem, and what
the NAS answered.
