# Non-Motion Validation — prtouch_v2 / z_compensate

Audit date: 2026-08-06. Scope: increase confidence in the Ender-3 V3 KE load-cell probe
reimplementation (`klippy_extras/{prtouch_mcu,prtouch_probe,prtouch_calibration,
prtouch_nozzle,prtouch_v2,z_compensate}.py`) as far as possible **without physical
movement**. No gcode was sent to the real printer during this audit; every finding below
was produced by source comparison, offline unit/property tests, and a fake-MCU harness
driving the real production code. Physical hardware was not touched.

Companion reading: `ANALYSIS.md` (original protocol trace), `DESIGN.md` (six-file layout
rationale + the 2026-08-05/06 live config-load findings), `reference/prtouch_v2_wrapper.py`
+ `reference/prtouch_v2.c` (genuine published Creality source this port is built from).

---

## Executive result

| Area | Confidence | Basis |
|---|---|---|
| Protocol encoding (config + runtime command fields) | **Verified** | Field-by-field diff against `reference/prtouch_v2_wrapper.py`'s own `.send()` calls, exercised through the real `PrtouchMCU` via a fake MCU (`test_prtouch_protocol.py`, 13 tests) |
| Configuration parity ([prtouch_v2]/[z_compensate]) | **Verified** | Real printer.cfg fixture instantiates the real `PRTouchV2`/`ZCompensate` classes; fails loud on any rejected/misrouted/defaulted-over/unread value (`test_prtouch_config.py`, 18 tests) |
| Sensor read path (`deal_avgs_prtouch`) | **Confirmed against live zero-motion hardware** | `READ_PRES` diagnostic, 4 consecutive real reads, stable baseline (~-251,500 ±150) — see `DESIGN.md`'s 2026-08-05 entry, not repeated this session |
| Runtime sequencing (arm order, poll loop, cleanup) | **Verified**, one **high-severity defect found and fixed** | Line-by-line comparison against `reference`'s `run_step_prtouch`; fake-MCU-driven state-machine tests (`test_prtouch_orchestration.py`, 16 tests) |
| Async result isolation (stale/duplicate/partial responses) | **Verified** | Buffer-reset-per-attempt + repair-path tests against the real `_repair_step_samples`/`_repair_pres_samples` (`test_prtouch_orchestration.py`) |
| Trigger math (`prtouch_calibration.py`) | **Verified** | Every stage (z-score, high-pass, low-pass, rotate-and-flatten, interpolation) diffed line-by-line against `reference`'s `cal_tri_data()`; 39 tests including property-based invariants (`test_prtouch_calibration.py`) |
| Unit conversions (mm↔steps, ticks↔seconds, timeouts) | **Verified** | Extracted to named helpers, each proven against the reference's own formula (`test_prtouch_units.py`, 16 tests) |
| Failure cleanup (mesh restore, probe recovery, safety lift) | **Verified**, one **medium-severity defect found and fixed** | Exception-injection tests at every meaningful point (`test_prtouch_orchestration.py`) |
| `z_compensate` orchestration | **Verified** (math/policy) / **inferred** (4 keys) | Coordinate math, offset sign, and persistence policy tested directly (`test_z_compensate.py`, 16 tests); `type_nozz`/`noz_pos_center`/`noz_pos_offset`/`pumpback_mm` remain **unresolved** — no reference exists anywhere for `z_compensate_wrapper.so` |
| Persistence (`CXSAVE_CONFIG` equivalence) | **Unresolved**, correctly defaulted safe | Confirmed still no evidence either way; session-only `SET_GCODE_OFFSET` remains the default, `persist_offset` opt-in only |
| The actual physical touch event | **Requires movement** | See "Remaining physical boundary" below — nothing offline can close this gap |

**128 tests, 7 files, all offline, all passing.** Two real defects found and fixed, both
via the reference-comparison discipline this audit was built around — neither would have
been caught by re-reading the port's own code in isolation.

---

## Exact findings

### 1. HIGH — no-trigger retries never lifted the toolhead back up

- **File/line**: `klippy_extras/prtouch_probe.py`, inside `_touch_probe()` — the `if not
  step_samples or not pres_samples:` branch (pre-fix: just `logging.info(...); continue`).
- **Consequence**: on a genuine no-trigger, the MCU's own step callback
  (`prtouch_v2.c` line ~207) only stops early on a real trigger — a no-trigger result means
  the *full* commanded `down_min_z` was physically executed. Klipper's own toolhead
  position tracking is never told about this raw, MCU-driven motion (it bypasses the
  normal trapq entirely), so `toolhead.get_position()[2]` kept reporting the pre-descent
  height. Without a compensating lift, every retry recomputed another full-depth descent
  from that same stale height — i.e. `retries` consecutive full blind descents stacked in
  the same direction, bounded by nothing but the stepper stalling against the bed.
