# Load-cell / automatic Z-offset safety hardening (2026-08-09)

Fully offline mission. The printer was never touched - no SSH, no flashing, no reboot, no
motion, no probing, no heating, no calibration. Continues the 2026-08-06 audit recorded in
`NON_MOTION_VALIDATION.md` (read that first for the protocol/config/math verification this
mission builds on rather than re-derives) and the previously-excluded no-trigger fix that had
been implemented in an out-of-sync local checkout but never reached this repo's own `main`.

Baseline: `nebulaos-canonical-baseline-2026-08-09-wifi-125`, untouched, not moved.

## Real deployment gap found: `klippy_extras/` here is a mirror, not the build input

Caught by inspecting the actual packaged rootfs after the first fresh-clone build, rather
than trusting that a correct `klippy_extras/` edit here was sufficient. It was not: the
freshly built rootfs shipped the OLD, pre-mission `prtouch_probe.py`, with none of this
mission's fixes - `04-cross-compile-app-stack.sh`'s own comment explains why:
`klippy_extras/` in this repo is "the reviewable source of truth" for these files' *content*,
but is **no longer injected at build time**. The real build input is `vendor/klipper`'s own
`klippy/extras/` - i.e. the separate `coreflake1/NebulaOS-klipper` fork, pulled by
`manifests/dependencies.conf`'s `KLIPPER_PIN`. Two of this mission's own new files
(`prtouch_units.py`, `prtouch_safety_guard.py`) didn't even exist there yet.

Fixed by mirroring every change from this mission into a real commit on
`coreflake1/NebulaOS-klipper`'s own `master` branch (commit `4510ee65`, see that repo's own
matching commit message) and bumping `KLIPPER_PIN` to it. The two repos' copies of these
files are DELIBERATELY not byte-identical in every respect: import style differs
(`NebulaOS-firmware`'s `klippy_extras/` uses `from klippy_extras import X`, matching how
`python3 -m unittest klippy_extras.test_X` resolves it from this repo's own root;
`NebulaOS-klipper`'s `klippy/extras/` uses `from . import X` / bare `import X`, matching how
`python3 -m unittest extras.test_X` from `klippy/` - or a bare standalone run from inside
`extras/` for files with no cross-module relative-import dependency - resolves it there).
Production logic is identical in both; only the import statements needed adapting, and each
side's own test suite was run and passed independently in its own real repo structure, not
just copied and assumed to work.

**Anyone doing future `klippy_extras/` work in this repo must remember this and update both
repos, or a "correct" change here will silently never reach a real device.**

## What this mission actually did

1. **Reconciled two divergent copies of the same work.** A separate local checkout
   (`~/Documents/ke-mainline-klipper`) contained real, tested fixes - a no-trigger recovery
   fix, a `safe_move_z` cleanup-safety fix, a `prtouch_units.py` refactor, an opt-in movement
   guard, and 5 new test files (129 offline tests, all passing) - that had never been merged
   into this repo's own `main`. Meanwhile `main` had independently gained its own real fixes
   (the `bed_add_temp` factory-value bound, the `z_compensate` structured status contract)
   that the other checkout never had. Neither side was simply "ahead" of the other. Both were
   read in full, diffed file-by-file against the actual pinned baseline commit, and merged
   deliberately rather than either checkout being blindly copied over the other.
2. Re-verified the Z-offset trigger math from the **firmware source itself**
   (`reference/prtouch_v2.c`), not just the host-side reference wrapper the existing tests
   compared against - see "Math verification" below for what that changed.
3. Added the additional safety hardening this mission specifically asked for, beyond what the
   2026-08-06 audit covered: a hard maximum-travel bound, a hard maximum-duration bound,
   invalid/saturated-sensor rejection, an opt-in already-triggered guard, a candidate-offset
   magnitude sanity check, and a disarm-safety gap in the lift/recovery paths that the prior
   audit's `safe_move_z` fix did not cover.
4. Added zero-motion structured diagnostics (`[prtouch_v2]`'s own `get_status()`, see
   `docs/prtouch_diagnostics.md`) and extended `READ_PRES`.

## Classification of every finding

