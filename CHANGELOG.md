# Changelog

Every 0.x release is a prerelease. 1.0.0 is the hardware test pass.

The register of what has been verified against real hardware, and what has not,
is [docs/TESTING.md](docs/TESTING.md) — it is more useful than this file for
deciding whether to trust a given release.

## [0.6.20] - 2026-08-07

### Added

- **`docs/og-image.png`** — the card a shared link shows. The `netapp` and
  `purestorage` projects have one and this project did not, which mattered more
  than a missing decoration: `twitter:card` was already declared as
  `summary_large_image`, and that card **needs** an image. Without one it silently
  degrades to a text-only summary, so every link ever shared showed the plain
  fallback. The accent is **`#0086E5`**, DSM's own `mask-icon` colour read off a
  real NAS rather than picked, and the layout follows the sibling cards so the
  four read as one family.
- **`make og-image`**, and **`check-og-image`** in `release-check`. The badge
  carries the version, so the file goes stale on every release; the check fails
  when it is older than `debian/changelog` rather than trusting anyone to
  remember. Shown to fail on a deliberately stale file.

### Fixed

- **All three social descriptions still said "discovery stage"** — what the
  project was before it had any hardware. It has since been driven end to end on
  two models and three DSM versions across a five-node production cluster. Those
  strings are exactly what someone sees when they share the link, so they were
  the most-read stale text in the project.

## [0.6.19] - 2026-08-07

### Added

- **The pre-release operational checklist is written down at last.** It existed
  only in a conversation: the A–E list, what each row exercises, and the audit of
  both sides afterwards — with the rule that made it worth having, which is that
  it **must be driven from the web interface**. `pvedaemon`, `pveproxy`, `vzdump`
  and `pct` run under `-T` with no `PATH`; `qm`, `pvesm`, `pvesh` and `qmrestore`
  do not. Five defects lived in code that worked perfectly from a shell. *A run
  from a shell is a regression check, not a verification.*
- The **results** of that checklist are on the documentation site, with the audit
  stated separately, because "the operation reported success" is not the same as
  "nothing was left behind" — and that audit is how `flush_map` was found never to
  have removed a map.

### Documentation

- **The Status box was one run-on paragraph, and three facts in it were stale**:
  one model, one DSM version, three nodes, twenty-five defects. It is now four
  labelled sentences — what has been driven, which models and DSM versions, what
  is still honest to say — with current numbers. `60 reads 0 failures` was also
  written in a way that could be read as *60 failures*.
- The nine protocol findings and the WWID derivation moved to the register as
  **What the protocol turned out to be**. None of it is needed to install or run
  the plugin, and it was the first thing on the page after the status box.
- **DS925+ is in the per-model table and the verified section.** Measuring a
  second model and not saying so on the page it belongs on was the omission that
  made the measurement worth less than it should have been.

## [0.6.18] - 2026-08-07

### Documentation

- **Installing and Upgrading had become a wall.** Each finding had been appended
  as another warning box until the page carried six in a row before an operator
  reached anything actionable. They now carry the commands, the one trap that
  **silently downgrades a node** (`wget` without `-O`), and the maintenance-window
  note. Everything else — why every node, the mixed-version symptom, why
  `apt install ./…` and not `dpkg -i`, the `reload-or-try-restart` journal — moved
  to a new **Notes for the curious** section in `docs/TESTING.md`, which is where
  this project keeps what it has measured. A general reader does not need it, and
  the page was drowning.
- **The Rollback section led with archaeology.** It opened by explaining that the
  method was found by asking a DSM about nine candidate names and that none of the
  three conditions was knowable in advance. It now opens with what a rollback
  *does* and the two measured facts that make it safe; the discovery is in the
  register.
- **Two boxes were in the wrong section**: *cloning from a snapshot* sat under
  Installing, and *schedule the first install* sat under Upgrading.
- **The roadmap was stale.** It said `1.0.0` waits on a second model and a second
  DSM version; both are done, so it now says what is actually left. `R-15` is
  marked narrowed, with the 7.1.1 → 7.4.1 measurement and an explicit note that a
  whole-NAS reboot is not a failover and does not answer it.

## [0.6.17] - 2026-08-07

### Fixed

- **`flush_map` passed `multipath` the wrong kind of argument, for the whole life
  of the function.** Measured:

  ```
  multipath -f /dev/mapper/<wwid>   →  "device not found", exit 1
  multipath -f <wwid>               →  exit 0, the map is removed
  ```

  The symlink exists and points at the right dm device; multipath does not accept
  that form. The wrong form was invisible **twice over**: the code treated
  *device not found* as success — correct for the case it was written for, since
  after `fail_if_no_path` multipathd may have removed the map already — so a
  flush that never happened was indistinguishable from one already done. Then
  multipathd covered for it, because a map with no paths is cleaned up on its
  own. The leftover only surfaced when a storage was removed before multipathd
  got round to it. It now passes the name **and looks the map up again** rather
  than trusting the exit status: the third time in one day that a command
  reported success for work it did not do.

### Verified

- **A DSM 7.1.1 → 7.4.1-90080 upgrade preserved every LUN uuid**, so every WWID
  survived. That is this plugin's most basic assumption — the storage's identity
  is pinned to the uuid — and it had never been through a major-version upgrade.
  Proven against the tracking file the plugin itself wrote before the upgrade,
  not against a note.
- **A whole-NAS outage does not hang the node.** Management and data path went
  down together for the first time, for about fourteen minutes:
  **zero processes in uninterruptible sleep**, `pvestatd`/`pvedaemon`/`pveproxy`
  all responsive, the API answering in 0.88 s, and **all seven other storages
  active** — only this one inactive. The kernel failed the paths rather than
  queueing (`fast_io_fail_tmo 5`, then `no_path_retry 18`), which is what rule 4
  exists for. The storage returned to `active` **by itself** once the NAS came
  back, with no intervention.
- **`_warn_once` warns once.** Over the whole outage, with `pvestatd` polling
  every ~10 s, its journal carried **one** message about this storage.
- **A new error code: 498, during a DSM upgrade.** DSM answers HTTP but refuses
  the login. It is **not** in the credential-error set, which is what saved the
  storage: a latched credential failure would have left it dead until an operator
  ran `pvesm set`. That was luck rather than design, and it is now recorded.

## [0.6.16] - 2026-08-07

### Verified

- **A DS925+ on DSM 7.3.2-86009 Update 4, driven end to end** over a VPN:
  `pvesm add` · `pvesm status` · LUN creation · **target creation** · iSCSI login
  · multipath with the device confirmed by the kernel's WWID · a guest booting in
  6.4 s · a snapshot of a running guest in 4.0 s · a **rollback in 3.3 s**, proven
  by the array's own `restored_time` rather than by the absence of an error ·
  snapshot deletion · `free_image` · and the whole storage removed. **The NAS was
  left with 0 LUNs and 0 targets and the node with no session** — nothing behind
  on either side.

  This was also the first real run of the credential path since 0.6.10 changed it:
  the file landed at `0600` in `/etc/pve/priv` and no password reached
  `storage.cfg`, which is what the project's own release checklist requires and
  what two earlier releases shipped without.

  **Not repeated there**: resize, clone, backup, restore, migration, two-portal
  multipath and HA were exercised on the DS918+ only. And that NAS is reached over
  a VPN — fine for testing, and **not** where a production guest's disk belongs,
  because a dropped tunnel is a pulled cable. Both READMEs say so.