- **How it was found**: not by re-reading our own port — by tracing the reference's
  `run_step_prtouch()` line-by-line and asking why its `Z_RefreshFlag`/`toolhead.set_
  position()` mechanism exists at all. It exists specifically to prevent this exact failure
  mode; our port had dropped it (correctly, per this module's own design principle — see
  below) without replacing its safety function.
- **Fix**: `_recover_after_no_trigger()` — issues a compensating upward raw-step move using
  the *known commanded* `step_cnt` (not sample-derived, since a no-trigger response is
  empty by definition) before the next attempt or before `_fail()`'s own final lift.
  Deliberately does **not** replicate the reference's `toolhead.set_position()` re-homing
  (which redefines Z=0 at the failure point) — this module's whole design principle is that
  BLTouch's Z=0 stays the one authoritative reference; silently redefining it from a failed
  touch would undermine `Z_OFFSET_CALIBRATION`'s own correction, not protect it.
- **Fixed**: yes.
- **Test proving the fix**: `test_prtouch_orchestration.py::NoTriggerTest::
  test_no_trigger_lifts_toolhead_back_before_each_retry` (asserts no two consecutive
  downward arms without an intervening upward recovery arm) and
  `test_recovery_lift_uses_full_commanded_distance_not_zero`.

### 2. MEDIUM — `safe_move_z`'s final disarm wasn't cleanup-safe

- **File/line**: `klippy_extras/prtouch_probe.py`, `safe_move_z()`.
- **Consequence**: the trailing `start_step(direction, 0, 0, 0, ...)` disarm call ran only
  if `collect_step_samples()` completed without raising. A genuine buffer-repair failure
  (`PrtouchProtocolError`, or any comms exception on the `manual_get_steps` query path)
  would skip it. `safe_move_z` is `_fail()`'s own last-resort safety lift — the one path
  specifically meant to make failures safe — so a repair failure there would both mask the
  intended `command_error` behind a lower-level protocol error *and* leave the step channel
  armed.
- **Fixed**: yes — wrapped in `try/finally`.
- **Test proving the fix**: `test_prtouch_orchestration.py::SafeMoveZCleanupTest::
  test_disarm_still_sent_when_repair_query_raises`.

### 3. LOW (informational, not fixed — behavior already correct) — `interpolate_trigger_step` never interpolates for a 2-sample buffer

- **File/line**: `klippy_extras/prtouch_calibration.py`, `interpolate_trigger_step()`.
- **Finding**: with exactly `n=2` samples, the interpolation guard `0 < step_tri_index <
  n-1` has no integer solution (would need an index strictly between 0 and 1), so the
  function always falls back to `step_values[-1]` regardless of where the trigger tick
  actually falls. Not a bug — `MAX_BUF_LEN` is fixed at 32 in real production, a 2-sample
  buffer never occurs — but non-obvious enough to pin down explicitly rather than assume.
- **Fixed**: N/A (documented, not changed).
- **Test**: `test_prtouch_calibration.py::InterpolateTriggerStepEdgeCasesTest::
  test_minimum_legal_two_samples_always_falls_back_to_last`.

### 4. Confirmed intentional deviation — `manual_get_pres` oid

- **File/line**: `klippy_extras/prtouch_mcu.py`, `_repair_pres_samples()`, vs.
  `reference/prtouch_v2_wrapper.py` line 641 (`ck_and_manual_get_pres`).
- **Finding**: the reference sends `manual_get_pres_cmd.send([self.step_oid, i])` — a real
  copy-paste bug in the published source (`manual_get_pres` is registered under `pres_oid`,
  in the `config_pres_prtouch`/`add_pres_prtouch` section). Already flagged and corrected in
  this port with an inline comment citing the exact reference line; this audit independently
  re-derived the same conclusion from the reference text rather than trusting the prior
  comment, and it holds up.
- **Fixed**: already fixed (pre-existing, re-confirmed this session).
- **Test**: `test_prtouch_protocol.py::ResponseHandlerUnmarshalTest::
  test_manual_get_pres_repair_uses_pres_oid_not_step_oid`.

### 5. Not a defect — `read_swap`/`write_swap` dead code

- The reference itself is internally inconsistent about which oid `read_swap_prtouch`
  should use across different call sites (debug/`TEST_SWAP`-only code, already out of scope
  per `DESIGN.md`). Confirmed by grep that neither `read_swap()` nor `write_swap()` is
  called anywhere in this port's production orchestration — the inconsistency is moot here.

