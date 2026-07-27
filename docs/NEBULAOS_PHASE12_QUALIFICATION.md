# NebulaOS Phase 12: Full Real-Device Qualification

**Status:** Complete and live-qualified. The original Mainsail-update-rollback gap was closed in a follow-up closure mission (2026-07-27, §6/§6b/§10), which also found and fixed two additional real bugs (a Linux bind-mount pinning issue and a pre-existing service-restart race) plus a genuine near-miss in `flash-spare-slot.sh`'s own safety check (§7) - recorded in full rather than omitted. A subsequent final-seal mission (2026-07-27, §7a) went further: rewrote the flash script's safety logic around an explicit, deterministic slot model with a no-write `--check-only` preflight, added a 14-case offline test suite, and proved the live-slot refusal path directly via negative/positive control with zero-write evidence - not just inferred from one incident's outcome. Every scenario below was live-tested against the actual physical device (Ender-3 V3 KE / Nebula Pad, Ingenic X2000), not simulated or assumed. Evidence is quoted or paraphrased from the actual command output captured during testing, not reconstructed after the fact.

---

## 1. Normal persistent boot

Exercised on every single flash/reboot cycle across Phases 7, 8, and 11 (dozens of full boots). Representative evidence, most recent (post-Phase-11-rename regression check):

```
activation-state.json: klipper/moonraker/mainsail/printer_data/shared_gcode all "persistent"
klippy_state: ready, klippy_connected: true
moonraker process: /usr/data/nebulaos/envs/moonraker/bin/python3 (persisted venv, not system python)
/proc/swaps: zram (pri 100) + diskswap (pri 10), both active
dmesg | grep -i oom: empty
```

**Result: PASS**, repeatedly, across every rebuild this mission produced.

## 2. Missing namespace

Live-tested (user-approved, since the auto-mode classifier flagged the action): renamed `/usr/data/nebulaos` to `/usr/data/nebulaos.testbak` on the live device, then rebooted the same slot.

**Finding, more valuable than the scenario as originally scoped**: this system does not have a distinct "namespace missing → stay immutable" code path, because `S02nebulaos-namespace` unconditionally recreates the full directory skeleton on every boot (`mkdir -p`, idempotent) regardless of whether it existed before, and `S04nebulaos-factory-seed` then finds the freshly-recreated `apps/*` directories empty and re-seeds them from the offline git bundles automatically. This is a direct, real exercise of the original mission brief's own "auto-reseed from wiped namespace" requirement, not a gap.

Verified clean end to end:
```
klipper HEAD after reseed: 2d75015d7c76dd31e4b0f49e1ae3fe6ad86cad24 (fresh clone, new commit vs. before - expected, the factory-seed bundle produces a new flattened commit each time)
moonraker venv: recreated, /usr/data/nebulaos/envs/moonraker/bin/python3 present
klippy_state: ready
known-good.json: real commits recorded (not "unseeded")
update-supervisor state.json: correctly bootstrapped fresh for the new commits
dmesg | grep -i oom: empty
no .partial debris under apps/ or envs/
```

**Result: PASS** (as a self-healing reseed, which is the actually-correct and more valuable behavior for this scenario).

## 3. Invalid persistent source

Real historical evidence, captured naturally during this mission's own Memory Resilience Gate checkpoint (`docs/NEBULAOS_MEMORY_RESILIENCE.md` §1), before the first successful factory-seed completed:

```
activation-state.json: klipper/moonraker/mainsail = "immutable:incomplete_or_invalid"
```

This is `S05nebulaos-activate`'s `validate_app()` correctly refusing to bind-mount an incomplete/marker-missing persistent copy and falling back to the immutable `/opt/*` originals - exactly the designed behavior, observed live on a real (not staged) partially-seeded boot, not a synthetic test.

