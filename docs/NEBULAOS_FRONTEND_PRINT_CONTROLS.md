# NebulaOS Frontend Print Controls — Restoring Standard Klipper Print State

Mission: "Autonomous Completion Mission: Restore Standard Klipper Print
Controls, Fix Mainsail Phantom Print State, and Requalify the Ender-3 V3 KE
Release" (2026-07-29). Builds on
[NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md](NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md)
and does not move or reopen tag `nebulaos-offline-firstboot-updates-camera-complete-2026-07-29`.

## 1. The defect

Mainsail reported these config-closure warnings on every boot, and showed a
phantom `0 / 0`, `0 seconds left` print state even with no print active:

```
virtual_sdcard is not defined in config.
pause_resume is not defined in config.
gcode_macro pause is not defined in config.
gcode_macro resume is not defined in config.
gcode_macro cancel_print is not defined in config.
display_status is not defined in config.
```

## 2. Live evidence gathered (read-only, no motion/heating)

Queried directly against the running device over SSH/HTTP, no G-code
executed, no macro invoked, nothing homed or heated:

- `/printer/objects/list` — confirmed `virtual_sdcard`, `print_stats`,
  `pause_resume`, `display_status`, `exclude_object` are genuinely absent
  from the live Klipper object list (not a Mainsail-only rendering issue).
- `/server/info` — Moonraker's own `missing_klippy_requirements` field
  independently confirms the same three: `["display_status", "pause_resume",
  "virtual_sdcard"]`.
- `/printer/gcode/help` — confirmed no `PAUSE`/`RESUME`/`CANCEL_PRINT`
  command registered at all.
- `/server/job_queue/status` → `{"queued_jobs": [], "queue_state": "paused"}`
  and `/server/history/list?limit=3` → `{"count": 0, "jobs": []}` — Moonraker
  itself holds no queued or historical job. This rules out a genuine stale
  job as the cause of the `0/0` display; it is Mainsail's own frontend
  fallback rendering for a printer that has never reported real
  `virtual_sdcard`/`print_stats` objects to key off of, not a second,
  independent bug in Moonraker's job state.
- `webhooks.state: ready`, `idle_timeout.state: Idle`,
  `toolhead.homed_axes: ""` — the printer is genuinely idle and unhomed;
  nothing about the underlying machine state is itself wrong.

## 3. Config closure audit

`/opt/printer_data/config/printer.cfg` had exactly one `[include ...]` line
(`GuppyScreen/guppy_cmd.cfg`). Searched that file and `printer.cfg` itself
for `virtual_sdcard|pause_resume|display_status|PAUSE|RESUME|CANCEL_PRINT|
rename_existing|exclude_object` — zero matches. The gap is real, not a
naming mismatch or a shadowed duplicate: these objects/commands were never
defined anywhere in this project's factory config at all.

| Function | Current source | Present | Used by Mainsail | Used by GuppyScreen | Hardware-specific | Keep/replace |
|---|---|---|---|---|---|---|
| `virtual_sdcard` | none | No | Yes (progress/job state) | Yes (`virtual_sdcard/progress`) | No | Add: native `[virtual_sdcard]` |
| `pause_resume` | none | No | Yes (pause/resume UI state) | Yes (`pause_resume/is_paused`) | No | Add: native `[pause_resume]` |
| `display_status` | none | No | Yes (progress bar/M117) | No (uses `print_stats`) | No | Add: native `[display_status]` |
| `print_stats` | none (auto-loaded by `virtual_sdcard`) | No | Yes (`print_stats/*`) | Yes (`print_stats/*`) | No | Auto-loaded, no explicit section needed |
| `PAUSE` | none | No | Yes | Yes (literal `PAUSE` string in binary) | No | Native `pause_resume.py` command, no macro override |
| `RESUME` | none | No | Yes | Yes (literal `RESUME` string in binary) | No | Native `pause_resume.py` command, no macro override |
| `CANCEL_PRINT` | none | No | Yes | Yes (literal `CANCEL` string in binary) | No | Native `pause_resume.py` command, no macro override |

No duplicate or conflicting macro names exist anywhere in the closure.

## 4. Source-precedence evaluation (mandatory 4-level order)

**Level 1 — native mainline Klipper components.** Read the actual source of
this exact fork's extras at `/opt/klipper/klippy/extras/` (not assumed from
memory or another Klipper version):

