# RESOLVED: canonical printer.cfg now wires in the load-cell probe

Originally found 2026-08-08 during the Clean-Update + Virgin Baseline
mission's Phase 6 work; **fixed the same day** during the follow-on Virgin-
Baseline Fix + Rebuild mission. Kept here (renamed from "known gap" to
"resolved") as the record of what the gap was, why the original plan to fix
it turned out to be unnecessary, and where the real values came from.

## The original gap

`printer.cfg`'s own header comment used to say `[prtouch_v2]`/
`[z_compensate]` were Creality-specific modules "not present in SimpleAF's
fork... wiring those in here remains real, separate, DEFERRED future work."
That was true when written, but per project memory
(`project_loadcell_config_reconciliation.md`, 2026-08-05), both sections
were subsequently wired in and load-tested **directly on the live device's
persistent printer.cfg**, never committed back to this repo's tracked
overlay. A virgin build from this repo would not have included them at all.

The first version of this document assumed fixing it required live SSH
access to the printer to pull the real, tuned section values - and
explicitly deferred the work for that reason, since the printer was
intentionally offline for that mission's duration.

## What actually resolved it

That assumption was wrong, and the real fix needed no device access at all.
`artifacts/reference/stock-printer.cfg` - already tracked in this repo,
pulled read-only from the device's **stock** partition (not the live custom
config) - contains Creality's own genuine, factory-shipped `[prtouch_v2]`/
`[z_compensate]` sections for this exact printer model. This is exactly the
FACTORY DEFAULTS category the mission wanted (as opposed to any one unit's
own live-tuned CALIBRATION values): the same for every unit of this model,
not per-printer tuning.

Every value was independently cross-checked against a second, completely
separate source: `klippy_extras/prtouch_test_support.py`'s own
`REAL_PRTOUCH_V2_CONFIG`/`REAL_Z_COMPENSATE_CONFIG` fixtures (built from a
live SSH pull on 2026-08-06, "cross-checked against factory_printer.cfg"
per that file's own comment) - every key and value matches
`stock-printer.cfg` exactly, field for field. Two independently-derived
sources agreeing this precisely is strong confirmation these are the
correct, genuine factory values, not a guess.

Reconciled against what the current canonical code (`klippy_extras/*.py`)
actually reads via `config.get*()` - per `DESIGN.md`'s own "Config-key
reconciliation against the real device" section, which already documents
the key-by-key mapping (`speed` not `tri_z_down_spd`, `pa_clr_dis_mm_x`/`_y`
as a 2D vector, `clr_noz_start_x`'s relaxed negative bound, etc.) - both
sections now parse cleanly with zero unused-option/must-be-specified
errors, proven by `klippy_extras/test_printer_cfg_config_validation.py`
against the real, shipped `printer.cfg` file directly (not a copied
fixture).

`bl_offset: 0,27` is derived from `[bltouch]`'s own `x_offset`/`y_offset`
in this same file (0, 27) - matching `z_compensate.py`'s own module
docstring claim that these must be identical - rather than copied
separately, so the two can never silently drift apart.

## bed_add_temp: 60 - also resolved, not just accepted

The original halt this mission also investigated (`bed_add_temp: 60`
rejected by an earlier `maxval=20` bound) turned out to have a real,
evidence-based explanation, not a device misconfiguration: 60 is
Creality's own genuine factory default (confirmed via the same
`stock-printer.cfg`), and the current code's `maxval=100` correctly
accommodates it - see the reasoning comment directly on that line in
`klippy_extras/z_compensate.py`, grounded in `[heater_bed]`'s own real
`max_temp: 120` safety ceiling (enforced independently, at runtime, by
Klipper's own heater code - the config-time bound only needs to catch a
clearly unreasonable value, not replace that separate safety layer).
Regression-tested directly: `test_printer_cfg_config_validation.py`'s
`test_z_compensate_section_parses_cleanly` asserts `bed_add_temp == 60.0`
against the real file.

## Deliberately still not done

`[prtouch_v2]`/`[z_compensate]` are wired in as available, callable gcode
commands (`CRTENSE_NOZZLE_CLEAR`, `Z_OFFSET_CALIBRATION`, `NOZZLE_CLEAR`,
`SAFE_MOVE_Z`, `READ_PRES`) - **not** auto-invoked from SimpleAF's own
print-start macro flow. The real runtime probe cycle (actual toolhead
motion, touch detection) has never been exercised on this build (see
`DESIGN.md`'s own "still not verified" note) - auto-calling untested motion
from every print-start would be exactly the kind of unproven guess this
project has consistently avoided. Wiring that integration in is real,
separate, future work, requiring an actual live motion test first.

## Load-cell scope for this baseline (Final Pre-Flash Audit, 2026-08-08)

Stated explicitly, for anyone auditing what this baseline does and does not
include:

```
[z_compensate] / [prtouch_v2]:
    configured for explicit Z-offset calibration
    (commands available, config validated offline - see above)

PRINT_START integration:
    NOT REQUIRED for this baseline
    (no macro calls these commands automatically; see "Deliberately still
    not done" above)

load-cell calibration:
    NOT RUN during virgin qualification
    (no real toolhead motion has ever been exercised on this build)
```

**Uncommitted no-trigger recovery fix - EXCLUDED from this baseline.**
While auditing this area, real, uncommitted work was found in a separate
working tree (`ke-mainline-klipper`, not this repo): a genuine safety
improvement to `prtouch_probe.py`'s touch-probe retry path (undoing a full
commanded descent when the MCU reports no trigger, preventing repeated
stacked full-depth blind descents on retry - see that tree's own
`prtouch_probe.py` diff against this repo's canonical version for the
exact change). It is real, reasoned, and worth pursuing, but:

- It has never been tested against real hardware (this build's own load-cell
  probing has never been exercised at all, per the section above).
- It sits in an uncommitted, unreviewed working tree, not this project's
  canonical history.

Importing it into this baseline would violate this exact mission's own
"no dirty checkout, no unreviewed local file" rule for what counts as an
accepted module. It is **preserved separately** (left exactly where it is,
in `ke-mainline-klipper`'s own working tree - not deleted, not merged) and
requires a dedicated future review-and-hardware-qualification pass before
it can become part of any canonical baseline.
