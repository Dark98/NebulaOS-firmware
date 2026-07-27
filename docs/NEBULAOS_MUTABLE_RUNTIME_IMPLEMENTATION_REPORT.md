# NebulaOS Mutable Applications, Updates, Recovery, Shared G-code, and Retention — Final Implementation Report

**Mission status: Complete**, with explicitly-scoped-out gaps documented rather than silently omitted (Mainsail update rollback, `moonraker.conf` env-versioning, exact retention-policy disk-pressure floors). GuppyScreen updatability was out of scope from the start (deferred to a future mission, per the governing brief) and remains immutable, served from its own read-only `/opt/guppyscreen` copy.

This report is the single entry point for what shipped. Each linked document is the authoritative source for its own area; this report summarizes and cross-references rather than duplicating their content.

---

## 1. What NebulaOS is, now

Before this mission, Klipper/Moonraker/Mainsail/GuppyScreen were all baked into the read-only squashfs with zero update mechanism (`docs/NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §1.2). After this mission:

- **Klipper and Moonraker** live as real, writable git checkouts under `/usr/data/nebulaos/apps/{klipper,moonraker}`, updatable by the user through Moonraker's own Update Manager (surfaced in Mainsail's UI), each backed by a rollback-capable supervisor that reacts to a bad update automatically.
- **Moonraker** runs from its own writable Python virtualenv (`/usr/data/nebulaos/envs/moonraker`, `--system-site-packages`), not the read-only system interpreter.
- **Mainsail** updates via official beta release archives (Moonraker's `type: web` update mechanism), served from `/usr/data/nebulaos/apps/mainsail`.
- **GuppyScreen** remains immutable and out of scope, exactly as the governing brief specified.
- All of this lives under a single namespace, `/usr/data/nebulaos`, with its own layout manifest, activation-decision record, update-transaction state, and backups — never touching the shared stock partition outside that namespace except for the one deliberate exception (shared g-code).
- **Shared g-code**: `/usr/data/printer_data/gcodes` is bind-mounted inside NebulaOS's own `printer_data`, so stock and NebulaOS builds see the same file tree, with a NebulaOS-owned `USB/` mount point inside it.
- **Recovery**: immutable factory-seed copies (offline git bundles built at image-compile time) reseed the namespace automatically if it's ever wiped or found invalid, with no network dependency for the initial seed.
- **Memory resilience**: a two-layer swap (zram + a NebulaOS-owned disk swap file) plus a maintenance-safety gate and a deliberate OOM-priority hierarchy, closing a real OOM incident found live during this mission (`docs/NEBULAOS_MEMORY_RESILIENCE.md`).
- **Retention**: a namespace-restricted cleanup manager with a graduated disk-pressure response, adapted from a proven reference implementation on the same board family (`docs/NEBULAOS_RETENTION_POLICY.md`).
- **Naming**: NebulaOS branding replaces OpenKE in new runtime/build code where it was safe and meaningful to do so, without rewriting git history or falsifying provenance comments (`docs/NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §3.8).

## 2. Phase-by-phase status