- **DSM starts listening on 3260 when a target exists.** A NAS with no target
  refuses the port outright. That is neither a firewall nor a port to open: the
  firewall was checked and permits the subnet for every port, and a closed port
  answers RST on both NAS units. **Creating the target is the act that starts the
  service**, and the plugin does that itself in `_ensure_target` — so `pvesm add`
  needs no iSCSI at all, and the first disk brings the port up. Measured: refused
  before `pvesm alloc`, listening immediately after.

## [0.6.15] - 2026-08-07

### Added

- **A second model and a second DSM version have answered**, read-only: a
  **DS925+ on DSM 7.3.2-86009 Update 4**, reached over a VPN. Every API this
  plugin uses is present at the same version and the same CGI path — including
  **`SYNO.API.Auth` on `entry.cgi`**, not the `auth.cgi` both public reference
  clients hardcode. That is precisely what asking `SYNO.API.Info` instead of
  using a constant was meant to protect against, and it had never been checked
  on a second DSM version. `max_iscsiluns`, `max_iscsitrgs`,
  `max_snapshot_per_lun` and `iscsi_target_type` all read the same as on the
  DS918+; `type=define` carries 346 keys there against 316. The Btrfs, model-
  support and volume checks that gate `pvesm add` all pass.

  **The data path was not exercised there** — that NAS refuses port 3260 — so
  this is the API half of the answer and is recorded as such.

### Fixed

- **Error 117 means "no such volume", and a wrong `syno-location` was reported
  as an unreachable NAS.** Measured on **both** DSM 7.1.1 and 7.3.2: asking for a
  well-formed volume path that does not exist answers 117, while a path that is
  not volume-shaped at all answers *success with no volume*. So the same operator
  mistake arrives two ways, and the 117 way said *the NAS did not answer* while
  the NAS had answered perfectly clearly. `Health` now uses `call` rather than
  `call_ok` where the error code is the answer — as that function's own comment
  had always said — and keys on the code, never on the words.
- **`has_acceptable_disk` is a healthy volume status.** It means the disks are not
  on Synology's validated list, which is what any NAS with third-party drives
  reports. The check compared against `normal` alone, so it warned on every
  healthy volume of that kind — and a guard with a false positive is a guard
  people learn to ignore. It is the only status added, because it is the only one
  that has been seen; `crashed` and `degrade` still warn.

## [0.6.14] - 2026-08-07

### Documentation

- **The migration leftover no longer happens, and saying it does was sending
  operators after a ghost.** Four published passages stated that a VM migrated
  `pve1 → pve2 → pve3` and destroyed on pve3 leaves the earlier nodes each
  holding a map for a LUN that no longer exists. Re-measured across two nodes,
  offline and online, in both directions: **the node a VM leaves holds 0 maps,
  0 by-path devices and an empty tracking file.** `vm_stop_cleanup` calls
  `deactivate_volumes` when the VM stops on the source after the switch, so the
  source node *is* told. The original measurement predates the `_detach_local`
  fix — the version that stopped at the first flush left a map a correct detach
  does not. `pve-syno-reap` keeps its purpose: a hard-reset node still never runs
  `deactivate_volume`. What has *not* been re-measured is the exact original
  scenario, and that is now recorded as an inference rather than a result.
- Both READMEs list **what has been driven from the web interface on a
  production five-node cluster** — disks, snapshots, rollback, migration in both
  directions, clones, templates, all three backup modes and both restore paths —
  with the two results a block-storage plugin is most likely to get wrong stated
  separately: nothing was left behind on either side, and deleting a template
  did not break its linked clone.

## [0.6.13] - 2026-08-07

### Fixed

- **Cloning from a snapshot was refused, by a guard defending an invariant that
  was half wrong.** `volume_has_feature` declares `clone => { snap => 1 }`, and
  `activate_volume` died on any snapname — so `qm clone --snapname <snap>
  --full 0` failed with *a snapshot cannot be activated; roll back to it or clone
  it*, while the operator was cloning it.

  PVE's `clone_vm` activates the source volumes **with the snapname** before
  cloning them — `activate_volumes($storecfg, $vollist, $snapname)` in
  `API2/Qemu.pm` — for a linked clone as much as a full one. The invariant this
  project had written down was *"anything claimed with `snap` must work without
  `path()` or `activate_volume`, because both refuse a snapname"*, and the second
  half of that made the first half unreachable.

  The corrected invariant: a `snap` claim must work without **`path()`**, and
  `activate_volume` must be a successful **no-op** for a snapname. There is
  nothing to activate — a Synology LUN has no device at a snapshot and
  `clone_from_snapshot` is entirely array-side — and `deactivate_volume` had
  always returned 1 for a snapname. Activation was the missing half of that
  symmetry. `path()` still refuses, and must: a caller that genuinely needs a
  device *at* a snapshot has to fail loudly rather than be handed the current
  state's device.

  `t/11-features.t` asserted the wrong invariant and had to be corrected with the
  code, which is the argument for writing an invariant as a test rather than as a
  comment: the test failed the moment the belief did.

### Documentation

- The command documented an hour earlier was wrong: **`--full 0` is required.**
  Omitting `--full` is not the same as disabling it — PVE defaults it to *true*
  for anything that is not a template
  (`$param->{full} // !PVE::QemuConfig->is_template($conf)`), so leaving it out
  asks for exactly the full clone that is correctly refused.

## [0.6.12] - 2026-08-07

### Fixed

- **A rollback failed with "no device appeared" because DSM had asked the node
  to log out.** From the journal, during the failed rollback:

  ```
  iscsid: connection1:0 Target requests logout within 10 seconds
  iscsid: connection1:0 is operational after recovery (1 attempts)
  iscsid: connection1:0 Target requests logout within 10 seconds
  iscsid: connection1:0 is operational after recovery (1 attempts)
  ```

  **DSM tears the session down while it restores a LUN from a snapshot**, twice
  over seven seconds. `activate_volume` rescanned the session **once** and then
  waited twenty seconds for the device — so a rescan issued in the middle of
  that bounce achieved nothing and the wait could never succeed. The LUN was
  mapped, the session came back up, and a single rescan by hand fixed it
  instantly. The rescan is now re-issued every five seconds for up to
  forty-five, with one warning if it takes long enough to notice.

  This is `grow_map`'s lesson at a different layer, and the third time in one
  day: **issuing a command once and then polling for its effect is not the same
  as polling and re-issuing.**

- **`t/07-imports.t` did not scan the plugin**, which is the largest file in the
  project — it was left off because it needs Proxmox VE to load. It missed a
  call to `_warn_once` added to `activate_volume` the same hour: `perl -c`
  compiled it silently, the test passed, and the sub exists only in `Health.pm`
  where it is private. It would have died at runtime, on the activation path,
  during a rollback. The plugin is now scanned wherever Proxmox VE is present,
  and the guard was shown to fail on that exact call.

## [0.6.11] - 2026-08-07

### Fixed

- **Rollback was refused on every cleanly stopped VM**, by the guard 0.6.8 added
  three releases earlier. `flush_device_cache` returned a bare `0` both when the
  flush failed and when **there is no device on this node** — and PVE requires a
  VM to be stopped before a disk rollback, which deactivates the volume, so the
  second case is the ordinary one. No device means no dirty pages, which is the
  safest state there is; it was being reported as a failure and the rollback
  stopped. Both cache helpers are now three-valued — `1` flushed, `0` a device is
  here and the flush failed, `undef` nothing here to flush — and all three call
  sites read `defined` first.

  This is rule 12's shape appearing inside the fix written for the previous
  instance of rule 12, which is the second time that has happened in this
  project. `t/05-multipath.t` now asserts the contract and greps the plugin's
  source for a bare negation of either helper.