---

## Test inventory

| File | Tests | Protects against |
|---|---|---|
| `test_prtouch_calibration.py` | 39 | Trigger-math regressions: z-score/high-pass/low-pass filter drift, flat-signal crashes, boundary outliers, offset-invariance, interpolation edge cases, malformed/mismatched array inputs |
| `test_prtouch_units.py` | 16 | Unit-conversion drift (mm↔steps, speed↔step timing, MCU ticks↔seconds, fixed-point scaling, timeout formulas) diverging from the reference's own formulas |
| `test_prtouch_protocol.py` | 13 | Wire-protocol field order/naming/scaling drift on config-time and runtime commands; response-handler unmarshal errors |
| `test_prtouch_config.py` | 18 | A real printer.cfg value being rejected, read from the wrong section, silently defaulted over, or left unconsumed (the exact three failure classes already hit live on 2026-08-05/06) |
| `test_prtouch_orchestration.py` | 16 | Success/no-trigger/timeout/retry/malformed-response/exception-cleanup regressions in the real `PrtouchProbe.touch_probe()` state machine, including the two fixed defects above |
| `test_prtouch_safety_guard.py` | 11 | The movement guard itself failing to block a real motion path, or failing to restore original behavior afterward |
| `test_z_compensate.py` | 16 | Coordinate math, offset sign, persistence-policy, and failure-cleanup regressions in `z_compensate.py`, independent of the low-level probe cycle |
| **Total** | **129** | (128 + 1 new cleanup regression test added mid-audit) |

Run everything: `python3 -m unittest discover -s klippy_extras -p "test_*.py"` from the
repo root (some files need the repo root on `sys.path` for `prtouch_v2.py`'s relative
imports — `test_prtouch_calibration.py` alone can still run standalone from within
`klippy_extras/`, unchanged from before this audit).

### New supporting infrastructure

- `klippy_extras/prtouch_test_support.py` — fake `ConfigWrapper`/`Reactor`/`MCU`/`Printer`/
  `Toolhead`/`BedMesh`/heaters, built to model the real Klipper API surface these modules
  actually call, not to mirror the modules' own internal logic. Used to exercise the *real*
  `PrtouchMCU`/`PrtouchProbe`/`PRTouchV2`/`ZCompensate` classes, not test-only rewrites of
  them.
- `klippy_extras/prtouch_units.py` — named, tested conversion helpers, extracted from
  previously-inline arithmetic in `prtouch_probe.py` (mm↔steps, speed→timing) and
  `prtouch_mcu.py` (four independently-duplicated `/ 10000.` tick conversions, one
  `sys_time_duty` scale, one fixed-point scale). Behavior verified identical to the code it
  replaced by the full existing + new test suite passing unchanged after the refactor.
- `klippy_extras/prtouch_safety_guard.py` — an opt-in, never-auto-installed context manager
  (`guard(pv2)`) that intercepts the two real choke points every motion-capable path in
  this module set funnels through (`start_step_prtouch_cmd.send()` with nonzero `step_cnt`,
  and `gcode.run_script_from_command()` for any movement/heating/persistence-capable
  command), raising `MovementBlockedError` immediately. Zero-motion diagnostics
  (`READ_PRES`, `deal_avgs_prtouch`) pass through untouched. Fails **closed** on any
  unrecognized gcode command, not open. Directly reusable against the real device (it wraps
  the same `.send`/`.run_script_from_command` interface real Klipper objects expose) for
  any future live bring-up session that wants an extra structural guarantee beyond
  discipline alone.

---

## Repository map (Phase 1 summary)

