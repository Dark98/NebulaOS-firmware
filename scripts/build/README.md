# Build scripts - reproduce the full custom firmware/OS build from scratch

These scripts reproduce everything documented in `FIRMWARE.md` §8-14: a custom Linux 6.6.18-rt23
kernel + Buildroot rootfs for the Ender 3 V3 KE's Nebula Pad (Ingenic X2000), with touch, display,
WiFi, Bluetooth, camera, and a full Klipper/Moonraker/nginx/Mainsail app stack - everything except
GuppyScreen (deliberately deferred, see the main README) and the real-hardware boot test itself
(needs the user present, not something a script can do).

**Read this before running anything**: these scripts encode the *correct*, clean sequence -  not a
literal replay of every trial-and-error step taken while first discovering it (several real bugs
were hit and fixed along the way; the fixes are baked in here rather than reproduced as separate
steps). If you hit an error these scripts don't anticipate, check `FIRMWARE.md`'s relevant section
first - the real bugs already found (Buildroot's kernel-config stamp-tracking gap, the
`/src`-vs-`/br` Docker mount RUNPATH issue, the internal-toolchain C++ rebuild requirement, the
rootfs-overlay deletion gotcha) are all documented there with root causes, not just workarounds.

## Prerequisites

- Docker, with the `pellcorp/k1-bash-build` image pullable (the same MIPS cross-toolchain image
  used throughout this whole project - has both a Buildroot-independent
  `mips-gcc720-glibc229` toolchain *and* is the container these scripts run Buildroot's own build
  inside).
- ~15GB free disk (kernel source, Buildroot's own internal toolchain build, and the final images
  add up) and a few hours of build time on a reasonably modern machine.
- Internet access for the `git clone`/`curl` steps in `00-fetch-vendor-sources.sh` - this project's
  `vendor/` directory is gitignored on purpose (large, mixed-provenance sources, see the main
  README), so nothing under `vendor/` is checked into this repo. The kernel is the one exception to
  "gitignored, nothing checked in": this project's kernel changes live as real commits on the
  `openke` branch of a real fork, [`coreflake1/NebulaOS`](https://github.com/coreflake1/NebulaOS)
  (forked from the original upstream, `Llixuma/ingenic-linux-kernel6.6-x2000-v1.0-20250221`) -
  `00-fetch-vendor-sources.sh` clones that branch directly, so the kernel changes travel with their
  own real git history instead of a patch file. What else *is* checked into this repo: the small set
  of files this project actually wrote by hand (`scripts/build/overlay/` - init scripts and configs,
  not the third-party source/binaries those scripts launch).

## Running the whole thing

```sh
cd scripts/build
./00-fetch-vendor-sources.sh
./01-apply-kernel-patches.sh
./02-configure-buildroot.sh
./03-build-kernel-and-rootfs.sh
./04-cross-compile-app-stack.sh
./05-final-build.sh
./06-verify.sh
```

Each script is idempotent (safe to re-run) and checks its own prerequisites before doing anything.
Run them in order the first time; after that, re-running just the stage you're iterating on is
fine as long as its inputs (the previous stages' outputs) are still in place.

## What each stage does

1. **`00-fetch-vendor-sources.sh`** - clones/downloads every third-party source this build needs
   into `vendor/` at the exact refs this project used: the X2000 kernel SDK, this project's own
   fork's `openke` branch (`coreflake1/NebulaOS`, forked from `Llixuma/ingenic-linux-kernel6.6-
   x2000-v1.0-20250221`), the Buildroot config (`lone0/buildroot-x2000`), Klipper
   (`pellcorp/klipper`, SimpleAF's fork), Moonraker (`Arksine/moonraker`, official),
   `pellcorp/k1-ustreamer`, and Mainsail's latest prebuilt release.
2. **`01-apply-kernel-patches.sh`** - no longer applies anything (this project's kernel changes -
   touch DT wiring, the new display panel driver, the new Bluetooth H5 Broadcom vendor extension,
   WiFi/BT/display Kconfig changes, the real ported NS2009 driver, and the upstream `binder.h`
   build-fix - are already real commits on the fork's `openke` branch, checked out by stage 0). Just
   verifies they're actually present, kept as stage "01" so the numbered sequence stays stable.
3. **`02-configure-buildroot.sh`** - writes the real Buildroot `.config` (base `x2000_halley5_v30_
   linux` defconfig plus every option this project added - WiFi/BT/touch/display/RNG/Python3/
   nginx/etc, using a helper that finds-and-replaces each option's *real* existing line rather than
   blindly appending, which is what caused a real class of bugs this session - see `FIRMWARE.md`
   §14), the kernel config fragment file, `local.mk` (the `LINUX_OVERRIDE_SRCDIR` pointer), and
   copies this repo's own hand-written overlay content (`scripts/build/overlay/`) into
   `board/halley5-openke-overlay/`.
4. **`03-build-kernel-and-rootfs.sh`** - the main kernel + rootfs build (`make`) - touch, display,
   WiFi, Bluetooth, camera-kernel-side, and Core SoC infra all come from this one pass, since
   they're all just kernel config + device-tree, no cross-compiled userspace extras needed yet.
5. **`04-cross-compile-app-stack.sh`** - cross-compiles the handful of things that need the
   Buildroot-built toolchain directly rather than going through a Buildroot package (Klipper's
   `chelper` C extension, Moonraker's `streaming-form-data` C extension, and `ustreamer` itself),
   and assembles the full app-stack overlay (Klipper/Moonraker source trees, Mainsail's static
   build, this repo's own init scripts/configs already in place from stage 2).
6. **`05-final-build.sh`** - the final full `make` that bakes everything from stage 4 into the
   actual `rootfs.ext2`/`uImage`.
7. **`06-verify.sh`** - the same `debugfs`-based presence checks and `readelf`/`file` architecture
   checks used throughout this project to confirm each piece actually landed in the image and is
   real MIPS32 little-endian code, without needing real hardware.

## Output

`vendor/buildroot-x2000/output/images/{uImage,rootfs.ext2}` - copy these into `artifacts/
buildroot-halley5-v30-image/` if you want them alongside this project's own previously-built copies
(sha256 sums won't match exactly build-to-build - timestamps and build-path strings end up
embedded in a few places - but the same real code should be present; that's what `06-verify.sh`
checks for, not byte-for-byte reproducibility).
