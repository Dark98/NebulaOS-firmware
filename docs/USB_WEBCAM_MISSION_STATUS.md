# USB host + pellcorp/k1-ustreamer webcam mission - status report

Working document for the in-progress "restore USB host functionality and
validate the pellcorp webcam implementation" mission. Written mid-mission
as a safety checkpoint - update or fold into FIRMWARE.md §60 once the
mission fully closes.

## Where this stands right now

**Committed and done (Phase 0-18):**

1. `1597057` - kernel: enable `CONFIG_EXFAT_FS=y` (the physically-attached
   USB flash drive is exFAT-formatted; `CONFIG_VFAT_FS` was already on but
   exFAT wasn't).
2. `7b69d68` - build: fix the real root cause of ustreamer never running -
   a MIPS glibc ABI mismatch between pellcorp's own `k1-camera-build`
   toolchain (glibc 2.29) and this project's Buildroot target (glibc 2.38).
   Rebuilt the identical, untouched pellcorp source with this project's own
   Buildroot toolchain instead. Live-tested: real MJPEG stream from the
   real webcam.
3. `c7f4de2` - build: package `v4l2-ctl` from upstream `v4l-utils` (pinned
   `v4l-utils-1.20.0`) via the same Buildroot-toolchain pattern - this
   vendored Buildroot tree never had a v4l-utils package at all.
4. `aa35cd0` - init: rewrite `S50webcam` - old version hardcoded
   `/dev/video0` (which is actually the SoC's own rotation engine, not the
   camera; the real UVC node is `/dev/video3`) and was one-shot with no
   retry/hotplug support. New version discovers the real UVC capture node
   dynamically via `v4l2-ctl`'s "Device Caps" block and runs a bounded 5s
   supervisor loop.
5. `353fb4c` - docs: corrected MIT→GPLv3 license misattribution
   (README.md, FIRMWARE.md, `00-fetch-vendor-sources.sh`) and overstated
   "confirmed live"/"proven live" USB claims in
   `docs/BOARD_CAPABILITY_MATRIX.md` and `docs/BOOT_WARNING_AUDIT.md`
   (those only ever meant driver registration in dmesg, not real device
   enumeration - reconciled against a real, previously-unresolved
   FIRMWARE.md §42 contradiction). Classified `OUTDATED_OR_INCOMPLETE_
   PRIOR_TEST`.
6. `913b386` - build: fixed a genuine bug in `05-final-build.sh`'s own
   source-fingerprint safety check, found *while* running this mission's
   own rebuild (see "Real bugs found" below).

All of the above are real, live-hardware-validated fixes with evidence
gathered directly from the device over SSH (see FIRMWARE.md §60 for the
full narrative and evidence quotes already written up before this status
doc).

**In progress (Phase 19 - full production rebuild):**

A full `02→03→04→05→06` rebuild is required to bake all of the above into
a real flashable image (kernel changes and the new binaries can't be
hot-loaded). Two real problems were hit and fixed *during* this rebuild
itself - see below. A second rebuild attempt (04→05→06 only, since 02/03
already succeeded and produced a correct kernel+base rootfs) was in flight
when this status doc was written - check
`artifacts/buildroot-halley5-v30-image/build-manifest.txt`'s `built_at`
timestamp and re-run `06-verify.sh`'s camera section, plus
`unsquashfs -l rootfs.squashfs | grep v4l2-ctl`, to see if it finished
and actually contains `v4l2-ctl` this time.

**Not started (Phase 20-21):**

- Reflash the spare custom slot (`kernel2`/`rootfs2`) via the established
  `flash-spare-slot.sh` + OTA-marker-flip procedure - only once the
  rebuild above is confirmed complete and correct.
- Post-reflash validation: full printer-stack safety re-check (heater
  targets zero, no homed axes, MCU link stable), then USB-specific
  validation (flash drive mount + the deferred safe write-test now that
  exFAT is baked in, webcam discovery, ustreamer via the real S50webcam,
  nginx `/webcam/` proxy, Mainsail live image - ask the user to confirm).
- Reboot-persistence check (both devices reconnect automatically after a
  real reboot).
- The one permitted controlled hotplug cycle per device (flash drive
  unplug/reinsert once, webcam unplug/reinsert once) - requires the user
  to physically do this.
- The mission's full required final report.

## Real bugs found and fixed *during* this mission (not part of the
   original USB/webcam scope, but blocking it)

