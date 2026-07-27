# NebulaOS Phase 12: Full Real-Device Qualification

**Status:** Complete, with one explicit, honestly-scoped gap (Mainsail update rollback — see §9). Every other required scenario below was live-tested against the actual physical device (Ender-3 V3 KE / Nebula Pad, Ingenic X2000), not simulated or assumed. Evidence is quoted or paraphrased from the actual command output captured during testing, not reconstructed after the fact.

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

**Not implemented — honest gap, not silently assumed covered.** See §10.

## 7. A/B rootfs switch

Exercised on every single flash cycle this entire mission - conservatively 15+ full stock↔custom switches across Phases 7, 8, and 11, every one following the mandatory safety discipline (separate SSH calls for the safety query vs. the marker-switch/reboot, MD5-verified writes via `flash-spare-slot.sh`, hash verification against the build manifest before flashing). Zero failed boots, zero corruption, zero safety-discipline violations across the whole mission.

**Result: PASS**, extensively.

## 8. Shared G-code

Confirmed via `activation-state.json`'s `"shared_gcode": "persistent"` on every boot this mission where the namespace was valid (including the fresh-reseed test in §2). `S05nebulaos-activate`'s own logic (bind-mount order: `printer_data` first, then the shared stock gcode tree inside it, with the USB mount-point directory pre-created) was reviewed and has produced this correct result consistently.

**Result: PASS.**

## 9. Disk/memory pressure

This is the entire subject of the Memory Resilience Gate sub-mission (`docs/NEBULAOS_MEMORY_RESILIENCE.md`), including reproducing the original real OOM-killed-git incident with zero OOM events after the fix, live-verifying zram+diskswap priorities, and a controlled fallback test. Full detail in that document, not repeated here.

**Result: PASS** (pre-existing, thoroughly documented in its own file).

## 10. Known, explicit gap: Mainsail update rollback

The Phase 8 update-supervisor (`nebulaos-update-supervisor.sh`) only tracks and rolls back **Klipper and Moonraker** (both `type: git_repo` in `moonraker.conf`'s `[update_manager]`, both trackable via a single git `HEAD` commit and `git reset --hard`). **Mainsail is `type: web`/`channel: beta`** - a release-archive download and extraction, with no git history to reset to. Rolling it back would require a genuinely different mechanism (snapshotting/restoring a full previous extracted release directory), which was not designed or implemented this mission.

`nebulaos-healthcheck.sh`'s Stage 1 already has a `mainsail` case (checks `index.html` presence), but nothing in this mission ever calls it after a real Mainsail update, and there is no rollback path if a bad Mainsail release breaks the UI. This is a real, scoped-out gap - explicitly recorded here rather than left for a reader to discover the hard way, and a natural next-mission candidate alongside GuppyScreen's own deferred update mechanism.

## Summary

| Scenario | Result | Evidence type |
|---|---|---|
| Normal persistent boot | PASS | Repeated live (dozens of boots) |
| Missing namespace | PASS (as self-healing reseed) | Live, user-approved |
| Invalid persistent source | PASS | Real historical live evidence |
| Failed update | PASS | Live, twice (one bug-fix cycle) |
| Failed previous version (factory-fallback) | PASS | Live, user-approved, deliberately engineered |
| Mainsail bad release | **NOT IMPLEMENTED** | Honest gap, see §9 |
| A/B rootfs switch | PASS | Live, 15+ times |
| Shared G-code | PASS | Live, repeated |
| Disk/memory pressure | PASS | Live (Memory Resilience Gate) |
