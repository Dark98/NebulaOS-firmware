# Load-cell first hardware test session (2026-08-09)

Live continuation of the offline load-cell safety hardening mission
(`docs/NEBULAOS_LOADCELL_SAFETY_HARDENING.md`). This session flashed the engineering package
built there, found and fixed two real deployment bugs that only surfaced on real hardware, and
ran the zero-motion sensor test the offline mission's own plan called for. **No motor-commanded
Z movement was ever issued** - every reading below either has zero motion at all, or motion the
user performed by hand/semi-auto with steppers subsequently disabled, never a Klipper `G1`/
`SAFE_MOVE_Z`/probe command.

## Deployment: two real bugs found live, both fixed

### 1. `klippy_extras/` is a mirror, not the build input

Documented in full in `NEBULAOS_LOADCELL_SAFETY_HARDENING.md`'s own "Real deployment gap"
section. Summary: the first fresh-clone build packaged and passed every check, but the actual
rootfs shipped the OLD `prtouch_probe.py` - `klippy_extras/` here is a reviewable mirror only;
the real build input is `vendor/klipper` (the separate `coreflake1/NebulaOS-klipper` repo),
pulled via `manifests/dependencies.conf`'s `KLIPPER_PIN`. Fixed by mirroring every change into
that repo (`master`, commit `4510ee652f11767b77dbab80181275e15d61c9b9`) and bumping the pin
(`NebulaOS-firmware` commit `a0698bc52fd94e220c1b3693de0e95dd6045e90e`). A second fresh-clone
build with the corrected pin verified correct via direct rootfs inspection before flashing.

### 2. `S04nebulaos-migrate` missing its executable bit