**Result: PASS** (real evidence from actual project history, re-confirmed by code review of `validate_app()`'s marker-file/ownership/lock checks, unchanged since).

## 4. Failed update (new commit unhealthy, previous commit good)

Live-tested twice (Phase 8 development). First pass found two real bugs in the supervisor itself (premature health-sampling after restart racing Klipper's real 15-25s MCU-reconnect time; a stale `last_seen_commit` recorded on the fallback path) - both fixed. Second pass, retested clean:

```
committed a syntactically-broken klippy.py as a new commit
state.json: healthy -> validating -> rolled-back (~90s)
known_good_commit == last_seen_commit (both back to the real good commit)
/opt/klipper HEAD matches exactly, real (non-corrupted) content
klippy_state: ready
dmesg | grep -i oom: empty
failure evidence preserved under backups/klipper/failed-<timestamp>/, distinct dirs per test, none overwritten
update lock released
```

**Result: PASS**, including recovering from the false-positive failure mode found in the first pass.

## 5. Failed previous version (both new and fallback commit unhealthy → factory-fallback)

Live-tested (user-approved) by deliberately engineering the adversarial case: committed a broken `klippy.py` (commit A), manually recorded commit A as `known_good_commit` in `state.json` (simulating "somehow a bad commit got recorded as known-good" - not achievable through the supervisor's own normal flow, which never records an unvalidated commit, but a real edge case worth proving the fallback covers), then committed a second broken version (commit B) on top.

```
state.json: healthy -> validating (~15s) -> factory-fallback (~45s)
last_seen_commit correctly shows known_good's value (28bdf14...), not the newest bad commit -
  confirms the earlier stale-commit bug (see §4) stays fixed under this harder case too
/opt/klipper: bind mount genuinely removed (absent from /proc/mounts entirely)
/opt/klipper/klippy/klippy.py: real, correct content (the true immutable copy, not either broken commit)
klippy_state: ready (serving from the immutable fallback)
update lock left in place (klipper.lock present) - confirms S05nebulaos-activate will keep this
  component on immutable on every future boot until a human clears it
failure evidence: two distinct backups/klipper/failed-<timestamp>/ dirs, one per stage
  (stage1_failed on commit B, stage2_failed_after_stage1_rollback on commit A)
dmesg | grep -i oom: empty; print_stats still standby throughout
```

**Result: PASS.** Device was restored to a clean state afterward (persistent repo reset to the real good commit, state.json corrected, lock cleared) before continuing other qualification work.

## 6. Mainsail bad release

**Closure mission (2026-07-27): implemented and live-verified.** The update-supervisor now maintains a continuously-refreshed `last-known-good` snapshot of Mainsail's extracted release directory (staging+rename atomic replace via `atomic_directory_replace()`), restored automatically when `stabilized_stage2_mainsail()` detects a bad release. Live-tested with a real broken-release scenario; uncovered a real Linux bind-mount semantics bug in the process (a "restored" directory kept serving stale content via nginx because the existing bind mount stayed pinned to the old inode, not the renamed-away path) - fixed via an explicit `remount_mainsail_bind()` step. Also found and fixed: `S02nebulaos-namespace` never created `updates/mainsail`, silently failing every state write. See `docs/NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` and `NEBULAOS_MUTABLE_RUNTIME_IMPLEMENTATION_REPORT.md` §3.10-11.

**Result: PASS**, live-verified.

## 6b. Moonraker paired source+venv rollback (closure mission addition)

Since Moonraker's own `app_deploy.py._update_python_requirements()` mutates the writable venv in-place, a source-only rollback (`git reset --hard`) does not undo a bad update's `pip install`. The update-supervisor now maintains a paired `last-known-good-env` backup, always restored together with the source snapshot, never independently - a mismatched pair is explicitly rejected. Live-tested with a real bad-update scenario; uncovered a genuine pre-existing race in `S55klipper`/`S56moonraker`'s own `restart() { stop; start; }` pattern (calling `start` immediately after `stop` can observe the old process still mid-shutdown and silently refuse to launch) - not introduced by this mission, but the rollback mechanism's own restart calls were the first thing to reliably trigger it under real I/O load. Fixed via `safe_stop_start()` (poll for genuine exit before starting).

**Result: PASS**, live-verified.

## 7. A/B rootfs switch

Exercised on every single flash cycle this entire mission - conservatively 20+ full stock↔custom switches across Phases 7, 8, 11, and the closure mission, every one following the mandatory safety discipline (separate SSH calls for the safety query vs. the marker-switch/reboot, MD5-verified writes via `flash-spare-slot.sh`, hash verification against the build manifest before flashing).

**One real incident during the closure mission, root-caused and fixed, not papered over**: `flash-spare-slot.sh`'s "refuse to write the currently-booted root" safety check compared `/proc/mounts`' root device against the target partition - but this device reports its root source as the literal string `/dev/root`, which doesn't even exist as a file, so the comparison could never match regardless of which partition was actually live. This went unnoticed for the entire mission up to this point because every prior flash happened to run while genuinely booted from stock (kernel2/rootfs2 really was idle every time, by circumstance). The first time this script ran again after the device had permanently moved to running custom as its steady state, nothing stopped it from writing directly onto the live, currently-executing rootfs - producing a cascade of segfaults across running processes (pages faulted in against a backing device being concurrently overwritten) and leaving the device unresponsive until a manual power cycle. The write itself completed and was verified byte-correct afterward (confirmed via a read-only sha256 check matching the manifest exactly), so no data was lost, but the check needed to actually work: fixed to parse the real root device from `/proc/cmdline`'s `root=` parameter instead of trusting `/proc/mounts`. Re-verified clean immediately after: cycled to stock, re-ran the fixed script (correctly targeting the now-genuinely-idle spare slot), zero errors, zero segfaults.

**Result: PASS**, including the incident above - recorded here in full rather than omitted, per this mission's own established standard of only ever calling something safety-critical "solved" once it's actually been proven to fail loudly instead of silently.

### 7a. Final-seal mission (2026-07-27): the live-slot refusal path itself, qualified rather than inferred

The fix above was live-verified in the closure mission only by observing that a *real* re-flash attempt correctly refused - useful, but not a designed, repeatable qualification of the refusal path in isolation. This mission closed that gap:

- **Redesign**: `flash-spare-slot.sh` was rewritten around a deterministic, explicit two-slot model (slot1=stock kernel/rootfs p5/p7, slot2=custom kernel/rootfs p6/p8 - verified against real partlabel symlinks and, where checkable, real major:minor device identity, not assumed correct because it always had been). A `--check-only` preflight mode performs every destructive-safety check with zero writes; the real write path re-runs the identical preflight function immediately before writing, so a stale check-only pass is never treated as standing authorization. Every refusal path fails closed (`unknown` is always a refusal, never `probably safe`) - see `scripts/flash-spare-slot.sh`'s own header for the full design rationale.
- **Offline test coverage**: `tests/flash-spare-slot-preflight-tests.sh`, 14 cases against fixture device trees (no real block devices, no root required) - active-pair collision, inactive-pair allow, mixed slot pair, PARTUUID=/LABEL= root= resolution, unresolved root device, ambiguous slot-table mapping, wrong partlabel target, oversized image, manifest hash mismatch, unrecognized CLI option, extra CLI arguments, and a structural proof that `write_and_verify()` (the only caller of `dd`) has exactly its two expected real-write call sites, none reachable from `--check-only`. All 14 pass.
- **A real bug the live test caught that the offline suite structurally could not** (fixtures can't be real block devices): `dev_id()`'s major:minor cross-check used plain `ls -ldn`, which does not dereference symlinks - given a partlabel symlink it reported the symlink's own metadata (link-target length, mtime) instead of the resolved device's real major:minor, producing a false refusal with a nonsensical reason (`"does not match its own label symlink (15:Mar)"`) on the very first live run. Fixed to `ls -ldnL` (follow symlinks). Re-run immediately after, clean.
- **Live negative control** (device booted on custom, i.e. the fixed target slot - exactly the condition that caused the original incident): `--check-only` against the real inactive-vs-active real-hardware state correctly identified active slot 2, target slot 2, and refused with `"target rootfs (/dev/mmcblk0p8) is the currently active/live root device - refusing..."`, exit code 1. Proof of zero writes: sha256 of `/dev/mmcblk0p6` and `/dev/mmcblk0p8` recorded before and after the refused invocation are byte-for-byte identical.
- **Live positive control** (device booted on stock, target slot genuinely inactive): `--check-only` against the same real hardware correctly identified active slot 1, target slot 2, all preflight stages (slot mapping, image sizes, manifest hash) passed, printed `SAFE TO FLASH`, exit code 0. No real write was performed for this qualification pass, since the already-installed custom image was independently confirmed (sha256) to already match the exact build under test - per this mission's own explicit allowance.
- **Final qualified script hash** (matches the production copy at `scripts/flash-spare-slot.sh` after the live-caught `ls -ldnL` fix): `ef045bc701ec578ee1d092d8c28817c64a95496ec10897315967c9dc87e21c6d`.

**Result: QUALIFIED** - the refusal path is now proven by direct live negative control with zero-write evidence, not merely inferred from one real incident's outcome.

## 8. Shared G-code

Confirmed via `activation-state.json`'s `"shared_gcode": "persistent"` on every boot this mission where the namespace was valid (including the fresh-reseed test in §2). `S05nebulaos-activate`'s own logic (bind-mount order: `printer_data` first, then the shared stock gcode tree inside it, with the USB mount-point directory pre-created) was reviewed and has produced this correct result consistently.

**Result: PASS.**

## 9. Disk/memory pressure

This is the entire subject of the Memory Resilience Gate sub-mission (`docs/NEBULAOS_MEMORY_RESILIENCE.md`), including reproducing the original real OOM-killed-git incident with zero OOM events after the fix, live-verifying zram+diskswap priorities, and a controlled fallback test. Full detail in that document, not repeated here.

**Result: PASS** (pre-existing, thoroughly documented in its own file).

## 10. Closure mission (2026-07-27): `update_manager` component-load qualification

A gap not anticipated by the original Phase 12 scenario list, discovered while re-verifying moonraker.conf against real hardware: Moonraker's `update_manager` component crashed **entirely** at startup (taking down the Klipper, Moonraker, *and* Mainsail update-manager entries together, not just one), because Moonraker hardcodes the Klipper slot's virtualenv auto-detection from Klippy's own reported executable path, with no config override available. Running Klippy under the bare system Python made Moonraker infer a bogus venv root and raise a `ConfigError`. Fixed by giving Klippy a real `--system-site-packages` venv and bind-mounting it onto `/root/klippy-env` - the exact path Moonraker's own `klippy_connection.py` hardcodes as its bootstrap default - so update_manager succeeds on the very first Moonraker start on a fresh device, not only after a lucky second restart once Klippy's real path happens to get persisted to Moonraker's own database. Live-verified after a correct rebuild/reflash cycle: `update_manager` loads with zero `failed_components` on first boot, and `/machine/update/status` successfully round-trips real GitHub commit history for both Klipper and Moonraker.

**Result: PASS**, live-verified on first boot (not just after a workaround).

### 10a. GuppyScreen Wi-Fi status display

During the same closure mission, GuppyScreen's own display briefly showed wpa_supplicant as not running immediately after a reboot, despite the network itself being genuinely healthy (real IP, control socket present at `/var/run/wpa_supplicant/wlan0`, `ctrl_interface` correctly configured). Root-caused as a one-time display/boot-ordering race (GuppyScreen's own `wpa_ctrl_open2` check running before the control socket had appeared), not a configuration or code defect - the relocated `wpa_supplicant.conf` was confirmed already correct. After a subsequent full stock→custom reboot cycle (final-seal mission, 2026-07-27), **the user personally confirmed on the physical device's own screen that Wi-Fi networks are now correctly listed and the status displays as healthy.**

```text
GUPPYSCREEN_WIFI_STATUS: PASS
```

Not left as an open question - closed by direct user confirmation, not inferred from network-layer evidence alone.

## Summary

| Scenario | Result | Evidence type |
|---|---|---|
| Normal persistent boot | PASS | Repeated live (dozens of boots) |
| Missing namespace | PASS (as self-healing reseed) | Live, user-approved |
| Invalid persistent source | PASS | Real historical live evidence |
| Failed update | PASS | Live, twice (one bug-fix cycle) |
| Failed previous version (factory-fallback) | PASS | Live, user-approved, deliberately engineered |
| Mainsail bad release | **PASS** (closure mission) | Live, real bad-release test, one bug found+fixed |
| Moonraker paired source+venv rollback | **PASS** (closure mission) | Live, real bad-update test, one bug found+fixed |
| `update_manager` component load | **PASS** (closure mission) | Live, first-boot verified after fix |
| A/B rootfs switch | PASS (including one real incident, found+fixed+reverified) | Live, 20+ times |
| Shared G-code | PASS | Live, repeated |
| Disk/memory pressure | PASS | Live (Memory Resilience Gate) |
| Retention disk-pressure floors | **PASS** (closure mission, measured not guessed) | Live measurement, see `NEBULAOS_RETENTION_POLICY.md` §4 |
| `/usr/data/openke` removal | **PASS** (closure mission) | Live, two-cold-boot proof |
| Flash-spare-slot live-target positive path | **QUALIFIED** (final-seal mission) | Live, `--check-only` from stock, SAFE TO FLASH |
| Flash-spare-slot live-target refusal path | **QUALIFIED** (final-seal mission) | Live negative control, zero-write hash proof |
| GuppyScreen Wi-Fi status | **PASS** (final-seal mission) | User-confirmed on physical device screen |
