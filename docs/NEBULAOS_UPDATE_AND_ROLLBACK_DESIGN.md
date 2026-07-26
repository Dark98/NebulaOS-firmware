# NebulaOS Update, Rollback, and Health-Check Design

**Status:** Design draft (Phases 8 and 10). Informed by direct investigation of SimpleAF's real, currently-shipping `[update_manager]` configuration (Section 1). Not yet implemented. This is separate from, and does not replace, NebulaOS's existing whole-image A/B rootfs rollback (`S00revert-safety`/`S99confirm-good`/`flash-spare-slot.sh`) — this document covers component-level (Klipper/Moonraker/Mainsail) mutability, which does not exist in any form today (confirmed in `docs/NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §1.2: today these three are baked into the read-only squashfs with zero update mechanism).

---

## 1. Reference: SimpleAF's real Moonraker Update Manager configuration

Fetched directly from `https://github.com/pellcorp/creality`, `k1/moonraker.conf`, 2026-07-26 (current HEAD, not a cached/historical copy):

```ini
[update_manager]
enable_auto_refresh: False
refresh_interval: 0
enable_system_updates: False

[update_manager klipper]
channel: dev
pinned_commit: 386fde4fd38e8eda6999e58bf260eceb00051188
report_anomalies: False

[update_manager moonraker]
channel: dev
pinned_commit: abd2026b90d86fb738c6619be3ceefcedee2006c

[update_manager fluidd]
type: web
channel: beta
repo: fluidd-core/fluidd
path: /usr/data/fluidd

[update_manager mainsail]
type: web
channel: beta
repo: mainsail-crew/mainsail
path: /usr/data/mainsail
```

Key confirmed facts this design adopts directly:
- `enable_system_updates: False` at the top level — Moonraker never exposes a general OS/package updater. NebulaOS must set this identically (satisfies the mission's explicit "no general Linux package updater exposed through Moonraker" requirement).
- Klipper and Moonraker are both `channel: dev` (git-checkout, not release-archive) updates, each gated by a `pinned_commit` — Moonraker's Update Manager will refuse to report/apply an update that isn't (or doesn't advance cleanly from) the pinned commit, giving exactly the "compatibility-controlled" behavior the mission asks for.
- Mainsail (and, on SimpleAF, Fluidd) use `type: web`/`channel: beta` — GitHub-release-archive-based updates with automatic extraction, not a git checkout — confirming Mainsail's own update path should be release-based, not git-based, matching the mission's own requirement.
- The pinned Klipper commit (`386fde4`) is **identical** to NebulaOS's own previously-vendored pin — independent confirmation that NebulaOS's Klipper fork (`docs/NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §2) and SimpleAF's own reference deployment started from the exact same base.

## 2. NebulaOS's own `[update_manager]` design (adapted, not copied verbatim)

```ini
[update_manager]
enable_auto_refresh: False
refresh_interval: 0
enable_system_updates: False

[update_manager klipper]
type: git_repo
channel: dev
path: /usr/data/nebulaos/apps/klipper
origin: https://github.com/coreflake1/NebulaOS-klipper.git
primary_branch: nebulaos
managed_services: klipper

[update_manager moonraker]
type: git_repo
channel: dev
path: /usr/data/nebulaos/apps/moonraker
origin: https://github.com/Arksine/moonraker.git
primary_branch: master
managed_services: moonraker
virtualenv: /usr/data/nebulaos/envs/moonraker
requirements: scripts/moonraker-requirements.txt

[update_manager mainsail]
type: web
channel: beta
repo: mainsail-crew/mainsail
path: /usr/data/nebulaos/apps/mainsail
```

Differences from SimpleAF's reference, each deliberate:
- **`path`/`origin` point at NebulaOS's own namespace and fork** (`/usr/data/nebulaos/apps/*`, `coreflake1/NebulaOS-klipper`) rather than SimpleAF's `/usr/data/klipper` and `pellcorp/klipper` — NebulaOS has its own fork specifically so its required extras are committed in-tree (architecture doc §2), which SimpleAF's own deployment does not need since it doesn't carry GuppyScreen-specific extras the same way.
- **No `pinned_commit`** in this draft — Moonraker's Update Manager `pinned_commit` freezes updates entirely at one exact commit, which is appropriate for SimpleAF's own stability goals but is in tension with this mission's own requirement that Klipper/Moonraker be **user-updatable** via Moonraker/Mainsail. Compatibility control here is intended to come from Phase 8's own two-stage health-check-gated rollback (§3) rather than a hard pin — **this is an open decision, not yet settled** (§5).
- **`virtualenv`/`requirements`** on the Moonraker entry — this is standard Moonraker Update Manager syntax for a self-updating Python virtualenv; used here deliberately because (per the architecture doc §1.2's build-pipeline finding) Moonraker's Python dependencies today are **not** in a venv at all — they are extracted directly into the system Python's site-packages at image-build time. Making Moonraker's env real, writable, and Update-Manager-aware is a structural change (Phase 7), not a small config edit; recorded here as the target shape.
- **GuppyScreen and Mainsail are otherwise unlisted for anything beyond what's shown** — GuppyScreen has no `[update_manager guppyscreen]` entry at all (stays immutable, per the mission's explicit scope boundary); Mainsail's entry is otherwise identical in shape to SimpleAF's own (`type: web`/`channel: beta`), since Mainsail's release-based update model needs no NebulaOS-specific adaptation.

## 3. Two-stage update verification (Phase 8)

### Stage 1 — component health (post-install, pre-activation)

For whichever component was just updated (Klipper, Moonraker, or Mainsail):

| Check | Klipper | Moonraker | Mainsail |
|---|---|---|---|
| Required files exist | `klippy/klippy.py` present, importable | `moonraker/server.py` present | `index.html` + asset manifest present |
| Manifest/compatibility metadata valid | New commit is a descendant of (or matches an allowed set relative to) the last known-good commit — exact rule pending §5 | Same | Release tag matches the channel's expected shape |
| Python imports succeed | `python3 -c "import klippy"`-equivalent smoke check inside the target's own interpreter | Same, against the (Phase 7) writable venv, not the system interpreter | N/A (static assets) |
| Process starts | Klipper process starts in a **dry-run/no-MCU-connect** mode if possible, else deferred to Stage 2 | Moonraker process starts and its HTTP listener opens | nginx can serve the new `index.html` (HEAD request, not a full page load) |
| No incomplete staging directory active | Update transaction state (§4) confirms the staging directory was fully committed, not partially copied | Same | Same |

A failed Stage 1 check aborts activation immediately — the previous version is never touched, and the new version's staged files are preserved (not deleted) for evidence, per the mission's own "preserve failure logs+version metadata" requirement.

### Stage 2 — full printer-stack health (post-activation)

Only run once Stage 1 has passed and the new version has been activated (paths switched, dependent services restarted):

- Moonraker running and responding on its HTTP port.
- Moonraker's own connection to Klipper (`server.info`) reports connected, not just "listening."
- Klipper reports `klippy_state == "ready"` (reusing the exact same real-readiness check `S99confirm-good` already implements and that this mission's frozen-functionality list protects — the two mechanisms should share logic, not duplicate it with a subtly different check).
- MCU connected (no `mcu.error`/shutdown state — reusing `S95mcu-boot-recovery`'s own detection logic where applicable, though that guard is itself frozen and must not be modified).
- Moonraker reports no failed required components (`server.info`'s own component-health field).
- Heater targets are exactly zero and no active print is running (the same printer-safety invariant already required before every reboot in this project's existing safety discipline) — verified as a **read-only query**, executed and reviewed as its own separate step, never combined with the activation/restart command that produced this state.
- System remains stable for a defined validation interval (proposed: 60 seconds of continuous `ready` state with no further `mcu.error`/component-failure events) before being recorded as known-good.

Only after **both** stages pass is the new version recorded as the current known-good version (§4). A failure at either stage triggers the rollback path (§3.1).

### 3.1 Rollback path

On any Stage 1 or Stage 2 failure:
1. Preserve the failed version's logs and version metadata (commit hash / release tag) under `/usr/data/nebulaos/backups/<component>/failed-<timestamp>/` — never overwritten by a subsequent attempt.
2. Restore the previous known-good version (Klipper: previous commit/worktree; Moonraker: previous source **and** its matching previous Python env, restored together, never mixed — a mismatched Moonraker-source/env pairing is exactly the kind of failure this two-part restore exists to prevent; Mainsail: previous extracted release).
3. Restart affected services.
4. Re-run Stage 2 (not Stage 1 — the previous version was already proven once) against the restored version.
5. If the previous version **also** fails Stage 2: fall back to the immutable factory copy (`/opt/klipper`, `/opt/moonraker`, `/usr/share/mainsail`) temporarily, and clearly report all three states (failed-new, failed-previous, running-factory) rather than silently succeeding on a degraded configuration.

## 4. Update/rollback state machine (persisted)

Persisted at `/usr/data/nebulaos/updates/<component>/state.json` (exact schema TBD during implementation), tracking at minimum: selected version, previous known-good version, activation state (`inactive`/`staged`/`activating`/`active`/`rollback-in-progress`/`factory-fallback`), pending-update state, last rollback reason, last health-check result. A reboot occurring during any of these states must resume deterministically on next boot (the activation manager, Phase 5, reads this state before starting any dependent service) rather than silently picking an arbitrary version.

## 5. Open decisions

1. **`pinned_commit` vs. no pin for Klipper/Moonraker** (§2): SimpleAF pins hard; this mission wants user-updatable components. Leaning toward **no hard pin**, relying instead on Stage 1/2 health checks and the rollback path as the compatibility gate — but this needs explicit confirmation before Phase 10 configuration is finalized, since it's a real behavioral difference from the proven reference.
2. **Exact commit-ancestry rule for Stage 1's "manifest/compatibility metadata valid" check** — not yet designed; needs to distinguish "a legitimate forward update" from "an unrelated/incompatible checkout" without assuming linear history (a rebase or force-push on the tracked branch could break naive ancestor-checking).
3. **Whether Moonraker's env is upgraded in place or versioned as `envs/moonraker-<n>`** — affects both this document's rollback mechanics and the retention manager's env-rotation row (`docs/NEBULAOS_RETENTION_POLICY.md` §2.2/§3).