Found live, after flashing the corrected package: the persistent `/opt/klipper` tree (mounted
from `/usr/data`, shared across A/B slots - see "Architecture note" below) stayed on the OLD
pre-mission commit despite the new image's seed archive and manifest being correct.
`app-generation.json`'s `recorded_at` was a placeholder epoch date, meaning `S04nebulaos-
migrate` had never once done real work on this device - this is the first mission ever to bump
`KLIPPER_PIN`, so this was the first real boot where the script needed to fire at all.

Root cause: the script was tracked as git mode `100644` since it was first added (Final
Baseline Closure mission, 2026-08-08) - every other `S0X` init.d script is `100755`. The init
system never executed it. Confirmed by running it by hand
(`sh /etc/init.d/S04nebulaos-migrate start`), which completed successfully immediately -
`reseed_git_app`'s own verification (branch/origin/clean-tree checks) all passed on the first
try, proving the script's *logic* was always correct, only the permission bit was wrong.

Fixed in the repo (`NebulaOS-firmware` commit `d383aa2`, mode change only). **Not yet verified
through a normal fresh reflash/migration path** - today's fix was proven by one manual
invocation plus a warm reboot to re-establish the bind mount, not by a genuine second reflash
exercising the corrected executable bit end to end. Explicit open item before promoting this
build - see "Open items" below.

### Architecture note: why a rootfs flash alone didn't move `/opt/klipper`

`/opt/klipper`, `/opt/moonraker`, and `/opt/printer_data` are ext4, bind-mounted from
`/dev/mmcblk0p10` (`/usr/data`) - a single persistent partition shared across both A/B slots,
not part of the squashfs rootfs. `S04nebulaos-factory-seed` only seeds a genuinely empty
namespace; `S04nebulaos-migrate` is the *only* mechanism that updates an already-provisioned
device's persistent app tree when a pinned commit moves forward. A bind mount established at
early boot does not automatically follow a later `mv` of its source directory - after the
manual migration, `/opt/klipper` needed a reboot (which re-establishes bind mounts fresh) before
it reflected the swapped-in content, even though the underlying `/usr/data/nebulaos/apps/
klipper` was already correct on disk immediately after the migration ran.

## Physical correction: sensor mounting

Corrected live by the user, mid-session (see `[[project_loadcell_physical_mounting]]` memory
for the full record): the load cell on this printer (Ender-3 V3 KE) is mounted **under the
heated bed at the front-left corner** - the bed rests on this one flexure/strain point, read by
a small daughterboard underneath. It is **not** in the toolhead/nozzle assembly. CR Touch
(BLTouch-equivalent) handles bed mesh/leveling separately; this front-left strain gauge detects
nozzle-bed contact force for automatic Z-offset. An initial assumption of toolhead-mounting
(made answering the user's question, without basis in this repo's own docs) was wrong and
corrected before any test data was collected on the wrong assumption. This does **not** indicate
any software design flaw - see the full reasoning in memory; the control logic never assumed
sensor location.

## Live verification results (all zero-commanded-motion)

Confirmed before any of this: Klipper `ready`, Moonraker healthy (`failed_components: []`, no
warnings), GuppyScreen running, `prtouch_v2.get_status()` and `READ_PRES` both working
end-to-end on real hardware for the first time.

### Idle baseline

```
READ_PRES: ch0=-252440 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-252590 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-252489 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-252604 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-252534 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-252536 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
```

Stable, ~150-200 count noise floor. Matches the historically-documented live baseline
(~-251,500, NON_MOTION_VALIDATION.md's 2026-08-05 entry) closely, confirming the sensor and the
new `ok`-verdict plausibility guard both behave correctly against real hardware for the first
time (previously only ever exercised against synthetic fixtures offline).

### Hand press on the bed (front-left corner area), held ~8s

```
READ_PRES: ch0=-353061 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-392821 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-366798 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-364440 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-362000 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
```

Delta from baseline: roughly -100,000 to -140,000. Clear, consistently negative-going, well
above noise, no saturation.

### Release after hand press

```
READ_PRES: ch0=-251835 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-251959 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-251830 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-251873 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
```

Clean, essentially full return to baseline.

### Object placed on bed (weight unmeasured)

```
READ_PRES: ch0=-269368 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-269304 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-269465 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
```

Delta from baseline: roughly -16,800 to -16,900. Very tight spread (~160 counts) - much
steadier than the hand press, as expected for a static load with no hand-shake.

### Object removed

```
READ_PRES: ch0=-247176 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-247129 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-247167 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
```

**Residual drift found**: settled at ~-247,150, not the original ~-252,536 - a ~+5,300 (~2%)
shift, itself tight/stable (~50-count spread) but not a full return. See "Open items" below.

### Nozzle lowered to rest on the bed (semi-automatic move by the user, then steppers disabled)

```
[stepper_enable confirmed: stepper_x=false, stepper_y=false, stepper_z=false, extruder=false]
READ_PRES: ch0=-422473 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-422416 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-422284 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-422268 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
```

The strongest, steadiest signal of the session (~200-count spread despite being the largest
magnitude) - genuine static nozzle-bed contact, no hand involved. Delta from baseline: roughly
-170,000. This is the first time in this whole project's history that a real nozzle-to-bed
contact has produced a captured, positive-confirmed signal from this sensor.

### Nozzle lifted off

```
READ_PRES: ch0=-254894 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-254849 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-254908 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
READ_PRES: ch0=-254816 ch1=0 ch2=0 ch3=0 (tri_min_hold=1000 tri_max_hold=1500) ok=True
```

Residual ~-2,300 to -2,400 from original baseline (opposite sign from the object-test residual)
- tight (~90-count spread), but again not a full return. See "Open items" below.

## Result summary against the offline mission's own test-plan goals

| Goal | Result |
|---|---|
| Signal direction under nozzle force | **Confirmed, consistent** across hand press / object / real nozzle contact - always negative-going |
| Magnitude of a normal response | **Observed a range** (17k / 100-140k / 170k for the three loading methods) but **not calibrated** - none of the applied forces were measured, so there is no real force-to-counts mapping yet |
| Repeatability | **Direction repeated every time; exact-same-condition numeric repeatability not tested** (no two trials used identical, measured force) |
| Return toward baseline | **Mostly yes, with a caveat** - always recovered to within ~1-2% of baseline, but never a perfect return, and the residual's sign was not consistent (once high, once low) |
| Clipping/saturation | **None observed** - every reading stayed far under `max_baseline_abs` (5,000,000), all finite, `ok=True` throughout, zero Klipper errors |

**No stop condition was triggered** (no invalid/non-finite reading, no reading stuck far from
baseline, no MCU/Klipper error, no unexpected motion).

## Open items (explicit, not resolved this session)

1. **The residual baseline drift's cause is unknown.** ~2,300-5,300 count (~1-2%) shift after
   release, tight/stable itself but inconsistent in sign between the two trials that showed it.
   Candidates not yet distinguished: thermal drift, mechanical bed-seating effects (the user
   independently noted the four bed spacers are not all the same height, which may be relevant
   for a single-point flexure design), or a genuine, benign sensor characteristic. Needs more
   data (e.g., a longer idle-only observation window, or repeated identical-load trials) before
   concluding anything.
2. **Raw-to-filtered signal mapping remains unknown.** `tri_min_hold`/`tri_max_hold` gate the
   *filtered* (high-pass then low-pass) signal `filter_pressure_series` produces, not the raw
   `deal_avgs_prtouch` magnitude `READ_PRES` reports (see `docs/prtouch_diagnostics.md`'s own
   already-corrected caution about this same distinction, from the earlier "already-triggered
   guard" mistake). A hand press or static rest is also a different transient *shape* than a
   real motor-driven approach-and-touch. **We still cannot predict, from today's data alone,
   whether or at what point a real commanded touch-probe cycle would actually fire the
   firmware's own trigger detection.**
3. **No motor-commanded Z movement has been exercised at all** - not `SAFE_MOVE_Z`, not
   `touch_probe()`, not `Z_OFFSET_CALIBRATION`. Everything today was manual/semi-auto positioning
   with steppers subsequently disabled. The natural next step, if/when resumed, is something
   much smaller than a full calibration - e.g. a single, slow, tightly-bounded `SAFE_MOVE_Z` from
   a known-safe hover height - but this is explicitly **not decided**, only identified as the
   logical next candidate. Do not proceed to it without a fresh, explicit go-ahead.
4. **`[prtouch_v2]` (tri_min_hold=1000/max=1500) vs `[z_compensate]` (tri_min_hold=1400/max=2000)**
   were not distinguished by anything tested today - both remain equally unverified against a
   real firing threshold.
5. **`S04nebulaos-migrate`'s executable-bit fix needs a real reflash verification**, not just
   today's one manual invocation + reboot (see "Deployment" section above) - required before
   this build is promoted to a canonical baseline.
6. **`baseline_reference`/`baseline_deviation_max` (the opt-in already-triggered guard) remains
   deliberately unconfigured** - today's data is a reasonable starting point for real values
   but was explicitly not used to set them yet, per the user's own instruction mid-session.

## Device state at end of session

- Custom slot (`root=/dev/mmcblk0p8`), OTA marker confirmed forward (`ota:kernel2`) - will boot
  back into this same image on the next power-on.
- Klipper running `coreflake1/NebulaOS-klipper@4510ee652f11767b77dbab80181275e15d61c9b9`,
  `ready`. Moonraker healthy. GuppyScreen running.
- `app-generation.json` correctly recorded (`migration_version: 31ac02ff4f539ab3`).
- **Steppers disabled** (`stepper_x/y/z/extruder` all `false`) - printer physically safe, nozzle
  currently lifted clear of the bed, heaters at 0 target, `print_stats.state: standby`.
- No pending gcode, no active/paused print, no open transactions.

Safe to leave as-is indefinitely. No further action required to reach this state on a future
session - just reconnect and continue from "Open items" above.
