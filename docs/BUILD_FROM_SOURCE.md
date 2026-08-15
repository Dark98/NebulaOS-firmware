# Building NebulaOS from source

**Developer documentation.** The canonical, complete build entry point:

```sh
git clone https://github.com/coreflake1/NebulaOS-firmware.git
cd NebulaOS-firmware
./build.sh
```

**Evidence: `LIVE_HARDWARE_VERIFIED`** — this exact command, from a genuinely fresh clone, was run and hardware-qualified as part of the Final Closure mission (2026-08-15).

## What this actually does

`build.sh` pulls one digest-pinned image, `ghcr.io/coreflake1/nebulaos-build@sha256:<see manifests/dependencies.conf's BUILD_IMAGE_REPO/BUILD_IMAGE_DIGEST>`, and runs the whole pipeline inside it. **Prerequisites: Docker or Podman — nothing else.** The image already contains every host build tool the pipeline needs; no separate `apt-get install`, no nested container, no `/var/run/docker.sock` requirement. See `docs/NEBULAOS_BUILD_ENVIRONMENT.md` for exactly what's in that image and why.

No normal complete build requires, and none should be documented as requiring:

```text
pellcorp/k1-bash-build
ghcr.io/coreflake1/guppydev
nested Docker
runtime host apt-get
```

These were the pre-2026-08-15 architecture, fully retired — see `docs/NEBULAOS_BUILD_ENVIRONMENT.md`'s own retirement section and the Final Closure report for the evidence trail. If you find a current-state document that still describes them as active dependencies, that's stale — see this project's own stale-reference sweep process rather than trusting it.

Under the hood, inside that container, `build.sh` runs these stages in sequence (see `scripts/build/README.md` for what each does):

```sh
cd scripts/build
./00-fetch-vendor-sources.sh      # fetches every pinned dependency, hash-verified
./01-apply-kernel-patches.sh      # verifies the openke fork's changes landed
./02-configure-buildroot.sh       # wires up buildroot.config, kernel fragment, overlay
./03-build-kernel-and-rootfs.sh   # builds the kernel + base rootfs
./04-cross-compile-app-stack.sh   # cross-compiles Klipper extras, GuppyScreen, v4l-utils, etc.
./05-final-build.sh               # final rootfs.ext2/rootfs.squashfs, writes build-manifest.txt
./06-verify.sh                    # sanity-checks the real output (architecture, artifact naming, etc.)
```

**Output:** `vendor/buildroot-x2000/output/images/{xImage,rootfs.ext2,rootfs.squashfs}`, copied by `05-final-build.sh` — alongside `build-manifest.txt` and `kernel.config` — into `artifacts/buildroot-halley5-v30-image/`. GuppyScreen's own compiled binaries land in `artifacts/guppyscreen-mips/`. The artifact is `xImage`, not `uImage` — `06-verify.sh` checks this directly; see `docs/BUILD_PROVENANCE.md` for what `xImage` actually is.

`06-verify.sh` confirms the output is real, correctly-architected MIPS32 code without needing real hardware — it does **not** claim byte-for-byte reproducibility build-to-build (timestamps and some build-path strings vary by design of the toolchain, not a bug — see the Phase 11 report for the full reproducibility classification).

~15GB free disk, network access throughout (every dependency is fetched fresh and hash-verified against `manifests/dependencies.conf`), and a few hours of build time on a reasonably modern machine.

## Where every pin lives

`manifests/dependencies.conf` is the single authoritative file for every external dependency — kernel, Klipper, GuppyScreen, Buildroot, Moonraker, k1-ustreamer, v4l-utils, Mainsail, WiFi firmware, and the build image itself — each pinned by exact commit/tag/digest plus a SHA-256, verified fail-loud on every run. Read that file's own comments before changing any pin; most entries have real incident history behind why they're pinned the way they are.

The 8 accepted kernel variants (PREEMPT_RT, WiFi SDIO IRQ priority, display VSYNC-gated pan, a pinctrl fix, the backlight final controller, PWM state readback, the touch final-qualification driver, WiFi roamoff-disable) are tracked, order-independent scripts under `scripts/build/`, composed by `scripts/build/apply-qualified-baseline.sh`.

The build fetches every component fresh; **it does not expect or use neighboring local checkouts** of `NebulaOS-kernel`, `NebulaOS-klipper`, or `NebulaOS-guppyscreen`. Don't clone and build those repos standalone expecting a working printer image — none of them alone produce one.

## Testing a change during development

There is no separate "fast" dev-loop build documented today — a normal `build.sh` re-run reuses the same `vendor/`, `build-work/`, and `artifacts/` state if you don't delete them first, so an already-fetched checkout doesn't need to re-fetch every dependency on a second run. For a genuinely clean-room result (proving reproducibility, not just iterating), use a fresh clone — an already-populated `vendor/` is convenient for iteration but defeats that specific purpose.

## Related documents

- `docs/NEBULAOS_BUILD_ENVIRONMENT.md` — what's in the build image, why it's digest-pinned, the promotion gate for a new candidate
- `docs/BUILD_PROVENANCE.md` — how to identify exactly which build produced a given artifact
- `scripts/build/README.md` — per-stage detail for `00`-`06`
- `docs/A_B_SLOT_MODEL.md` / `docs/DEVELOPER_INSTALL_FROM_STOCK.md` — what to do with the artifacts this produces
