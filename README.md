# jt-pve-storage-synology

A Proxmox VE storage plugin for Synology NAS over iSCSI. One VM disk is one
thin LUN on the NAS, so DSM's own snapshots, clones and capacity act on the
unit an operator actually thinks about — no LVM layer, no shared LUN carved up
locally.

[English](README.md) · [繁體中文](README_zh-TW.md)

---

> ### Status: specification and discovery. **There is no plugin yet.**
>
> This repository currently contains the development specification, the project
> rules, and `bin/pve-syno-api-probe` — a read-only tool that asks a DSM what
> it actually supports. The plugin itself is not written.
>
> It is public at this stage because the discovery tool is useful on its own,
> and because the honest register of what is and is not known about Synology's
> SAN API is worth reading before anyone trusts a plugin built on it.
>
> **Do not put production data on this yet.** There is nothing to put it on.

---

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
| **Rollback** | **Refused in the first release** — see below |
| Attach / detach | iSCSI login, device discovered by the kernel's own identification, dm-multipath |

### Why rollback is refused

Neither reference implementation has one: Kubernetes and Cinder both restore by
cloning a snapshot into a *new* volume, so neither needed it.

The method has since been found on hardware — it is **`restore_snapshot`**, on
`SYNO.Core.ISCSI.LUN`, established by asking a DSM 7.1.1 about nine candidate
names and getting exactly one answer. That is a real step forward, and it is
still not enough to enable a rollback. **Knowing a method exists is not knowing
what it does.** Its parameter names are unconfirmed, and so is the behaviour
that actually matters: whether a rollback keeps snapshots newer than the one
restored, and whether it preserves the LUN's uuid. A rollback that silently
changes the uuid changes the WWID, and every node in the cluster then sees a
different disk.

The alternative some plugins take — clone the snapshot, delete the original,
rename the clone into its place — is not acceptable here. It destroys the
original before the replacement is proven, and it changes the LUN's identity,
so every node sees a different disk.

Snapshot create, list and delete all work, so `vzdump` snapshot mode is fine.
Rollback is scheduled for 0.7.0, once that behaviour has been observed on a LUN
nobody minds losing.

## Requirements

| | |
|---|---|
| DSM | 7.x. Dual-controller DSM UC is **refused**, not approximated |
| Volume | **Btrfs.** Snapshots exist only for a thin LUN on Btrfs — an ext4 volume is refused when the storage is added, rather than failing at the first snapshot |
| Model | One with iSCSI target support and enough free space. 512 LUNs and 256 targets per NAS are the product ceilings |
| Network | HTTPS to DSM (5001). Plain HTTP is refused |
| Account | A dedicated DSM account — see **[docs/DSM-ACCOUNT.md](docs/DSM-ACCOUNT.md)**, which also explains the one thing DSM will not let you restrict |
| PVE | 8.x / 9.x. The storage API version is negotiated, never hardcoded |

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

## Documentation

| | |
|---|---|
| [docs/TESTING.md](docs/TESTING.md) | What is verified, what is not, and the test plan. **Read this before trusting anything** |
| [docs/DSM-ACCOUNT.md](docs/DSM-ACCOUNT.md) | The DSM account, its minimum privileges, Auto Block, 2FA, TLS |

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
