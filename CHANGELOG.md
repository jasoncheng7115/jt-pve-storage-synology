# Changelog

Every 0.x release is a prerelease. 1.0.0 is the hardware test pass.

The register of what has been verified against real hardware, and what has not,
is [docs/TESTING.md](docs/TESTING.md) — it is more useful than this file for
deciding whether to trust a given release.

## [0.2.1~beta1] - 2026-08-06

### Added

- `Synology::Naming` — name building and **the ownership gate**, which decides
  what this plugin may delete. It takes the storage id, not merely a name that
  looks like some PVE plugin's: a prefix identifies the *storage*, never the
  kind of object, so both halves are checked.
- A measured answer that simplifies things: **snapshot names need no folding
  at all.** DSM stores underscores, spaces, `+`, `@` and leading digits in a
  snapshot name exactly, so PVE's names pass straight through — and a duplicate
  within one LUN is refused with **18990513**, so a name identifies a snapshot.
- 48 more tests, most of them hostile: a foreign LUN, a Virtual Machine Manager
  disk, a prefix that is not at the start, and a name with a trailing newline
  are all correctly *not* owned.

### Fixed

- The naming functions now refuse a **method** call instead of answering
  wrongly. Called as `Naming->is_pve_managed_volume(...)` the arguments shift
  along and the gate answers "not owned" for an object that is owned — safe,
  but silent, and a listing would come back empty with nothing to explain it.
  Writing the tests is what found it.

## [0.2.0~beta1] - 2026-08-06

**The first code that talks to a NAS.** Three modules, 91 unit tests, and a full
lifecycle driven against a DS918+ on DSM 7.1.1: create, duplicate-name refusal,
snapshot, ownership filtering, rollback past a newer snapshot, clone, resize,
target creation, additive mapping, surgical unmapping, and delete.

There is still no PVE plugin — `synologyiscsi` cannot be added to a node yet.
This is the layer beneath it.

### Added

- `Synology::API` — the transport. Discovers paths and versions from the NAS
  instead of hardcoding them, carries the session as **both** a cookie and a
  form parameter because the two reference clients disagree about which works,
  echoes the anti-CSRF token neither of them sends, JSON-encodes parameters for
  the APIs that ask for it, rotates portals on failure with the URL built
  **after** the rotation, and **latches on a rejected credential so it never
  retries** — DSM blocks an address for a day after three failures, and PVE
  polls every ten seconds.
- `Synology::LUN` — LUNs and snapshots. Never sends the types filter that hides
  LUNs; enforces the 1 GB minimum the API does not; refuses illegal names
  locally rather than at a NAS that sometimes creates them anyway; **looks a
  name up after any failed create** and removes what it finds; waits out
  `is_action_locked` with a bound and reports a timeout as "still working"
  rather than "failed"; filters snapshots by `taken_by` so a user's own are
  never touched; and verifies after a rollback that the LUN's uuid did not
  change.
- `Synology::Target` — targets and mapping. Creates every target with
  `max_sessions = 0`, because at the default of 1 only one node can log in;
  reads a target's IQN from the NAS rather than deriving it from the current
  hostname; and treats `mapping_index` as a hint for finding a device, never as
  an identity, since it is reused.

### Fixed

- **A lookup by id that failed was reported as "not there".** `target_id` must
  reach DSM as a JSON string — a bare number is refused with **18990710** — and
  the lookup's fallback searched by name only, so a lookup by id fell through to
  "not found" and every mapping check silently answered no. Both the encoding
  and the fallback are fixed, and both halves have regression tests. This is the
  confusion between "could not ask" and "the answer is no" that this project
  exists to avoid, found in its own code by driving it at hardware rather than
  by reading it.
- `Synology::LUN` used `JSON::encode_json` without importing JSON, working only
  because `API.pm` happened to have loaded it.

## [0.1.4~beta1] - 2026-08-06

The rest of the stage-4 write tests, including the first attach to a Proxmox VE
node. The node and the NAS were both confirmed back to their exact starting
state afterwards.

### Added

- **The WWID derivation is confirmed on a second, independent sample.** A LUN
  attached to a node produced exactly the predicted WWID from `scsi_id`.
- The device's own identification, which no NAS API exposes: vendor `SYNOLOGY`,
  product `Storage` (space-padded to 16), revision `4.0`, and **`TPGS=1`** — it
  advertises implicit ALUA, which is why multipath enables `hwhandler='1 alua'`
  by itself.

### Changed

- **A device is no longer addressed as `/dev/mapper/<wwid>`.** The test node has
  `user_friendly_names yes`, so multipath named the map `mpathc` and that path
  does not exist. `/dev/disk/by-id/dm-uuid-mpath-<wwid>` always does. Setting
  `user_friendly_names no` globally would rename other vendors' maps, so it is
  not an option.
- **Capacity never comes from summing `allocated_size`.** A clone of a LUN
  holding 512 MiB reports 512 MiB allocated and consumes **zero** bytes of the
  volume — it is a reflink, and the shared blocks are counted for both LUNs. A
  template with twenty linked clones would appear to consume twenty times what
  it does.

### Learned

- **There is no built-in multipath configuration for Synology** — no `SYNOLOGY`
  entry exists in `multipathd show config` — so the `conf.d` drop-in is
  mandatory, not tuning. Without it the generic defaults apply, and on the test
  node those include `no_path_retry "queue"`.
- `multipath -f` may answer "device not found" because `fail_if_no_path` already
  removed the map. That is success.
- Space is reclaimed **lazily**: the volume's free space had not moved minutes
  after deleting a LUN that had 512 MiB written to it.
- A clone of a LUN with data is locked for 3.5 s; a snapshot takes 0.20 s
  regardless of contents.
- Snapshot ownership is filterable: `taken_by` is returned verbatim, and an
  empty value becomes `webapi`, so snapshots this plugin did not take are always
  distinguishable.
- **R-14 could not be narrowed safely.** A new non-administrator account was
  refused at login with 402, before any SAN API could be tried, and each further
  attempt spends one of the three failures that Auto Block turns into a one-day
  block. Two incidental findings kept: `create` with `expired=now` silently
  produces an account that cannot log in, and `set` with `expired=never`
  reported success while changing nothing.

### Fixed

- **The documentation site defaults to English and carries the language in the
  URL** (`?lang=zh`). It was consulting the browser's locale, so a zh-TW browser
  landed on the Chinese version of a page whose canonical form is English. The
  language is applied in `<head>` so there is no flash of the wrong one, and
  `pushState` means the back button returns to the language the reader came
  from.

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
