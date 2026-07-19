# ke-mainline-klipper

Standalone investigation/build workspace for this printer's underlying platform (Klipper fork,
kernel, OS), **completely separate from the OpenKE/GuppyScreen project**
(`~/Documents/guppyscreen`, `ke-next`/`main` branches). Nothing here should be folded into that
repo's branches or release planning.

## Three tracks (as of 2026-07-18)

1. **Mainline Klipper + load-cell probe** - see "Status" and "Current focus" below, plus
   `ANALYSIS.md`/`DESIGN.md`. Goal: "SimpleAF + the probe" (SimpleAF's own framing, see below).
   PAUSED, resume after `ke-next` testing. Memory: `project_mainline_klipper_ke_separate.md`.
2. **USB-ethernet adapter compatibility** - see `NETWORKING.md`. Motivated by poor WiFi
   reliability. Fully scoped, not started - the fix now lives inside track 3's Phase 1 (see below).
   Memory: `project_ke_platform_networking.md`.
3. **Build our own firmware package (kernel + OS)** - see `FIRMWARE.md`, the source-of-truth doc
   for this track, kept up to date as work continues (edit it in place rather than creating new
   dated files - `git log` on this file already gives the chronological trail if ever needed).
   The big underlying question both track 2 needed and the user asked directly: how hard would a
   real custom kernel/OS be, not just a driver or a Klipper module. **Phase 0 (research/source
   acquisition) is essentially complete** - real vendor documentation was found in the OpenKE
   workspace's `docs hw/` directory, an exact-matching kernel source was found on GitHub and cloned
   into `vendor/` (gitignored), the real partition table was parsed, and the chip's silicon-level
   recovery mode is fully documented. Phase 1 (build + test the ethernet driver as first proof) is
   the ready next step. Memory: `project_ke_custom_firmware.md`.

All three tracks share the same workspace and a lot of platform-level groundwork (SoC identity,
kernel source, etc.) - that shared material lives in track 3's files/memory, not duplicated across
all three.

## Status: IN PROGRESS (2026-07-19) - Track 1 (items 2-4) implemented while user was away; Track 3 item 1 resume point unchanged

`ke-next`'s M600 fixes were confirmed working on real hardware and `v1.5.0-OpenKE` shipped
(2026-07-18/19) - the "paused until ke-next real-device testing is done" condition below is now
satisfied. Track 3 item 1 (ethernet driver `insmod` test) is exactly where it was left: the
`ax88179_178a` kernel module is built and vermagic-verified, but not yet transferred to or tested
on the real device. **Next session: go straight to Todo item 1's "Remaining" paragraph** - don't
redo the build, just re-check the printer is idle and run the `insmod` test.

**New this session (2026-07-19, done autonomously while the user was away for the afternoon,
explicitly pre-approved to make the fork-vs-standalone call and proceed without further
check-ins)**: Track 1 items 2-4 are done. Researched pellcorp's actual `klipper`/`kalico` forks
directly (both use the exact stock `klippy/extras/<module>.py` layout, no structural change
needed for either target - see `DESIGN.md`'s new top section), made the two small flagged calls
per their stated leaning, and **implemented all six `klippy_extras/` files with real, working
logic** (no more `NotImplementedError` skeletons) - MCU protocol, calibration math (with 17
passing standalone unit tests against synthetic data, no hardware needed -
`klippy_extras/test_prtouch_calibration.py`), touch-probe orchestration, nozzle-wipe, and the new
`z_compensate` per-print Z-offset piece. All six files pass `python3 -m py_compile`. Full account
of what changed vs. the original design sketch, and everything deliberately left out of v1, is in
`DESIGN.md`'s new "What actually changed during implementation" and "Deliberately dropped for v1"
sections - read those before touching this code.

**Deliberately not done, and should not be done without the user present**: no real hardware was
touched this session - no flashing, no installing SimpleAF, no changes to the live printer, which
is shared with `ke-next` testing and where a bad flash has no one present to help recover from.
The code above is untested against real firmware. **Real-hardware validation is the actual next
step for Track 1** - see the Todo below.

### Readiness comparison: Track 3 item 1 vs. Track 1 - NOT the same level of "done", read before assuming either is close

Asked and answered explicitly 2026-07-19 - recorded here so it never needs re-deriving:

- **Track 3 item 1 (ethernet driver)**: build + **vermagic verification** done - the four `.ko`
  files report the exact same `vermagic` string as the real device's own existing modules. That's
  strong, concrete evidence the build is correct; the *only* remaining step is physically running
  `insmod` on the real device and checking `dmesg`/`ip link`. Genuinely "just needs testing" -
  low-risk, session-only, one clear pass/fail check.
- **Track 1 (`klippy_extras/` prtouch_v2 + z_compensate)**: all six files have real, complete
  logic, and the pure-math half (`prtouch_calibration.py`) has 17 passing unit tests against
  synthetic data - that part is genuinely verified. But the MCU protocol layer, probe
  orchestration, and nozzle-wipe code have **never executed against anything real at all** - not
  just "untested on hardware." There is no mocked/simulated Klipper printer object standing in
  for a real one anywhere in this codebase or in Klipper itself, so this code has never even been
  smoke-tested inside an actual `klippy` process, real MCU or otherwise. Calling this "just needs
  testing" like the driver would overstate its readiness - it's closer to "first real exercise of
  carefully-read-but-never-run code." There's also a smaller unresolved item: only the *file
  layout* was confirmed to match SimpleAF's conventions (`klippy/extras/<module>.py`, both
  `pellcorp/klipper` and `pellcorp/kalico`) - whether anything else about SimpleAF's specific fork
  needs adjustment (config parsing quirks, module-load order, etc.) is unverified, not just
  untested.

**Practical takeaway**: if picking one to test first, the ethernet driver is the safer, faster
win - verifying a build already strongly likely to work. The load-cell module needs more careful,
attended testing (raw MCU step pulses during `touch_probe()`, no `trsync` safety net if something
goes wrong mid-probe - ANALYSIS.md §6).

## Todo (as of 2026-07-19)

1. **[Track 3, IN PROGRESS - resume here] Phase 1 - build + test the ethernet driver.**
   **Build + vermagic verification DONE (2026-07-19)**: `ax88179_178a.ko`, `usbnet.ko`, `mii.ko`,
   `asix.ko` all cross-compiled against `vendor/x2000_kernel` with `CONFIG_USB_NET_AX88179_178A`
   enabled, and all four confirmed to report the exact same
   `vermagic=4.4.94 SMP preempt mod_unload MIPS32_R2 32BIT` string as the real device's own existing
   modules. Built files are saved at `artifacts/ax88179-modules/` (four `.ko` files) - durable, not
   inside the gitignored `vendor/` clone. Full build recipe (exact commands, toolchain, gotchas
   already hit and fixed) is in `FIRMWARE.md` §5 step 4 - read that before redoing any of this work.
   **Remaining, not yet done**: `scp` the four `.ko` files to the real printer, confirm it's idle
   with a *fresh* `print_stats` check (do not trust the 2026-07-19 check - it was mid-print and is
   now stale), then `insmod` them (dependency order: `mii` → `usbnet` → `asix` → `ax88179_178a`) and
   check `dmesg`/`ip link` for a new interface. Session-only test, low risk either way (see
   `NETWORKING.md` §2 for why - nothing persists across a reboot unless we deliberately add an init
   script, which only happens after success is confirmed). This is also track 2's entire remaining
   fix - one piece of work closes both.
2. **[Track 1, DONE 2026-07-19]** ~~Resolve one open design question before writing real
   `klippy_extras/` logic~~ - resolved: target SimpleAF's own environment. Both of pellcorp's
   forks (`klipper`, `kalico`) use the exact stock `klippy/extras/<module>.py` layout, so no
   structural change was needed either way - see `DESIGN.md`'s top section.
3. **[Track 1, DONE 2026-07-19]** ~~Resolve the two smaller open questions in `DESIGN.md`~~ -
   both resolved per their stated leaning: `Z_OFFSET_AUTO` not registered, plain `command_error`
   used instead of Creality's `PR_ERR_CODE_*` catalog.
4. **[Track 1, DONE 2026-07-19, NOT hardware-tested]** ~~implement `klippy_extras/`~~ - all six
   files now have real logic (protocol, calibration math, touch-probe, nozzle-wipe, z_compensate).
   Calibration math has 17 passing standalone unit tests against synthetic data. See `DESIGN.md`'s
   "What actually changed during implementation" section for the specifics.
5. **[Track 1, NEW real next step] Real-hardware validation** - nothing in `klippy_extras/` has
   run against actual MCU firmware yet. Needs, in order: (a) get this code plus the real
   `printer.cfg` `[prtouch_v2]`/`[z_compensate]` sections onto a test Klipper checkout (SimpleAF's
   own environment, per the resolved design question above), (b) a `FIRMWARE_RESTART`/config
   round-trip to confirm the module loads and the MCU accepts the config commands without
   protocol errors, (c) a real `NOZZLE_CLEAR`/`Z_OFFSET_CALIBRATION` run watched closely with the
   printer attended the whole time (raw MCU step pulses, no `trsync` safety net - ANALYSIS.md §6).
   **Do not attempt this without the user present** - this is real hardware, not a reversible
   config change.
6. **[Track 3] Once Phase 1 succeeds: Phase 2** - a custom Buildroot rootfs using the
   now-validated kernel/toolchain, using the spare `rootfs2`/`kernel2` partition slots (confirmed
   unused, `FIRMWARE.md` §4b) rather than the active ones.
7. **[New since last session] Adapt GuppyScreen for this environment** - the three-option question
   in "GuppyScreen/OpenKE also needs adapting" above (point at pellcorp's `grumpyscreen`, port
   OpenKE's own UI, or a hybrid) is unresearched and will eventually need answering, but isn't
   blocking anything above yet - it's downstream of tracks 1 and 3 actually working.

**Recommended order: Track 3 item 1 first** (concrete, ready, low-risk, unblocks track 2 entirely
as a byproduct - real device/insmod work, do with the user present), **then Track 1 item 5**
(real-hardware validation of the now-implemented `klippy_extras/` - also needs the user present),
**then item 6**. Item 7 whenever it becomes the actual bottleneck, not before.

## Scope corrected 2026-07-18 - read this before anything else

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
  `prtouch_nozzle.py`/`z_compensate.py`) **implemented 2026-07-19** - real logic, not skeletons;
  `test_prtouch_calibration.py` has 17 passing standalone unit tests for the pure-math half. Not
  yet tested against real MCU firmware - see the Todo above. See `DESIGN.md` for the layout
  rationale and its "What actually changed during implementation" section for specifics.
- `ANALYSIS.md` - complete protocol + algorithm write-up, both reference source files read in full,
  real production scope confirmed against the live printer. The technical source of truth for
  track 1.
- `DESIGN.md` - the `klippy_extras/` module layout sketch, including the one real naming-
  compatibility decision and two smaller open questions, all flagged for confirmation before real
  implementation starts.
- `NETWORKING.md` - track 2's write-up (the USB-ethernet adapter investigation).
- `FIRMWARE.md` - track 3's write-up and the actual phased gameplan (research/acquisition ->
  ethernet-module proof -> custom Buildroot rootfs -> eventual real flash). The source of truth for
  "how hard would a full custom firmware/OS be" - kept current in place as work progresses.
- `vendor/` - **gitignored**, not committed. Real, exact-version-matching kernel source
  (`x2000_kernel`) and a matching Halley5 Buildroot config (`buildroot-x2000`), both found via
  GitHub code search and cloned locally for track 3/Phase 1 work. Provenance/exact repo URLs and
  commit state are recorded in `FIRMWARE.md` §4a - re-clone from there if this workspace ever moves,
  don't assume `vendor/` travels with the repo.
- `artifacts/ax88179-modules/` - built, vermagic-verified kernel modules from track 3/Phase 1
  (`ax88179_178a.ko`, `usbnet.ko`, `mii.ko`, `asix.ko`) - **not gitignored on purpose**, small
  binary build outputs worth keeping around rather than a large source tree. See `FIRMWARE.md` §5
  step 4 for the exact build recipe and current status (built + verified, not yet `insmod`-tested).

## License note

Everything under `reference/` is Creality's own GPLv3-licensed code, fetched from their own public
GitHub org - included here for protocol/reference purposes (reading it to understand the wire
format), not modified. Any new code we write in `klippy_extras/` is ours and should carry its own
license header (GPLv3, to stay compatible with Klipper's own licensing, since it'll need to load
into a Klipper `klippy` process either way).
