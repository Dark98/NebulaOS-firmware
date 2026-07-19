# klippy_extras/ module layout — implemented 2026-07-19, not yet hardware-tested

**Status: all six files below have real, working logic now (no more `NotImplementedError`
bodies)** - implemented autonomously while `ke-next` real-device testing was in progress and the
user was away, per explicit instruction to make the SimpleAF-fork-vs-standalone-host-tree call
independently and proceed. See "What actually changed during implementation" near the end of this
file for the handful of places the real code ended up diverging from this sketch, and the repo's
top-level README's "Status" section for the current resume checklist (real-hardware validation is
the next step, deliberately not attempted without the user present - see that section for why).

Everything below this point is the original pre-implementation design sketch, kept as-is for the
reasoning trail; treat the "What actually changed" section as authoritative where the two disagree.

This sketches the file/class layout for the rewrite scoped in `ANALYSIS.md` (read that first if
you haven't - it's the source of truth for the protocol, algorithm, and real production scope this
is built from). This is a layout + signatures sketch to review before any real logic gets written,
per the "resume checklist" in the OpenKE memory file.

## The one real design decision: match Creality's existing names, or not?

Klipper maps a config section directly to a module filename: `[prtouch_v2]` in `printer.cfg` loads
`klippy/extras/prtouch_v2.py`'s `load_config()`, `[z_compensate]` loads `z_compensate.py`. The
existing `printer.cfg` already has real, live-tuned `[prtouch_v2]` and `[z_compensate]` sections
(`tri_min_hold`, `clr_noz_start_x`, `bl_offset`, etc.) and real macros (`gcode_macro.cfg`,
`custom_macro.py`) call `CRTENSE_NOZZLE_CLEAR`/`Z_OFFSET_CALIBRATION`/`Z_OFFSET_AUTO` by name.

**Recommendation: keep both the config section names and the gcode command names identical to
what's already deployed.** This makes the new module a true drop-in replacement for the two
compiled `.so` files - zero edits to `printer.cfg` or any macro file, and trivial to revert (just
swap the `.py` files back out) if something's wrong. The alternative (fresh names) would require
editing every macro that calls these commands, for no real benefit. Flagging this because it's a
real, if small, decision - not something to silently assume.

Given that, the top-level entry points are constrained to be named `prtouch_v2.py` and
`z_compensate.py`. Everything else below them is free to be organized cleanly.

## File layout

```
klippy_extras/
    prtouch_v2.py           # load_config() for [prtouch_v2] - thin facade + gcode registration
    prtouch_mcu.py          # MCU protocol: oid/config setup, raw command send, response buffering
    prtouch_calibration.py  # pure math: channel select, filtering, trigger detection, interpolation
    prtouch_probe.py        # touch-probe orchestration: send+poll+retry, calls calibration
    prtouch_nozzle.py       # nozzle-wipe routine (heat + move + probe sequence)
    z_compensate.py         # load_config() for [z_compensate] - the new orchestration piece
```

Six files instead of one 2202-line class. The split follows what ANALYSIS.md already showed was
naturally separable: MCU plumbing vs. pure math vs. algorithm orchestration vs. one-off procedures.
`prtouch_calibration.py` in particular should be usable with no MCU/reactor object at all, just
lists of numbers in and a Z value out - straightforward to test standalone against saved sample
data if we ever want to.

### `prtouch_mcu.py` — MCU protocol layer

Owns both oid channels and all raw wire traffic. Mirrors `hx711s.py`'s already-proven pattern
(`mcu.create_oid()`/`add_config_cmd()`/`lookup_command()`/`register_response()`) but combines the
step and pressure sides into one coherent object instead of two globals plus scattered handler
methods.

```python
class PrtouchMCU:
    def __init__(self, config, step_pins, pres_pins):
        # create_oid() x2, add_config_cmd() x4 (config_step_prtouch/add_step_prtouch/
        # config_pres_prtouch/add_pres_prtouch), lookup_command() for the 8 runtime commands,
        # register_response() for debug_prtouch/result_run_step_prtouch/result_run_pres_prtouch/
        # result_read_pres_prtouch
        ...

    def start_step(self, direction, step_cnt, step_us, acc_ctl_cnt, send_ms=5, auto_rtn=False):
        """start_step_prtouch - arm the MCU's step-pulse timer. step_cnt=0 stops."""

    def start_pres(self, direction, acq_ms, send_ms, need_cnt, hftr_cut, lftr_k1, min_hold, max_hold):
        """start_pres_prtouch - arm MCU-side trigger detection + sampling."""

    def stop(self):
        """Send both commands with zeroed params - the shutdown/idle state."""

    def deal_avgs(self, base_cnt=8):
        """deal_avgs_prtouch - tare/baseline the pressure channels."""

    def read_swap(self) -> bool: ...
    def write_swap(self, state: bool): ...

    def collect_step_samples(self) -> list:
        """Poll until MAX_BUF_LEN (32) samples collected or timeout; re-fetch any gaps via
        manual_get_steps (packet-loss repair, ck_and_manual_get_step-equivalent). Returns
        [{'tick': float, 'step': int, 'index': int}, ...] or raises on repeated loss."""

    def collect_pres_samples(self) -> list:
        """Same shape, manual_get_pres-equivalent repair. Returns
        [{'tick': float, 'ch0'..'ch3': int, 'index': int}, ...]."""
```