## [0.6.10] - 2026-08-07

### Fixed

- **The other half of taint mode: file operations.** 0.6.9 untainted what reaches
  a *command*; `open` for writing, `unlink`, `mkdir` and `rename` are restricted
  just as hard, and a storage id reaches a filename in **four** places — the
  credential store, the WWID state file, the credential latch and its clearer.
  All four sanitised the id with `s///`, which **does not untaint**: only a
  capture does. Probed under `-T` with a tainted storeid, three of the four died
  with *Insecure dependency in unlink*, and they are exactly the paths
  `pvesm add` and `pvesm set` take from the web interface. There is now one
  `Naming::filename_component`, and it validates and untaints in the same
  operation — which is how `slaves_of_map` has always done it.

  This was found by asking "where else?" straight after 0.6.9 rather than
  waiting for a report. The same procedure written four times is the recurring
  shape: `_fuser`/`scsi_id` against five bare command names, `slaves_of_map`
  against every other tainted argument, and now this.

- **`$ENV{PATH}` must contain nothing taint mode would reject, and 0.6.10's own
  "belt and braces" line was the next failure.** Perl refuses to `exec` when
  **any** directory in `$ENV{PATH}` is writable by group or other —
  *Insecure directory in `$ENV{PATH}` while running with -T switch* — and the
  PATH set for the child was the whole search list, `/usr/local/bin` included.
  On a machine where that directory is group-writable, every command the plugin
  runs from `pvedaemon` or `vzdump` dies. It is now filtered to the directories
  taint mode accepts, checked per call because a directory's mode is exactly the
  node-local fact this project has been caught assuming.

### Documentation

- The capacity-units comparison is now **shown**: Proxmox VE reporting
  `28.12% (4.32 TB of 15.36 TB)` above DSM's `3.9 TB / 14 TB, 28%`, which is
  the same volume and the same bytes.

## [0.6.9] - 2026-08-07 — tagged, never published

Its CI run failed and no release was ever created, so nothing was downloadable
under this version and the tag has been withdrawn. Everything below shipped in
**0.6.10**; the section is kept because the changes are real and the reason the
release did not happen is worth recording — `t/13-taint.t` carried `-T` in its
shebang, which depends on the harness noticing it and passing the switch on.

### Fixed

- **Taint mode.** `pvedaemon` is `#!/usr/bin/perl -T`, so every value the plugin
  reads from a file is tainted and Perl refuses to `exec` with it:
  *Insecure dependency in exec while running with -T switch*. The multipath map
  name is read from `/sys/block/dm-N/dm/name` and goes straight into
  `multipathd resize map <name>`, so **every resize started from the web
  interface failed** — the second barrier behind the missing `PATH` fixed in
  0.6.7, and invisible until that one was out of the way.
  `slaves_of_map` already took its device names from what a regex *matched*
  rather than what it read, and its comment calls that "the taint discipline and
  the correctness check in one" — applied there and nowhere else. Arguments are
  now validated against an allowlist and untainted at the command runner, and a
  value the plugin could not have produced is **refused** rather than stripped.
- Taint mode also requires a clean environment before `exec`, so `IFS`,
  `CDPATH`, `ENV` and `BASH_ENV` are removed for the child alongside the
  absolute `PATH` 0.6.7 added.

### Added

- **`t/13-taint.t` runs under `-T`**, so `make test` finally reaches the
  environment a daemon actually runs in. Nothing in this project reproduced it
  before: `qm`, `pvesm` and `pvesh` are all plain `#!/usr/bin/perl`, which is
  why two rounds of hardware verification passed while the web interface went
  on failing. The shebang is the fixture — a case in any other file does not
  cover it. Shown to fail on a deliberate regression.

## [0.6.8] - 2026-08-07

### Fixed

- **The host cache flush around a snapshot and a rollback now reports when it
  did not happen.** Both were called for their side effect with the return
  value dropped — and that return value is the only thing that says whether
  `blockdev` ran at all, which from a PVE daemon it did not. So **every
  snapshot taken from the web interface skipped its flush silently**, and a
  rollback skipped the invalidation that this project measured as necessary:
  reads returned pre-rollback bytes until the cache was dropped. A rollback now
  **refuses** if the flush cannot be done, a snapshot **warns** (it is still
  crash-consistent, only staler than intended), and the post-rollback
  invalidation warns because the array-side work is already complete by then.

## [0.6.7] - 2026-08-07

### Fixed

- **Every external command is now resolved to an absolute path, and the reason
  is that a Proxmox VE daemon has no `PATH` at all.** Measured on this node:
  `/proc/<pid>/environ` for **pvestatd, pvedaemon, pveproxy and pve-ha-lrm**
  contains no `PATH` variable, and nothing in the PVE tree sets one at runtime.
  `exec` then falls back to the C library's default of `/bin:/usr/bin` — and
  `multipathd`, `multipath`, `iscsiadm`, `dmsetup` and `blockdev` all live in
  `/usr/sbin`. So the *same operation* succeeded or failed according to who
  started it: a resize from `qm resize` on a shell worked, and the identical
  resize from the web interface could not execute `multipathd` at all. The
  plugin ran five commands by bare name. PVE's own plugins have always written
  absolute paths for exactly this reason — `ISCSIPlugin` has
  `/usr/bin/iscsiadm`, `LVMPlugin` has `/sbin/vgs` — and the two places this
  plugin already resolved a path by hand, `_fuser` and `scsi_id`, were the
  shape of the answer applied to two commands out of seven.
- **A command that never ran no longer looks like one that ran and declined.**
  `resize_map` returned a bare 0 for both, so a `multipathd` that could not be
  executed was indistinguishable from one that had looked and found nothing to
  do. That is how the fault above survived a 60-second retry loop: three
  hundred failures, no output, and a final error blaming the map for not
  following the paths. `grow_map` now stops at the first such failure and says
  which of the two happened.

### Added

- `make check-tool-paths` fails the build on any process spawned outside the
  command runner, so a command added later cannot be the one that forgets. It
  found three more on its first run, and has been shown to fail on a
  deliberate regression.
- The discovery tool no longer shells out to `stty` to turn off echo.
  `POSIX::Termios` is core Perl, makes the same `termios(3)` call, and has
  nothing to find and nothing to exec.

## [0.6.6] - 2026-08-07

### Fixed

- **A disk resize reached the NAS but not the node.** `qm resize` grew the LUN
  correctly and then failed with `qmp command 'block_resize' failed - Cannot grow
  device files`, leaving the NAS at the new size while the VM configuration still
  claimed the old one. The cause: `multipathd resize map` takes the new size from
  multipathd's own **udev view** of a path, and that view has not been refreshed
  microseconds after the sysfs rescan that changed it. multipathd compared the
  stale size against the map's, found them equal, logged *map is still the same
  size* and exited **0**. So the map never grew, nothing reported a problem, and
  PVE's very next step — `block_resize`, which has no tolerance at all for a
  device that has not caught up — was the thing that failed. Measured on hardware:
  the NAS grew the LUN to 33 GiB, `sdb` picked it up (`detected capacity change
  from 67108864 to 69206016`), and `dm-0` stayed at 67108864. The map is now polled
  until it carries the new size, with the resize re-issued as it waits, and a
  resize that never reaches the node **fails with an explanation** instead of
  leaving QEMU to produce an unrelated one.
