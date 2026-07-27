# NebulaOS Retention Policy

**Status:** Implemented (Phase 9) — `/etc/nebulaos-retention.sh` + `/etc/init.d/S45nebulaos-cleanup`, verified present by `06-verify.sh`. Informed by direct investigation of SimpleAF's real, currently-shipping cleanup mechanism (Section 1). Section 3's open decisions (exact disk-pressure floor values, env-versioning-dependent rotation) were not revisited against real-device measurement during this pass — see `docs/NEBULAOS_MUTABLE_RUNTIME_IMPLEMENTATION_REPORT.md` for what Phase 12 did and did not exercise live.

---

## 1. Reference: SimpleAF's proven cleanup pattern (evidence, not yet adapted)

Investigated directly from `https://github.com/pellcorp/creality` (`k1/services/S45cleanup` → `tools/cleanup-files.sh`), 2026-07-26, current HEAD. This is real, currently-shipping behavior on the same board family, not a historical/superseded reference. Full findings recorded in `docs/NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §1.5; restated here as the basis for NebulaOS's own design:

- **RTC-before-NTP wait**: on Buildroot targets only, detects a start timestamp before a fixed reference date (its own clock hasn't synced yet) and busy-waits for a >20-minute forward jump before doing any `mtime`-based deletion.
- **Emergency gcode threshold**: free space on the data partition `< 1000MB` triggers deletion of `.gcode` files at `-maxdepth 1` (never recurses) in the shared gcodes root, and only those with `mtime +7` (7+ days old).
- **Log rotation**: rolled log files older than 7 days, explicitly excluding the live `moonraker.log`/`klippy.log`/`grumpyscreen.log` (its GuppyScreen-fork counterpart).
- **Backup rotation**: backup tarballs older than 7 days, but **always skips the single newest one** even if it's also past the age threshold ("in case its the only file left").
- **Cache purge**: `/root/.cache` (pip cache) removed every run, unconditionally.
- **Logging**: every deletion (real or `--dry-run`) appended to a `cleanup.log`, truncated at the start of each run.
- **Notable gap in the reference itself**: no active-print check exists anywhere in this script before deleting old gcode files. NebulaOS's own design must not repeat this gap (see §2.4).

## 2. NebulaOS retention manager design

### 2.1 Scope boundary (namespace-restricted, not a literal port)

Unlike SimpleAF's script (which operates directly on `/usr/data`), NebulaOS's retention manager is restricted to an explicit allowlist of paths under `/usr/data/nebulaos/{updates,backups,maintenance,envs,system}` plus the one deliberate special exception below (§2.4). It must:

- Reject any resolved path that escapes the namespace (`realpath` resolution, then a prefix check against `/usr/data/nebulaos`, not a string-prefix check on the unresolved path — must not be foolable by `..` or symlinks).
- Never follow a symlink that resolves outside the namespace.
- Never descend into a USB mount (checked via `/proc/mounts` device match, not just a path-prefix guess, since USB devices could in principle be bind-mounted to look path-adjacent).
- Coordinate with an in-flight update transaction (Phase 8's state machine) — refuse to run (or run in a reduced, backup/log-only mode) while an update transaction is active, to avoid racing a rollback's own file operations.

### 2.2 Allowlisted actions (normal operation, always safe)

| Path | Action | Threshold | Notes |
|---|---|---|---|
| `/usr/data/nebulaos/updates/*/staging` | Remove abandoned staging directories | Age > 24h AND no active transaction owns it | Transaction ownership tracked via Phase 8's state file, not just age |
| `/usr/data/nebulaos/updates/*` (downloads) | Remove incomplete/orphaned downloads | Same as above | |
| `/usr/data/nebulaos/backups/{klipper,moonraker,mainsail,printer_config}` | Rotate to current + previous known-good only | Keep exactly 2 (current, previous); never delete the only remaining copy | Mirrors the mission's rollback policy (one previous known-good per component) |
| `/usr/data/nebulaos/maintenance/*.log`, retention-manager's own log | Rotate | Age > 7 days, adapted from SimpleAF's own 7-day log threshold | Never delete the live/active log |
| `/usr/data/nebulaos/envs/moonraker-*` (old venvs, if the venv itself is versioned per update) | Remove superseded envs beyond current + previous | Keep exactly 2 | Only once Phase 7's env-versioning scheme is implemented |

### 2.3 Disk-pressure levels (update-blocking)

Three levels, adapting SimpleAF's single 1000MB threshold into a graduated response since NebulaOS's namespace-restricted retention has less to reclaim than SimpleAF's whole-partition script:

1. **Normal** (free space above a "safe" floor — proposed 800MB, informed by SimpleAF's 1000MB reference minus this mission's own smaller footprint per the storage budget in the architecture doc): no action beyond routine rotation above.
2. **Caution** (below the safe floor): block new update downloads/staging (refuse to start a new update transaction) but do not delete anything beyond the routine rotation in §2.2; log a warning.
3. **Critical** (below a hard floor — proposed 300MB): in addition to Caution's blocking, run the emergency shared-gcode cleanup (§2.4) and purge the pip cache (adapting SimpleAF's unconditional `.cache` purge into a Critical-only action here, since NebulaOS's `wheel`/`pip` tooling, Phase 2, is new and this cache did not previously exist).

Exact floor values are proposed, not yet validated against a real device measurement under load — to be confirmed during Phase 12 qualification, not asserted as final here.

### 2.4 Emergency shared-gcode cleanup (special exception to the namespace rule)

Per the mission brief, the shared gcode directory (`/usr/data/printer_data/gcodes`, outside the `/usr/data/nebulaos` namespace) is a deliberate, explicit exception: under Critical disk pressure only, follow SimpleAF's verified pattern — delete `.gcode` files at `-maxdepth 1` (never recursing, so a USB-mounted subtree or an organized subfolder is never touched), oldest-`mtime`-first, stopping as soon as free space returns above the Critical floor rather than deleting everything eligible.

**Deliberate improvement over the SimpleAF reference** (§1's noted gap): before deleting any gcode file, NebulaOS's implementation must check:
- It is not the file backing the currently active print (via Moonraker's `print_stats`/`virtual_sdcard` state — an active or paused print's file is never eligible, full stop, regardless of age or disk pressure).
- It is not a partial/in-progress upload (match against Moonraker's upload-in-progress state, not just a naive "recently modified" heuristic, since a slow upload of an old-looking file could otherwise be misjudged as stale).
- It is not on a mounted USB device (already excluded by `-maxdepth 1` against the gcodes root, but re-checked explicitly here since this is the one path outside the namespace where a mistake would be highest-impact).

If a file's state is ambiguous for any reason, it is skipped, not deleted — matching the mission brief's explicit "never delete... files with ambiguous state."

### 2.5 Logging and dry-run

Every retention-manager run supports `--dry-run` (log intended deletions without performing them, matching SimpleAF's own `--dry-run`/`--client` convention) and logs every actual deletion with timestamp, path, size, and reason (rotation/staging-cleanup/emergency-gcode) to `/usr/data/nebulaos/maintenance/retention.log`, itself subject to the same 7-day rotation as any other log (§2.2).

### 2.6 RTC-before-NTP handling

Adapted directly from SimpleAF's own mechanism (§1): detect a start timestamp before a fixed reference date, wait for a large forward clock jump before performing any `mtime`-based comparison. NebulaOS's own implementation should use a reference date close to its own baseline (`functional-production-baseline-2026-07-23` or later) rather than SimpleAF's hardcoded 2025 date, and the same "wait for >20 minute jump" heuristic, adjusted only if real-device testing (Phase 12) shows this project's own NTP sync timing differs meaningfully from SimpleAF's board.

## 3. Open decisions

- Exact Caution/Critical free-space floors (proposed 800MB/300MB above) — need real-device validation, not just adapted from SimpleAF's single 1000MB number, since NebulaOS's own footprint (~150-250MB per the architecture doc's storage budget) differs from SimpleAF's.
- Whether Moonraker env versioning (Phase 7) actually produces multiple env directories needing rotation, or whether a single env is upgraded in place with a full backup/restore instead — affects whether the `envs/moonraker-*` row in §2.2 is real or moot.
- Retention manager invocation mechanism: a dedicated `S45cleanup`-numbered init script (matching SimpleAF's own numbering convention and this project's existing `S*` scheme) triggered at boot, versus a periodic cron-like mechanism — NebulaOS's BusyBox init has no native cron; likely a boot-time run plus an optional periodic re-invocation hook from Moonraker itself (a component or a timer), to be decided during implementation.