### `prtouch_calibration.py` — pure math, no hardware dependency

```python
def select_channel(toolhead_xy, mesh_min, mesh_max, tri_chs_bitmask) -> list[int]:
    """get_valid_ch-equivalent: which corner sensor(s) are geometrically nearest / were flagged
    as triggered, by distance from current XY to each of the 4 mesh corners."""

def filter_pressure_samples(raw_samples, use_adc, hftr_cut, lftr_k1) -> list[float]:
    """z-score outlier rejection + high-pass + low-pass filter, matching the firmware's own
    filter_datas_prtouch() math so host and MCU agree."""

def find_trigger_index(filtered_samples) -> int:
    """The normalize-to-[0,1] -> atan tilt angle -> rotate by -angle -> take-minimum trick
    (cal_tri_data, ANALYSIS.md §4). Robust to slow signal drift."""

def interpolate_trigger_z(step_samples, pres_samples, trigger_tick, start_step, start_pos_z,
                           mm_per_step, z_offset=0.0) -> float:
    """Linear-interpolate step position at the pressure trigger tick, convert to an absolute Z."""

def compute_trigger_z(step_samples, pres_samples, start_step, start_pos_z, mm_per_step,
                       toolhead_xy, mesh_min, mesh_max, tri_chs, use_adc, hftr_cut, lftr_k1,
                       z_offset=0.0) -> float:
    """Top-level entry point tying the above together - one call per probe cycle, averaged
    across however many channels were valid. This is the direct cal_tri_data() replacement."""
```

### `prtouch_probe.py` — touch-detection orchestration

```python
class PrtouchProbe:
    def __init__(self, mcu: PrtouchMCU, toolhead, bed_mesh, config):
        ...

    def touch_probe(self, down_min_z, tolerance, retries=3, consistent_needed=3) -> float:
        """run_step_prtouch-equivalent: send start_step+start_pres concurrently, poll both
        buffers, call prtouch_calibration.compute_trigger_z(), retry with Z-zero
        self-correction on a no-trigger, average/median over `consistent_needed` agreeing
        samples within `tolerance`. Raises on repeated failure (mirrors ck_and_raise_error's
        real error codes, at minimum PR_NOT_TRIGGER/STEP_LOST/PRES_LOST)."""

    def safe_move_z(self, direction, distance, speed): ...
        """Non-probing raw Z move via the same step command, for the 'always lift 5mm before
        raising an error' safety courtesy and general manual moves."""
```

`env_self_check`'s 5-stage sensor self-test is deliberately **not** in this file for v1 - per
ANALYSIS.md §7/§8, it's only ever called from `run_G28_Z` (confirmed dead code in real production)
and the standalone `SELF_CHECK_PRTOUCH` diagnostic command. Worth having eventually as a manual
diagnostic, but it doesn't block the real feature. Flag if you want it pulled forward.

### `prtouch_nozzle.py` — nozzle-wipe routine

```python
def clear_nozzle(probe: PrtouchProbe, toolhead, heaters, config,
                  hot_min_temp, hot_max_temp, bed_max_temp) -> None:
    """clear_nozzle()-equivalent (ANALYSIS.md §4): heat bed/nozzle, probe two randomized XY
    points on the wipe pad via probe.touch_probe() to find local Z at each, drag the nozzle
    between them at wipe temp, cool down. Config-driven (clr_noz_start_x/y, clr_noz_len_x/y,
    pa_clr_dis_mm_x/y - already live in printer.cfg's [z_compensate] section)."""
```

### `z_compensate.py` — the new piece, config section `[z_compensate]`

This is the one genuinely new design, not a port (no source exists for Creality's real
`z_compensate_wrapper.so`) - built from confirmed evidence in `ANALYSIS.md` §7: it calls straight
into `prtouch_v2`'s primitives via `lookup_object`, no MCU protocol of its own, and `bl_offset`
matches BLTouch's own `y_offset` exactly.