- **A map smaller than its LUN is reconciled at activation.** `volume_resize` runs
  only on the node that owns the guest, so every other node went on presenting the
  old size; a live migration onto one of them would have handed the guest a device
  smaller than its own configuration says. `activate_volume` now compares the two —
  the LUN's size is already in hand there, so it costs no extra call to the NAS —
  and warns rather than refusing, because an activation that fails stops a VM from
  starting.

### Documentation

- **Why Proxmox VE and DSM report different sizes.** They do not: the plugin
  passes the volume's `size_total_byte` and `size_free_byte` through in bytes and
  does no arithmetic, and then PVE divides by 1000 while DSM divides by 1024 —
  both writing "TB". 15.36 TB and 14 TB are the same 15,356,124,401,664 bytes.
- The snapshot description added in 0.6.5 is now **shown** in both READMEs and on
  the documentation site. It is a change that is much easier to see than to read.
- Corrected the documentation-site claim that SAN Manager lists snapshot *names*
  under LUN → Snapshot. It lists the snapshots; there is no name column anywhere.

## [0.6.5] - 2026-08-07

### Fixed

- **The Proxmox VE snapshot name now appears in SAN Manager.** Its snapshot list
  shows time, consistency state, description, status and lock — and **no name
  column at all**. The `name` field is in the API and the plugin matches on it, but
  an operator looking at DSM could not see it: the description was
  `Proxmox VE <storage>`, so every snapshot of every disk on a storage looked
  identical, and *which PVE snapshot is this row?* had no answer without going back
  to PVE and comparing timestamps. It is now
  `<snapshot name> (Proxmox VE <storage>)`.

### Verified on hardware

- **Snapshot names: the NAS refuses nothing.** 256 characters, spaces, `_` `+` `@`
  `/` `%` `:`, a leading hyphen and Chinese characters were all accepted — a
  different rule from LUN names, which refuse `_`, space, `+` and `@` with 18990503.
  No sanitising is needed, and **PVE is the stricter end**: `pve-snapshot-name` is
  `pve-configid` capped at 40 characters, so a name reaching the plugin can only be
  a letter followed by letters, digits, underscores and hyphens. There is no
  combination PVE can produce that the NAS will refuse.
- The install command now uses
  `/releases/latest/download/jt-pve-storage-synology_all.deb`, which does not go
  stale. `check-doc-urls` verifies it resolves, because the two things it depends on
  — releases not being flagged as prereleases, and the workflow publishing a
  version-free copy — live in the release workflow and could silently stop being
  true.

## [0.6.4] - 2026-08-07

**The `beta1` suffix is gone from this release onwards.** Versions are now plain
`0.6.4`, the tag is `v0.6.4`, and the package is
`jt-pve-storage-synology_0.6.4-1_all.deb`. Earlier releases keep their `~beta1`
names — renaming history would break the upgrade instructions that refer to them.

Two consequences worth knowing:

- **GitHub's `latest` now works.** The release workflow marked a release as a
  prerelease when the tag contained `beta`, and GitHub's `latest` skips
  prereleases — which is why `/releases/latest/download/…` answered 404 and the
  documented install command had to carry a version. From 0.6.4 the release is a
  normal one.
- **The `.deb` is published a second time under a version-free name**,
  `jt-pve-storage-synology_all.deb`, so
  `/releases/latest/download/jt-pve-storage-synology_all.deb` stays correct across
  releases. The versioned asset stays too: `releases/` archives it under that name,
  and a tester must be able to fetch exactly what they run.

This is still a 0.x release. What 1.0.0 waits on has not changed — a second model,
a second DSM version, and the minimum DSM privileges settled — and
`docs/TESTING.md` remains the register.

### Added

- `--nodes` is documented: how to restrict the storage to some nodes, why to do it
  while staging a rollout, and the thing that is easy to get backwards — `shared`
  is forced on and cannot be turned off, so `nodes` restricts *which nodes may use
  it* and never makes the storage node-local.

### Fixed in the documentation, all found by installing on a clean node

- The install command used `/releases/latest/download/…`, which **404s**, and then
  `dpkg -i`, which **does not resolve dependencies** — on a node without
  `multipath-tools` it unpacks and leaves the package unconfigured. Now
  `apt install ./…`, with the recovery step for anyone who already hit it.
- The prerequisites were never stated. Checked rather than guessed:
  `open-iscsi` and `multipath-tools` have **zero** PVE reverse-dependencies, so a
  node can genuinely lack them; the four Perl modules are dependencies of 86 to 151
  PVE packages each and are always present.
- **A storage can be invisible in the web interface.** The interface is served by
  whichever node the browser is connected to, and a node without the plugin does not
  know the type and silently omits the storage from the list — which reads exactly
  like `pvesm add` having failed.
- The install warning said `multipathd reconfigure` "re-reads configuration for
  every map on the node", which is true and reads like a threat. **Measured
  instead**: on multipath-tools 0.11.1, with continuous reads against an unrelated
  map, 1776 reads and 0 failures, and the map's device-mapper event counter did not
  move — it was never reloaded.

## [0.6.3~beta1] - 2026-08-07

**R-14 probed on hardware, and this page's previous answer to it was wrong.**
Documentation only — no code change.

### Corrected

- **A non-administrator DSM account does not get as far as being denied the storage
  calls. It is refused at login.** `docs/DSM-ACCOUNT.md` predicted that a plain
  account would authenticate and then answer `105` on every LUN listing. A temporary
  account created on the test NAS with the owner's permission, probed, and deleted,
  showed otherwise:

  | Step | Result |
  |---|---|
  | Groups on DSM 7.1.1 | exactly three — `administrators`, `http`, `users`; **none iSCSI-specific** |
  | No groups at all | login refused, **error 402** |
  | Member of `users` (confirmed from the group side) | login refused, **402** |
  | `SYNO.Core.User get` | returns `name` and `uid` only; no privilege fields |
  | `Group.Member add` to `administrators` | **reported `success: true` and changed nothing** |

  So the minimum cannot be isolated through the API, and the probing stopped rather
  than guessing at an undocumented model on a production NAS. The honest statement is
  now: **the account in use is an administrator and no smaller working configuration
  has been demonstrated.** The remaining step is a DSM-interface check, written down
  in `DSM-ACCOUNT.md` with the exact command to run.

- **A third API that reports success without acting**, joining the LUN create that
  refuses a 255-character name and makes the LUN anyway, and `multipath -w` which
  prints `wwid ... removed` and does nothing. Rule 35 says `success` is the only
  success; these three say that even `success` is not enough where the effect can be
  read back independently — and the user-side `additional=["groups"]` returns an
  empty list for an account that *is* in a group, so which side you ask matters too.

## [0.6.2~beta1] - 2026-08-07

**Node failure, fencing and takeover.** Run on a node the owner allowed to be
disrupted, with quorum kept throughout.

### Fixed

- **A crash leaves a tracking entry that nothing would ever remove.** A
  hard-reset node never runs `deactivate_volume`, so `WwidState` keeps an entry for
  a LUN that is no longer attached — while the LUN still exists on the NAS, so
  `orphans` correctly does not report it. `reap_orphans` now handles it as a
  distinct case and says so in its report.

  The check is `map_is_gone`, **not** `device_path_for_wwid`: the latter collapses
  "no device" and "the stat never came back" into undef by design, and untracking
  on that would be exactly the bug fixed in 0.6.1~beta1. Only a confirmed *gone*
  untracks anything.

  Not dangerous before the fix — every consumer re-checks for a device — but it is
  a record asserting the node holds something it does not, and it is left to
  `pve-syno-reap` rather than done on the `activate_storage` path, which may not
  mutate anything. **After a node crash, run the reaper.**