```
KEEP_AS_IS:
  - Protocol encoding, config parity, calibration math's own algorithm (z-score/high-pass/
    low-pass/interpolation) - already verified against the reference line-by-line
    (NON_MOTION_VALIDATION.md), re-confirmed by the full test suite passing unchanged.
  - z_compensate.py's coordinate math (bed-mesh-center + bl_offset), offset sign convention
    (SET_GCODE_OFFSET applied verbatim, not inverted), and persist_offset's opt-in/session-
    only-by-default design - already correct, already tested (test_z_compensate.py).
  - The manual_get_pres oid correction (intentional deviation from a real copy-paste bug in
    the published reference) - already fixed, already tested.

FIXED_OFFLINE:
  - No-trigger retries never lifted the toolhead back up (HIGH severity - ported from the
    2026-08-06 audit, was never on this repo's own main until this mission).
  - safe_move_z's final disarm wasn't cleanup-safe against a repair-query failure (MEDIUM -
    same origin).
  - The SAME disarm-safety gap, NOT previously closed, in _lift_after_down/
    _recover_after_no_trigger's own shared _raw_lift helper - found this mission by asking
    "does every raw MCU move in this file have the same guarantee the audited one does," not
    assumed just because a sibling function got the fix.
  - _lift_after_down silently treated a negative computed "traveled" distance as "nothing to
    do" - now logs it loudly (still doesn't act on it, since there's no sane distance to lift
    by from malformed data, but a silent pass-through of clearly-corrupted data is itself a
    defect worth surfacing).
  - The offline test fixtures (test_prtouch_orchestration.py's _full_step_trace,
    test_prtouch_calibration.py's ComputeTriggerZTest) modeled the MCU's step-count field
    counting the WRONG direction (see "Math verification" below) - production code was
    already correct; only the tests' own realism was wrong, which matters because a wrong-
    direction fixture cannot catch a real sign bug in the code it's supposedly testing.
  - Missing safeguards this mission's own brief specifically asked for: maximum probing
    travel, maximum probing duration, invalid-sensor rejection, already-triggered rejection
    (structurally - see NEEDS_HARDWARE_DATA below for its threshold), and a maximum-offset-
    magnitude sanity check in z_compensate.py's own calibration command.
  - Two genuinely broken tests on main (ImportError on `prtouch_safety_guard`, which simply
    didn't exist there) are now fixed as a side effect of porting that file.

NEEDS_HARDWARE_DATA:
  - The already-triggered guard's own threshold (baseline_reference/baseline_deviation_max) -
    implemented, tested, off by default. Activating it needs real at-rest channel values from
    this specific sensor/mount, which only READ_PRES on real hardware can provide (see
    docs/prtouch_diagnostics.md's own activation steps).
  - max_baseline_abs/max_probe_travel_mm/max_probe_duration_s/max_offset_correction_mm's own
    numeric defaults - conservative, configurable, explicitly NOT physical thresholds derived
    from this specific hardware's real limits (none of which are measured yet).
  - Everything the 2026-08-06 audit already listed under "remaining physical boundary" is
    unchanged by this mission - the firmware's real timing/response-shape assumptions, the
    load cell's actual mechanical trigger behavior, and whether compute_trigger_z's output
    matches true physical contact position for this sensor/mount, are all still unverifiable
    without real motion.

BLOCKED_BY_UPSTREAM_INTERFACE:
  - None. Every safeguard and diagnostic this mission added lives entirely in
    klippy_extras/{prtouch_probe,prtouch_v2,z_compensate}.py, built from existing Klipper
    APIs (config.get*, printer.command_error, gcode.register_command, get_status()) already
    used throughout this module set. Nothing required touching Klipper core.
```

## Math verification: a real, independently-found direction bug in the TEST fixtures

`compute_trigger_z`'s formula (`trigger_z = (start_step - out_step) * mm_per_step`) was
previously verified only by diffing it against Creality's host-side reference wrapper
(`reference/prtouch_v2_wrapper.py`), which uses the identical formula - a match that proves
this port is faithful to the reference, but not that either side is physically correct,
since a bug present in the reference would just get faithfully reproduced.

