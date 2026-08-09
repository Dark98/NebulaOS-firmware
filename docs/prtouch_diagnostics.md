# `prtouch_v2` zero-motion diagnostics and safety guards (2026-08-09)

Companion to `docs/z_compensate_status_api.md` (same status-contract pattern, applied one
layer lower - the raw load-cell probe itself, not the per-print calibration orchestration on
top of it). Added as part of the load-cell safety hardening mission; see
`NON_MOTION_VALIDATION.md` for the earlier offline audit this mission continues.

## `[prtouch_v2]`'s status contract

`PRTouchV2.get_status(eventtime)` is automatically queryable/subscribable under the
`prtouch_v2` config section name, same Klipper mechanism `z_compensate` already uses - see
that doc's "How to get it" section, unchanged here.

| Field | Type | Meaning |
|---|---|---|
| `sensor_ok` | bool or `null` | Verdict from the last real sensor reading (see below). `null` only before any reading has ever been taken this session. |
| `sensor_reason` | string or `null` | Why `sensor_ok` is `false` (or `"no reading taken yet"` before the first read); `null` when `sensor_ok` is `true`. |
| `raw` | dict or `null` | The last raw `deal_avgs_prtouch` response (`ch0`..`ch3`), or `null` if the last read attempt failed at the MCU level. |
| `tri_min_hold` / `tri_max_hold` | int | This probe's own configured trigger-sensitivity thresholds (context for `raw`, not directly compared against it by this contract - see "What this guard is not" below). |
| `max_baseline_abs` | float | The configured sanity ceiling on raw channel magnitude. |
| `max_probe_travel_mm` / `max_probe_duration_s` | float | The configured hard ceilings `touch_probe()` enforces before/during a real attempt. |
| `last_error` | string or `null` | The message from the most recent raised error (safety guard refusal or `_fail()`), cleared only by a subsequent successful `touch_probe()`/`safe_move_z()`. |

**This is a cache, not a live query.** Calling `get_status()` never itself talks to the MCU -
it returns whatever `read_diagnostics()` last observed, whether that came from an explicit
`READ_PRES` command or a real probe attempt's own pre-motion/per-attempt checks. Klipper's
subscription layer polls `get_status()` on its own schedule (potentially from a live
GuppyScreen screen), and a synchronous serial round-trip on every poll would be both wasteful
and a genuine timing risk - see `prtouch_probe.py`'s own `last_diagnostic` comment.

## `READ_PRES` (zero motion, unchanged trigger, extended response)

```
READ_PRES [BASE_CNT=<int>]
```

Still a pure `deal_avgs_prtouch` read - **no `start_step_prtouch` involved, ever, in this
command's own call graph.** As of this mission it goes through the same
`read_diagnostics()`/`_evaluate_baseline()` path `touch_probe()` itself checks before ever
arming a real descent, and its console response now reports the plausibility verdict
alongside the raw channel values, not just the raw numbers:

```
READ_PRES: ch0=-251471 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
```

## Safety guards this mission added

All are configurable in `[prtouch_v2]`, all have conservative defaults, and none require a
`printer.cfg` edit to take effect.

| Option | Default | What it does |
|---|---|---|
| `max_probe_travel_mm` | 50 (matches `[z_compensate]`'s own long-standing `z_offset_down_min_z` `maxval`) | `touch_probe()` refuses, before arming anything, if the requested `down_min_z` exceeds this - independent of whichever caller's own config bounds happen to apply. |
| `max_probe_duration_s` | 120 | Wall-clock ceiling across an entire `touch_probe()` call (all retries combined), not just the existing per-attempt timeout. |
| `max_baseline_abs` | 5,000,000 | Any raw channel magnitude beyond this is treated as invalid/saturated/disconnected sensor data and refuses to probe. Roughly 20x this project's own documented real at-rest baseline (~-251,500). |
| `baseline_reference` (4 floats) + `baseline_deviation_max` | unset (disabled) | Opt-in "already triggered before any motion" guard - see below. |

### What the "already triggered" guard is, and is not

`baseline_reference`/`baseline_deviation_max` compare the **raw** `deal_avgs_prtouch` reading
against a configured expected-at-rest reference, per channel. **Deliberately not derived from
`tri_min_hold`/`tri_max_hold`** - those threshold the *filtered* (high-pass + low-pass) delta
signal `touch_probe()`'s own real trigger detection uses (see `prtouch_calibration.py`'s
`filter_pressure_series`), not the raw magnitude, which carries a large sensor-specific DC
offset. An earlier version of this guard compared raw magnitude straight against
`tri_min_hold` and would have rejected every single real probe attempt outright - caught
before ever reaching hardware, by checking that exact scenario against this project's own
real-baseline test fixture value (`-251,471`, ~250x `tri_min_hold`'s own 1000-2000 range).

With no `baseline_reference` configured (the default), this specific guard is a documented
no-op - genuinely `NEEDS_HARDWARE_DATA`, not a fabricated threshold. To activate it once real
at-rest values are known for this specific sensor/mount:

1. Boot the engineering image, run `READ_PRES` several times with the printer completely
   untouched, and record the 4 channel values (see `ch0`..`ch3` in its response).
2. Set `baseline_reference: <ch0>, <ch1>, <ch2>, <ch3>` and a real, qualified
   `baseline_deviation_max` (how much normal thermal/electrical drift is expected at rest -
   not guessed here) in `[prtouch_v2]`.
3. Re-run `READ_PRES` - `ok=True` with the printer untouched confirms the reference and
   tolerance are sane before trusting the guard for anything else.

### `max_offset_correction_mm` (`[z_compensate]`, not `[prtouch_v2]`)

A companion sanity ceiling one layer up - see `z_compensate.py`'s own `__init__` comment.
Default 2mm: `Z_OFFSET_CALIBRATION` is documented as a per-print thermal/wear *fine-tune*, so
a multi-millimeter "correction" can only mean something went wrong upstream (a bad touch, a
corrupted measurement, a miscalibrated BLTouch reference), never genuine drift this feature
is meant to compensate. Checked after the pre-existing NaN/inf check, before the measurement
is ever applied via `SET_GCODE_OFFSET` or published as a `"complete"` status.