| Module | Owns | Config keys consumed | MCU commands sent |
|---|---|---|---|
| `prtouch_mcu.py` | Wire protocol, OID/pin setup, response buffering, buffer repair | `[prtouch_v2]`: `use_adc`, `pres_cnt`, `sys_time_duty`, `step_swap_pin`, `pres_swap_pin`, `pres%d_{adc,clk,sdo}_pins` | `config_step_prtouch`, `add_step_prtouch`, `config_pres_prtouch`, `add_pres_prtouch`, `start_step_prtouch`, `start_pres_prtouch`, `manual_get_steps`, `manual_get_pres`, `deal_avgs_prtouch`, `read_swap_prtouch`*, `write_swap_prtouch`* |
| `prtouch_probe.py` | Touch-probe send/poll/retry orchestration, safety lift | `[prtouch_v2]`: `tri_acq_ms`, `tri_send_ms`, `tri_need_cnt`, `cal_hftr_cut`, `cal_lftr_k1`, `tri_min_hold`, `tri_max_hold`, `tri_hftr_cut`, `tri_lftr_k1`, `speed`, `lift_speed`, `acc_ctl_mm`, `low_spd_nul`, `send_step_duty`, `probe_min_3err`, `step_base` | (via `prtouch_mcu`) |
| `prtouch_calibration.py` | Pure trigger-Z math, no MCU/reactor dependency | none | none |
| `prtouch_nozzle.py` | Wipe routine + `ClearNozzleConfig` (config-reading, separated from motion since 2026-08-06) | `clr_noz_start_x/y`, `clr_noz_len_x/y`, `pa_clr_dis_mm_x/y`, `pa_clr_down_mm`, `clr_xy_spd`, `rdy_xy_spd`, `bed_max_err`, `g29_down_min_z`, `vs_start_z_pos`, `pr_clear_probe_cnt` (owned by whichever section instantiates `ClearNozzleConfig`) | (via `prtouch_probe`) |
| `prtouch_v2.py` | Facade, gcode registration (`NOZZLE_CLEAR`, `SAFE_MOVE_Z`, `READ_PRES`) | `[prtouch_v2]`: `hot_min_temp`, `hot_max_temp`, `bed_max_temp` | (delegates) |
| `z_compensate.py` | Per-print orchestration, gcode registration (`CRTENSE_NOZZLE_CLEAR`, `Z_OFFSET_CALIBRATION`) | `[z_compensate]`: `hot_start_temp`, `hot_rub_temp`, `hot_end_temp`, `bed_add_temp`, `bl_offset`, `z_offset_down_min_z`, `vs_start_z_pos`, `tri_min_hold`, `tri_max_hold`, `speed`, `tri_expand_mm`, `pr_probe_cnt`, `type_nozz`*, `noz_pos_center`*, `noz_pos_offset`*, `pumpback_mm`*, `persist_offset`, `save_config_command` | (delegates) |