This mission instead traced the `step` field back to the **firmware itself**
(`reference/prtouch_v2.c`): `step_cfg.now_steps` is initialized to the commanded pulse total
(`fix_steps`) and *decrements* every pulse (`now_steps--`); the value pushed to the FIFO the
host reads back as `step` is `now_steps / 2` - a REMAINING-pulse countdown, not a
steps-issued-so-far count. Given that, `(start_step - out_step) * mm_per_step` (where
`start_step` is the commanded total, confirmed by direct inspection of
`prtouch_probe.py`'s real call site) correctly computes distance traveled - **the production
formula was already right.**

What was wrong: every existing synthetic test fixture modeling MCU step responses
(`test_prtouch_orchestration.py`'s `_full_step_trace`, `test_prtouch_calibration.py`'s
`ComputeTriggerZTest._make_samples`) ramped the OPPOSITE direction (0 up to the commanded
total), and the one test that computed an "expected" Z value did so by re-invoking a piece of
the same formula under test rather than reasoning from physical first principles - both
individually plausible-looking choices that, combined, meant no existing test could actually
have caught a sign/direction bug in the real formula. Fixed by:

- Correcting `_full_step_trace`'s direction (now counts down, matching firmware).
- Adding `ComputeTriggerZIndependentVerificationTest`
  (`test_prtouch_calibration.py`) - builds a synthetic case with a *chosen* physical distance
  traveled, computes the expected Z from `start_pos_z - traveled` directly (never calling
  `compute_trigger_z` or any of its own helpers to derive the expected value), and asserts
  both the magnitude and, explicitly, that the result is *below* `start_pos_z` (a
  `start_step=0`-class bug would have produced a result *above* it - this is the test that
  would actually catch that class of regression).

## Transactional calibration / persistence

Audited `z_compensate.py`'s `cmd_z_offset_calibration` end to end:

- A failed `touch_probe()` call raises before `SET_GCODE_OFFSET` is ever reached - the live
  offset is untouched by construction, not by a rollback step. Proven explicitly in
  `test_z_compensate_offset_safety.py`'s `FailedCalibrationPreservesPreviousOffsetTest` (the
  gcode script log contains zero `SET_GCODE_OFFSET` calls after a failure, and a
  success-then-failure sequence leaves the successful one as the only offset command ever
  issued).
- `calibration_z_offset`/`calibration_error` are reset to `null`/cleared at the START of
  every new attempt (pre-existing, already correct - `docs/z_compensate_status_api.md`), so a
  status subscriber can never see a stale result attributed to a new, still-failing attempt.
- Repeated invocations never compound: each call's `SET_GCODE_OFFSET` carries exactly that
  call's own raw measurement, proven in `DoubleApplicationRuledOutTest` by running two
  different stub measurements back to back and confirming the second command's value is
  neither the sum nor any function of the first.
- `persist_offset`'s own `Z_OFFSET_APPLY_PROBE`/`SAVE_CONFIG` pair runs only after `complete`
  is already published - a real design choice (not this mission's own change), documented as
  intentional: the live session offset was already genuinely correct and applied before that
  point, so a later persistence failure is a separate concern from the measurement's own
  correctness.
- New this mission: `max_offset_correction_mm` (default 2mm) rejects an implausibly large
  candidate the same way the pre-existing NaN/inf check does - before it is ever applied or
  published as `"complete"`.

## Zero-motion diagnostics

See `docs/prtouch_diagnostics.md` for the full contract. Summary: `PRTouchV2.get_status()`
(new), `READ_PRES` (pre-existing, now goes through the same plausibility check a real probe
attempt would run first). Both are provably zero-motion - `read_diagnostics()` is a pure
`deal_avgs_prtouch` read with `start_step_prtouch` never in its own call graph, confirmed by a
direct test (`test_read_diagnostics_never_sends_a_step_command`).

## Test inventory (offline, all passing)

184 tests total across 12 files, run via
`python3 -m unittest discover -s klippy_extras -p "test_*.py"` from the repo root (and
`test_prtouch_units.py`/`test_prtouch_calibration.py` also standalone from within
`klippy_extras/`, per their own docstrings). Breakdown of what's new/changed this mission vs.
what was ported unchanged from the 2026-08-06 audit is in each file's own header comment.

## Not done, deliberately

Per this mission's own scope: no changes to bed-mesh behavior, no load-cell probing added to
homing, no automatic calibration added to `PRINT_START`, no changes to kernel/WiFi/display/
touch/camera/OTA/Moonraker/GuppyScreen/unrelated extras. `UPSTREAM_KLIPPER_CORE_DIFFS=NONE` -
see the final report's own verification of this.