### Verified on hardware

| Test | Result |
|---|---|
| Clean reboot, VM running, LUN attached | no stale map, session or tracking; VM restarted, data intact |
| Hard reset (`sysrq-trigger b`), no cleanup | no stale map or session; the tracking entry above |
| HA fencing with the VM under `ha-manager` | node rejoined inside the fence window, HA restarted the service, storage re-attached unaided, data intact after a crash-boot |
| **Takeover while the crashed node was still down** | the surviving node started the VM in **3.6 s** with the dead node's session still registered on the NAS; guest booted, data intact |
| The crashed node's return | storage `active`, no map, no session, and it did not contest the disk |

The takeover is the one that mattered: a shared target with `max_sessions=0` was
carrying **two connected sessions** at the moment of the crash, and the surviving
node attached the LUN without waiting for anything to time out. That is what a
production cluster depends on and it had never been demonstrated.

## [0.6.1~beta1] - 2026-08-07

**An allocation held Proxmox VE's cluster-wide storage lock for 3.6 seconds. Now
2.16.** Under fifteen concurrent allocations from three nodes, one used to fail on
the lock wait.

### Fixed

- **Three full `LUN list` calls and two DSM sessions per allocation, all inside
  `cluster_lock_storage`.** That lock serialises every allocation on a storage
  across the whole cluster, so the time one takes is the time every other node
  waits. The listing was fetched by `find_free_diskname` (which goes through
  `list_images` and therefore opens its own session — a second login, a second API
  discovery, a second logout), again by the LUN-ceiling check for a count, and
  again by the near-limit warning. `alloc_image` now fetches it once and passes it
  to all three; `find_free_diskname` takes an optional listing and behaves exactly
  as the base class does without one.

  | Per allocation | Before | After |
  |---|---|---|
  | Wall clock | 3.6 s | **2.16 s** |
  | DSM sessions | 2 | **1** |
  | HTTP requests | 17 | **12** |
  | `LUN list` calls | 3 | **1** |

- **`wait_unlocked` polled with `sleep 1`** while the register records
  `is_action_locked` clearing in **0.20 s** after a snapshot and 1.2 s after a
  1 GiB create. A fifth of a second cost a whole one, on every create and every
  snapshot, inside the cluster lock. It polls at 0.2 s now.

- **A three-valued answer was negated in 0.6.0~beta1's own fix.**
  `_detach_local`'s residual-path removal was written `if (!map_is_gone($wwid))`,
  and `map_is_gone` returns 1 / 0 / **undef** — so "could not tell" read as "still
  there" and the `sd` devices were deleted on a state nothing had established. It
  was not theoretical: `qm stop` then `qm rollback` failed with *"no device …
  appeared on this node after logging in"*. The branch now requires
  `defined $gone && !$gone`.

### Verified on hardware

| Test | Result |
|---|---|
| 15 concurrent allocations, three nodes | 37 s, 15/15, no duplicate names |
| `qm move_disk` off the storage and back | both directions; guest booted from the moved-back disk |
| Snapshot of a **running** guest, then rollback | guest boots and sees the pre-snapshot content |
| DSM management port blocked while a guest wrote continuously | `inactive` in 6.3 s, warned **once**, **0 I/O errors in the guest**, recovered on the first poll |
| `syno-min-free` above the NAS's free space | allocation refused, with the figures |
| 1 MiB requested | 1 GiB created — the minimum the API does not enforce |

Ended with the NAS on its original four LUNs and three targets, and every node
with no map, session, node record, credential or drop-in. Another storage's
credential file in `/etc/pve/priv/storage/` was untouched throughout.

## [0.6.0~beta1] - 2026-08-06

**Backup, restore, a guest booting from the NAS, live migration across three
nodes.** The last three gaps that mattered are closed, and closing them found two
more defects.

### Added

- **`pve-syno-reap`** — reports, and with `--remove` clears, multipath maps this
  node holds for LUNs the NAS no longer has. Default is a dry run. It never
  touches a device that is in use, and skips rather than assumes anything whose
  state it cannot establish.

### Fixed

- **`WwidState::orphans` had no caller.** It was written for the case below,
  documented at length, and invoked from nowhere — dead code standing in for a
  fix. `reap_orphans` is the caller.
- **`_detach_local` could not flush a map whose LUN was deleted from another
  node.** This node's iSCSI session is still up, so each `sd` node survives as a
  dead device and multipathd rebuilds a map over it. `free_image` captured the
  slaves, flushed, removed the residual paths and flushed again; `_detach_local`
  stopped at the first flush — the same procedure written twice with only one copy
  correct. It now removes residual paths when, and only when, a flush has failed,
  so an ordinary VM stop is unchanged.

### Corrected

- **Nothing in Proxmox VE calls `deactivate_storage`.** Verified across the whole
  `/usr/share/perl5/PVE` tree: only the dispatcher and the per-plugin
  implementations exist. So this project's instruction that
  `pvesm set --disable 1` makes "each node deactivate on its next poll" was false,
  and a code comment written the same afternoon claiming PVE calls it "when it is
  finished with the storage on this node" was false too. The sibling NetApp plugin
  had already found and corrected the identical claim. The documented removal
  procedure now runs `pve-syno-reap` on each node first.

### Verified on hardware

A cirros guest booting from a Synology LUN, on a three-node cluster, all under TCG
(no KVM anywhere):

| | |
|---|---|
| Guest boot from the LUN | mounted `sda1` and resized the filesystem to fill it |
| `vzdump` snapshot / stop / suspend | 13 s / 19 s / 15 s, all succeeded |
| `qmrestore` to a new VMID, boot, verify | payload `md5` **identical** |
| Live migration pve1 → pve2 → pve3 | **5 ms** then **87 ms** downtime, `/proc/uptime` continuous |
| Guest reboot | payload intact |
| Three nodes, one shared storage | all active, all authenticated from the replicated credential |
| `/etc/pve/priv/storage/` replication | confirmed on all three nodes at mode `0600` |

Ended with the NAS on its original four LUNs and three targets, nothing `pve-`
left, and every node with no map, session, node record, credential or drop-in.

## [0.5.5~beta1] - 2026-08-06

**0.5.3~beta1 and 0.5.4~beta1 could not be used. `pvesm add` failed outright.**
Upgrade past them.

### Fixed

- **`pvesm add` failed with "missing value for required option 'syno-password'"
  for a password that was supplied.** `extract_sensitive_params` removes every
  sensitive property from the parameters *before* `check_config` validates them —
  PVE does them in that order — so the required-option check was looking for
  something already taken out. A sensitive property must be declared
  `optional => 1`, with the plugin enforcing its presence itself; PVE's own CIFS
  plugin does exactly this. No unit test could have caught it: the fault is in the
  interaction between two PVE stages, and it was found in the first minute of
  running the thing.
- **CHAP was applied only when the target was created.** Adding CHAP to a storage
  whose target already existed gave no error and no access control — the target
  kept `auth_type=0` on the NAS while the configuration said otherwise. Measured on
  hardware. `Target::ensure` now reconciles CHAP against what the array reports,
  and the update hook pushes the secret to **every** target the storage owns,
  because in `per-volume` mode there is one per disk. The array never returns a
  password, so a changed secret can only be pushed, never compared.
- **A CHAP username with no secret was accepted with a warning.** Refused now,
  before anything is written, and `pvesm set` leaves the configuration untouched.
