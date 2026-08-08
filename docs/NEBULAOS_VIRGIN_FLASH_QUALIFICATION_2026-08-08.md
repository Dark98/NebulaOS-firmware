# Virgin Flash + Verification mission (2026-08-08)

Running record for the Autonomous NebulaOS Virgin Flash + Verification
mission: deploying `build-work/deploy-packages/z-compensate-guppyscreen-
20260808T152643Z/` to the real device, proving first boot uses no previous
NebulaOS runtime state, live qualification, and the resulting canonical
baseline tag. Appended to as each phase completes.

## Phase 1: traceability correction

The package under deployment was built from a genuinely fresh clone at
firmware commit `91a190e` (`build: pin pellcorp/k1-bash-build by immutable
digest`). One further commit, `f939141` (`docs: record explicit load-cell
scope + exclude uncommitted safety fix`), landed on `main` afterward -
**independently re-verified here** via `git diff --stat 91a190e f939141`:
exactly one file changed, `docs/NEBULAOS_PRINTER_CFG_LOADCELL_GAP.md`, pure
Markdown, zero lines touched in any script, manifest, `klippy_extras/`
module, or `printer.cfg`. Confirmed documentation-only; no rebuild
performed, per this mission's own explicit instruction.

```
BUILT_FROM_FIRMWARE_SHA=91a190e4cd6b128de1cc071012e899cbd44b53a4
CURRENT_DOCUMENTATION_HEAD=f939141afa5dcbd30472f37e94bb233013e7d0c1
```

Full commit SHAs, for the record:

- `BUILT_FROM_FIRMWARE_SHA` = `91a190e4cd6b128de1cc071012e899cbd44b53a4`
  (matches this package's own `build-manifest.txt`'s `git_commit_main` and
  `/opt/nebulaos-version.json`'s `firmware_sha`, independently confirmed by
  direct `unsquashfs` inspection of the packaged `rootfs.squashfs` during
  the prior mission's own artifact-inspection step)
- `CURRENT_DOCUMENTATION_HEAD` = `f939141afa5dcbd30472f37e94bb233013e7d0c1`
  (current `origin/main` tip at the time this deployment mission began)

The canonical baseline tag this mission creates (Phase 11) is placed on
`91a190e` - the commit that actually produced the flashed bytes - not on
the later docs-only HEAD, so the tag always points at something a fresh
clone can rebuild byte-reproducibly-equivalent to what is actually running
on the device.

## Phase 2: final package gate

Re-verified fresh (not reused from memory): `sha256sum -c SHA256SUMS` all 7
files OK; `rootfs.squashfs` 119,410,688 bytes (~113.9 MiB, well under the
500MB rootfs2 budget); `build-manifest.txt` confirms
`git_commit_main=91a190e...`, `git_commit_klipper=462fd68...`,
`git_commit_v4l_utils=3b22ab0` (`_dirty=no`, confirming the deterministic
archive fetch produces a clean checkout); fresh `unsquashfs` extraction
directly confirmed `[nebulaos_version]`/`[prtouch_v2]`/`[z_compensate]`
present in the packaged `printer.cfg`, `bed_add_temp: 60`, all 7 required
Klipper modules present and non-empty, `S04nebulaos-factory-seed`/
`S04nebulaos-migrate` present, GuppyScreen a real stripped MIPS32 ELF
binary, `nebulaos-version.json` reporting `firmware_sha: 91a190e...`. Both
canonical repos (`NebulaOS-firmware`, `NebulaOS-klipper`) confirmed clean
with local HEAD == remote HEAD.

## Phase 3: pre-flash printer checks

Device located via `nmap -p 22 --open` scan (IP had drifted, as expected -
see project memory on DHCP lease churn): `192.168.0.242`, dropbear banner,
password `openke` accepted. Confirmed:

- `/proc/cmdline`: `root=/dev/mmcblk0p8 ... rootfstype=squashfs ro` - real
  board, currently booted on the **custom** slot (rootfs2). Partition
  table (`/dev/disk/by-partlabel/*`) matches this project's own documented
  layout exactly (kernel/kernel2/rootfs/rootfs2/rootfs_data/userdata/rtos/
  rtos2/sn_mac/ota) - confirms genuine device identity.
- OTA marker (`/dev/mmcblk0p1`): `ota:kernel2` - internally consistent
  with currently booted on custom.
- Moonraker `/printer/objects/query`: `print_stats.state: "standby"`,
  `idle_timeout.state: "Idle"`, `extruder.target: 0.0`,
  `heater_bed.target: 0.0` - idle, no active/paused print, heaters off.
- Moonraker `/server/info`: `klippy_connected: true`,
  `klippy_state: "ready"` - Klipper healthy, not halted (resolves the
  open question carried from before this mission chain: whatever earlier
  `bed_add_temp`-related halt existed is not present in the currently
  running, pre-this-deployment image).
- `moonraker_version: v0.10.0-31-gd5ee171` matches the pinned
  `MOONRAKER_PIN`.

**Real finding, not previously documented**: `/opt/klipper` is NOT
currently bind-mounted from `/usr/data/nebulaos/apps/klipper` on this
boot (`mount` output has no `klipper` entry, unlike `/opt/moonraker`,
`/opt/printer_data`, `/usr/share/mainsail`, `/root/klippy-env`, all of
which are correctly bound). Klipper is therefore currently running from
whatever `/opt/klipper` resolves to on the read-only squashfs itself
(content dated 2026-08-07, consistent with the prior "canonical-
baseline-2026-08-07" live deployment). The **persistent** checkout at
`/usr/data/nebulaos/apps/klipper` (HEAD `d839d0375a31327e57e0a35e99e70ba60814ec05`,
branch `nebulaos`) is unaffected by this and is what actually gets backed
up in Phase 4 below - this anomaly does not change this mission's plan
(a fresh flash + virgin provisioning replaces the whole picture
regardless) but is recorded here since it is real, observed device
state, not something to silently paper over.

No motion/homing/heating/extrusion/printing/calibration command was ever
issued - every check above is a read-only query.

Stock slot health / current custom image recoverability: not directly
probed from within custom (deferred to Phase 6, where booting into stock
as part of the flash sequence itself is the real, direct verification -
stronger evidence than any indirect check possible from custom).

## Phase 4: persistent-state backup

Real, active runtime paths identified precisely from the live device's
own `/etc/init.d/S05nebulaos-activate` (not inferred): every real bind
mount source is under `NEBULAOS_ROOT=/usr/data/nebulaos`, plus one
separate shared-gcodes source at `/usr/data/printer_data/gcodes`. The
device's `/usr/data` partition (99% full, only 67MB free) also carries
several GB of unrelated, non-bind-mounted historical debris from past,
unrelated missions (`creality/`, a dozen `*-stage/` directories, six
separate `nebulaos.*-backup-*/` snapshots, `staging/`, `deploy-staging/`,
etc.) - confirmed inert (not referenced by the live activation script) and
out of scope for this backup, which targets the real active state only.

Backed up (streamed directly over SSH to the build host - the device had
no free space to stage a local copy at all):

```
ssh root@192.168.0.242 "tar -cf - -C /usr/data nebulaos printer_data/gcodes" \
    > nebulaos-device-backup-20260808T165251Z/usr-data-backup.tar
```

- Path: `/home/tim/Documents/nebulaos-device-backup-20260808T165251Z/usr-data-backup.tar`
- Size: 373,587,968 bytes (~356 MiB), 12,665 entries
- SHA256: `be6f597b665d917a089aaaf3027a00ca5cbfa51b3ff8b746137995e6ab40c4d0`
- Two Unix-domain sockets (`nebulaos/printer_data/comms/moonraker.sock`,
  `.../klippy.sock`) were skipped by `tar` (expected, harmless - live
  runtime sockets, not data)
- Verified by extraction: `nebulaos/apps/klipper`'s checkout re-hashes to
  the exact same HEAD confirmed live (`d839d0375a...`), `printer_data/
  config/printer.cfg` present

This backup is complete, checksummed, and left untouched at an inert
location off the device, outside anything Phase 5's virgin-state reset or
Phase 6's flash can affect. Not deleted; not to be restored before
qualification (Phase 5's own explicit instruction).
