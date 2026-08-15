# Identifying exactly what produced a build

**Developer documentation.** How to answer "what factory, and what source, actually produced this specific `xImage`/`rootfs.squashfs`?" — for a build you just ran, or one someone else shipped you.

This is a different question from `docs/NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md`, which tracks *third-party* artifacts this build fetches and consumes (Mainsail's release zip, WiFi firmware, etc.) and whether each is reconstructable from its own upstream. This document is about the *build's own identity* — which commit of this repo, which pinned dependency versions, and which build image produced a given output.

## `build-manifest.txt`

Every real build writes `artifacts/buildroot-halley5-v30-image/build-manifest.txt` (`05-final-build.sh`). This is the source of truth `scripts/flash-spare-slot.sh` verifies transferred artifacts against before writing anything to real hardware (see `docs/DEVELOPER_INSTALL_FROM_STOCK.md`), and the record a future investigator needs to reconstruct exactly what a given image is, without needing the original `vendor/` checkouts to still exist.

Fields recorded (`SCRIPT_VERIFIED` against the current `05-final-build.sh`):

| Field | What it tells you |
|---|---|
| `built_at` | UTC timestamp of the build |
| `build_image_repo` / `build_image_digest` | Which unified build container actually produced this — added 2026-08-15 (Final Closure mission); a shipped artifact previously had no record of which factory built it |
| `git_commit_main` (+ `_dirty`) | This repo's own commit, and whether the tree was clean |
| `git_commit_kernel`, `git_commit_buildroot`, `git_commit_klipper`, `git_commit_moonraker`, `git_commit_guppyscreen`, `git_commit_pellcorp_creality`, `git_commit_k1_ustreamer`, `git_commit_v4l_utils` (each + `_dirty`) | Exact commit of every vendored source tree |
| `git_submodules_k1_ustreamer` | Submodule pins within that vendor tree |
| `mainsail_zip_sha256`, `guppyscreen_sha256`, `guppybeep_sha256`, `wifi_firmware_sha256`, `wifi_clm_sha256`, `wifi_nvram_sha256`, `regulatory_db_sha256` | Hashes of fetched/built binary artifacts |
| `kernel_config_sha256`, `buildroot_config_sha256`, `device_tree_sha256` | Hashes of the resolved build configuration actually used |
| `xImage_sha256` / `xImage_size`, `rootfs_squashfs_sha256` / `rootfs_squashfs_size` | The two artifacts that actually get flashed |

## The qualified baseline

`manifests/dependencies.conf`'s `QUALIFIED_BASELINE_TAG` names the one explicit, current reference — not "whichever tag is newest" (that auto-selection was itself a real bug, fixed during the Final Closure mission; see that report). `scripts/build/assert-baseline-config.sh` and `scripts/build/baseline-difference-gate.sh` both read this value and fail loudly if it doesn't resolve to a real tag, printing the exact baseline they checked against.

## Reconstructing a build's identity from artifacts alone

Given just `build-manifest.txt` from a shipped image:

1. `git_commit_main` — check out that commit in `NebulaOS-firmware`.
2. `build_image_repo`/`build_image_digest` — pull that exact image; don't assume it still matches whatever `manifests/dependencies.conf` currently pins, since that value can move forward over time.
3. Every other `git_commit_*` field — cross-check against what `manifests/dependencies.conf` pins **at that commit** (`git show <git_commit_main>:manifests/dependencies.conf`), not the current tip.
4. Re-running `./build.sh` at that exact commit, with that exact image digest, should reproduce a build classified `SEMANTICALLY_IDENTICAL_WITH_KNOWN_NONDETERMINISM` against the original — not byte-identical (see the Phase 11 and Final Closure reports for exactly which differences are expected and why: Buildroot's own self-versioning string, BusyBox's build-timestamp, and the target toolchain being rebuilt from source each run).

## Related documents

- `docs/BUILD_FROM_SOURCE.md` — how to actually produce a build in the first place
- `docs/NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md` — third-party artifact provenance and reconstructability
- `docs/A_B_SLOT_MODEL.md` / `docs/DEVELOPER_INSTALL_FROM_STOCK.md` — what `flash-spare-slot.sh` does with `build-manifest.txt`
