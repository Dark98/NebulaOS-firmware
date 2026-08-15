# Recovering a NebulaOS printer

**Developer / advanced testing documentation.** These procedures expose raw firmware images, partitions, A/B boot slots, SSH/root access, and recovery mechanisms. They document the current NebulaOS development workflow and are not presented as a supported consumer installer.

Ranked from least to most invasive, derived from what's actually been exercised — not assumed.

## 1. Automatic fallback

**Evidence: `LIVE_HARDWARE_VERIFIED`.** No user action. Covered in full in `docs/A_B_SLOT_MODEL.md` — summarized here: `S00revert-safety` unconditionally resets the OTA marker to stock the instant a custom boot starts; only `S99confirm-good`, after confirming Moonraker/Klipper are genuinely healthy, flips it back forward. A boot that never gets that far leaves the marker on stock, so the *next* reboot lands there automatically.

> **Known limitation:** automatic fallback depends on userspace reaching far enough to run `S00revert-safety` at all. A kernel that never boots, or a rootfs that fails before init can start, may fail *before* this protection can execute — in which case the marker stays wherever it was left, and if that was already `"ota:kernel2"`, there is no proven automatic recovery through this path. `NOT_PROVEN` against an intentionally broken kernel/rootfs; not addressed by any mechanism in this repo today. Recorded here rather than implied solved.

## 2. Manual SSH slot switch

**Evidence: `LIVE_HARDWARE_VERIFIED`.** Requires the currently-running OS to still have working SSH/network. Two minutes, no tools.

From custom:
```sh
. /etc/ota_marker.sh
write_ota_marker "ota:kernel"    # or "ota:kernel2" to go the other way
reboot
```

From stock:
```sh
. /etc/ota_bin/ota_local_method.sh
local_set_next_boot_device
reboot
```

Switching slots erases nothing on either side — see the persistence table below and `A_B_SLOT_MODEL.md`'s note on shared, non-duplicated storage.

## 3. USB recovery to stock

**Evidence: `LIVE_HARDWARE_VERIFIED`. Advanced / emergency — not a routine path.** Use only when SSH/network is unreachable on the currently-booted OS.

This is a **panic button back to stock**, not a general installer — the tool it uses is built specifically to force the device back to stock, not to select an arbitrary target.

**Requirements:**
- A computer (Linux — the build/run commands below are the only ones documented and tested; no Windows/Mac procedure is documented for this tool)
- A USB cable to the Nebula Pad's MicroUSB port
- Possibly opening the case, to reach two small buttons next to the MicroUSB port
- `sudo` (plain USB access without it fails with a permissions error)
- `ballaswag/ingenic-usbboot`, built from source:
  ```sh
  git clone https://github.com/ballaswag/ingenic-usbboot
  cd ingenic-usbboot
  make
  ```
  The compiled binary is `usbboot`, not `ingenic-usbboot` — that's just the repo name. This is a third-party tool; **no version or checksum is pinned by this project.**

**Procedure** (real mistakes made during live testing are preserved below because they affect safety, not just history):

1. Power off. Hold both buttons for 3 seconds, release reset first, then boot. This enters mask-ROM USB recovery mode — nothing runs yet.
2. Optional sanity check: `lsusb`, look for `ID a108:eaef Ingenic Semiconductor Co.,Ltd Ingenic USB BOOT DEVICE`.
3. **u-boot must be loaded before the marker swap** — the raw mask-ROM stage does not support the marker-swap request at all; running it first fails with `Could not open USB device` or a transfer error.
   ```sh
   sudo ./usbboot --uboot
   sudo ./usbboot --swap-ota
   ```
   There is no `--force-swap-ota` flag — `--swap-ota` **toggles**, it does not target a specific side. It prints the state before and after switching; read that output.
4. **Don't trust the printed status alone.** Two consecutive real invocations both printed the same "before/after" text despite having different actual starting states — the raw USB-boot session does not reliably preserve state between separate tool invocations the way the printed text implies. Verify the real bytes instead:
   ```sh
   sudo ./usbboot --uboot
   sudo ./usbboot -o 0x100000 -s 0x1000 --dump-partition ./ota.out
   xxd ./ota.out | head -3
   ```
   Confirm `ota:kernel` (stock) in the output. If it still shows `ota:kernel2`, run `--swap-ota` again and re-dump until the real bytes confirm stock.
5. Power-cycle normally (or press reset) to leave recovery mode and boot for real. It comes up on stock.

**What this changes:** only the OTA marker partition (`mmcblk0p1`), via the tool's own `--dump-partition`/marker-write path — it does not flash a kernel or rootfs, and does not touch the bootloader or partition table in this documented use.

## 4. Manual repair via SSH

If SSH is reachable on either slot, ordinary root access and shell tooling are available — but there is **no canonical, dedicated repair script** in this repo beyond what's already covered above (slot switch, component-update rollback). `NOT_PROVEN` / not invented here as a named procedure.

## 5. Complete factory restore

**Evidence: `NOT_PROVEN`, `EXTERNAL_TO_NEBULAOS`.** Creality publishes its own official recovery images and USB flashing tooling that reinstalls the entire board (bootloader, kernel, rootfs) to a factory-original state, using the same USB mask-ROM mode as §3. This project does not provide, redistribute, or pin any version of that tooling, and has never executed this procedure as part of its own qualification record. If you need this, treat it as Creality's own procedure, not a NebulaOS one — do not present it elsewhere in this project's docs as a tested NebulaOS recovery path.

## Data persistence across slots

| Data | Behavior | Evidence |
|---|---|---|
| `printer.cfg`, macros, `moonraker.conf` | `PERSISTENT_ACROSS_SLOT_SWITCH` | `DOCUMENTED_NOT_REVERIFIED` — dedicated, never-touched directory tree by design |
| Z offset / calibration, bed mesh | `PERSISTENT_ACROSS_SLOT_SWITCH` | `DOCUMENTED_NOT_REVERIFIED` — via `SAVE_CONFIG` into `printer.cfg`; the slot-switch scenario itself not directly re-tested |
| WiFi credentials (NebulaOS's own) | `PERSISTENT_ACROSS_SLOT_SWITCH` | `LIVE_HARDWARE_VERIFIED` — explicitly confirmed untouched during a real persistent-state reset |
| Moonraker config/state | `PERSISTENT_ACROSS_SLOT_SWITCH` | `LIVE_HARDWARE_VERIFIED` |
| GuppyScreen config/theme | `PERSISTENT_ACROSS_SLOT_SWITCH` | `LIVE_HARDWARE_VERIFIED` — verified across a real flash during the Final Closure mission (2026-08-15) |
| User G-code uploads | `PERSISTENT_ACROSS_SLOT_SWITCH` | `LIVE_HARDWARE_VERIFIED` — explicitly included in a real backup |
| Logs | `REGENERATED` | `DOCUMENTED_NOT_REVERIFIED` — 7-day rotation |
| Mainsail config | `UNKNOWN` | `NOT_PROVEN` for this project specifically |
| Camera config, timelapses | `UNKNOWN` | `NOT_PROVEN` |

Stock's own configuration (if any) lives in a **separate namespace** on the same shared `/usr/data` partition — switching to stock never exposes or overwrites NebulaOS's data, and vice versa. See `A_B_SLOT_MODEL.md`.

## Related documents

- `docs/A_B_SLOT_MODEL.md` — the partition/marker mechanics behind everything above
- `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md` — the same §2/§3 procedures, written for a less technical reader
- `docs/DEVELOPER_UPDATE.md` — what to do instead if the device is healthy and you just want a newer version
