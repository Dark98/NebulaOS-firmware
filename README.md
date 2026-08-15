# NebulaOS Firmware

Canonical integration and build repository for [NebulaOS](https://github.com/coreflake1/NebulaOS)
on the Creality Ender-3 V3 KE.

**This is the repository developers use to build the complete NebulaOS image.** It pins exact
commits of the three component repos, fetches them fresh on every build, applies the accepted
kernel variants, and produces the final rootfs + kernel + app-stack image.

```
NebulaOS-kernel  ─┐
NebulaOS-klipper ─┼─►  NebulaOS-firmware  ─►  final rootfs + kernel + firmware image
NebulaOS-guppyscreen ┘   (this repo)
```

- [`NebulaOS-kernel`](https://github.com/coreflake1/NebulaOS-kernel) — Linux 6.6 kernel fork (`openke` branch)
- [`NebulaOS-klipper`](https://github.com/coreflake1/NebulaOS-klipper) — Klipper runtime fork (`master` branch)
- [`NebulaOS-guppyscreen`](https://github.com/coreflake1/NebulaOS-guppyscreen) — touchscreen UI fork (`main` branch)
- [`NebulaOS`](https://github.com/coreflake1/NebulaOS) — end-user releases, not a source tree

`manifests/dependencies.conf` is the single authoritative file for every external dependency this
build needs — kernel, Klipper, GuppyScreen, Buildroot, Moonraker, k1-ustreamer, v4l-utils, Mainsail,
WiFi firmware, and the build toolchain container — each pinned by exact commit/tag/digest plus a
SHA256. **The build fetches all of it fresh; it does not expect or use neighboring local
checkouts of the component repos.**

## Quick start

```sh
git clone https://github.com/coreflake1/NebulaOS-firmware.git
cd NebulaOS-firmware
./build.sh
```

This is the one documented, verified command to reproduce the current qualified NebulaOS baseline
from a fresh clone — `build.sh` pulls the single, digest-pinned `ghcr.io/coreflake1/nebulaos-build`
image (`manifests/dependencies.conf`'s own `BUILD_IMAGE_REPO`/`BUILD_IMAGE_DIGEST`) and runs the
whole pipeline inside it: fetches every pinned dependency, composes the 8 accepted kernel variants,
builds the kernel/rootfs/app-stack, and verifies the result.

Under the hood, `build.sh` runs these stages in sequence, inside that container (see
`scripts/build/README.md` for what each one does):

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

**Prerequisites:** Docker or Podman — nothing else. The pinned build image already contains every
host build tool the pipeline needs (see `docs/NEBULAOS_BUILD_ENVIRONMENT.md`); no separate
`apt-get install`, no nested container, no `/var/run/docker.sock` requirement. ~15GB free disk and
a few hours of build time on a reasonably modern machine. Network access throughout (every
dependency is fetched fresh, hash-verified against `manifests/dependencies.conf`, and fails loudly
on any mismatch).

**Output:** `vendor/buildroot-x2000/output/images/{xImage,rootfs.ext2,rootfs.squashfs}` (the kernel
image and root filesystem, both ext2 and squashfs forms) — `05-final-build.sh` copies these,
alongside `build-manifest.txt` and `kernel.config` (the resolved build identity), into
`artifacts/buildroot-halley5-v30-image/`. GuppyScreen's own compiled binaries land in
`artifacts/guppyscreen-mips/`. `06-verify.sh` checks these are
real, correctly-architected MIPS32 output without needing real hardware — it does not claim
byte-for-byte reproducibility build-to-build (timestamps/build-path strings vary), only that the
same real code landed.

## What NOT to build directly

Don't clone and build `NebulaOS-kernel`, `NebulaOS-klipper`, or `NebulaOS-guppyscreen` on their own
expecting a working printer image — none of them alone produce one. This repo is the only one that
pins, fetches, and assembles all three into something flashable.

## Reproducibility

Every dependency in `manifests/dependencies.conf` is pinned by exact commit/tag/digest and a
SHA256, verified fail-loud on every run — see that file's own comments for the pin history and
rationale behind each one. The 8 accepted kernel variants (PREEMPT_RT, WiFi SDIO IRQ priority,
display VSYNC-gated pan, a pinctrl fix, the backlight final controller, PWM state readback, the
touch final-qualification driver, and WiFi roamoff-disable) are tracked, order-independent scripts
under `scripts/build/`, applied by `scripts/build/apply-qualified-baseline.sh`.

## Is OpenKE part of NebulaOS?

No. [OpenKE](https://github.com/coreflake1/guppyscreen) is a separate, independently-released
project (its own installer for stock Creality firmware, its own version train) that shares an
author and some engineering lineage with NebulaOS, but is not part of it. `NebulaOS-guppyscreen`'s
kernel-side sibling repo keeps the branch name `openke` for historical reasons — see that repo's own
README for the distinction.

## Developer documentation

Beyond building (above), this repo is also the canonical source for installing, updating, switching, and recovering a real device — developer/advanced-testing procedures, not consumer instructions:

- [`docs/A_B_SLOT_MODEL.md`](docs/A_B_SLOT_MODEL.md) — the partition layout and boot-slot mechanism
- [`docs/DEVELOPER_INSTALL_FROM_STOCK.md`](docs/DEVELOPER_INSTALL_FROM_STOCK.md) — first install
- [`docs/DEVELOPER_UPDATE.md`](docs/DEVELOPER_UPDATE.md) — component vs. whole-image updates
- [`docs/DEVELOPER_RECOVERY.md`](docs/DEVELOPER_RECOVERY.md) — the recovery ladder, incl. known limitations
- [`docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md`](docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md) — day-to-day slot switching
- [`docs/BUILD_PROVENANCE.md`](docs/BUILD_PROVENANCE.md) — identifying exactly what produced a given build
- [`docs/NEBULAOS_BUILD_ENVIRONMENT.md`](docs/NEBULAOS_BUILD_ENVIRONMENT.md) — the build container itself

The other four component repos (kernel, Klipper, GuppyScreen, and the [`NebulaOS`](https://github.com/coreflake1/NebulaOS) release repo) link back here for all of the above rather than maintaining their own copies — this repo is the one place these procedures are canonical.

## Project history

This repo was previously developed under the name `ke-mainline-klipper` as a broader research
workspace. That history — including the real hardware bring-up investigations, root-cause writeups,
and mission-by-mission progress log — is preserved at [`docs/HISTORY.md`](docs/HISTORY.md) and
throughout `docs/`, not deleted. `FIRMWARE.md` remains the detailed technical source-of-truth
document for the build's internals.

## License

See [`LICENSES/`](LICENSES/) for this project's own code and the license terms of everything it
vendors/fetches.
