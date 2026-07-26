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
7. `3cab4f0` - build: fixed the *actual* root cause of the ustreamer
   `mkdir: cannot create directory '/src': Permission denied` failure -
   raw apostrophes inside the single-quoted `bash -c '...'` heredoc body
   were silently corrupting shell parsing (see "Real bugs found" below,
   bug #3 - this superseded my earlier, incorrect diagnosis that blamed
   vendor/k1-ustreamer corruption for this specific symptom).
8. `2328f77` - build: v4l2-ctl's docker build was missing `--user root`,
   so its `apt-get install` silently failed and no output at all was
   produced for that step (see "Real bugs found" below, bug #4).

All of the above are real, live-hardware-validated fixes with evidence
gathered directly from the device over SSH (see FIRMWARE.md §60 for the
full narrative and evidence quotes already written up before this status
doc).

**Phase 19 - full production rebuild: DONE and independently verified**
(commit `b436139`). Fourth attempt succeeded cleanly after fixing a
fourth real bug (v4l2-ctl's docker build was missing `--user root` -
commit `2328f77`). Verified directly, not just via exit code:
`build-manifest.txt`'s `rootfs_squashfs_sha256` matches a fresh
`sha256sum` of the real file on disk; `unsquashfs -l` confirms
`usr/bin/ustreamer`, `usr/bin/v4l2-ctl`, and `etc/init.d/S50webcam` are
all present; `kernel.config` confirms `CONFIG_EXFAT_FS=y`; `readelf` on
the built `v4l2-ctl` binary confirms interpreter `/lib/ld.so.1` and only
NEEDED libs already present on-device (`libstdc++.so.6`, `libm.so.6`,
`libgcc_s.so.1`, `libc.so.6`, `ld.so.1`).

**Old, no-longer-relevant note below** (kept only for the debugging
narrative in "Real bugs found"):

A full `02→03→04→05→06` rebuild is required to bake all of the above into
a real flashable image (kernel changes and the new binaries can't be
hot-loaded). Three real bugs were hit and fixed *during* this rebuild
itself - see "Real bugs found" below. `02`/`03` (kernel + base rootfs,
including the exFAT kernel change) already succeeded once and do not need
re-running unless kernel/buildroot config changes again. A third `04→05→06`
attempt (background task `bd40fozyc`, log at
`/var/tmp/pip/.../scratchpad/rebuild3.log`) was in flight when this status
doc was last updated, now that all three bugs below are fixed - this
should be the one that actually finishes clean. Before trusting it:
- `grep -n "^=== \|EXIT_CODE\|Permission denied\|ABORT" rebuild3.log`
  should show all three stage markers, `EXIT_CODE=0`, and no
  Permission-denied/ABORT lines.
- `unsquashfs -l artifacts/buildroot-halley5-v30-image/rootfs.squashfs |
  grep -E "v4l2-ctl|ustreamer"` should show BOTH
  `squashfs-root/usr/bin/v4l2-ctl` and `squashfs-root/usr/bin/ustreamer`
  (the first two rebuild attempts had ustreamer but never v4l2-ctl - do
  not assume this is fixed without checking again).
- `grep CONFIG_EXFAT_FS artifacts/buildroot-halley5-v30-image/kernel.config`
  should show `=y`.
- `artifacts/buildroot-halley5-v30-image/build-manifest.txt`'s `built_at`
  should be a fresh timestamp, `git_commit_main` should be `3cab4f0` or
  later, and `rootfs_squashfs_sha256` should match a fresh
  `sha256sum rootfs.squashfs` of the actual file on disk.

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
   was real and did need fixing, but turned out **not** to be the cause of
   the `mkdir: cannot create directory '/src': Permission denied` symptom
   below - see bug #3, the actual root cause, found afterward when the
   identical failure persisted even with a freshly re-cloned vendor tree.
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

3. **The real root cause: apostrophes broke the ustreamer heredoc's
   quoting** (commit `3cab4f0`). The `mkdir: cannot create directory
   '/src': Permission denied` symptom persisted identically even after
   bug #1's fix (fresh vendor/k1-ustreamer clone) - and was 100%
   reproducible inside the real script, but never reproduced when the
   exact same `docker run` command was typed directly or placed in a
   minimal standalone script. `bash -n` on the script confirmed a real
   syntax error at an unrelated later line. Root cause: the ustreamer
   docker run's `bash -c '...'` body is a single-quoted string, and its
   own explanatory comment used real English contractions with literal
   apostrophes ("Buildroot's own host/bin", "the container's real
   system", "Buildroot's own build tree", "the container's own PATH"). A
   raw `'` inside a `'...'`-quoted string has no escape meaning in
   POSIX/bash - each one closes the string early. With four apostrophes
   toggling quote state on/off across those lines, bash's parser ended up
   alternating between quoted/unquoted interpretation of the surrounding
   text, corrupting how much of the rest of the file it folded into that
   string. Quote parity happened to resolve close enough that most of the
   script still ran (chelper, Moonraker) before the corruption became
   visible: `mkdir -p /src/build` got parsed as a real, unquoted,
   top-level command in the *outer* script rather than as content
   destined for the container, so it ran directly against this host's
   real root filesystem - which a non-root user cannot write to. Fixed by
   rewording the comment to avoid all contractions/apostrophes inside the
   single-quoted heredoc. Verified via `bash -n` on every `scripts/build/
   *.sh` file (all clean) - this class of bug could exist in any other
   single-quoted heredoc in this project, so it is worth an occasional
   `bash -n` sweep after editing comments inside any `bash -c '...'`
   block.

4. **v4l2-ctl's docker build ran as non-root but needs root for
   `apt-get`** (commit `2328f77`). After bug #3's fix, the rebuild got
   past ustreamer (built and linked correctly this time) but v4l2-ctl's
   own step produced zero output and the pipeline moved straight to
   `05-final-build.sh` with `EXIT_CODE=0` and v4l2-ctl still absent from
   the squashfs. Root cause: this docker run never had `--user root`, so
   it ran as the image's default non-root "developer" user - but its
   first two commands are `apt-get update`/`apt-get install` (needed for
   autoconf/automake/libtool/gettext/autopoint/pkg-config), which require
   root to write `/var/lib/dpkg` and `/usr`. Both commands are piped
   through `>/dev/null 2>&1` (intentional, to keep routine apt noise out
   of the log), which also silenced the real permission-denied error, and
   the container's own `set -e` exited immediately - before autoreconf/
   configure/make ever ran. (The Moonraker pywheels/streaming-form-data
   download steps a few lines earlier correctly use `--user root`; this
   one was simply missed when the section was first written.) Fixed by
   adding `--user root`. Verified in isolation first (standalone docker
   run, not through the full pipeline) before committing to another full
   rebuild: v4l2-ctl now builds to a real 542KB MIPS binary.

**Important process note for whoever continues this**: because of bug #1
(and, it turned out, primarily bug #3), *do not trust a pipeline's
`EXIT_CODE=0` alone as proof the build is complete and correct* - a
docker-internal/shell-parsing failure did not propagate up through
`set -e` as a nonzero exit from the overall `04-cross-compile-app-stack.sh`
in the way you would expect (the `mkdir: ... Permission denied` line just
printed to the log and the script carried on running whatever commands the
corrupted parse produced next - chelper and Moonraker's C extension both
built fine before the ustreamer docker step's real failure). Always
independently verify the actual squashfs contents (`unsquashfs -l
rootfs.squashfs | grep <expected file>`) and the `build-manifest.txt`'s
`built_at` timestamp/`rootfs_squashfs_sha256` against a real fresh
`sha256sum` of the file on disk before trusting a build enough to flash
it. Also worth running `bash -n` on any pipeline script right after
editing it, before spending 10+ minutes re-running a build against it.

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
