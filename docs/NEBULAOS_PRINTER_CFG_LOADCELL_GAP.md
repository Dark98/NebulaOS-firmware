# Known gap: canonical printer.cfg does not yet wire in the load-cell probe

Found 2026-08-08, during the Clean-Update + Virgin Baseline mission's Phase 6
work, while tracing where `[z_compensate]`/`[prtouch_v2]` are actually
loaded from. **Not fixed in this mission** - fixing it correctly requires
pulling the real, hardware-specific config values (pin assignments,
`bed_add_temp`, wipe-pad geometry, etc.) from the live printer, and the
printer is intentionally offline for the duration of this mission (see the
mission's own Phase 9 stopping point). Documented here so it is not lost,
and so Phase 9's deployment checklist inherits it explicitly.

## The gap

`scripts/build/overlay/opt/printer_data/config/printer.cfg`'s own header
comment (still accurate as of this writing) says:

> `[prtouch_v2]` / `[z_compensate]` - Creality-specific load-cell modules,
> not present in SimpleAF's fork... wiring those in here remains real,
> separate, DEFERRED future work... this release is BLTouch-only for Z
> homing and bed mesh, on purpose.

That was correct when written. It is no longer the whole story: per project
memory (`project_loadcell_config_reconciliation.md`, 2026-08-05),
`[z_compensate]`/`[prtouch_v2]` were subsequently wired in and load-tested
**directly on the live device's persistent printer.cfg** (`/opt/klipper`
config-load + MCU-handshake test passed) - a live, on-device-only edit that
was never committed back into this repo's own tracked `printer.cfg` overlay.
The live device also has a real, working `bed_add_temp` value in its
`[z_compensate]` section (confirmed live during this session's own
diagnostic work, when a stale value of `60` briefly halted Klipper against
`z_compensate.py`'s `maxval=20` bound - the point being that a real, tuned
section with real values exists on the device, not a placeholder).

## Why this matters for this mission specifically

Phase 8 builds a "virgin candidate" from a genuinely fresh clone of this
repo, and Phase 11 requires proving a from-scratch install has **every**
accepted feature with nothing explainable only by an old persistent file.
As things stand right now, a virgin build's `printer.cfg` would NOT include
`[z_compensate]`/`[prtouch_v2]` at all - if the live device's load-cell
wiring is considered "accepted" (memory says the load test passed), then a
virgin install would currently regress it, and Phase 11's own defining test
("no accepted feature exists only as a leftover file from the previous
install") would legitimately fail on this specific point once probing/
motion is exercised.

klippy_extras/z_compensate.py and the prtouch_*.py files themselves ARE
canonical (tracked in this repo, synced to the real coreflake1/NebulaOS-
klipper fork - see Phase 5's own fix for the prtouch_v2/probe/nozzle
staleness this same investigation found). It is specifically the
**printer.cfg wiring** - the `[z_compensate]`/`[prtouch_v2]` sections
themselves, with their real tuned parameter values - that only exists on
the live device.

## Why this was not fixed now

Guessing at pin assignments, `bed_add_temp`, or wipe-pad geometry values
without pulling them from the real device would be actively dangerous (a
wrong pin/geometry value can cause real hardware collisions) - exactly the
kind of guess this project's own conventions (see `klippy_extras/z_compensate.py`'s
own header comment on this) have always refused to make. The printer is
intentionally offline for this mission's duration; this is real, necessary,
device-reachable work, not repository-only work.

## Required follow-up (Phase 9/10 territory, not yet done)

Once the printer is back online and reachable:

1. Pull the live, working `[z_compensate]`/`[prtouch_v2]` sections from the
   device's persistent `printer_data/config/printer.cfg` via read-only SSH
   (idle printer, no motion/heating involved in the read itself).
2. Commit those sections into this repo's own tracked `printer.cfg`
   overlay, replacing the "deferred" comment with the real, working
   configuration.
3. Re-run this repo's own build-time config validation (06-verify.sh's
   blank-required-option check and friends) against the newly-committed
   sections.
4. Only then does a virgin build genuinely carry this accepted feature -
   before that, treat load-cell probing as **not yet part of the canonical
   baseline**, regardless of what the currently-deployed live device does.

This document should be referenced from the Phase 9 deployment checklist as
a known, explicit, pre-existing gap - not something this mission's virgin
build silently regresses without anyone knowing why.
