# Synology LUN and target limits, per model

[English](LIMITS.md) · [繁體中文](LIMITS_zh-TW.md) · [Documentation site](https://jasoncheng7115.github.io/jt-pve-storage-synology/)

**One VM disk is one LUN in this plugin.** So the LUN ceiling is not a footnote —
it is the maximum number of virtual disks the storage can ever hold, and on some
models it is small enough to matter before anything else does.

Every figure on this page is quoted from an official Synology document, with the
URL. Nothing is interpolated: where Synology publishes no figure, it says so.

---

## The number everyone quotes is the product line's, not your model's

Synology's **SAN Manager Technical Specifications** page states:

| | |
|---|---|
| Maximum iSCSI targets | **256** (see limitation 1) |
| Maximum LUNs | **512** (see limitation 1) |
| Maximum snapshots per LUN | **256** (see limitation 1) |
| Minimum LUN size | **1 GB** |

> **limitation 1** — "The maximum number of LUNs, targets, and snapshots varies
> according to models (Refer to the software specifications of your Synology
> products)"

— [SAN Manager Technical Specifications, DSM 7.1](https://www.synology.com/en-global/dsm/7.1/software_spec/san_manager)
(identical wording on the [DSM 7.3](https://www.synology.com/en-us/dsm/7.3/software_spec/san_manager) page)

So **512 and 256 are the ceiling for the whole product line.** They are not your
NAS's numbers unless your NAS's own datasheet says so.

### There is no discrepancy between the datasheet and the API

This project previously documented one, and was wrong. The test NAS is a DS918+:

| Source | Max LUNs | Max targets |
|---|---|---|
| SAN Manager software spec (line-wide) | 512 | 256 |
| [DS918+ Product Specification](https://global.download.synology.com/download/Document/Hardware/ProductSpec/DiskStation/18-year/DS918+/enu/Product_Spec_DS918+_enu.pdf) | **256** | **128** |
| `SYNO.Core.System info type=define` on that NAS | **256** | **128** |

The model's datasheet and the NAS's own API **agree exactly**. What disagreed was
this documentation, which had compared the model against a line-wide figure.

---

## Published figures, by model

Quoted from each model's own datasheet or product specification PDF. All URLs are
under `https://global.download.synology.com/download/Document/Hardware/`.

| Series | Model | Max LUNs | Max targets |
|---|---|---:|---:|
| **FS** | FS6400 | 512 | 256 |
| | FS3600 | 512 | 256 |
| | FS3410 | 256 | 128 |
| | FS2500 | 128 | 64 |
| **SA** | SA6400 | 512 | 256 |
| | SA3600 | 512 | 256 |
| | SA3410 | 256 | 128 |
| | SA3400D | 256 | 128 |
| | SA3200D | 128 | 64 |
| **XS+ / XS** | DS3622xs+ | 256 | 128 |
| | RS4021xs+ | 256 | 128 |
| | RS3621xs+ | 256 | 128 |
| | RS3618xs | 128 | 64 |
| **Plus** | DS1821+ | 256 | 128 |
| | DS923+ | 256 | 128 |
| | DS920+ | 256 | 128 |
| | **DS918+** (the test NAS) | **256** | **128** |
| | DS723+ | 256 | 128 |
| | DS1825+ | **128** | **64** |
| | RS2825RP+ | 128 | 64 |
| | RS1221+ | 128 | 64 |
| | DS425+ | **4** | **2** |
| | DS423+ | *not published* | *not published* |
| **Value** | DS423 | 4 | 2 |
| | DS223 | 4 | 2 |
| | DS218play | 10 | 10 |
| **J** | DS223j | 4 | 2 |
| | DS124 | 4 | 2 |

### Read this table for the shape, not to look your model up

Three things in it matter more than any individual row.

**The series does not predict the number.** The figures cluster on 4/2, 128/64,
256/128 and 512/256, but Synology assigns them per model and publishes no
series-level rule. A "Plus" model may be 256, 128 or 4.

**They are not monotonic with generation.** The **DS1825+** (2025, eight-bay Plus)
publishes **128/64**, where the older **DS1821+** publishes **256/128**. The
**RS3618xs** publishes 128/64 where the **RS3621xs+** publishes 256/128. A newer or
larger model is not a bigger number.

**On J, Value and some small Plus models the limit is 4 LUNs.** A DS425+, DS423,
DS223, DS223j or DS124 publishes **4 LUNs and 2 targets**. In this plugin that is
**four virtual disks for the entire storage** — one VM with a system disk and a data
disk uses half of it. Those models can run the plugin, and will run out of LUNs long
before they run out of space.

---

## So ask the NAS, and this plugin does

`SYNO.Core.System` `info` with `type=define` reports the model's own ceilings.
Neither of the public reference clients reads them. From the test DS918+:

```
max_iscsiluns          256
max_iscsitrgs          128
max_snapshot_per_lun   256
max_btrfs_snapshots    65536
support_iscsi_btrfs_lun    yes
iscsi_target_type          lio4x
```

The plugin reads all three ceilings and refuses **before** the NAS does, so the
message names the real reason instead of an error number:

| Ceiling | What the plugin does |
|---|---|
| LUNs | refuses the allocation, and warns from 16 remaining. Counts **every** LUN on the NAS, including ones this storage does not own |
| Snapshots per LUN | refuses the snapshot. Counts **every** snapshot on that LUN, including any taken by a SAN Manager schedule — the ceiling is shared |
| Targets | refuses target creation. Only reachable with `syno-target-mode=per-volume`; `shared` uses one target for the whole storage and is the default for this reason |

`undef` from any of them means the NAS did not report it, and the guard stands down
rather than inventing a number. It never means "no limit".

### Why `shared` is the default target mode

On a model publishing 256 LUNs and 128 targets, `per-volume` gives each disk its own
target — so the target ceiling is reached at **128 disks, half of what the LUNs
allow**. `shared` uses one target per storage and leaves the LUN ceiling as the only
limit.

---

## Snapshots per LUN, and a budget that is shared

**256 per LUN**, from the SAN Manager Technical Specifications page, carrying the
same "varies according to models" footnote. The test DS918+ reports 256.

Two things about that number:

- **It is shared with SAN Manager.** A snapshot schedule configured in DSM consumes
  the same 256. This plugin counts every snapshot on the LUN, not only its own, for
  exactly that reason.
- **No datasheet examined states a per-LUN snapshot figure.** The datasheets'
  "Maximum Snapshots per Shared Folder" (128 / 512 / 1,024) and "Maximum of System
  Snapshots" (1,024 / 4,096 / 16,384 / 65,536) are Snapshot Replication rows for a
  different object. The DS918+ datasheet has no per-LUN snapshot row at all. Do not
  read those numbers as LUN limits.

---

## LUN type changes what works, not how many

Synology documents LUN-type dependency for **capability**, never for the count. From
the SAN Manager specification page:

- Snapshots and space reclamation are **not supported on Thick Provisioned LUNs**
- **Only Thin Provisioned LUNs on Btrfs volumes, DSM 6.2 and above, support instant
  snapshot and restoration**
- Defragmentation is supported only on Thin Provisioned Btrfs LUNs
- iSCSI LUN Clone/Snapshot are available only on specific models

This is why the plugin requires a Btrfs volume and refuses at `pvesm add` rather
than at your first snapshot. No official source states a different maximum LUN
count for thin versus thick.

---

## What is not published

Stated plainly, because a gap is more useful than a guess:

- **No maximum sessions per target.** Nothing official states the default or the
  maximum. That the default admits one node, and that `max_sessions=0` is needed for
  a cluster, is measured on hardware only — see `TESTING.md`.
- **No Knowledge Center article** of the form "what is the maximum number of LUNs".
  The SAN Manager help pages exist and point you at your model's datasheet, but their
  body text is rendered client-side and was not read directly:
  [LUN](https://kb.synology.com/en-global/DSM/help/ScsiTarget/lun?version=7) ·
  [iSCSI](https://kb.synology.com/en-global/DSM/help/ScsiTarget/iscsi?version=7) ·
  [Snapshot](https://kb.synology.com/en-global/DSM/help/ScsiTarget/snapshot?version=7)
- **No link between the limits and DSM version or RAM.** Every datasheet examined was
  checked for such a footnote and none exists. The only RAM-conditional figure is SMB
  concurrent connections.
- **DS423+ publishes no figure at all.** It is not the same as the DS423 — it is
  unknown.
- **UC3200, SA3400 and the newest XS+ rack models** were not retrieved; their
  datasheet URLs did not resolve under the pattern that worked for the rest. Unknown
  rather than absent, and relevant to the unverified UC support in `TESTING.md`.

---

## Official references

- [SAN Manager Technical Specifications — DSM 7.1](https://www.synology.com/en-global/dsm/7.1/software_spec/san_manager)
- [SAN Manager Technical Specifications — DSM 7.3](https://www.synology.com/en-us/dsm/7.3/software_spec/san_manager)
- [DS918+ Product Specification (PDF)](https://global.download.synology.com/download/Document/Hardware/ProductSpec/DiskStation/18-year/DS918+/enu/Product_Spec_DS918+_enu.pdf)
- [DS923+ Datasheet (PDF)](https://global.download.synology.com/download/Document/Hardware/DataSheet/DiskStation/23-year/DS923+/enu/Synology_DS923+_Data_Sheet_enu.pdf)
- [DS1825+ Datasheet (PDF)](https://global.download.synology.com/download/Document/Hardware/DataSheet/DiskStation/25-year/DS1825+/enu/Synology_DS1825+_Data_Sheet_enu.pdf)
- [FS6400 Datasheet (PDF)](https://global.download.synology.com/download/Document/Hardware/DataSheet/FlashStation/20-year/FS6400/enu/Synology_FS6400_Data_Sheet_enu.pdf)
- [SA6400 Datasheet (PDF)](https://global.download.synology.com/download/Document/Hardware/DataSheet/SA/22-year/SA6400/enu/Synology_SA6400_Data_Sheet_enu.pdf)
- [DS3622xs+ Datasheet (PDF)](https://global.download.synology.com/download/Document/Hardware/DataSheet/DiskStation/22-year/DS3622xs+/enu/Synology_DS3622xs+_Data_Sheet_enu.pdf)
- [Synology product index](https://www.synology.com/en-global/products) — every model's own datasheet is linked from its product page, and that is the figure to trust for your NAS

**To check your own NAS rather than a table:**

```bash
pve-syno-api-probe --host <nas> --user <account>
```

It reports the model's ceilings, creates nothing and deletes nothing.
