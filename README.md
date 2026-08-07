# jt-pve-storage-synology

A Proxmox VE storage plugin for Synology NAS over iSCSI. One VM disk is one
thin LUN on the NAS, so DSM's own snapshots, clones and capacity act on the
unit an operator actually thinks about — no LVM layer, no shared LUN carved up
locally.

[English](README.md) · [繁體中文](README_zh-TW.md) · **[Documentation site](https://jasoncheng7115.github.io/jt-pve-storage-synology/)**

---

> ### Status: **the plugin works.** Still a prerelease.
>
> `pvesm add synologysan` works, and every lifecycle operation — allocate,
> activate, snapshot, roll back, clone, resize, free, remove — has been driven
> end to end against a DS918+ on DSM 7.1.1, twice over, leaving nothing behind on
> the node or the NAS.
>
> Since then: **two nodes** on different kernels with the same LUN attached, live
> migration at about 3 ms downtime, a real booted VM holding the disk, and
> **two-portal multipath** with a path blocked under load — 0 of 60 reads failed
> and the path came back by itself.
>
> It is still a prerelease, and the honest reasons are: **one** model, **one** DSM
> version, and no HA or dual-controller chassis has ever been near it. Seven bugs
> were found in the first hour of running it that no amount of reading had shown,
> and an audit afterwards found four more — including a credential in the wrong
> file — so assume there are others.
>
> It is public at this stage because the discovery tool is useful on its own,
> and because the honest register of what is and is not known about Synology's
> SAN API is worth reading before anyone trusts a plugin built on it.
>
> **Do not put production data on this yet.**

---

> **Upgrading from a version before 0.5.3~beta1?** Those versions stored the DSM
> password in `/etc/pve/storage.cfg`, where it was readable by `www-data` and
> returned by the API to any user with `Datastore.Audit`. Run
> `pvesm set <storage> --syno-password '<password>'` once per storage to move it
> into `/etc/pve/priv`, and **treat the old value as disclosed** — change the DSM
> account's password. Details and the 2FA token case:
> [docs/DSM-ACCOUNT.md](docs/DSM-ACCOUNT.md).

## Why this exists, and what makes it awkward

Synology publishes no specification for the SAN Manager Web API. The only
official document — the DSM Login Web API Guide — covers logging in and
discovering APIs, and documents no LUN, target, mapping or snapshot call at
all.

What does exist is two independent implementations that talk to it in
production:

- **Synology's own CSI driver**, [SynologyOpenSource/synology-csi](https://github.com/SynologyOpenSource/synology-csi) (Apache-2.0)
- **OpenStack Cinder's Synology driver**, in the [Cinder](https://github.com/openstack/cinder) tree (Apache-2.0)

This project's facts come from reading those two **against each other**, and
then from asking real hardware. That last part matters: the two disagree, and
where they disagree at least one of them is wrong on any given DSM. On the
DSM 7.1.1 used for testing, Cinder's way of carrying a session does not work at
all, and neither client sends the token a DSM with anti-CSRF enabled requires.

Where nothing could be established, this plugin **refuses the operation**
rather than guessing. `docs/TESTING.md` is the register of exactly what that
covers, and it is kept honest.

Only the protocol facts are taken from those projects — API names, method
names, parameters, error codes. No code is derived from either; this is Perl and
its structure is its own.

## What it will do

| PVE operation | On the NAS |
|---|---|
| Create a disk | A thin (`BLUN`) LUN on a Btrfs volume, with `can_snapshot` and UNMAP enabled |
| Delete a disk | Unmap, then delete, with its own snapshots first |
| Grow a disk | LUN expansion, then a bounded per-device refresh on each node |
| Snapshot | DSM LUN snapshot, tagged so it is never confused with a user's own |
| Clone | Clone from a LUN or from one of its snapshots |
| **Rollback** | `restore_snapshot`. The LUN's uuid is unchanged and newer snapshots survive |
| Attach / detach | iSCSI login, device discovered by the kernel's own identification, dm-multipath |

### Rollback, and why it took a while to get here

Neither reference implementation has a snapshot rollback: Kubernetes and Cinder
both restore by cloning a snapshot into a **new** volume, so neither needed one.
The method was found by asking a DSM about nine candidate names, one of which
answered — **`restore_snapshot`**, taking `src_lun_uuid` and `snapshot_uuid`.

Finding the name was not enough to enable it, because three things had to be
true and none was knowable in advance:

| | |
|---|---|
| The LUN's uuid must not change | **It does not.** So the SCSI serial and the WWID survive, and a node does not suddenly find a different disk where its own was |
| Snapshots newer than the restored one must survive | **They do.** Restoring to the oldest of three left all three in place |
| It must be observable afterwards | `restored_time` records the epoch second of the restore |

The second one is the reason the related projects **refuse** a rollback past
newer snapshots: on those arrays the newer snapshots are destroyed, so a plugin
that let PVE do it silently would delete snapshots the user could still see.
Here nothing is destroyed, so that restriction is not needed and a disk can be
rolled back repeatedly.

## Requirements

| | |
|---|---|
| DSM | **7.0 or later**, and only 7.1.1 has been verified. Dual-controller DSM UC is **refused**, not approximated. See below — the version is a floor, not the decision |
| Volume | **Btrfs.** Snapshots exist only for a thin LUN on Btrfs — an ext4 volume is refused when the storage is added, rather than failing at the first snapshot |
| Model | One with iSCSI target support and enough free space. **The LUN ceiling is per-model and small on some of them** — a DS425+ or any J/Value model publishes **4 LUNs**, which is four virtual disks for the whole storage. Sourced table: [docs/LIMITS.md](docs/LIMITS.md) |
| Network | HTTPS to DSM (5001). Plain HTTP is refused |
| Account | A dedicated DSM account — see **[docs/DSM-ACCOUNT.md](docs/DSM-ACCOUNT.md)**, which also explains the one thing DSM will not let you restrict |
| PVE | 8.x / 9.x. The storage API version is negotiated, never hardcoded |

### The DSM version is a floor, not the decision

**7.0 is required.** The technical floor is lower — Cinder's driver works back
to DSM 6.0.2, and snapshots on a Btrfs thin LUN exist from 6.2 — so 7.0 is a
deliberately conservative choice, for four reasons: SAN Manager is the 7.0
product where 6.x had iSCSI Manager; the access-control object this plugin needs
has only been seen on 7.x; **Synology's own CSI driver requires 7.0 or above**,
which makes that the range Synology itself exercises with an API client; and
DSM 6.2 is end of life, so recommending it for production storage would be
wrong regardless of whether the API works.

Only **7.1.1-42962 Update 9** has actually been verified. Between 7.0 and that,
the plugin should work and has not been tried.

**But passing the version check does not mean a NAS can be used**, and this
matters more than the number:

| What actually decides | Why it beats a version number |
|---|---|
| `support_iscsi_target`, `supportsnapshot`, `support_storage_mgr` from `SYNO.Core.System` | These describe the **model**, not the OS release |
| Whether `SYNO.API.Info` advertises the APIs needed | The test NAS runs 7.1.1 and has no NVMe-of API at all. No version number shows that |
| Whether the volume is **Btrfs** | A stricter constraint than the DSM version: **Btrfs support is model-dependent**, and an entry-level model without it can never snapshot, on any DSM release |

So an entry-level NAS running 7.2 may still be unusable, and a check that only
read the version would not say why. The plugin gates on all four and names the
one that failed.

## How many LUNs, and what happens at the ceiling

One VM disk is one LUN, so the LUN ceiling is a real capacity limit — and it is
not the number on the specification sheet.

**Ask the NAS.** `SYNO.Core.System` `info` with `type=define` reports the
model's own ceilings, and neither public reference client reads them:

| Key | On the test DS918+ | DS918+ datasheet | SAN Manager spec (line-wide) |
|---|---|---|---|
| `max_iscsiluns` | **256** | 256 | 512 |
| `max_iscsitrgs` | **128** | 128 | 256 |
| `max_snapshot_per_lun` | 256 | *not published* | 256 |

So the NAS's API and its own datasheet **agree**; the 512 is the ceiling for the
whole product line, which Synology footnotes as varying by model. Larger models
report larger numbers, smaller ones report as few as **4**; the point is that the
number is per-model and the NAS
will tell you which one applies.

### What happens when you reach it

DSM refuses cleanly — **18990541** for LUNs, **18990542** for targets,
**18990543** for snapshots. Nothing is damaged. But the refusal reaches an
operator as an allocation failure with a five-digit number in it, while
`pvesm status` goes on showing terabytes free, because free space is not the
problem and adding disks will not fix it.

### So the plugin refuses first

Before it asks the NAS to create anything it compares the LUN count against
`max_iscsiluns` and refuses with a message that names the real reason: the NAS
holds its model's maximum number of LUNs, deleting is the only remedy. It also
warns once when fewer than sixteen remain, while there is still time to plan.

**The count includes LUNs this storage does not own** — the owner's own LUNs and
any Virtual Machine Manager virtual disks all consume the same ceiling. That is
the second reason this plugin never sends the types filter Synology's own client
sends: that filter hides exactly those objects, so a client trusting it would
under-count against the very ceiling it was checking.

### The three ceilings, in the order they will bite

1. **LUNs** — one per VM disk. The real limit for a busy storage.
2. **Snapshots per LUN**, 256, **shared with the user's own schedule.** A LUN
   with a SAN Manager snapshot schedule on it has fewer left for PVE, and
   "cannot take a snapshot" will not obviously be about that.
3. **Targets**, 128 here. Irrelevant in the default `shared` target mode, which
   uses one — and the reason `per-volume` is not the default, since it would cap
   the storage at 128 disks, *below* the LUN ceiling.

## High availability and dual controllers

Synology has two arrangements that both get called "HA", and they are different
problems with different answers. **Both are supported.**

| | **Synology HA (SHA)** | **UC / SA dual controller** |
|---|---|---|
| Shape | two chassis, active/passive | two controllers in one chassis |
| Detected by | — | `firmware_ver` contains `DSM UC` |
| Management address | **one floating cluster IP** | **one per controller, none floating** |
| Configure as | `--syno-portal <cluster-ip>` | `--syno-portal <ctrl-a>,<ctrl-b>` |
| Closest analogue | Pure Storage's `vir0` | PowerVault ME's two controller addresses |

`syno-portal` takes a list, tried in order and rotated on failure. The rotation
happens **inside** the login and the request URL is built after it — a related
project shipped a bug where the URL was built first, so every retry went on
travelling to the address that had just been found dead.

For a UC chassis the second address does not have to be configured:
`SYNO.Core.Network.Interface` accepts `relay_node=node0` and `node1`, which
enumerates the peer controller's interfaces. On a single-controller NAS both
answer with the same interfaces, so the mechanism is harmless where it is not
needed. On those models a target's `network_portals` also carries a
`controller_id`, which a single-controller NAS omits entirely.

### Neither has been run on hardware, and the plugin says so

SHA is low risk: it is one address that happens to move, which is the case the
plugin already handles. UC is a genuine unknown, and the open questions are the
ones only a chassis can answer — whether a LUN is owned by one controller, and
whether a target's portals differ per controller. Together those decide whether
a node still reaches its disk after a failover.

So the plugin **warns** when it detects `DSM UC` rather than refusing, and this
page will keep saying "unverified" until someone reports a run. Both are in the
register as R-15 and R-16.

**If you run either, the most useful thing you can report is one number**: does
`SYNO.Core.ISCSI.Node`'s uuid stay the same across a failover? A storage's
identity is pinned to it, so if it changes, that pin stops protecting the
storage and starts breaking it.

## Installing

On every node of the cluster.

```bash
wget https://github.com/jasoncheng7115/jt-pve-storage-synology/releases/download/v0.6.3-beta1/jt-pve-storage-synology_0.6.3.beta1-1_all.deb
dpkg -i jt-pve-storage-synology_0.6.3.beta1-1_all.deb
systemctl restart pvedaemon pveproxy pvestatd
```

The version is in the URL on purpose: `/releases/latest/download/…` answers **404**
here, because every 0.x is tagged as a prerelease and GitHub's `latest` skips those.
Newer builds are on the [releases page](https://github.com/jasoncheng7115/jt-pve-storage-synology/releases).
From a clone, `make install`.

> **Schedule the first install.** `activate_storage` writes a multipath drop-in for
> `vendor "SYNOLOGY"` and, when that file changes, runs `multipathd reconfigure` —
> a **node-wide** command. It runs once, when the file first appears or changes.
>
> **Measured: it does not disturb another vendor's storage.** On multipath-tools
> 0.11.1, with continuous direct reads against an existing unrelated map, a
> `multipathd reconfigure` gave **1776 reads and 0 failures**, the map's
> device-mapper **event counter did not move** — so it was never reloaded — and its
> path stayed `active ready running`. Reconfigure re-reads configuration but only
> reloads a map whose configuration actually changed. The maintenance window is
> advice for a first install on a production node, not a known outage.
>
> The drop-in is mandatory rather than tuning: without it multipath's generic
> defaults apply, and those include `no_path_retry "queue"`, which turns the loss
> of every path into an unkillable process instead of an I/O error.

Four of these plugins can share a node — but `PVE::SectionConfig::init` **dies on a
duplicate property name**, and every storage on the node then stops working. The
`syno-` prefix exists for that reason.

## Configuring a storage

Once, on one node. The storage is shared by construction.

```bash
pvesm add synologysan mysyno \
    --syno-portal   192.0.2.10 \
    --syno-username pve-storage \
    --syno-password '<the password>' \
    --syno-location /volume1 \
    --content       images
```

`pvesm add` refuses immediately if the volume is not Btrfs, if the model does not
support iSCSI targets or snapshots, or if the storage id would fold onto an existing
storage's LUN prefix.

**The password never lands in `/etc/pve/storage.cfg`.** It goes to
`/etc/pve/priv/storage/<storage>.syno`, mode `0600`, root only, replicated to every
node. Full option list and the removal procedure: the
[documentation site](https://jasoncheng7115.github.io/jt-pve-storage-synology/#configure).

## The discovery tool

This works today, and it is worth running before anything else. It is
**read-only**: it creates nothing, deletes nothing, and logs out after itself.
It is safe against a production NAS.

```bash
bin/pve-syno-api-probe --host 192.0.2.10 --user pve-storage
```

The password is prompted for with echo off — never passed on the command line,
where it would be visible in `ps` and in the shell history.

It reports the API set and every version range the NAS accepts, whether
anti-CSRF is on, the DSM volumes and their filesystems, the LUNs and targets as
they are now, the `dev_attribs` of an existing LUN, and — at the end — a
register of what the run settled and what still needs a write to answer.

```
--probe-methods    ask which snapshot-restore method names exist
--otp <code>       for an account with 2-factor authentication
--json             also print the findings as JSON
```

`--probe-methods` is opt-in. It names a LUN and snapshot uuid the NAS has never
issued, so a method that exists can only refuse — and the refusal proves it is
there. Nothing it could act on is real, but the names being sent are
destructive ones, so it asks first.

## The cleanup tool

`pve-syno-reap` reports — and with `--remove` clears — multipath maps this node
holds for LUNs the NAS no longer has, and tracking entries left by a crash.
**Default is a dry run.**

```bash
pve-syno-reap --storage <storage>            # show what is left behind
pve-syno-reap --storage <storage> --remove   # then act
pve-syno-reap --all --remove                 # every synologysan storage on this node
```

**Run it after a node crash, and on every node before removing a storage.** Two
things make it necessary, both measured on a three-node cluster:

- Proxmox VE's only `deactivate_volumes` call during migration is inside
  `sync_offline_local_volumes`, so for a **shared** storage the source node is
  never told a VM left. A VM migrated `pve1 → pve2 → pve3` and destroyed on pve3
  leaves pve1 and pve2 each holding a map for a LUN that no longer exists.
- A hard-reset node never runs `deactivate_volume` at all, so its tracking file
  keeps an entry for a LUN it is no longer attached to.

Neither is dangerous — every consumer re-checks for a device before acting, and
device identity always comes from the kernel's WWID — but they accumulate. The
tool never touches a device that is in use, and skips rather than assumes anything
whose state it cannot establish.

Nothing in Proxmox VE calls `deactivate_storage` (verified across the whole
`/usr/share/perl5/PVE` tree), so this cleanup is the operator's, not PVE's.

## Documentation

| | |
|---|---|
| [docs/TESTING.md](docs/TESTING.md) | What is verified, what is not, and the test plan. **Read this before trusting anything** |
| [docs/DSM-ACCOUNT.md](docs/DSM-ACCOUNT.md) | The DSM account, its minimum privileges, Auto Block, 2FA, TLS |
| [docs/LIMITS.md](docs/LIMITS.md) | Every model's published LUN and target maxima, with the official source for each figure |

## Related projects

Proxmox VE storage plugins for other arrays, sharing the host-side layer and
the operational rules this one inherits:

- [jt-pve-storage-dellemc](https://github.com/jasoncheng7115/jt-pve-storage-dellemc) — Dell EMC PowerStore, PowerVault ME, PowerFlex, Unity XT
- [jt-pve-storage-netapp](https://github.com/jasoncheng7115/jt-pve-storage-netapp) — NetApp ONTAP
- [jt-pve-storage-purestorage](https://github.com/jasoncheng7115/jt-pve-storage-purestorage) — Pure Storage FlashArray

## Licence

MIT. See [LICENSE](LICENSE).

This project is not affiliated with or endorsed by Synology Inc. Synology and
DSM are trademarks of Synology Inc.

## Author

Jason Cheng (Jason Tools) &lt;jason@jason.tools&gt;