1. **`vendor/k1-ustreamer` corruption.** Mid-mission, this gitignored,
   pinned-upstream-commit vendor checkout was found reduced to just 2
   leftover files (`build.sh`, `docker.sh`) - its `.git`, the `ustreamer`/
   `jpeg-9d` submodules, and source tarballs were all gone. Root cause not
   fully forensically determined (most likely leftover from earlier ad-hoc
   Docker testing in a part of this session that was summarized away), but
   confirmed isolated to this one vendor directory (klipper/moonraker/
   buildroot-x2000/x2000_kernel_6.6/v4l-utils were all still intact). This
   silently broke the ustreamer/v4l2-ctl build step (`mkdir: cannot create
   directory '/src': Permission denied` right at the first command inside
   the docker container) without failing the outer pipeline loudly - **the
   first rebuild's resulting squashfs still had the OLD ustreamer binary
   and no v4l2-ctl at all**, despite the pipeline printing `EXIT_CODE=0`.
   Fixed (with explicit user confirmation before the destructive `rm -rf`)
   by re-cloning `https://github.com/pellcorp/k1-ustreamer.git` fresh at
   the exact pinned commit (`18e30bb313d54b1b01dd995bd31ce5a3d5adffd6`)
   with submodules, matching what `00-fetch-vendor-sources.sh` already
   does. Not committed as a fix (nothing to commit - `vendor/` is
   gitignored) but worth remembering if it recurs.

2. **`05-final-build.sh`'s own source-fingerprint check self-tripped**
   (commit `913b386`). This safety check hashes `git status` before/after
   the real `make`, meant to catch some *other* process editing the repo
   mid-build. But the script itself overwrites the git-tracked
   `artifacts/buildroot-halley5-v30-image/{kernel.config,buildroot.config}`
   with the freshly-built versions as part of its own normal operation -
   any real kernel/buildroot config change (like this mission's own exFAT
   fragment addition) makes the freshly-built `kernel.config` legitimately
   differ from the currently-committed one, flipping `git status` between
   the BEFORE and AFTER snapshots and aborting with "ABORT: source tree
   changed during the build" - a false positive on a build that actually
   succeeded (mksquashfs had already completed and the images were already
   copied to `artifacts/` by the time the abort fired). This is why the
   first rebuild attempt's `build-manifest.txt` was never regenerated even
   though `xImage`/`rootfs.squashfs`/`kernel.config` on disk *were* fresh.
   Fixed by excluding `artifacts/buildroot-halley5-v30-image/` from the
   git-status snapshot via a `:(exclude)` pathspec.

**Important process note for whoever continues this**: because of bug #1,
*do not trust a pipeline's `EXIT_CODE=0` alone as proof the build is
complete and correct* - a docker-internal failure inside one `docker run`
block did not propagate up through `set -e` as a nonzero exit from the
overall `04-cross-compile-app-stack.sh` in the way you'd expect (the
`mkdir: ... Permission denied` line just printed to the log and the script
seems to have carried on rebuilding whatever it could - chelper and
Moonraker's C extension both built fine before the ustreamer docker step
failed). Always independently verify the actual squashfs contents
(`unsquashfs -l rootfs.squashfs | grep <expected file>`) and the
`build-manifest.txt`'s `built_at` timestamp/`rootfs_squashfs_sha256`
against a real fresh `sha256sum` of the file on disk before trusting a
build enough to flash it.

## Mission constraints still in force for whoever continues

- Production streamer must stay `pellcorp/k1-ustreamer` - do not swap in
  crowsnest/mjpg-streamer/ffmpeg/etc.
- Do not touch the gyro USB-C connector.
- Printer safety: no G28/motion/heater/fan/probing commands; verify heater
  targets=0 and `homed_axes=""` after every reboot.
- A/B safety: flash only the spare custom slot, never stock.
- User may only be asked to: confirm both devices connected, one
  unplug/reinsert per device, confirm flash-drive files visible, confirm
  live webcam image in Mainsail, move a device to another port if evidence
  requires it.
