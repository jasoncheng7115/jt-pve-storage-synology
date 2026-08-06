# Changelog

Every 0.x release is a prerelease. 1.0.0 is the hardware test pass.

The register of what has been verified against real hardware, and what has not,
is [docs/TESTING.md](docs/TESTING.md) — it is more useful than this file for
deciding whether to trust a given release.

## [0.1.3~beta1] - 2026-08-06

Stage-4 write tests against a DS918+ on DSM 7.1.1, on a dedicated `pvetest-`
prefix, with every object deleted afterwards and the array confirmed back to its
original contents.

### Added

- **Rollback is supported.** `restore_snapshot(src_lun_uuid, snapshot_uuid)`
  leaves the LUN's uuid unchanged — so the WWID survives — and snapshots newer
  than the restored one are kept. `volume_rollback_is_possible` therefore does
  **not** need the refusal the related projects require, and a disk can be
  rolled back repeatedly.
- **Both high-availability arrangements are supported**: Synology HA (one
  floating cluster IP, like Pure's `vir0`) and UC/SA dual controller (one
  address per controller, discovered via `relay_node`). Neither has been run on
  hardware; the plugin warns on `DSM UC` rather than refusing, and the
  documentation says unverified until someone reports a run.
- A clone from a snapshot is **thin** (`allocated_size: 0`), so linked clones
  and templates are genuinely cheap.

### Fixed / learned

- **A create that reports failure can create the LUN anyway** — a 255-character
  name is refused with 18990068 and the LUN is made regardless. A failed create
  is never believed: the name is looked up afterwards and what is found is
  adopted or deleted.
- **`mapping_index` is reused.** A freed index goes to the next LUN mapped, so a
  stale device path resolves to a different disk. Device identity comes from the
  kernel's WWID, never from a path — which both public reference clients rely on
  exclusively.
- **Nothing refuses a delete for dependency reasons** — not a LUN with
  snapshots, not a snapshot with a live clone, and not a **mapped** LUN. So
  unmapping before deleting is entirely this plugin's responsibility.
- `map_target` adds and `unmap_target` removes only what is named, the opposite
  of Unity's replace-the-list behaviour.
- Sixteen simultaneous creates all succeeded and the array matched what the API
  reported; a second login does not evict the first.
- `_` is not legal in a LUN name, nor space, `+` or `@`. Sizes are created
  exactly, with no rounding — and the documented 1 GB minimum is not enforced by
  the API, so the plugin enforces it.

## [0.1.2~beta1] - 2026-08-06

### Fixed

- **The published `SHA256SUMS` could not be verified.** GitHub rewrites the `~`
  in a release asset's filename to `.`, so the checksum file listed
  `..._0.1.1~beta1-1_all.deb` while the file served was
  `..._0.1.1.beta1-1_all.deb`, and `sha256sum -c SHA256SUMS` answered "No such
  file or directory". The release workflow now renames the package to the name
  GitHub will serve before hashing it, and then verifies its own checksum file
  rather than assuming. The `.deb` itself was always correct — dpkg reads the
  version from the package's control data, never from the filename — so
  0.1.0~beta1 and 0.1.1~beta1 install correctly; only their checksum files are
  unusable.

### Added

- This changelog, in both languages. `make release-check` now requires an entry
  for the version being released.

## [0.1.1~beta1] - 2026-08-06

### Added

- **The snapshot restore method is `restore_snapshot`**, established against
  hardware: nine candidate names were sent to a DSM 7.1.1, each naming a LUN and
  snapshot uuid the NAS has never issued, and one answered with `18990505 bad
  LUN UUID` — proving it exists and got as far as looking the LUN up. Neither
  public reference implementation has this method.
- Error 18990004 recorded, observed from `SYNO.Core.ISCSI.Host` `get`.

### Changed

- **The LUN listing no longer sends a types filter.** Synology's own CSI driver
  sends an explicit twelve-type list, and on the test NAS that list hid a
  Virtual Machine Manager virtual disk whose 120 GiB comes out of the same
  volume. A filter verified to be incomplete is worse than no filter, because a
  listing that quietly omits objects is read as "this is everything" by whatever
  decides what may be deleted. The probe now runs both listings and reports what
  the filter would have hidden.
- **Rollback remains refused.** Knowing a method exists is not knowing what it
  does: its parameter names are unconfirmed, and so is whether a rollback keeps
  snapshots newer than the one restored and whether it preserves the LUN uuid.

### Fixed

- The register reported a listing skipped by `--no-luns` as one the account
  could **not** read. Skipped, refused and succeeded are three different
  outcomes, and conflating the first two is the confusion this project's rules
  exist to prevent.
- A read method that succeeded was flagged as alarming. Only a destructive
  candidate succeeding is.
- The header comment still described `--probe-methods` as sending no parameters,
  which the change to naming a non-existent uuid had made untrue.

## [0.1.0~beta1] - 2026-08-06

First packaged build. **Contains no storage plugin.**

### Added

- `pve-syno-api-probe` — read-only discovery of a Synology DSM's SAN Web API.
  Discovers API paths and version ranges instead of hardcoding them, carries a
  session both ways because the two public reference clients disagree about
  which works, echoes the anti-CSRF token neither of them sends, and never puts
  a credential in a URL.
- `docs/TESTING.md` — the register of what is verified against hardware and
  what is not, with the test plan for closing the gap.
- `docs/DSM-ACCOUNT.md` — the DSM account the plugin needs, what can be taken
  away from it, and the Auto Block behaviour that makes retrying a rejected
  credential dangerous.
- Build guards: no node-wide `multipath` flush, and no credential in a URL.
