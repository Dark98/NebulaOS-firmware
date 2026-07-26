# NebulaOS Mutable Runtime Architecture

**Status:** Phase 1 (Reconcile and investigate) — in progress. This document records verified findings only; anything not yet confirmed is marked `NEEDS_RUNTIME_EVIDENCE` or `NEEDS_DECISION`. No implementation has started. No device or build-artifact state has been changed while producing this section.

**Scope:** this is the architecture doc for the "NebulaOS Mutable Applications, Updates, Recovery, Shared G-code, and Retention" mission. It will be extended through each phase; Section 1 is the Phase 1 investigation record.

---

## 1. Phase 1 investigation findings (2026-07-26)

### 1.1 Prior planning documents (read in full)

Two planning documents already exist in the sibling GuppyScreen repo (`/home/tim/Documents/guppyscreen/`), written 2026-07-26, read-only static audits, no device/build actions taken while producing them:

- `gap analisys nebulaOS.md` (558 lines) — GuppyScreen↔NebulaOS compatibility gap analysis. Its scope is **GUI/Klipper-extra feature portability** (GuppyScreen panels, Klipper extras, Moonraker API compatibility), not the mutable-runtime/update/retention architecture this mission covers. Still directly useful here for:
  - **Klipper-extras provenance** (its Section 6, G42/G43, and open questions #4/#5) — partially resolved further in this document, Section 1.3 below.
  - **Confirmation that `[spoolman]` is not currently shipped**, that `custom_macro`/`BL24C16F`/`temp_offset_flag`/power-loss recovery have no source anywhere and are explicit product decisions, not technical gaps.
  - Its own recommended architecture (hybrid, mainline-first, thin compatibility shims) is **orthogonal** to this mission — it concerns GuppyScreen panel behavior, not how Klipper/Moonraker/Mainsail themselves get installed/updated/rolled back. No conflict found.
- `suggested fix plan nebulaOS.md` (597 lines) — turns the gap analysis into a GuppyScreen-porting implementation roadmap (path-centralization, seed-config macros, feature gating, hardware-dependent work). Same scope note applies. No update-manager, retention, or mutable-application-layout content found in this document (confirmed by direct keyword search — no hits for "update manager", "mutable", "namespace", "SimpleAF", "retention" as architectural topics, only one incidental "Cleanup/retention service" row about GuppyScreen's own `S45cleanup`/`cleanup-files.sh` porting, which **is** relevant and is folded into Section 1.5 below).

**Conclusion:** both documents satisfy this mission's Phase 1 instruction to read existing gap-analysis/fix-plan material, but neither substitutes for this mission's own investigation — their content is adjacent (GUI porting), not the mutable-runtime/update/retention design this mission must produce.

### 1.2 Current NebulaOS persistent-storage and bind-mount architecture (as of commit `81a4fcf`, the known-good baseline)

Read directly: `scripts/build/overlay/etc/init.d/S01persistent-datastore` (full file).

- `/usr/data` (`/dev/mmcblk0p10`, ext4, physically shared with stock) is mounted at boot by this script (not `S00`).
- Everything this build writes lives under **`/usr/data/openke/`** — the exact top-level name this mission must retire (Section 1.4).
- Only **one** persistent app-data tree currently exists: `/usr/data/openke/printer_data`, seeded once from `/opt/printer_data`'s squashfs defaults, then bind-mounted (`mount --bind`) back over `/opt/printer_data`. This is the **only** bind-mount currently in the system for application data.
- GuppyScreen's own single config file (`guppyconfig.json`) gets a **single-file bind mount** (not a directory) — the only other bind mount in the system — because GuppyScreen hardcodes its config path relative to its own binary location (`/opt/guppyscreen/guppyconfig.json`, read-only squashfs) with no override flag.
- **Klipper, Moonraker, and Mainsail themselves are not persistent at all today** — they are baked directly into the read-only squashfs at `/opt/klipper`, `/opt/moonraker`, `/usr/share/mainsail`. There is no existing bind-mount, versioning, or update mechanism for any of the three. This confirms the mission brief's own framing: Phases 3–7 are genuinely new work, not an extension of an existing partial mechanism.
- Two compatibility symlinks exist guarding against destroying real stock data on the shared partition (`/usr/data/printer_data`, `/usr/data/guppyscreen` — only created if nothing already exists at that path). This defensive pattern (never blindly overwrite existing content on the shared partition) must carry over to the new namespace-creation logic in Phase 3/4.
- **No cleanup/retention script exists anywhere in NebulaOS today** (confirmed by repo-wide `find -iname '*cleanup*'`, only hits were an unrelated dmesg artifact under `artifacts/parity/`). Phase 9's retention manager has **no existing NebulaOS implementation to extend** — it is new work, informed by stock's proven pattern (Section 1.5), not a port of an existing NebulaOS cleanup.

### 1.3 Klipper-extras provenance audit (byte-level, resolves gap-analysis open questions #4/#5)

Diffed directly (`diff`), not inferred:

| Extra | Location | Provenance | Classification |
|---|---|---|---|
| `guppy_config_helper.py` | `klippy_extras/` | **Byte-identical** to `guppyscreen/k1/k1_mods/guppy_config_helper.py` | `required-in-NebulaOS-fork` — GuppyScreen's TMC-autotune/config-CRUD panels depend on it; carried over verbatim from the GuppyScreen community-extra ecosystem, not from `pellcorp/klipper` upstream. |
| `guppy_module_loader.py` | `klippy_extras/` | **Byte-identical** to guppyscreen's copy | `required-in-NebulaOS-fork`, same reasoning. |
| `calibrate_shaper_config.py` | `klippy_extras/` | **Byte-identical** to guppyscreen's copy | `required-in-NebulaOS-fork` (blocked on host-MCU/accelerometer bring-up before it does anything useful, but the file itself is confirmed correct/unmodified). |
| `tmcstatus.py` | `klippy_extras/`, wired into `printer.cfg:41` | Near-identical to guppyscreen's own `k1/k1_mods/tmcstatus.py`, with one real fix (deferred `lookup_object` to `klippy:connect`) guppyscreen's copy lacks (per prior gap analysis, not re-verified byte-for-byte in this pass) | `required-in-NebulaOS-fork` — already wired and in production use. |
| `prtouch_v2.py` + 4 companions (`prtouch_probe.py`, `prtouch_mcu.py`, `prtouch_nozzle.py`, `prtouch_calibration.py`) | `klippy_extras/` | Clean-room rewrite (no Creality source available anywhere), 17 unit tests, **never run against real MCU firmware**, **not wired into shipped `printer.cfg`** (confirmed: `printer.cfg` header explicitly documents this as deferred) | `experimental-unsuitable` for the production-tracked branch until real-hardware validation (per `docs/PRINTER_MAINBOARD_PRECONNECTION_CHECKLIST.md`'s staged protocol) — keep present but unwired, exactly as today. |
| `z_compensate.py` | `klippy_extras/` | New design, calls into `prtouch_v2`, unwired, unvalidated | `experimental-unsuitable`, same disposition as `prtouch_v2`. |
| `gcode_shell_command.py` | **Confirmed present natively** in `vendor/klipper/klippy/extras/gcode_shell_command.py` (`pellcorp/klipper` fork itself) | Upstream, not a NebulaOS or GuppyScreen addition | `already-in-pellcorp-klipper` — resolves gap-analysis open question #4 definitively. No separate vendoring needed for anything depending on this (camera-reload macro, calibration shell-outs). |
| Adaptive bed-mesh (`patch_bed_mesh.py` target) | `vendor/klipper/klippy/extras/bed_mesh.py` | Confirmed present natively (`adaptive_margin` config option, `set_adaptive_mesh()` method, `ADAPTIVE_MARGIN` gcode param, at lines 331/453/463/475/612) | `already-in-pellcorp-klipper` — guppyscreen's `patch_bed_mesh.py` core-patcher is moot for NebulaOS, resolves gap-analysis open question #4. |
| Axis-twist wiring (`patch_probe.py` target) | `vendor/klipper/klippy/extras/probe.py` | Confirmed present natively (explicit `axis_twist_compensation` result-adjustment hook at line 366) | `already-in-pellcorp-klipper` — same resolution. |
| `custom_macro` | Referenced only as a live status object by GuppyScreen; no source in either repo | Creality-proprietary, plaintext on stock, never captured | `obsolete` for now / `NEEDS_DECISION` if GuppyScreen's 3-4 consumed fields are ever worth reimplementing — **out of this mission's scope** (this mission's brief does not ask for `custom_macro`; only listed as a minimum audit candidate because it appeared in the earlier GuppyScreen gap analysis). |

**Net effect on this mission's required Klipper-fork content (Phase 6):** every extra GuppyScreen's *currently-enabled* feature set needs (`tmcstatus`, `guppy_config_helper`, `guppy_module_loader`, `calibrate_shaper_config`, `gcode_shell_command` — already upstream) has now been confirmed either present-and-correct or present-natively-upstream. `prtouch_v2`/`z_compensate` remain correctly excluded from production wiring pending real-hardware validation — this mission does **not** change that; Phase 6 only needs to ensure these files are committed into the NebulaOS Klipper fork's own tracked git history (today they live in **this** repo's `klippy_extras/` and are copied into the vendored Klipper checkout by the build pipeline — they are not part of `vendor/klipper`'s own git history at all, which is exactly the gap this mission's Phase 6 must close).

### 1.4 `openke` naming footprint (Phase 11 input)

Repo-wide case-insensitive search (excluding `vendor/`, `.git/`, `artifacts/`) found `openke`/`OpenKE` in 33 files, spanning: top-level docs (`README.md`, `FIRMWARE.md`, `NETWORKING.md`, `ANALYSIS.md`, `DESIGN.md`, several `docs/*.md`), every numbered build script (`scripts/build/0{0-6}-*.sh`), six init scripts' own comments (`S01persistent-datastore`, `S39wifi`, `S50webcam`, `S55klipper`, `S56moonraker`, `S58guppyscreen`), `nginx.conf`, the udev rule and its helper script, three GuppyScreen-config Python scripts, `moonraker.conf`'s own header comment, `songs.conf`, `supervisorctl`, a Buildroot patch, and `.gitignore`.

The single most consequential runtime occurrence is `S01persistent-datastore`'s own `DATA_ROOT=/usr/data/openke` (Section 1.2) — this is the literal on-disk directory name this mission's Phase 11 must migrate away from, coordinated with Phase 3's new `/usr/data/nebulaos` layout (they should very likely be the same migration, not two separate renames — `NEEDS_DECISION`, but doing them together is the obvious low-risk choice: creating the new namespace at its final name from the start, with a one-time migration of the existing `printer_data` content from `/usr/data/openke/printer_data` into `/usr/data/nebulaos/printer_data`, rather than creating `/usr/data/nebulaos` now and renaming it again later).

Per the mission brief, git history is not rewritten and truthful provenance/license text is preserved — the naming-removal work is scoped to **runtime** paths/services/manifests/user-facing text only, not to historical commit messages or doc sections documenting where NebulaOS came from.

### 1.5 Stock/SimpleAF cleanup-and-retention pattern (direct upstream investigation, Phase 9 input)

Investigated `https://github.com/pellcorp/creality` directly via the GitHub API (current HEAD, 2026-07-26; repo is public, 112 stars, actively pushed same day) — **not** the guppyscreen repo's own docs, which don't contain this.

**`k1/moonraker.conf`** (SimpleAF's real, shipped Moonraker config for this exact board family) confirms the update-manager pattern this mission must replicate:
```
[update_manager]
enable_auto_refresh: False
refresh_interval: 0
enable_system_updates: False        # <- confirms "no general Linux package updater exposed", matches this mission's requirement exactly

[update_manager klipper]
channel: dev
pinned_commit: 386fde4fd38e8eda6999e58bf260eceb00051188   # <- identical pinned commit to NebulaOS's own vendored pellcorp/klipper checkout
report_anomalies: False

[update_manager moonraker]
channel: dev
pinned_commit: abd2026b90d86fb738c6619be3ceefcedee2006c

[update_manager fluidd]
type: web
channel: beta
repo: fluidd-core/fluidd
path: /usr/data/fluidd

[update_manager mainsail]
type: web
channel: beta
repo: mainsail-crew/mainsail
path: /usr/data/mainsail
```
This is real, proven, currently-shipping evidence for exactly the shape this mission asks for: Klipper/Moonraker as `channel: dev` git-checkout updates with a `pinned_commit` compatibility gate; Mainsail as `type: web`/`channel: beta` release-based updates; and `enable_system_updates: False` at the top level so Moonraker never exposes a general OS-package updater. **This mission's Phase 10 should follow this exact shape** (adjusted for NebulaOS's own fork URL and A/B path model), not invent a new one.

**`k1/services/S45cleanup`** delegates to **`tools/cleanup-files.sh`** (shared between the K1 and RPi targets) — fetched and read in full. Concrete, currently-shipping thresholds/behavior this mission's Phase 9 retention manager must compare against before designing its own emergency-gcode-cleanup path (per the mission brief's explicit requirement not to guess this):

- **RTC-before-NTP handling**: on Buildroot (`ID=buildroot` in `/etc/os-release`) only, the script records its own start timestamp and — if that timestamp is before a fixed 2025 reference date — **busy-waits** (`sleep 1s` loop) until the clock has jumped forward by more than 20 minutes (i.e., waits for NTP to actually sync) before doing any time-based (`mtime`) deletion at all. This directly matches this mission's own explicit "account for incorrect boot time before NTP sync" requirement — SimpleAF's exact mechanism (detect epoch-2025 floor, wait for a large forward jump) is the concrete pattern to adapt.
- **Emergency gcode deletion threshold**: `REMAINING_DISK < 1000` (MB) on the data partition — **only then** does it delete `.gcode` files from the shared gcodes root, and only ones with `mtime +7` (older than 7 days), only at `-maxdepth 1` (never recurses into subdirectories — would not touch a USB-mounted subtree or nested folders).
- **Deletion order/exclusions elsewhere**: rolled log files older than 7 days, **except** `moonraker.log`/`klippy.log` (NebulaOS equivalent would also need to exclude `guppyscreen.log` if one exists — SimpleAF's own list includes `grumpyscreen.log`, its GuppyScreen-fork counterpart); old `.override.bkp`/`printer-*.cfg` backup files; backup tarballs older than 7 days **with the newest one always explicitly skipped** even if it's also old (`skipped=false` sentinel pattern, "in case its the only file left"); a `pip`/`root/.cache` purge on every run to free overlay space.
- **Logging**: every deletion (or, in `--dry-run`, every planned deletion) is appended to a `cleanup.log` file at the base data directory; the log itself is truncated at the start of each run.
- **Never touches**: active uploads, USB media (no code path in this script references anything outside `$BASEDIR`, which is `/usr/data` — it never descends into a differently-mounted USB path), or the currently-active print (no print-state check exists in this script at all — **note for this mission's own design**: SimpleAF's script does not itself check print-in-progress state before deleting old gcodes; this mission's own brief explicitly requires never deleting an active print, so NebulaOS's retention manager must add an explicit print-state/active-file check that SimpleAF's own reference script does **not** have — this is a deliberate improvement, not a gap in the investigation).

**Installer-level facts also gathered from `k1/installer.sh`** (not the retention script itself, but relevant context): SimpleAF clones itself to `/usr/data/pellcorp` and refuses to run from anywhere else; Klipper lives at `/usr/data/klipper` (real git checkout) with `/usr/share/klipper` as a compatibility symlink; a Moonraker/Klipper Python venv lives at `/usr/share/klippy-env`; a bundled static `curl` binary is installed to `/usr/bin/curl` because stock has none (independent confirmation of a gap this mission's Phase 2 already knew about); the installer checks remaining disk space before proceeding and aborts below a threshold. None of this is proposed for literal reuse (NebulaOS is a flashed A/B image, not an installer-onto-stock, per the earlier gap analysis's own Section 13 conclusion) — it is recorded here only as further proven-pattern evidence for Phase 2 (tooling) and Phase 9 (retention).

### 1.6 Storage/capacity budget (Phase 1 item 11)

Measured directly (not estimated from git-clone size, which overstates on-device footprint substantially — `vendor/klipper`'s full checkout is 231MB but 205MB of that is `lib/` MCU cross-compilation toolchain content never deployed to the device; only `klippy/`+`config/` — about 4.5MB plus a ~12MB `.git` — is ever relevant on-device):

| Component | Per-version on-device footprint | Two versions (current+previous) | Basis |
|---|---|---|---|
| Klipper (git checkout, `klippy/`+`config/`, no MCU toolchain) | ~5MB + ~12MB `.git` ≈ 17MB | ~22–34MB (worktree-sharing vs. duplicate clones) | Measured (`du -sh`) against this project's own vendored checkout |
| Moonraker (git checkout) | ~1.6MB + ~1.4MB `.git` ≈ 3MB | ~6MB | Measured against this project's own vendored checkout |
| Moonraker Python venv (numpy, matplotlib, and the other pywheels already built by this project's own pipeline) | ~20–40MB | ~40–80MB | Measured: existing prebuilt `numpy-2.4.6-...whl` is 17MB; other already-built pywheels (`apprise`, `ldap3`, etc.) total ~1.7MB; a venv also needs a small amount of interpreter/site-packages overhead beyond the wheels themselves |
| Mainsail (extracted release) | ~13MB | ~26MB | Measured against this project's existing `vendor/mainsail-dist` |
| Update staging (transient, one extra full copy during an in-flight update) | up to ~40MB transient | n/a (transient, freed after activation) | Worst-case sum of one extra Klipper+Moonraker+Mainsail copy |
| Logs/backups (rotating cap, retention-managed) | budget, not measured | ~50–100MB recommended cap | Policy choice, informed by Section 1.5's stock pattern |
| Safety margin | — | ≥200MB recommended | Policy choice |

**Total estimated new footprint for the entire mutable-application architecture: roughly 150–250MB**, against the mission brief's own cited ~2.9GiB currently available on `/usr/data` (48% used of ~5.99GiB). **This is not a binding constraint** — capacity is not a blocker for this mission (no `insufficient capacity` stop condition triggered) — but the retention manager (Phase 9) should still enforce the log/backup caps above rather than relying on the large existing margin, since `/usr/data/printer_data` (~1.2GB) and shared gcode (~1.2GB) already consume roughly half the partition today and are expected to keep growing independently of this mission's own footprint.

**Reproducibility caveat carried over from the fix-plan document**: the most recent build artifact was produced from a dirty working tree (`git_dirty_main=yes` at the time that document was written). This mission's own final image should be built from a clean, tagged commit before any acceptance testing, consistent with the existing `KNOWN_GOOD_PRODUCTION_BASELINE.md` precedent.

---

## 2. Phase 6: NebulaOS Klipper fork (completed 2026-07-26)

Resolved the open decision from the original Section 2 draft: the user authorized live GitHub write access (an already-authenticated `gh` CLI session, account `coreflake1`, `repo` scope confirmed) and asked to proceed.

- Created `coreflake1/NebulaOS-klipper` as a real GitHub fork of `pellcorp/klipper` (`gh repo fork ... --fork-name NebulaOS-klipper --default-branch-only`), matching the existing `coreflake1/NebulaOS-guppyscreen` naming convention. Confirmed the fork's default branch (`jun2025`, upstream's own default — not `main`/`master`) contains the project's pinned commit `386fde4`.
- Created a `nebulaos` branch off that pinned commit in the local `vendor/klipper` checkout, copied this repo's own `klippy_extras/*.py` into `klippy/extras/`, and committed them directly into the fork's tracked history (commit `b3d5ab2`) — with per-file provenance in the commit message (community-extra vs. clean-room, matching Section 1.3's classification table). Pushed to `coreflake1/NebulaOS-klipper` (`nebulaos` branch); `origin` was left pointed at `pellcorp/klipper` upstream for future diffing, with a new `nebulaos` remote added for the fork.
- Updated `scripts/build/00-fetch-vendor-sources.sh` to clone from the fork (`coreflake1/NebulaOS-klipper.git`) pinned at commit `b3d5ab2` instead of `pellcorp/klipper.git` pinned at `386fde4` — the local `vendor/klipper` checkout already matches this exactly (verified: correct branch, correct commit, no re-clone needed).
- Removed the now-redundant `cp "$REPO_ROOT/klippy_extras/"*.py ...` step from `scripts/build/04-cross-compile-app-stack.sh` — the wholesale `cp -r "$VENDOR/klipper/klippy" ...` copy a few lines above it already carries the extras into the overlay now that they're committed into the vendored checkout itself. This is the concrete fix for the mission's own requirement that extras be "committed into the tracked branch, not injected as untracked files post-update." This repo's `klippy_extras/` directory remains the reviewable source of truth for editing these files; changes there should be re-committed into the fork's `nebulaos` branch, not just left as loose files.
- Both modified build scripts pass `bash -n` syntax-checking.

**Not yet done** (deferred, not blocking): a rebuild/reflash to prove the new fetch path produces a byte-identical (or intentionally different only in extras-location) image; that is folded into Phase 2's rebuild since both touch the same build stages.

## 3. Phase 2: rootfs tooling (completed 2026-07-26)

Added to `artifacts/buildroot-halley5-v30-image/buildroot.config`: `BR2_PACKAGE_GIT`, `BR2_PACKAGE_CA_CERTIFICATES`, `BR2_PACKAGE_RSYNC`, `BR2_PACKAGE_LIBCURL` (+`BR2_PACKAGE_LIBCURL_CURL` for the `curl` binary, +`BR2_PACKAGE_LIBCURL_OPENSSL` selecting the already-enabled OpenSSL as its TLS backend — confirmed via `package/git/git.mk:31-37` that Buildroot's own git package auto-enables `--with-curl` once `BR2_PACKAGE_LIBCURL=y`, giving git real HTTPS transport through libcurl+OpenSSL, not a bundled/insecure fallback), and `BR2_PACKAGE_LIBOPENSSL_BIN` (the OpenSSL library itself was already enabled; only the CLI binary was missing). Added `wheel==0.42.0` (pure-Python, universal wheel) to the existing pywheels download-and-flatten-into-site-packages step in `04-cross-compile-app-stack.sh`, since Buildroot's own `package/python-wheel` is host-only (`$(eval $(host-python-package))`, no target-package eval) and can't be selected as a target package at all.

Ran the pipeline (`02-configure-buildroot.sh` → `04-cross-compile-app-stack.sh` → `05-final-build.sh` → `06-verify.sh`). **Caught a real bug via this project's own "never trust exit 0 alone" discipline**: the first pass completed with exit 0 and all of `06-verify.sh`'s existing checks passed, but `openssl` was silently absent from the built squashfs despite `BR2_PACKAGE_LIBOPENSSL_BIN=y` being correctly present in the normalized `.config` — Buildroot's per-package build stamps don't automatically invalidate on a suboption-only config change to an already-built package (a known Buildroot limitation, and the same general class of "config change silently not applied" bug this project has hit before, per `02-configure-buildroot.sh`'s own header comments). Fixed by explicitly forcing `make libopenssl-dirclean && make libopenssl` inside the same `pellcorp/k1-bash-build` container (with the same host-dependency `apt-get install` list `02-configure-buildroot.sh` already uses), then re-running `05-final-build.sh` and `06-verify.sh`. Directly confirmed via `unsquashfs -l` (not just trusting the verify script) that `/usr/bin/git`, `/usr/bin/curl`, `/usr/bin/rsync`, and `/usr/bin/openssl` are all now present in the rebuilt `rootfs.squashfs`, and via `unsquashfs -d` extraction that `/usr/lib/python3.11/site-packages/wheel` (v0.42.0) and `/etc/ssl/certs/*` (CA bundle, ~cert count consistent with Mozilla's bundle via the `ca-certificates` package) are present. `06-verify.sh`'s full existing check suite re-ran clean (no MISS/FAIL lines) after the fix, confirming no regression to previously-verified functionality.

New artifact: `built_at=2026-07-26T17:41:13Z`, `git_commit_main=81a4fcf8...` (still `git_dirty_main=yes` — this mission's own source changes are not yet committed), `rootfs_squashfs_sha256=cf8e563df045c1e8a589735ab2611f9cab1631744f1815931b6c57b274a1b489`, `xImage_sha256=65c0e21401f5b4a81a945b4dec196ebf5746f3c992f6642e7ce00d7fed15f6bb` (kernel rebuilt despite no source change — Buildroot's own `olddefconfig` normalization pass evidently touched a kernel-relevant symbol; `git_dirty_kernel=no` confirms no actual kernel source drift).

**Not yet done**: proving real HTTPS (`git ls-remote https://github.com/coreflake1/NebulaOS-klipper.git HEAD`, `curl --fail --location --head https://api.github.com/`, `wget --spider https://github.com/`) requires either flashing this image to the spare slot and testing on the real device's network, or MIPS emulation of the built binaries offline — deferred to a live-device check (paired with Phase 12's own qualification pass, or sooner if useful to de-risk Phase 7 earlier) rather than assumed working from static presence alone.

## 3.1 Phase 3 pre-check: shared gcode location confirmed live (read-only device query)

Before drafting Phase 3's implementation, checked live on the real device (192.168.0.146, confirmed booted on NebulaOS custom via `uname -r` → `6.6.18-rt23` and the OTA marker → `ota:kernel2`; read-only queries only, no state change) whether `/usr/data/printer_data` — the path the mission brief names as the shared stock gcode location — is real, independent content or something NebulaOS itself created:

- `/usr/data/printer_data` is a **real, substantial, independently-owned directory** (root-owned, `readlink -f` confirms it is not a symlink), containing `certs/`, `comms/`, `config/`, `database/`, `gcodes/` (**1.2GB**, real print files with realistic names/dates), `logs/`, `misc/`, `timelapse/`, `.moonraker.uuid`, `moonraker.asvc` — this is a mature, actively-used GuppyScreen/SimpleAF-style install's own printer_data, genuinely independent of NebulaOS.
- `/usr/data/openke/printer_data` (NebulaOS's own private tree, per `S01persistent-datastore`) exists **separately** — confirming the two really are already-distinct trees today, not aliased or overlapping.
- This confirms `S01persistent-datastore`'s existing defensive guard (`[ -e /usr/data/printer_data ] || ln -s ...`) worked exactly as intended on this device: since real content already existed at that path, NebulaOS's boot never created a symlink there, leaving stock's real data untouched.
- **Net effect**: the mission's shared-gcode design (bind-mount `/usr/data/printer_data/gcodes` → `/opt/printer_data/gcodes`) is validated against real, live evidence, not an assumption — there is real, substantial content to share, and no risk of the "shared" directory actually being NebulaOS's own leftover symlink.
- Directory timestamps of `Mar 1-2 2020` seen elsewhere under `/usr/data/openke/` (e.g. `guppyscreen/`, `wpa_supplicant.conf`) are consistent with this board's confirmed RTC-before-NTP-sync behavior (`docs/NEBULAOS_RETENTION_POLICY.md` §1/§2.6) — an early-boot clock artifact, not evidence of genuinely stale content.

## 4. Pacing

Per explicit user direction, proceeding straight through the remaining phases, checkpointing at major risk points (live-device tests, anything that looks destructive) rather than after every phase. Next: **Phase 2** (add git/curl/rsync/openssl/CA-certs/unzip/tar/venv/pip/setuptools/wheel to the Buildroot rootfs and prove real HTTPS against the required GitHub endpoints) — self-contained, no device changes, matches the mission's own phase ordering, unblocks Phase 7's dependency installs and Phase 10's git-based update manager.