- **`pvesm set --delete syno-chap-username,syno-chap-password` refused itself.**
  PVE applies deletions *after* the hook returns, so `$scfg` still held the
  username while the credential store had already dropped the secret. The hook now
  computes the effective configuration — current, minus deletions, plus new values.
- **An unrelated `pvesm set --disable 1` reported "CHAP REMOVED from 1 target(s)"**
  for a storage that had no CHAP and lost none. The reconcile now skips a target
  the array already reports as having none.

### Verified on hardware

Every change in 0.5.2–0.5.5 driven against the DS918+: the password absent from
`storage.cfg` and present in `/etc/pve/priv/storage/pvesyno.syno` (0600, `www-data`
denied), the API returning no credential key, allocate, activate, a block-level
rollback (`sha256` before = after, with an 8 MiB random pattern zeroed in between),
a clone from a snapshot, `copy` correctly refused for a snapshot while `clone` is
allowed, the shrink refusal, the pre-existence refusal, twelve consecutive failed
operations with no session exhaustion, then free, disable and remove — **ending with
the NAS on its original four LUNs and three targets and nothing `pve-` left, and
the node with no map, session, node record or drop-in.**

### Documented, not fixed

`multipath -w <wwid>` prints `wwid '<...>' removed` and **changes nothing** while
multipathd is running; `multipathd del wwid` answers `fail`. So the WWIDs this
plugin appends to `/etc/multipath/wwids` are not removed on detach, and nothing
claims they are. `-W` would work and is never used: the test node's file holds 334
entries, 319 of them another storage's. The residue is one line per LUN ever
attached and cannot mislead, because a WWID is derived from the LUN's uuid and so
can only ever match the LUN it came from.

## [0.5.4~beta1] - 2026-08-06

**A third audit pass, and two of its three findings are about the second one.**
That is the argument for running it again after changing things rather than
before.

### Fixed

- **Moving the credentials in 0.5.3~beta1 broke CHAP, silently.** Making
  `syno-chap-password` sensitive means PVE strips it from the config, so
  `$scfg->{'syno-chap-password'}` is undef — and both CHAP call sites still read
  it from there, while both consumers ended in `$opt{chap_password} // ''`. The
  result was not a failure but an **empty CHAP secret** on the target and in the
  node's iSCSI record: access control that reports itself as configured and admits
  anyone. There is one accessor now, and neither `Target::ensure` nor
  `ISCSI::node_add` accepts a missing secret — there is no safe default for a
  shared secret, so both refuse with the reason.

  **Nobody shipped a storage with this**, because it was found by auditing the
  change rather than by running it. If you configured CHAP on 0.5.3~beta1,
  re-set `--syno-chap-password` and check the target's secret in SAN Manager.

- **`copy` is no longer claimed for a snapshot.** `qm clone --full --snapshot
  <name>` asks PVE for the `copy` feature with a snapshot name; a yes sent it to
  `qemu-img convert` on `path(..., $snapname)`, which dies — a Synology LUN has no
  device at a snapshot until it is cloned or rolled back. So PVE began an
  operation and failed partway, reporting a problem with addressing rather than
  with what was asked. It now refuses up front, and the action it suggests — a
  linked clone from the snapshot — is supported. `clone => { snap => 1 }` is
  unchanged and correct.

### Changed

- **A snapshot timestamp is validated instead of asserted.** The comment said
  `create_time` had been "confirmed against the NAS's own clock"; no such
  measurement exists in the register, and it **cannot** be made read-only because a
  LUN carries no `create_time` field at all. It is now R-25, openly. A value
  outside 2001–2065 yields no timestamp rather than one dated 1970, and a
  millisecond value is converted. Nothing in Proxmox VE 9 reads the value —
  `Replication` and `QemuServer` use the snapshot names and a `parent` field — so
  this changes no behaviour today.

### Added

- `t/11-features.t` — 283 tests in total. It parses the feature table and asserts
  that only `clone` and `snapshot` are claimed for a snapshot, so adding a `snap`
  key forces someone back to the two refusals that make such a claim safe.

## [0.5.3~beta1] - 2026-08-06

**A security fix that needs one action from anyone already running this.** The
DSM password was being written into `/etc/pve/storage.cfg`.

### Security

- **The DSM credentials are no longer stored in `storage.cfg`.** They live in
  `/etc/pve/priv/storage/<storage>.syno`, mode `0600`, in a directory the cluster
  filesystem serves to root only — the same place Proxmox VE's own CIFS, PBS and
  ESXi plugins keep theirs.

  `storage.cfg` is `root:www-data 0640`, and worse: a property Proxmox VE does
  not know is a secret is returned by `GET /storage/<id>` to **any user holding
  `Datastore.Audit`**. A read-only auditor could read a DSM credential with SAN
  Manager rights. The device token — a standing 2FA bypass — was stored the same
  way.

  PVE has a first-class mechanism for this, `sensitive-properties`, and this
  plugin was not declaring it. `sensitive_properties` falls back to a hardcoded
  list when a plugin declares none (`encryption-key keyring master-pubkey
  password`), and `syno-password` is not in it — so the omission failed silently
  and in the least safe direction, which is the only reason it survived fifteen
  releases.

  **If you are upgrading, do this once per storage:**

  ```bash
  pvesm set <storage> --syno-password '<the password>'
  ```

  That moves it to the private file and removes it from `storage.cfg`. The old
  location is still read, so nothing breaks before you get to it, and the plugin
  warns once. Because the value was readable by anything running as `www-data`,
  **treat it as disclosed and change the DSM account's password**, and revoke the
  2FA device token if you used one. Full procedure in `docs/DSM-ACCOUNT.md`.

### Fixed

- **Nine methods leaked a DSM session on their error paths.** Twenty build an API
  object; nine have a `die` between the construction and the `logout`. R-13
  established that a second login does not evict the first, so they accumulated
  on the NAS — a repeatedly failing operation leaked one per attempt. The object
  now logs out in `DESTROY`, which Perl runs on the die path too. Fixing it at
  the nine call sites would have been nine chances to forget and no cover for the
  tenth method.
- **A shrink was silently declined instead of refused.** `resize` short-circuited
  on `size >= requested` and returned the LUN unchanged — a success for something
  that had not happened. Proxmox VE writes the *requested* size into the VM
  configuration regardless of what a plugin returns, so the configuration would
  have claimed a size the NAS does not have, and the next grow-by-N would be
  computed from it. Refused now, with the reason.
- **The delete-on-refusal path proved the object was new only by absence.** DSM
  refusing a create and performing it anyway is measured behaviour, and the
  cleanup deletes what a lookup finds; the only thing separating that from
  deleting a pre-existing LUN was the error code not being 18990538. `create` now
  looks the name up first and refuses outright if it is taken, so the cleanup acts
  only on an object it made. R-9 established that `LUN list` reports no total, so
  a silently truncated listing was a real route to the wrong branch.
- **`on_delete_hook` left the credential file behind**, including on the path
  where the NAS could not be reached and it returned early. A scope guard now
  removes the credentials and the latch on every exit.

### Added

- `t/10-credentials.t` and `t/09-session.t` — 249 tests in total. The credential
  tests drive PVE's own `sensitive_properties` and `extract_sensitive_params`, so
  what is asserted is that PVE strips the values, not merely that the plugin asked
  it to.

## [0.5.2~beta1] - 2026-08-06

**An audit found three things that reading the code had not.** All three are the
same species: code that was correct by argument rather than by check.

### Fixed

