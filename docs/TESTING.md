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
| Note | A **production** NAS. Read-only probing only, so far |

**No write test has been run yet. No plugin code exists yet.** Everything in
the "verified" table below was established read-only.

---

## Verified on hardware (2026-08-06, read-only)

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

## Not verified

Nothing in this list is acted on by code. Where a plugin decision depends on
one, the plugin refuses rather than assumes.

### Needs a write on hardware

| # | Question | Why it matters |
|---|---|---|
| R-1 | **The method name for restoring a LUN from its snapshot** | Neither reference client has one. `restored_time` proves the operation exists. Until the name is known, **rollback is refused** |
| R-2 | Does `unmap_target` replace a LUN's target list or add to it? | If it replaces, unmapping one node could unmap all of them |
| R-3 | LUN name length limit and legal characters | The name carries the ownership check. Silent truncation means two disks with one name |
| R-4 | Size granularity | Getting less than was asked for means a filesystem that fills and then fails |
| R-5 | The Linux WWID a LUN's `vpd_unit_sn` becomes | Decides how a node identifies its device. Half-answered: the serial is the uuid; the kernel-side string still has to be read from a host that has one mapped |
| R-6 | Whether a LUN with snapshots refuses deletion, and a snapshot with a clone | `qm destroy` and vzdump's snapshot mode both walk straight into this |
| R-7 | Whether a clone is thin or a full copy | Decides whether linked clones are possible |
| R-8 | How long `is_action_locked` stays set | A large clone can outlast a naive wait — the CSI driver's own bound is 20 seconds |
| R-9 | Whether `LUN list` has a server-side cap | **A silently truncated listing reads as "this is everything"**, and the code that reads it decides what may be deleted |
| R-10 | Whether `list_snapshot` returns snapshots taken by DSM's own schedule | If it does, PVE would show a user's scheduled snapshots as its own and could delete them |
| R-11 | `mapping_index` ceiling per target, and whether it is reused | A reused index with a stale device node in the kernel is the "wrote to the wrong disk" class of fault |
| R-12 | Whether DSM tolerates concurrent requests | **Cinder wraps every single request in a process-wide lock.** It did not do that for fun |
| R-13 | Whether a second login on one account evicts the first (error 107) | If it does, every node in a cluster would evict every other, every poll |

### Needs a non-administrator account

| # | Question |
|---|---|
| R-14 | The minimum DSM privileges. The probe ran as an administrator, so it proved "an administrator can" and not "a non-administrator cannot". See `DSM-ACCOUNT.md` |

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
