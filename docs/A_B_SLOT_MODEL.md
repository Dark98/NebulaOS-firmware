# The A/B boot-slot model

**Developer / advanced testing documentation.** This describes the raw partition layout and boot-selection mechanism this board actually uses. It assumes comfort with SSH, root access, and reasoning about block devices — not a consumer install guide.

Written as part of the developer-documentation consolidation mission (2026-08-15), consolidating facts previously scattered across `FIRMWARE.md`, `docs/NEBULAOS_OTA_FLOW.md`, and `scripts/flash-spare-slot.sh`'s own comments. See those for the original investigation history; this is the current-state reference.

## The layout

```
Slot 1 (stock)              Slot 2 (custom / NebulaOS)
  mmcblk0p5  kernel            mmcblk0p6  kernel2
  mmcblk0p7  rootfs             mmcblk0p8  rootfs2
  (8 MiB / 500 MB)              (8 MiB / 500 MB - real, fixed capacities)

              mmcblk0p1  ota marker (1 MB)
                 shared, not per-slot

              mmcblk0p9  rootfs_data (300 MB, ext4, /overlay)
              mmcblk0p10 userdata    (~6 GB, ext4, /usr/data)
                 shared, not duplicated per slot - see below
```

**Evidence:** `SCRIPT_VERIFIED` (these are `scripts/flash-spare-slot.sh`'s own hardcoded constants, re-verified against the current script for this document) and `LIVE_HARDWARE_VERIFIED` (`/proc/cmdline`'s `root=` value has been directly observed on real hardware showing each of `p7` and `p8` at different times).

This is **two fixed physical slots, not a rotating pair**. Slot 1 is Creality's own stock kernel/rootfs. Slot 2 is this project's own permanent custom-OS home — updating NebulaOS always means overwriting slot 2 again, never alternating between two custom copies.

### Shared, not duplicated, storage

`mmcblk0p9` (`/overlay`) and `mmcblk0p10` (`/usr/data`) are **not duplicated per slot** — the same physical partitions are mounted regardless of which slot is active. Stock and custom each use their own, non-overlapping subdirectory namespace within `/usr/data` (stock: `/usr/data/moonraker`, `/usr/data/guppyscreen`, etc.; NebulaOS: `/usr/data/nebulaos/*`) — so switching slots does not expose one OS's data to the other, and does not erase either. See `docs/DEVELOPER_RECOVERY.md`'s persistence table for exactly what lives where.

## What normal NebulaOS flashing writes — and never touches

`scripts/flash-spare-slot.sh` writes exactly two devices: `/dev/mmcblk0p6` (kernel2) and `/dev/mmcblk0p8` (rootfs2). It is hardcoded to target slot 2 only and **refuses outright** if the resolved target ever matches the currently-active slot — this is enforced in code (see the script's own `run_preflight()`), not merely documented practice. It never writes:

- `mmcblk0p5`/`p7` (stock kernel/rootfs) — architecturally unreachable as a write target
- `mmcblk0p1` (the OTA marker) — a separate script, separate deliberate step
- `mmcblk0p9`/`p10` (persistent storage) — not part of this script's job at all
- U-Boot, the partition table, OTP, or any factory-calibration partition — no code path in this repo touches these

**Known limitation, not fixed by this document:** the script's own header describes a real prior incident where an earlier version's live-root check was broken, and a write landed on the currently-executing rootfs, causing cascading segfaults that needed a manual power cycle to recover from. The current version was rewritten specifically to close that — resolving the active slot from `/proc/cmdline`'s real `root=` value rather than an aliased name, and refusing any write where the resolved target and resolved active slot match. This history matters for anyone modifying this script: the safety property is deliberate and was earned the hard way, not assumed.

## The OTA marker

`/dev/mmcblk0p1`, a raw 1 MB partition. Its content is one of two literal strings, written with trailing newlines and zero-padded to 512 bytes:

```
ota:kernel      (boot slot 1 / stock next)
ota:kernel2     (boot slot 2 / custom next)
```

**Who writes it:**

| From | Tool | Evidence |
|---|---|---|
| Custom (NebulaOS) | `/etc/ota_marker.sh`'s `write_ota_marker()` | `SCRIPT_VERIFIED`, `LIVE_HARDWARE_VERIFIED` |
| Stock (Creality) | `/etc/ota_bin/ota_local_method.sh`'s `local_set_next_boot_device()` | `LIVE_HARDWARE_VERIFIED` (used successfully during the 2026-08-08 virgin-flash mission while genuinely booted on stock) |

These are **two different, context-appropriate tools for two different operating systems** — not competing or inconsistent mechanisms. `ota_marker.sh` is NebulaOS's own helper, shipped as part of its rootfs; it does not exist on stock. `ota_local_method.sh` is Creality's own pre-existing tool, already present on stock, and does the equivalent job there. A developer switching from stock for the first time uses stock's own tool; from then on, whichever OS is running has its own.

**Who reads it:** the boot-time logic that decides which slot to actually boot lives in the bootloader (u-boot/mask-ROM stage), which is vendor code — not part of this repo. This document can only state the **observed behavior** (`LIVE_HARDWARE_VERIFIED`: writing the marker and rebooting reliably switches the boot target), not the reading implementation itself, which is `INFERRED_FROM_CODE` / out of this repo's own source.

## First boot and automatic rollback

```
reboot
  |
S00revert-safety   -- unconditionally sets marker to "ota:kernel" (stock),
  |                   the very first thing custom's own init runs
init sequence proceeds (S04 factory-seed/migrate, S5x services...)
  |
S99confirm-good    -- polls Moonraker's /server/info for klippy_state=="ready"
  |                   (up to 30 retries, 5s apart = 150s)
  |
  +-- success --> write_ota_marker "ota:kernel2"  (marker flipped forward)
  |
  +-- timeout ----> marker stays "ota:kernel" (stock)
                     next reboot lands on stock automatically
```

**Evidence:** `LIVE_HARDWARE_VERIFIED` for the marker mechanics themselves (a real warm-reboot cycle in the 2026-08-08 mission showed `S00revert-safety` correctly reset the marker at boot start and `S99confirm-good` correctly flipped it forward once Klipper/Moonraker were confirmed healthy). `LIVE_HARDWARE_VERIFIED` also for the equivalent component-level health-check-and-rollback logic (`docs/NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` §6.4 — two real bugs found via an induced failure, fixed, then a clean retest).

**Known limitation — read this before relying on it:** `S00revert-safety` is part of the *new* image's own init sequence. If the kernel never boots, or the rootfs never mounts far enough for `/sbin/init` to run at all, `S00revert-safety` never executes, and the marker is left at whatever it already was. If that was already `"ota:kernel2"` from an earlier successful boot, a genuinely broken new kernel/rootfs pair has **no proven automatic recovery path** through this mechanism — the device would keep attempting to boot the broken custom slot on every reboot. This has not been tested against an intentionally broken kernel/rootfs pair (`NOT_PROVEN`) — see `docs/DEVELOPER_RECOVERY.md` for what the actual recovery ladder looks like if this happens.

## Related documents

- `docs/DEVELOPER_INSTALL_FROM_STOCK.md` — the full first-install sequence this model supports
- `docs/DEVELOPER_UPDATE.md` — updating an existing install
- `docs/DEVELOPER_RECOVERY.md` — the recovery ladder, including what happens when this model's own safety net doesn't apply
- `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md` — the practical, step-by-step version of the marker-flip mechanics described above
- `docs/NEBULAOS_OTA_FLOW.md` — the broader end-to-end release→device flow this slot model is one piece of