```python
class ZCompensate:
    def __init__(self, config):
        self.prtouch = None  # resolved via self.printer.lookup_object('prtouch_v2') at connect
        self.probe = None    # resolved via self.printer.lookup_object('probe') (BLTouch) at connect
        self.gcode.register_command('CRTENSE_NOZZLE_CLEAR', self.cmd_nozzle_clear)
        self.gcode.register_command('Z_OFFSET_CALIBRATION', self.cmd_z_offset_calibration)
        self.gcode.register_command('Z_OFFSET_AUTO', self.cmd_z_offset_auto)  # alias, TBD if distinct

    def cmd_nozzle_clear(self, gcmd):
        """Reads HOT_START_TEMP/HOT_RUB_TEMP/BED_ADDTEMP params (matches the real
        custom_macro.py call site exactly), delegates to prtouch_nozzle.clear_nozzle()."""

    def cmd_z_offset_calibration(self, gcmd):
        """NEW logic, design not yet final: touch-probe at the point BLTouch already homed
        (current XY, adjusted by bl_offset), diff the result against self.probe's current
        z_offset, apply the correction - almost certainly via gcode 'Z_OFFSET_APPLY_PROBE'
        (stock Klipper, confirmed present in z_compensate_wrapper.so's strings)."""
```

## What's deliberately out of scope (confirmed dead code in real production, ANALYSIS.md §7)

- `run_G28_Z`/`run_G29_Z`/`bed_mesh_post_proc`/`run_re_g29s`/`correct_bed_mesh_data` and everything
  they depend on - the real `G29` macro never calls into `prtouch_v2` for homing or bed-mesh at all,
  BLTouch owns both. Roughly 500 of the original 2202 lines, not needed.
- Most of the diagnostic gcode commands (`TEST_PRTH`, `TRIG_TEST`, `TRIG_BED_TEST`, `READ_PRES`,
  `DEAL_AVGS`, `TEST_SWAP`) - useful for bring-up/debugging but not load-bearing for the real
  feature. Worth keeping *some* of these eventually (they're cheap and genuinely useful for
  verifying the rewrite works before trusting it), but not blocking v1.

## Rough size estimate

Maybe 500-700 lines total across the six files for a working v1 (protocol + touch-probe + nozzle
clear + the new z-offset orchestration), versus 2202 in the original - most of the reduction is the
confirmed-dead bed-mesh/homing code, plus not carrying over Creality's debug scaffolding (UDP
waveform streaming, the commented-out TEST_PRTH scratch command, extensive `print_msg` logging).

## Decisions made autonomously during implementation (2026-07-19)

All three items below were flagged in the pre-implementation draft as "not decided yet." The user
was away and had pre-approved making these calls per the stated leaning rather than blocking on
them; all three were taken as stated:

1. **Keep Creality's exact config-section and gcode-command names** - done. `[prtouch_v2]`,
   `[z_compensate]`, `NOZZLE_CLEAR`, `SAFE_MOVE_Z`, `CRTENSE_NOZZLE_CLEAR`, `Z_OFFSET_CALIBRATION`
   all match the deployed `printer.cfg`/macros exactly - true drop-in, zero config edits needed.
2. **`Z_OFFSET_AUTO` skipped for v1** - not registered. Nothing in this printer's real macros
   calls it (ANALYSIS.md §7/this file above); add it later only if something turns out to need it.
3. **Plain `command_error` instead of Creality's `PR_ERR_CODE_*` catalog** - done, in
   `prtouch_probe.py`'s `_fail()`. Every raised error is a plain descriptive `command_error`, not
   a `key5xx`-coded lookup table.

## What actually changed during implementation vs. this sketch

- **`select_channel`'s signature dropped `toolhead_xy`/`mesh_min`/`mesh_max`.** Reading
  `cal_tri_data()`/`get_valid_ch()` completely (not just the excerpt this sketch was written
  against) showed the geometric corner-distance calculation only feeds a debug "nearest channel"
  log line - the actual channel-averaging loop uses every channel whose trigger bit is set,
  regardless of distance. `prtouch_calibration.select_valid_channels(tri_chs_bitmask, pres_cnt)`
  needs only the bitmask. Renamed from `select_channel` to `select_valid_channels` to match.
- **`interpolate_trigger_z` split into two functions**: `find_trigger_index()` (locates the
  trigger sample within one channel's filtered series) and `interpolate_trigger_step()` (linear
  interpolation at that tick) - `compute_trigger_z()` in `prtouch_calibration.py` ties both
  together per-channel and averages, same overall shape as the original sketch, just factored so
  each piece is independently unit-testable (see `test_prtouch_calibration.py`, 17 tests, all
  passing against synthetic data - no hardware needed for this part).
