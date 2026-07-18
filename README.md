# ke-mainline-klipper

Standalone investigation/build for running mainline (upstream) Klipper on the Creality
Ender-3 V3 KE (Nebula Pad), **completely separate from the OpenKE/GuppyScreen project**
(`~/Documents/guppyscreen`, `ke-next`/`main` branches). Nothing here should be folded into that
repo's branches or release planning. See that project's own memory
(`project_mainline_klipper_ke_separate.md`) for the full backstory and prior research.

## Status: PAUSED (2026-07-18), scope corrected the same day - read this before anything else

**Correction, same day as the pause above**: the standing assumption that a full mainline-Klipper
migration needs an SWD reflash was wrong. [pellcorp's SimpleAF](https://github.com/pellcorp/creality)
already runs a custom, mainline-adjacent Klipper build on this exact printer (Ender 3 V3 KE is an
explicitly supported target) with **zero SWD, zero soldering** - via a reverse-engineered serial
in-application-programming protocol (`k1/mcu_util.py` in that repo) that flashes custom firmware
over the same serial line Klipper already uses. SimpleAF's own FAQ is explicit that dropping
load-cell probe support was a choice, not a limitation: *"There are no plans to support load cells
in simple af."* Full correction with sources: the OpenKE memory file
`project_mainline_klipper_ke_separate.md`'s "CORRECTED 2026-07-18" section (near the top).

**What this changes**: this workspace's actual job is best described as **"SimpleAF + the probe."**
Everything analyzed/designed here (protocol, algorithm, module skeleton) is still exactly right and
still needed - it's the one piece SimpleAF deliberately doesn't provide. What's newly open: whether
`klippy_extras/`'s design should target SimpleAF's own environment directly (their Klipper fork,
their config/mount conventions) rather than a hypothetical standalone host tree - not yet
researched, flagged as the next real question once work resumes.

Still paused until `ke-next` (the separate OpenKE/GuppyScreen repo) finishes its own real-device
testing.

## The end-user story (why this project exists, in plain terms)

Today, this printer is stuck on Creality's own frozen, unmaintained Klipper fork - any fix or
feature that lands in the real Klipper project doesn't reach this printer unless someone manually
re-ports it. SimpleAF is a real, working way off that dead end onto an actively-maintained,
mainline-adjacent Klipper build - but today, choosing it means giving up the built-in load-cell
auto-Z-tune entirely: either do a fully manual Z-offset check before every print, or buy and
physically install a separate aftermarket probe (Klicky, Cartographer, etc.).

**What this project delivers to an end user**: everything SimpleAF already gives you (a maintained
Klipper base instead of an abandoned vendor fork) *plus* the exact same day-to-day experience the
stock firmware already provides - the printer auto-probes and fine-tunes its own Z-offset before
each print, using the load cell already built into the machine, no new hardware, no lost
convenience. Today those two things (real Klipper vs. keep your auto-probe) are mutually exclusive
on this printer; closing that gap is the entire point.

## GuppyScreen/OpenKE also needs adapting - new, real scope item, not yet started

**Confirmed 2026-07-18: an end user on "SimpleAF + this probe module" would also need an adapted
GuppyScreen, not stock OpenKE as-is.** OpenKE's GuppyScreen (`~/Documents/guppyscreen`, `ke-next`)
talks to the Moonraker/Klipper API the same way regardless of which Klipper fork is underneath, but
it's currently built, tested, and released assuming Creality's stock software environment (their
init system, their file layout, their specific `printer.cfg` conventions, their bundled
Moonraker/nginx/etc - see the OpenKE memory's `project_moonraker_nginx_dependency.md` and
`project_ke_deploy.md` for how deep that assumption runs). SimpleAF's environment is genuinely
different (their own install layout, config conventions, service management).

**Open question, not yet researched or decided**: pellcorp (SimpleAF's author) already maintains
their own GuppyScreen fork, **"grumpyscreen"** (see the OpenKE memory's
`reference_pellcorp_grumpyscreen.md` - already a known sibling project, we've shared touchscreen
commits with them before). The real options for whoever picks this up:
1. Point end users at pellcorp's existing `grumpyscreen` for the UI layer, and only ship our own
   prtouch/z_compensate module as an add-on to their environment - least new work, but means the
   UI experience isn't OpenKE's own and any OpenKE-specific feature work doesn't reach these users.
2. Adapt OpenKE's own GuppyScreen to run on SimpleAF's environment directly - more work, keeps
   OpenKE's own UI/feature set, but is real, unscoped porting effort (how much of `ke-next`'s
   install/deploy assumptions break under SimpleAF's layout is completely unknown right now).
3. Some hybrid (upstream useful pieces between the two projects) - not explored at all.

None of this is decided or researched beyond noting it exists. Whoever resumes this project should
treat "which UI approach" as a real open design question, not something to assume an answer to.

## Current focus

The load-cell/pressure-probe ("prtouch") auxiliary Z-fine-tune layer - the one thing SimpleAF
doesn't provide. Building it doesn't require reflashing the toolhead MCU either way: the
currently-installed (Creality) firmware already implements the custom commands needed, and a new
host-side Klipper "extra" can talk to it directly, the same way Creality's own
`hx711s.py`/`dirzctl.py` do, using entirely standard Klipper host APIs (`mcu.create_oid()`,
`mcu.add_config_cmd()`, `mcu.lookup_command()`, `mcu.register_response()`).

Basic motion/homing/heating/BLTouch is a separate, already-solved problem either way - mainline's
own `bltouch.py` is stock, and SimpleAF already provides a complete working base for everything
except this probe layer, with no SWD required.

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
- `klippy_extras/` - the new, OpenKE-authored replacement module. Six files
  (`prtouch_v2.py`/`prtouch_mcu.py`/`prtouch_calibration.py`/`prtouch_probe.py`/
  `prtouch_nozzle.py`/`z_compensate.py`), currently skeletons only - signatures and docstrings,
  `raise NotImplementedError` bodies, no real logic yet. See `DESIGN.md` for the layout rationale.
- `ANALYSIS.md` - complete protocol + algorithm write-up, both reference source files read in full,
  real production scope confirmed against the live printer. The technical source of truth.
- `DESIGN.md` - the `klippy_extras/` module layout sketch, including the one real naming-
  compatibility decision and two smaller open questions, all flagged for confirmation before real
  implementation starts.

## License note

Everything under `reference/` is Creality's own GPLv3-licensed code, fetched from their own public
GitHub org - included here for protocol/reference purposes (reading it to understand the wire
format), not modified. Any new code we write in `klippy_extras/` is ours and should carry its own
license header (GPLv3, to stay compatible with Klipper's own licensing, since it'll need to load
into a Klipper `klippy` process either way).