\* registered/read but not exercised by real production macros (`read_swap`/`write_swap`)
or deliberately left unwired pending evidence (`type_nozz`/`noz_pos_center`/
`noz_pos_offset`/`pumpback_mm` — see z_compensate.py's own `__init__` comment).

**State shared between the step and pressure paths**: `PrtouchMCU.step_res`/`pres_res`
(reset together via `reset_buffers()`, populated independently by two separate async
response handlers), `step_tri_time`/`pres_tri_time`/`pres_tri_chs`/`pres_buf_cnt`. No
locking needed — Klipper's reactor is single-threaded/cooperative; async callbacks only run
between `reactor.pause()` yield points, never concurrently with the code that reads these
fields.

**All paths capable of initiating real motion** (the complete set the movement guard
intercepts): `PrtouchProbe.touch_probe()` → `PrtouchMCU.start_step()`;
`PrtouchProbe.safe_move_z()` → same; `prtouch_nozzle.clear_nozzle()`'s `_move()` helper →
`gcode.run_script_from_command('G1 ...')`; `z_compensate.cmd_z_offset_calibration()`'s
positioning move → same.

---

## Protocol parity table

| Command | Reference format | Custom format | Parity | Evidence |
|---|---|---|---|---|
| `config_step_prtouch` | `oid=%d step_cnt=%d swap_pin=%s sys_time_duty=%u` | identical | ✅ | `test_prtouch_protocol.py::test_config_step_prtouch_fields` |
| `add_step_prtouch` | `oid=%d index=%d dir_pin=%s step_pin=%s dir_invert=%d step_invert=%d` | identical | ✅ | `test_add_step_prtouch_fields` |
| `config_pres_prtouch` | `oid=%d use_adc=%d pres_cnt=%d swap_pin=%s sys_time_duty=%u` | identical | ✅ | `test_config_pres_prtouch_fields` |
| `add_pres_prtouch` | `oid=%d index=%d clk_pin=%s sda_pin=%s` (clk==sda in ADC mode) | identical, including ADC-mode same-pin behavior | ✅ | `test_add_pres_prtouch_fields`, `test_adc_mode_uses_same_pin_for_clk_and_sda` |
| `start_step_prtouch` | `oid,dir,send_ms,step_cnt,step_us,acc_ctl_cnt,low_spd_nul,send_step_duty,auto_rtn` | identical field order | ✅ | `test_start_step_prtouch_field_order` |
| `start_pres_prtouch` | `oid,tri_dir,acq_ms,send_ms,need_cnt,hftr_cut*1000,lftr_k1*1000,min_hold,max_hold` | identical, same ×1000 fixed-point scaling on exactly those two fields | ✅ | `test_start_pres_prtouch_field_order_and_fixed_point_scaling` |
| `result_run_step_prtouch` | `tri_time`/`tick*` ÷10000 → seconds | identical divisor | ✅ | `test_step_response_tick_scaling` |
| `result_run_pres_prtouch` | `tri_time`/`tick_*` ÷10000, `tri_chs`/`buf_cnt` passthrough | identical | ✅ | `test_pres_response_tick_scaling_and_metadata` |
| `manual_get_steps` | oid=step_oid | identical | ✅ | (exercised throughout `test_prtouch_orchestration.py`) |
| `manual_get_pres` | oid=**step_oid (reference bug)** | oid=**pres_oid (corrected)** | ✅ deliberate deviation | `test_manual_get_pres_repair_uses_pres_oid_not_step_oid` |
| `deal_avgs_prtouch` | `oid, base_cnt` | identical | ✅ | `test_deal_avgs_prtouch_fields`; also confirmed against real hardware (`DESIGN.md`, 2026-08-05) |
| `read_swap_prtouch` / `write_swap_prtouch` | internally inconsistent oid usage across the reference's own debug-only call sites | never called by production code in this port | N/A — dead code both sides | grep confirms zero call sites in `prtouch_probe.py`/`prtouch_v2.py`/`z_compensate.py`/`prtouch_nozzle.py` |

No command was marked equivalent on name-similarity alone — every row above was checked
against the reference's actual `.send([...])` argument list, not just its declared
`lookup_command`/`lookup_query_command` format string.

---

## Remaining physical boundary

Everything above closes as much of the gap as source comparison and offline
testing can close. What's left is **exactly** the following, and none of it can be
resolved without real motion:

1. **Whether the unchanged MCU firmware actually begins both internal tasks
   (`prtouch_event()`'s step timer, `prtouch_pres_task()`'s sampling) in response to this
   port's specific `start_step_prtouch`/`start_pres_prtouch` command timing** — the fake
   MCU harness proves our *host-side* send sequence, argument encoding, and poll/response
   handling are correct; it cannot prove the *firmware* reacts to that sequence the way the
   reference's own host code's sequence does, because the fake MCU is not the firmware.
2. **Whether the real async response buffers (`result_run_step_prtouch`/
   `result_run_pres_prtouch`) actually arrive in the shape (32 samples, 4-per-message
   step / 2-per-message pres, in-order) this port's collect/repair logic assumes** — this
   was modeled from the protocol trace and matches the reference's own assumptions, but has
   never been observed from the real firmware in this project (`READ_PRES`'s successful
   live reads exercised `deal_avgs_prtouch` only, a single synchronous query-response pair,
   not the async streaming path `touch_probe()` actually depends on).
3. **Whether the real load-cell's mechanical/electrical trigger threshold (`tri_min_hold`/
   `tri_max_hold`, both this printer's actual live-tuned values) genuinely fires
   `write_swap_sta(1)` on real physical nozzle-bed contact, at the timing this port's
   `tri_z_down_spd`/`tri_hftr_cut`/`tri_lftr_k1` assume** — the live `READ_PRES` baseline
   (~-251,500, stable) proves the sensor produces a real signal at rest; it says nothing
   about the signal's behavior under an actual approaching/contacting nozzle.
4. **Whether the calculated trigger Z (`compute_trigger_z`'s output) corresponds to the
   true physical contact position** — the math is verified to reproduce the reference's
   formula exactly on synthetic data; whether that formula's real-world accuracy holds for
   *this* sensor, *this* mechanical mount, and *this* printer's actual compliance is
   unmeasurable without a real touch.
5. **Whether the 2026-08-06 no-trigger recovery fix (#1 above) behaves correctly under the
   real firmware's actual timing** — the fix's *logic* is proven via the fake-MCU harness;
   its *physical* correctness (does the compensating upward move actually clear the nozzle
   before the next attempt, given the real firmware's real step timing) is unverifiable
   without motion.

## Readiness assessment

Not a claim of physical readiness — a description of what the evidence above actually
supports. Every layer that can be verified offline now is: protocol encoding, configuration
parity, the pure trigger-math, unit conversions, the runtime state machine's logic
(including a real safety defect this audit found and fixed), and `z_compensate`'s own
orchestration policy. What is categorically unverified is the one thing this task was
explicitly scoped to leave unverified: the real-hardware behavior of an actual step-and-
sense cycle. Tests passing is not evidence about that cycle — it is evidence that the
*host-side* code this port controls behaves as designed against every protocol shape this
audit could construct. A first controlled physical probe attempt is a decision about
accepting the five items above as remaining unknowns, not a decision this report can make
on the requester's behalf.