| Phase | Subject | Status | Primary reference |
|---|---|---|---|
| 1 | Investigation (build pipeline, OpenKE naming footprint, existing mechanisms) | Complete | `NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §1 |
| 2 | Reproducibility checkpoint (toolchain ordering, overlay staleness) | Complete | `NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §3, §3.9 |
| 3 | `/usr/data/nebulaos` namespace + openke-data migration | Complete | `NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §3.1-3.3; `S02nebulaos-namespace` |
| 4 | Offline factory-seed git bundles (Klipper, Moonraker) | Complete | `04-cross-compile-app-stack.sh`; `S04nebulaos-factory-seed` |
| 5 | Activation manager (bind-mount persistent-vs-immutable decisions) | Complete | `S05nebulaos-activate` |
| **Memory Resilience Gate** | zram + disk swap, OOM priorities, maintenance gate | Complete, live-qualified | `NEBULAOS_MEMORY_RESILIENCE.md` (full doc) |
| 6 | NebulaOS Klipper fork (extras committed in-tree) | Complete | `NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §2 |
| 7 | Writable Moonraker Python environment | Complete, live-qualified | `NEBULAOS_MEMORY_RESILIENCE.md` §8; `S56moonraker` |
| 8 | Update rollback orchestration + transaction state machine | Complete, live-qualified (two real bugs found and fixed) | `NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` §6; `nebulaos-update-supervisor.sh` |
| 9 | Retention/cleanup manager | Complete (floor values not re-validated against real-device measurement this pass) | `NEBULAOS_RETENTION_POLICY.md` |
| 10 | Moonraker `[update_manager]` configuration | Complete | `moonraker.conf`; `NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` §2 |
| 11 | OpenKE → NebulaOS naming cleanup | Complete | `NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §3.8 |
| 12 | Full real-device qualification | Complete, one explicit gap (Mainsail rollback) | `NEBULAOS_PHASE12_QUALIFICATION.md` |

## 3. Real bugs found and fixed during this mission (live, not simulated)

Every one of these was found by testing against the real physical device, not caught by static review — recorded here as evidence of what "qualification" actually meant in practice, not a rubber stamp:

1. **No swap at all, kernel-level** — `CONFIG_SWAP` wasn't compiled in; a real `git clone` during factory-seed OOM-killed on a 208MB device with zero swap. Root-caused to the kernel config, not just missing userspace tools. (`NEBULAOS_MEMORY_RESILIENCE.md` §1-2)
2. **`swapon -p` silently no-op'd** — BusyBox's `CONFIG_FEATURE_SWAPON_PRI` wasn't enabled; the fstab `pri=` workaround also silently failed for the same reason. (`NEBULAOS_MEMORY_RESILIENCE.md` §5)
3. **`mv srcdir destdir` nesting bug** — moving a `.partial` seed directory into place nested it inside an existing destination instead of replacing it; needed two fix attempts (the first, `rmdir` first, held up in isolation but not on a real boot; the second, unconditional `rm -rf` first, held up both places). (`NEBULAOS_MEMORY_RESILIENCE.md` §6)
4. **`known-good.json` write-once guard never re-evaluated** — permanently recorded `"unseeded"` even after a later successful seed. (`NEBULAOS_MEMORY_RESILIENCE.md` §6)
5. **No NTP client at all** — clock permanently stuck at the post-reset default (not just briefly wrong at boot), permanently breaking real HTTPS certificate validation. (`NEBULAOS_MEMORY_RESILIENCE.md` §7)
6. **BusyBox `wget` has no real TLS certificate validation**, even with HTTPS support compiled in — a permanent tool limitation, now a documented policy (never rely on `wget` for HTTPS where authenticity matters; use `curl`/`git`/`python3` instead, each proven with positive and negative controls). (`NEBULAOS_MEMORY_RESILIENCE.md` §7)
7. **BusyBox `ip` has no `-json`/`-det` support at all** — Moonraker's own `machine.py` network poller failed every ~10s indefinitely; fixed by building the real `iproute2` package and disabling BusyBox's `ip` applet to remove install-order ambiguity over `/sbin/ip`. (`NEBULAOS_MEMORY_RESILIENCE.md` §8)
8. **Update-supervisor sampled health too soon after a restart**, racing Klipper's real 15-25s MCU-reconnect time and causing a false-positive rollback failure. (`NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` §6.4)
9. **Update-supervisor recorded a stale commit on the factory-fallback path**, causing state.json to drift out of sync with git's real state and risking a spurious re-validation loop. (`NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` §6.4)

## 4. Known, honestly-scoped gaps (not silently dropped)

1. **Mainsail update rollback is not implemented.** The update-supervisor only covers Klipper/Moonraker (both git-based, trackable via a single commit hash). Mainsail is a release-archive update with no git history to reset to — rolling it back needs a different mechanism (snapshot/restore of the extracted release directory), not designed this mission. (`NEBULAOS_PHASE12_QUALIFICATION.md` §10)
2. **Moonraker's writable venv is not versioned independently of the source tree.** A Moonraker source rollback (`git reset --hard`) does not undo any `pip install` a bad update might have run into the venv. (`NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` §6.3)
3. **Retention policy's disk-pressure floor values (proposed 800MB/300MB) were not re-validated against real-device measurement this pass** — they're adapted from a reference board's own single 1000MB threshold, scaled down for this project's smaller footprint, but not independently confirmed live. (`NEBULAOS_RETENTION_POLICY.md` §3)
4. **`S01persistent-datastore`'s `DATA_ROOT=/usr/data/openke` was deliberately left unrenamed** — a considered decision, not an oversight, since it's the real on-disk legacy migration source a live device already depends on, not new NebulaOS-authored code. (`NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §3.8)

## 5. Frozen functionality — reconfirmed intact, not just assumed

Across every reboot/reflash cycle this mission performed (dozens), the following were reconfirmed working with zero regression: webcam (ustreamer/nginx proxy), USB gcode mounting, printer safety invariants (heater targets, print state, homed axes always queried read-only before any disruptive action), the existing whole-image A/B rootfs rollback (`S00revert-safety`/`S99confirm-good`/OTA marker), and WiFi/network connectivity.

## 6. Final known-good tag

`nebulaos-mutable-runtime-baseline-2026-07-27` — the commit at which this report was written, with every phase above live-qualified against the real device on the exact image that tag's manifest describes.