- **`prtouch_probe.py`'s `touch_probe()` suspends the active bed mesh for the probe's duration** -
  not mentioned in this sketch, but the original `run_step_prtouch()`/`cal_tri_data()` always
  probe with the mesh cleared (`bed_mesh.set_mesh(None)`), since a loaded mesh applies a Z
  transform to every toolhead move that would skew a raw touch-probe reading. Missing this would
  have been a real correctness bug, not a style simplification.
- **`prtouch_nozzle.py` gained a small `NozzleHeaters` helper class** (temperature set/wait-for-
  target on the extruder and bed heaters) that this sketch's plain-function signature implied but
  didn't spell out - built once at `klippy:connect` and passed into `clear_nozzle()`, not global
  mutable state.
- **`z_compensate.py`'s `cmd_z_offset_calibration()` design is now concrete**, not just "design
  not final" - verified the exact sign convention against `pellcorp/klipper`'s real `probe.py`
  (`Z_OFFSET_APPLY_PROBE`: `new_calibrate = z_offset - offset`, where `offset` comes from
  `SET_GCODE_OFFSET`'s accumulated `homing_origin.z`). Net result: the raw `touch_probe()`
  reading at the BLTouch-homed point (adjusted by `bl_offset`) can be applied directly via
  `SET_GCODE_OFFSET Z=<measured_z>` with no extra transform. **New, deliberate design decision
  not in the original sketch**: since real production calls `Z_OFFSET_CALIBRATION` once *per
  print* (not once at factory calibration time - `custom_macro.py`'s
  `CX_PRINT_LEVELING_CALIBRATION` sequence, ANALYSIS.md §7), baking the correction into the saved
  `z_offset` via stock Klipper's `Z_OFFSET_APPLY_PROBE` + `SAVE_CONFIG` would trigger a klippy
  restart in the middle of a print-start sequence - clearly wrong. So by default the module only
  applies the correction as a live per-session `SET_GCODE_OFFSET`; permanent persistence is
  opt-in (`persist_offset` config flag) and needs a real non-restarting save command for
  whichever environment this runs under (Creality's own stock image has a restart-free
  `CXSAVE_CONFIG` for exactly this reason - whether pellcorp's SimpleAF environment has an
  equivalent is unconfirmed, a real open item, not assumed either way - see README.md's Todo).
- **`prtouch_mcu.py`'s constructor signature changed from `(config, step_pins, pres_pins)` to
  just `(config)`** - it reads its own pins directly from the `[prtouch_v2]` config section
  (mirrors exactly how the original `PRTouchEndstopWrapper.__init__` does it), rather than
  expecting the caller to have already parsed them.

## Deliberately dropped for v1 (flagged, not silently omitted)

- `set_step_par`'s temporary max-velocity/accel override during a nozzle wipe (wipe-speed
  optimization only, not correctness-critical as long as `clr_xy_spd`/`rdy_xy_spd` stay under the
  printer's own configured `max_velocity`).
- `nozzle_clear_z_out_of_range`'s Z-reference-reset retry path (only matters if the wipe pad sits
  implausibly close to `position_min` - a config problem worth surfacing directly, not silently
  working around).
- `env_self_check()`'s 5-stage sensor self-test, and the full diagnostic gcode set (`TEST_PRTH`,
  `TRIG_TEST`, `TRIG_BED_TEST`, `READ_PRES`, `DEAL_AVGS`, `TEST_SWAP`) - per ANALYSIS.md §7/§8,
  only reachable from the confirmed-dead `run_G28_Z` path or manual bring-up; cheap to add later,
  not blocking the real feature.
- `run_G28_Z`/`run_G29_Z`/`bed_mesh_post_proc`/`run_re_g29s`/`correct_bed_mesh_data` and their
  gcode entry points (`CHECK_BED_MESH`, `ACCURATE_HOME_Z`, `PRTOUCH_READY`) - confirmed dead code
  in real production, BLTouch owns homing/bed-mesh (ANALYSIS.md §7).
- `run_step_prtouch`'s `Z_RefreshFlag` re-home-on-no-trigger branch, `fast_probe`'s
  `lost_min_cnt` bookkeeping, and the `re_g28` auto-rehome path - all exist in the original to
  serve the now-dead `run_G28_Z`/bed-mesh paths above. `prtouch_probe.py`'s `touch_probe()` only
  needs to serve `clear_nozzle()` and `Z_OFFSET_CALIBRATION`, both of which probe with BLTouch
  already homed and a known-good Z reference - a no-trigger there is a real failure to surface
  via `command_error`, not a homing state to silently repair.