- **`Command`'s functions could be called as methods, and the answer would have
  been a silent wrong one.** `Naming` and `Multipath` were guarded against this
  after being called as `Module->function(...)`, where the arguments shift by one
  and nothing errors. `Command` is the third module of that shape and had no
  guard — `Command->is_block_device($dev)` binds the class name to the path and
  reports **"not a block device"** for a device that exists. That is worse than
  the earlier two: it answers a safety question wrongly, in the direction of
  acting. `is_block_device`, both sysfs helpers and the command runner now refuse
  a method call outright.
- **An unbounded `waitpid` on a success path.** `sysfs_read_with_timeout` cleared
  its alarm and then blocked in `waitpid($pid, 0)`. Safe by argument — reaching
  it needs EOF, so the child had already flushed — but a child merely stopped
  rather than dead would hold it forever, and this module exists precisely to not
  reason that way. Bounded now, and it does not signal: the child did its job.
- **The ownership gate was in `free_image` only.** `volume_snapshot_rollback`
  overwrites a disk and was relying on the `taken_by` whitelist. Sound, but it is
  inference where the rule asks for a check. Both snapshot paths now call
  `is_pve_managed_volume($name, $storeid)` directly.

### Changed

- **`make critic` passes, and is now part of `release-check`.** It had never
  passed: 120 findings, mostly policies this code violates on purpose —
  `return undef` is what the three-valued safety contract requires, and the
  `_not_a_method` guard must read `@_` before unpacking it. `.perlcriticrc`
  disables exactly those, with the reason written beside each, and the result was
  then shown to still fail on a deliberate regression. A guard in the command
  list that cannot pass is a guard nobody runs.
- **The base-class sweep re-run against current PVE**: 21 methods reach
  `filesystem_path` or `$scfg->{path}`, 20 overridden. The twenty-first,
  `list_volumes`, is safe by construction — only `images` and `rootdir` are
  declared and both route to the overridden `list_images` — and that is now
  recorded so the next sweep does not chase it.
- **R-10 narrowed.** The only enabled snapshot schedules on the test NAS are
  *share* snapshots, which cannot appear in a LUN's snapshot list, and
  `SYNO.Core.ISCSI.LUN.Snapshot.Schedule` does not exist. The filter is a
  whitelist on `taken_by`, so an unknown origin is excluded by default.

### Added

- `t/08-command.t` — 203 tests in total. It demonstrates the bounded reap
  surviving a stopped child, and the method-call guard refusing.

## [0.5.1~beta1] - 2026-08-06

**Real multipath, and a defect that a real block exposed.** Both of the NAS's
addresses configured as data portals — the first genuinely multipathed test, with
failover injected under load.

### Fixed

- **A rejected credential was retried on every poll, not once.** The latch that
  stops repeated failed logins was an instance field, and the plugin builds a new
  API object per call — so it died with the object. Three polls meant three failed
  logins, which is DSM's Auto Block threshold. It is now a file under `/run`,
  cleared by `on_update_hook` because a configuration change is the operator
  having had a chance to fix things. Verified across five polls: one login
  attempt reached the NAS, four were refused locally.

  Finding this cost a real block on the test cluster's node, which is the
  clearest evidence for the guard that there could be: the blocked node got
  **407 (IP blocked)** while another node logged in normally and the iSCSI data
  path went on working throughout — the reason an operator can miss it entirely.
  Clearing it is Control Panel → Security → Account → Auto Block →
  Allow/Block List.

### Verified

- **Two paths, and failover with zero I/O loss.** Blocking one portal at the
  node: the path went `failed faulty offline` within ~15 s, the survivor stayed
  `active ready running`, **0 of 60 reads failed**, and the path was reinstated
  automatically about 10 s after unblocking.
- **A management outage does not take the data with it.** Blocking DSM's port
  5001 while leaving 3260 alone: the storage reported `inactive`, other storages
  on the node were unaffected, `pvesm status` grew by about one
  `syno-status-timeout`, the warning appeared once rather than per poll, the disk
  stayed readable, and it recovered by itself.

## [0.5.0~beta1] - 2026-08-07

**Two nodes, and live migration with 3 ms downtime.** Verified on a two-node
cluster running different kernels, with the same LUN attached to both.

### Added

- **The plugin no longer hopes a multipath map exists.** `find_multipaths` is a
  per-node policy: one test node had `no` and built a map for every device, the
  other had `yes` and builds one only for a device with two or more paths — so a
  single-portal LUN got **no map at all**, and the path this plugin hands out
  pointed at nothing while the session was up. `ensure_map` now appends the one
  WWID with `multipath -a`, asks for the map, and **fails the activation** rather
  than letting a VM start against a path that is not there.
- `debian/control` now describes what the package actually contains, and depends
  on `proxmox-ve`, `open-iscsi` and `multipath-tools` rather than merely
  recommending them.

### Verified on a two-node cluster

- **Two DSM sessions on one account, from two addresses, at once** — the last of
  the register's cluster questions, answered in a real cluster: they coexist and
  nothing is evicted.
- Two iSCSI sessions on one target with `max_sessions = 0`, both listed by the
  NAS; both nodes reading the same bytes; `shared` forced to 1.
- Offline migration in 2 s with no disk copy. **Live migration with 3 ms
  downtime**, the source node releasing the device as the destination took it.
- Data intact across two migrations, and a snapshot taken while the VM was live
  then rolled back with the data correct.

### Documented

- **Removing a shared storage leaves the other nodes' sessions behind.**
  `on_delete_hook` runs on one node and the others are never told, because the
  storage is gone from the configuration before PVE would deactivate it there.
  That is PVE's shape rather than something the plugin can fix, so the procedure
  is documented — disable, wait, then remove — along with the per-node cleanup
  commands.

## [0.4.1~beta1] - 2026-08-07

A real VM was booted from a Synology LUN, and a rollback was verified **at the
block level**: a written pattern, snapshotted, overwritten with zeros, rolled
back, and the original sha256 came back. Twice — the second time with no manual
cache handling at all.

### Added

- **Host cache symmetry.** A snapshot flushes the device first, so it records what
  the guest believes it wrote. A rollback flushes first *and* invalidates
  afterwards — the second was demonstrated directly: reading the device straight
  after a successful rollback returned the **old** bytes until the cache was
  dropped.
- **An in-use check**, ported with its three-valued contract intact: 1, 0, or
  **undef**, and `free_image` and `volume_snapshot_rollback` refuse on undef.
  Verified against a real booted VM — both refused while QEMU held the disk, with
  a message naming `fuser -vm`.
- `volume_size_info`, `volume_export` and `volume_import`, answered from the NAS.
  Export and import have been round-tripped byte-identical through `pvesm`.
- `rename_snapshot`, `get_subdir` and `prune_backups` refuse with something an
  operator can act on, rather than reaching a base implementation that would
  produce a message about a path.
- `t/07-imports.t` — `perl -c` compiles a call to an undefined subroutine without
  a word, and one such call reached a running VM.

### Fixed

- **`qm destroy` silently leaked its LUN, every time.** `path()` must return
  `($path, $vmid, $vtype)` — the owner as the second element. Returning the leaf
  name made PVE's own check read `"vm-9999-disk-0" != 9999`, so it returned early
  and **never called `vdisk_free`**. Nothing failed; a numeric warning was the
  only trace.
- **`qm create` with an existing volume died before it started.** The base
  `volume_size_info` runs `qemu-img info` on `filesystem_path`, which a block
  storage has none of — and the error named `filesystem_path` rather than the
  cause. Found by a sweep of the base class for methods whose *default* reaches
  `filesystem_path` or `$scfg->{path}`; five were unhandled.