- `virtual_sdcard.py`: constructor takes one required option, `path`
  (`config.get('path')`), and one optional Jinja template option,
  `on_error_gcode` (loaded via `gcode_macro.load_template`, defaulting to
  `TURN_OFF_HEATERS` if any heater exists). **`on_error_gcode: CANCEL_PRINT`
  is confirmed supported** by this fork — it is rendered through the same
  `gcode_macro` template mechanism as any other macro option, not a
  hardcoded string. It also auto-loads `print_stats` itself
  (`self.printer.load_object(config, 'print_stats')`), so `[print_stats]`
  needs no separate config section.
- `pause_resume.py`: takes one optional option, `recover_velocity` (default
  `50.0`). It registers `PAUSE`, `RESUME`, `CLEAR_PAUSE`, and `CANCEL_PRINT`
  **itself**, directly, with no macro layer required. Read in full:
  - `PAUSE`: if printing from virtual SD, pauses it (`do_pause()`, which
    just stops the SD work timer — no motion); otherwise just marks paused.
    Runs `SAVE_GCODE_STATE NAME=PAUSE_STATE`. No lift, no heater change, no
    homing.
  - `RESUME`: runs `RESTORE_GCODE_STATE NAME=PAUSE_STATE MOVE=1` (moving
    only back to the exact position/state that was saved at pause time —
    not an arbitrary or unconditional move), then resumes the SD timer if
    it was SD-paused. No re-homing, no heater restoration beyond whatever
    the saved state already held.
  - `CANCEL_PRINT`: cancels the virtual-SD file if active
    (`virtual_sdcard.do_cancel()`, which closes the file and calls
    `print_stats.note_cancel()` — no heaters touched, no motion), then
    clears the pause flags. Does not delete the G-code file itself, does
    not touch Moonraker's history (that's Moonraker's own concern via job
    completion callbacks, unaffected by this change).
- `display_status.py`: takes **no config options at all**. Registers `M73`,
  `M117`, and `SET_DISPLAY_TEXT`.

Conclusion: Level 1 alone fully covers every object and command in the
defect list, with safe, minimal, non-destructive default behavior that
already satisfies every safety constraint in this mission (no automatic
homing, no hidden heating, no unconditional movement, no unsafe Z lift).

**Level 2 — official Mainsail-built configuration.** No internet access was
used. The only locally pinned reference tied to the Mainsail/Klipper
installer ecosystem already vendored in this repo is
`vendor/kiauh/kiauh/components/klipper/assets/printer.cfg` (`mainsail-crew`'s
own KIAUH installer, also vendored at `vendor/kiauh/`). Its entire relevant
content is:

```
[virtual_sdcard]
path: %GCODES_DIR%
on_error_gcode: CANCEL_PRINT
```

This is the same convention Level 1 already arrived at independently
(`on_error_gcode: CANCEL_PRINT`), and — notably — it does **not** define
custom `PAUSE`/`RESUME`/`CANCEL_PRINT` macro overrides either. The widely
known community `mainsail-config` repository does define fancier
`rename_existing`-based macros (retract, park, conditional heater-off), but
that repository is not vendored anywhere in this project, and fetching it
at runtime would violate this mission's explicit no-internet-dependency
requirement. Given Level 1 already safely satisfies every named object and
command, and the one config genuinely available locally confirms the same
minimal approach, no such macro wrapping is added.

**Level 3 — GuppyScreen compatibility.** `strings` against the shipped
`/opt/guppyscreen/guppyscreen` binary confirms it reads the standard object
paths (`pause_resume/is_paused`, `print_stats/*`, `virtual_sdcard/progress`)
and issues the standard command names — a literal pattern string
`PRINT|SDCARD|PAUSE|RESUME|CANCEL|EXCLUDE_OBJECT|M24|M25|M73` is present in
the binary. GuppyScreen requires no behavior beyond what Level 1 supplies;
no GuppyScreen-specific compatibility file is added.

**Level 4 — Creality Ender-3 V3 KE fallback macros.** Not required. Nothing
in the defect list is hardware-specific (bed clearance, load-cell interlock,
etc.) — every missing piece is a standard Klipper object/command with no
Creality-only behavior involved.

## 5. Decision record

Implement exactly, and only:

```ini
[virtual_sdcard]
path: /opt/printer_data/gcodes
on_error_gcode: CANCEL_PRINT

[pause_resume]

[display_status]
```

