# ke-mainline-klipper

Standalone investigation/build for running mainline (upstream) Klipper on the Creality
Ender-3 V3 KE (Nebula Pad), **completely separate from the OpenKE/GuppyScreen project**
(`~/Documents/guppyscreen`, `ke-next`/`main` branches). Nothing here should be folded into that
repo's branches or release planning. See that project's own memory
(`project_mainline_klipper_ke_separate.md`) for the full backstory and prior research.

## Status: PAUSED (2026-07-18)

Analysis is complete and this is intentionally paused here - resume only once `ke-next`
(the separate OpenKE/GuppyScreen repo) has finished its own real-device testing. **No further
investigation is needed before resuming** - read `ANALYSIS.md` in full, then go straight to
design/implementation. See `ANALYSIS.md` §7-8 for the exact scope and next-step checklist, and
the OpenKE memory file `project_mainline_klipper_ke_separate.md`'s final "Status: PAUSED" section
for the same checklist duplicated there.

Short version of where this landed: the real, user-facing feature (per-print auto-Z-offset) is
buildable from `prtouch_v2` primitives already read completely and documented in `ANALYSIS.md`
(MCU protocol, `run_step_prtouch`, `cal_tri_data`, `clear_nozzle`, `env_self_check`) plus one small
new piece of orchestration logic - not a full 2202-line port (confirmed against the real printer
that most of that file, its own homing/bed-mesh code, is dead code in production - BLTouch owns
that), and not a binary reverse-engineering project (`z_compensate`, the one remaining closed
module, turned out to have no MCU protocol of its own - it just calls into `prtouch_v2`).

## Current focus

The load-cell/pressure-probe ("prtouch") auxiliary Z-fine-tune layer. This does **not** require
reflashing the toolhead MCU - the currently-installed (Creality) firmware already implements the
custom commands needed; a new host-side Klipper "extra" can talk to it directly, the same way
Creality's own `hx711s.py`/`dirzctl.py` do, using entirely standard Klipper host APIs
(`mcu.create_oid()`, `mcu.add_config_cmd()`, `mcu.lookup_command()`, `mcu.register_response()`).

Basic motion/homing/heating/BLTouch is a separate, already-solved problem (mainline's own
`bltouch.py` is stock and needs no new work) - and still requires the community's documented
SWD-flash path if a full mainline migration is ever pursued. This directory is only about the
prtouch/load-cell piece for now.

## Layout

- `reference/` - real source Creality published for this exact subsystem (a different printer
  line, K1, but confirmed byte-for-byte matching command signatures against our own KE's compiled
  binary via `strings`). GPLv3-licensed, copyright Creality. Fetched from
  [`CrealityOfficial/K1_Series_Klipper@e09f36e6`](https://github.com/CrealityOfficial/K1_Series_Klipper/commit/e09f36e6ada60e5467b0bef731a96263b5d8095b)
  ("open prtouch_v1 and prtouch_v2 source code"). A second copy lives in the OpenKE memory
  directory (`reference_prtouch_v2_source/`) for durability - treat these as identical, sha256
  recorded there.
  - `prtouch_v2_wrapper.py` - host-side Python, the currently-relevant generation (matches what's
    actually compiled into our KE's `prtouch_v2_wrapper.cpython-38-mipsel-linux-gnu.so`).
  - `prtouch_v2.c` - MCU firmware C source for the same commands - confirms these are implemented
    using stock Klipper firmware infra (`DECL_COMMAND`, `sched_add_timer`, `gpio_adc_sample`,
    `sendf`), not proprietary plumbing.
  - `prtouch_v1_wrapper.py` - older generation, fetched for completeness, not yet cross-checked
    against this device (which runs v2-era code).
- `klippy_extras/` - where the new, OpenKE-authored replacement module will live. Empty so far.

## License note

Everything under `reference/` is Creality's own GPLv3-licensed code, fetched from their own public
GitHub org - included here for protocol/reference purposes (reading it to understand the wire
format), not modified. Any new code we write in `klippy_extras/` is ours and should carry its own
license header (GPLv3, to stay compatible with Klipper's own licensing, since it'll need to load
into a Klipper `klippy` process either way).