- The ported in-use check called `dirname()` with no `use File::Basename`, and a
  second port had copied `_untaint_device_path` but not `_untaint_device_name`.

## [0.4.0~beta1] - 2026-08-07

**The plugin works.** `pvesm add synologysan` registers, and every lifecycle
operation has been driven end to end against a DS918+ on DSM 7.1.1 — twice over,
leaving nothing behind on the node or the NAS:

```
add → alloc → activate → snapshot → rollback → clone → resize → free → remove
```

Still a prerelease: one node, one model, one DSM version, and no VM has actually
booted from it yet.

### Added

- `SynologySANPlugin` — the PVE storage plugin. `path()` returns the dm-uuid
  link rather than `/dev/mapper/<wwid>`, which does not exist on a node with
  `user_friendly_names yes`. Every activation confirms the device against the
  **kernel's** WWID before using it, because `mapping_index` is reused and a
  stale path resolves to a different disk. `volume_rollback_is_possible` returns
  1 deliberately: unlike the related projects' arrays, a rollback here keeps
  newer snapshots and leaves the LUN's uuid unchanged.
- `on_add_hook` refuses a storage whose id folds onto an existing one's LUN
  prefix on the same NAS and volume — they would be indistinguishable
  afterwards, and each could delete the other's disks.
- `on_delete_hook` removes the storage's own target and logs this node out of
  it; `deactivate_storage` does the same on any other node once nothing of ours
  is attached there.

### Fixed — all five found by running it, not by reading it

- **`status()` returns `(total, available, used, active)`**, not the intuitive
  order. Backwards, the NAS's free space appeared in the Used column — and worse,
  `syno-min-free` compared against *used* space, so the guard against filling a
  Btrfs volume was reading the wrong number.
- `pvesm alloc` passes an **empty string** for the disk name rather than undef,
  so the default never applied and the LUN name came out as the bare prefix.
- **A resize never reached the node.** The rescan must go to the map's slave `sd`
  devices; `/sys/block/dm-N` has no `device/rescan`, and returning 0 for a
  missing file hid it.
- **A LUN mapped to an existing session needs `--rescan`.** A login discovers
  only the LUNs mapped at that moment, so the first activation worked and every
  one after it found no device.
- **Two leftovers.** `free_image` left a stale multipath map, because deleting
  the LUN does not remove the `sd` node while the session is up. And
  `pvesm remove` left this node logged in to a target it had just deleted.

## [0.3.1~beta1] - 2026-08-06

### Changed

- **The PVE storage type is `synologysan`, not `synologyiscsi`.** No type in this
  family carries a protocol in its name — `dellpowerstore`, `dellpowervault`,
  `dellunity`, `netappontap`, `purestorage` — and Dell EMC's covers iSCSI, FC,
  SAS and NVMe through one `dell-protocol` option. The risk is not
  inconsistency: **a storage type cannot be renamed once anyone has used it**,
  and some Synology models do support NVMe/TCP, at which point `synologyiscsi`
  would be a wrong name that could not be corrected. `synologysan` is
  vendor plus product — SAN Manager, which is exactly the subsystem this plugin
  drives — and a `syno-protocol` option is reserved for later.
- Changed now precisely because it costs nothing: the plugin is not written, so
  no `storage.cfg` anywhere names either spelling.

### Added

- `Synology::WwidState` — per-node tracking of the WWIDs this node has claimed,
  so `free_image` can clean up a device *before* the LUN is deleted and there is
  still something that knows which device belonged to it. Validates every entry
  on read: an unattended reaper consumes this file, and a corrupt line must not
  become an instruction.
- `Synology::Health` — what `status()` answers. Capacity from **one** volume
  read, never by summing `allocated_size` (a reflink counts its blocks for both
  LUNs), plus the LUN-count pressure warning that `pvesm status` has no way to
  express, and the preconditions checked when a storage is added rather than
  discovered at the first snapshot.

## [0.3.0~beta1] - 2026-08-06

### Added

- `Synology::ISCSI`. **`iscsiadm -m discovery` is never used**: a SendTargets
  discovery creates a node record for *every* target on the NAS, including the
  owner's own and one a Proxmox Backup Server was already using, and on a node
  with `node.startup = automatic` those would be logged in to at boot. Node
  records are created directly, one target and one portal at a time.
- **The per-model ceilings, read from the NAS instead of the datasheet.**
  `SYNO.Core.System info type=define` reports `max_iscsiluns` **256** and
  `max_iscsitrgs` **128** on a DS918+ where the specification sheet says 512 and
  256. Neither public reference client reads them.
- The plugin now refuses to create a LUN **before** the NAS does, with a message
  that names the real reason — at the ceiling DSM answers 18990541, which reaches
  an operator as an allocation failure while `pvesm status` shows terabytes free.
  It warns once while sixteen remain. The count includes LUNs this storage does
  not own, which is the second reason it never sends the types filter that hides
  Virtual Machine Manager disks.
- The node-side modules verified against hardware: a LUN attached to a Proxmox VE
  node, the device confirmed by the kernel's WWID (a **third** independent
  confirmation of the derivation), resized, then detached — with the node checked
  back to its exact prior state.

### Fixed

- **`make check-zh` was passing on 62 real artefacts.** It had no `use utf8;`, so
  the literal 。 and 、 in its character class were bytes while the input was
  decoded characters. Rule 1 worked regardless because it spells its ranges as
  `\x{...}` escapes — the partial success that made a broken guard look like a
  working one. All 62 corrected.
- The same guard then began *manufacturing* findings: deleting a code span joined
  the text either side and produced a space after full-width punctuation that was
  not in the source. Code spans are replaced, not deleted.
- The guard now also sees past emphasis markers: 「程式碼。** 下面」 renders with a
  visible space exactly as 「程式碼。 下面」 does.
- `docs/TESTING.md` still said no write test had been run and no plugin code
  existed. Both had stopped being true.
- Both READMEs now link to the documentation site, the Chinese one to its Chinese
  version — the language is in the URL, so a link can carry it.

## [0.2.2~beta1] - 2026-08-06

### Fixed

- **Every Traditional Chinese document rendered with stray spaces inside its
  sentences.** GitHub turns a soft line break between two Chinese characters
  into a *visible* space, so a tidily wrapped paragraph reached the reader as
  「登記簿值得 先讀一遍」. Found by looking at the rendered page — it is invisible
  in an editor. All four Chinese documents are unwrapped, and `make check-zh`
  now fails on a wrapped Chinese paragraph, on `*text*` italic emphasis (English
  typography; Chinese uses bold or 「」), on `<em>` inside a Chinese span on the
  site, and on a space after full-width punctuation.
- The status notice still said "specification and discovery" and named three
  modules when there are six. It now says what is actually true: the module
  layer works, the PVE plugin is not written.

### Added

- `Synology::Command` — bounded external commands, bounded file tests, bounded
  sysfs, **ported almost unchanged** from the Dell EMC project. This is the most
  hardware-punished code in the family and rewriting it would throw away the
  incidents that shaped it; the comments are kept verbatim for that reason.
- `Synology::Multipath` — the mandatory `conf.d` drop-in (multipathd ships no
  Synology entry, so without it the generic defaults apply and those include
  `no_path_retry "queue"`), addressing by `dm-uuid-mpath-<wwid>` rather than
  `/dev/mapper/<wwid>` which does not exist on a node with
  `user_friendly_names yes`, one-map-at-a-time operations, and device identity
  taken from the kernel because `mapping_index` is reused.

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