in a new dedicated file, `frontend-controls.cfg`, included from
`printer.cfg`. `print_stats`, `PAUSE`, `RESUME`, and `CANCEL_PRINT` all come
for free from `virtual_sdcard`/`pause_resume` themselves — no explicit
`[print_stats]` section and no `gcode_macro` overrides are added. This is
the complete, single, reviewed source of truth for all six named
objects/commands: 100% Level 1 (native mainline Klipper), independently
corroborated by the one real Level 2 reference available locally. No Level
3 or Level 4 additions were needed or made.

`/opt/printer_data/gcodes` matches this project's already-seeded canonical
G-code directory (confirmed present, populated, and shared with stock via
the same physical partition) — not a placeholder or `~`-relative path.

## 6. Live qualification evidence (2026-07-29)

Every step below ran against the real Ender-3 V3 KE / Nebula Pad device, no
motion/heating/homing performed at any point.

- **One-time live correction (dev printer, before rebuild)**: read-only
  safety check first (heaters at target 0, `idle_timeout.state: Idle`,
  `toolhead.homed_axes: ""`, no queued/history jobs) confirmed the machine
  was safe to touch. Full backup taken of `printer.cfg`, `moonraker.conf`,
  `GuppyScreen/`, the Moonraker SQLite database, both logs, and the
  pre-fix warning evidence. `frontend-controls.cfg` deployed and the
  include line added atomically; Klipper restarted alone (no Moonraker
  restart needed - it detected the reconnect on its own). Result: Klipper
  `ready`, `missing_klippy_requirements: []`, `PAUSE`/`RESUME`/
  `CANCEL_PRINT`/`CLEAR_PAUSE` all registered, `virtual_sdcard.is_active:
  false`, `print_stats.state: standby`, `pause_resume.is_paused: false` -
  checked at the API level, not just "the warning panel looks empty."
- **Full clean rebuild**: `04-cross-compile-app-stack.sh` ran the new
  print-control closure validator for real against the tracked overlay
  source and passed (`virtual_sdcard`/`pause_resume`/`display_status`
  each defined exactly once, correct path, no duplicate or circular
  macros). `05-final-build.sh` produced a clean `rootfs.squashfs`.
  `06-verify.sh` reported **zero MISS lines** across the entire packaged
  image, including every new print-control check and the already-shipped
  `uv4l-mjpeg` camera default (confirmed directly inside the packaged
  `/usr/libexec/nebulaos-seed-camera`).
- **Safe reflash**: booted to stock, qualified `flash-spare-slot.sh`
  preflight reported `SAFE TO FLASH` (target slot 2 inactive), real write
  independently md5-verified for both `xImage` and `rootfs.squashfs`, OTA
  marker flipped as its own separate step, reboot as its own separate
  step. Booted successfully on the new image (`root=/dev/mmcblk0p8`,
  kernel build timestamp matching the rebuild).
- **Genuine empty-namespace requalification**: wiped
  `/usr/data/nebulaos/{apps,backups,envs,guppyscreen,maintenance,
  printer_data,system,updates}` (keeping only `wpa_supplicant.conf` and
  the separately-mounted shared-gcodes partition, exactly as required),
  one offline reboot. Result: `printer_data/config` - including
  `frontend-controls.cfg` - reseeded entirely from the immutable factory
  seed with no restored/carried-over files; zero `FileNotFoundError` in
  `klippy.log`; `missing_klippy_requirements: []` and `warnings: []`;
  `virtual_sdcard`/`print_stats`/`pause_resume`/`display_status` all
  clean; the 48 shared G-code files survived untouched; the database
  camera freshly re-seeded with the correct `uv4l-mjpeg` service from
  scratch (not carried over from the earlier live edit).
- **Non-motion integration check**: Mainsail's static UI served (`200`),
  GuppyScreen's process alive with an active websocket connection, all 72
  registered G-code commands including the six print-control ones present
  with no conflicts. The only log noise present (a pre-existing, unrelated
  gcode-file metadata quirk; empty `guppyscreen`/`fluidd` database
  namespaces on a brand-new database; one early-boot JSON-RPC race before
  Klipper's connection was established) was reviewed and is unrelated to
  this fix.
- **Persistence**: a plain reboot (same slot, no marker change) left the
  seed marker timestamp unchanged - proving no unwanted re-seed - and
  every print-control object still clean. A static check of
  `nebulaos-update-supervisor.sh` confirms its rollback logic only ever
  touches `printer_data/logs/*.log`, never `printer_data/config` -
  printer configuration was never part of, and remains outside of,
  application rollback.
