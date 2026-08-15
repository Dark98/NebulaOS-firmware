# Updating an existing NebulaOS installation

**Developer / advanced testing documentation.** Assumes NebulaOS is already installed and booted (see `docs/DEVELOPER_INSTALL_FROM_STOCK.md` if it isn't yet).

There are three genuinely different things this document keeps separate: two that exist and are proven today (A, B), and one that's design-only (C). Do not conflate them — they update different things, through different mechanisms, with different evidence behind them.

## A. Component updates (Klipper / Moonraker) — proven, live-tested

**Evidence: `LIVE_HARDWARE_VERIFIED`.** This is a real, working, already-shipping mechanism — not a proposal.

**What it updates:** the persistent Klipper and Moonraker checkouts under `/usr/data/nebulaos/apps/{klipper,moonraker}`, triggered through Moonraker's own `[update_manager klipper]`/`[update_manager moonraker]` sections (visible in Mainsail's UI as the normal "Update" button for these components). No hard `pinned_commit` — either tracks its branch tip.

**What it does NOT update:** the kernel, rootfs, or GuppyScreen. GuppyScreen deliberately has no `[update_manager guppyscreen]` section at all — it's served immutably from the squashfs, replaced only by a new whole-image build (§B). Full detail: `docs/NEBULAOS_UPDATE_OWNERSHIP.md`.

**Rollback behavior:** because this Moonraker version's `git_repo` updater has no pre/post-update hook, health-checking and rollback run as a separate, independent poller — `/etc/init.d/S59nebulaos-update-supervisor` → `nebulaos-update-supervisor.sh`, polling every 20s. On detecting a commit change it runs a two-stage health check (files present + imports succeed, then a stabilized full printer-stack check against Moonraker/Klipper/MCU state); on failure it `git reset --hard`s back to the last known-good commit and restarts the service directly (bypassing Moonraker's own API, since a bad Moonraker update may have broken Moonraker itself); if the restored version *also* fails, it falls back to the immutable factory copy baked into the squashfs (unmounting the bind mount that shadows it) and leaves a lock in place so the persistent copy stays off until a human clears it.

**Live-tested, including two real bugs found and fixed:** a false-positive rollback from sampling health too soon after a restart (fixed with a grace period), and a stale bookkeeping field that could mask a factory-fallback event on the next poll (fixed). Retested clean afterward. Full evidence and the exact bugs: `docs/NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` §6.4.

**What it never touches:** `printer_data/config` (your `printer.cfg`, macros, `moonraker.conf`) — confirmed by direct code inspection, a completely separate directory tree from anything this mechanism reads or writes.

**Known limitation, not yet solved:** Moonraker's Python virtualenv is not independently versioned or rolled back — a source-level `git reset --hard` does not undo a `pip install` a bad update's changed `requirements.txt` might have run into the venv. Recorded as open in `NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` §6.3, not silently assumed solved here either.

## B. Whole-image developer update — proven as a manual procedure

**Evidence: `HISTORICALLY_HARDWARE_VERIFIED`** as an operator-run sequence.

This replaces the kernel and rootfs — the same mechanism as first install (`docs/DEVELOPER_INSTALL_FROM_STOCK.md`), run again against an already-populated device:

```
build/download new xImage + rootfs.squashfs + build-manifest.txt
        |
scp to the device
        |
independent sha256sum check
        |
flash-spare-slot.sh --check-only   (confirms target slot 2 is inactive -
        |                            the OTHER slot from whatever's running now)
flash-spare-slot.sh                (writes + MD5 read-back verification)
        |
flip the marker, reboot
        |
same first-boot sequence as install (S00/S04/S5x/S99 - see A_B_SLOT_MODEL.md)
```

**There is currently no fully automated release discovery, download, or whole-image updater.** A developer runs every step above by hand. Do not describe this as automatic anywhere else in this project's documentation — it isn't yet.

## C. Future OTA architecture — design only, not implemented

Existing design documents (`docs/NEBULAOS_OTA_FLOW.md`) describe a future end-to-end flow: release discovery → download → hash verification → inactive-slot flash → reboot → confirm-good, largely automated. **This is design intent, not current behavior.** The manual sequence in §B is what actually exists today. If you're reading an older document that describes this as already working, treat §B above as the authoritative current state.

## Related documents

- `docs/A_B_SLOT_MODEL.md` — the slot/marker mechanics both B and the first-boot sequence rely on
- `docs/NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` — full engineering detail and live-qualification record for §A
- `docs/NEBULAOS_UPDATE_OWNERSHIP.md` — which component owns which update path, and why GuppyScreen deliberately has none
- `docs/DEVELOPER_RECOVERY.md` — what happens if an update (either kind) leaves the device unhealthy
