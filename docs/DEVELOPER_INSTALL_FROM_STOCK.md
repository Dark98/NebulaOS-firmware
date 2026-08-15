# Installing a developer build from stock

**Developer / advanced testing documentation.** These procedures expose raw firmware images, partitions, A/B boot slots, SSH/root access, and recovery mechanisms. They document the current NebulaOS development workflow and are not presented as a supported consumer installer.

See `docs/A_B_SLOT_MODEL.md` first if you haven't — this document assumes you already understand the two-slot layout and the OTA marker.

## Evidence status

`SCRIPT_VERIFIED` for every individual step below (each command is real, current, and matches the actual scripts in this repo as of this writing). The sequence as a whole is `HISTORICALLY_HARDWARE_VERIFIED` with one specific, real gap:

> The flashing mechanism and first-boot sequence have been exercised on real hardware, including a full persistent-state reset scenario (the 2026-08-08 virgin-flash mission) that reproduces everything a first install does *except* one thing: that device had already had NebulaOS's custom slot (`mmcblk0p6`/`p8`) written and booted before. No run in this project's own qualification archive begins from a printer whose custom slot has literally never been written. The write mechanism itself has no code path that distinguishes "first ever write" from "re-write" — there's no specific reason to expect it behaves differently — but that expectation has not been verified end-to-end from a genuinely virgin slot.

This is a real, open item, not hidden here. It does not block development use; it means "first install" specifically hasn't had its own dedicated hardware run.

## Prerequisite: root/SSH access on stock

This procedure assumes the printer already has SSH and root access on its stock Creality firmware. **Obtaining that is out of scope for this document and for NebulaOS as a project** — it's the same standing assumption other Creality K1/KE-family mod projects make. If you don't already have this, this isn't the place to start.

## The sequence

```
stock printer, root/SSH already available
        |
1. build or obtain: xImage, rootfs.squashfs, build-manifest.txt
   (from `./build.sh` - see docs/BUILD_FROM_SOURCE.md)
        |
2. scp xImage rootfs.squashfs build-manifest.txt scripts/flash-spare-slot.sh
   root@<printer-ip>:/usr/data/<some-staging-dir>/
        |
3. sha256sum the four transferred files, independently, before touching
   the flash script - confirm they match what you scp'd
        |
4. sh flash-spare-slot.sh --check-only xImage rootfs.squashfs build-manifest.txt
        |
5. sh flash-spare-slot.sh xImage rootfs.squashfs build-manifest.txt
        |
6. flip the marker to custom (see docs/A_B_SLOT_MODEL.md for why this
   is stock's own tool, not NebulaOS's):
   . /etc/ota_bin/ota_local_method.sh; local_set_next_boot_device
        |
7. reboot
        |
8. S00revert-safety / S04 factory-seed+migrate / S5x services / S99confirm-good
   (see docs/A_B_SLOT_MODEL.md - this is the same sequence every boot goes through)
```

### Why `/usr/data` for staging, not `/tmp`

`/tmp` is a small `tmpfs` on this board and can genuinely run out of space partway through a multi-hundred-megabyte transfer (`rootfs.squashfs` alone is well over 100 MB). `/usr/data` is the real, ~6 GB persistent partition — stage there.

### Step 4/5 in detail — what `flash-spare-slot.sh` actually checks

Both the check-only and real run execute the identical preflight (the real run repeats it immediately before writing, specifically so a check-only pass earlier in time is never treated as still-valid authorization):

1. **Slot mapping** — verifies both slots' partlabel symlinks (`/dev/disk/by-partlabel/{kernel,kernel2,rootfs,rootfs2}`) resolve to the exact hardcoded device nodes, and that the label and the device agree on major:minor — catches an unexpected GPT before trusting anything else.
2. **Active slot** — resolves the real, live boot device from `/proc/cmdline`'s own `root=` value (not `/proc/mounts`' aliased `/dev/root`, which can't distinguish the two slots at all).
3. **Target slot** — always slot 2 (custom), not user-selectable.
4. **Live-target collision** — refuses outright if target and active slot are the same. This is the check that exists because of a real prior incident (see `A_B_SLOT_MODEL.md`).
5. **Image sizes** — checked against the real, fixed partition capacities (8,388,608 bytes kernel / 524,288,000 bytes rootfs), not recomputed from `/proc/partitions` at runtime.
6. **Manifest/hash verification** — if `build-manifest.txt` is given, both files' sizes and SHA-256 are checked against its recorded `xImage_size`/`xImage_sha256`/`rootfs_squashfs_size`/`rootfs_squashfs_sha256` fields. This argument is optional; every real qualification run on record provided it.

Only after both preflight passes succeed does the real write happen: `dd` to the target device, then a read-back of exactly the written byte count (never the whole partition, so a shorter new image can't accidentally compare against leftover trailing data from a larger old one), MD5-compared against the source file.

**The script does not flip the OTA marker.** That's step 6 above, a separate and deliberate action — writing new images to the inactive slot and actually booting them are two different decisions.

## What this does and doesn't touch

Only `mmcblk0p6` (kernel2) and `mmcblk0p8` (rootfs2) are written. Stock's own `mmcblk0p5`/`p7` are never touched — enforced in code, not just intent (see `A_B_SLOT_MODEL.md`). `/usr/data` (persistent storage, shared between both OSes) is untouched by this entire sequence.

## Related documents

- `docs/A_B_SLOT_MODEL.md` — the partition layout and marker mechanics this procedure relies on
- `docs/DEVELOPER_UPDATE.md` — updating an already-installed NebulaOS
- `docs/DEVELOPER_RECOVERY.md` — what to do if this doesn't boot correctly
- `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md` — the day-to-day switching guide once both slots are populated
