# Frozen baseline - boot-cleanup investigation (2026-07-23)

Recorded before any Phase 2-18 change in the "Nebula Pad Linux 6.6 boot-cleanup investigation and
remediation" mission. This is a separate, later baseline than the printer-port-audit baseline from
earlier the same day - do not confuse the two, and do not amend either retroactively.

## Git commits

| Repo | HEAD | Notes |
|---|---|---|
| Main repo (`ke-mainline-klipper`) | `3b179f5c17cc07f5616bbcf7b11dc5901631ac45` | Working tree has one pre-existing, unrelated modification (`scripts/build/overlay/opt/guppyscreen/guppyscreen` + untracked `themes/`) from outside this session - not touched, not part of this baseline's scope. |
| Kernel fork (`vendor/x2000_kernel_6.6`, branch `openke`) | `d945c07f1b97c944b86fbb24f90c6c1512a8223a` | One commit ahead of the mission brief's own list (`095970ba2`/`970bd6b83`/`72236226a`) - `d945c07f1` (canonical `"disabled"` status string for MSC2) is a real, already-verified, already-flashed commit from the same prior session, correctly part of the current running system. |

## Config / artifact hashes (last verified build, timestamp 2026-07-23 14:15 CEST - this is the
build currently flashed to the custom slot and running on real hardware)

```
sha256(kernel.config)          = b418c7d5c81f84154df101bd86c290162c5e8d55dd401221d0393042d3a48537
sha256(buildroot.config)       = 49a0afc5d238bf95371202dada85c50223703fe0439850a20eeda73fa846beff
sha256(xImage)                 = 7be344d06bec89d9d1842c4852ea9f1ac7538b5af61a62d5666ceb4002c86a3b
sha256(rootfs.squashfs)        = 0093d73634452d553a3d8defc3ca412e80da97745184fa4070052ca10ef11d61
sha256(rootfs.ext2)            = acb3f7860735679909abc3c06ee748b8a3fffc1d649453b39093041e7c7cb239
sha256(custom-packaged.dts)    = 1e496e1f63b56fadffe9b63d67f28b24f0e8025cbc947ad71d79dbc72ebb4310
```

`custom-packaged.dts` is the decompiled form of the actual booted DTB, captured earlier the same
session (`artifacts/parity/custom/custom-packaged.dts`) - used here as the "packaged DTB hash"
since the vendor build embeds the DTB into `xImage` rather than producing a standalone `.dtb`
artifact; `xImage`'s own hash above is the authoritative artifact-level check.

No `build-manifest.txt` exists yet for this artifact set (it predates the manifest mechanism added
in commit `26fdec1`, mid-session) - the hashes above were computed directly from the artifact files.
Every build from Phase 2 onward will produce a real manifest per `05-final-build.sh`.

## Complete serial log at freeze time

Captured via `dmesg` on the currently-running custom system (slot `ota:kernel2`), full kernel ring
buffer from cold boot through `Run /linuxrc as init process` (236 lines - the point where dmesg
naturally stops, before userspace log messages, which don't go through the kernel ring buffer):

- `dmesg-part1.txt` - lines 1-101
- `dmesg-part2.txt` - lines 95-236 (small overlap by design, to guarantee no gap)

This is the exact log this mission's Phase 1 inventory is built from. It does **not** include
userspace service startup, Wi-Fi association, DHCP, Moonraker, Klipper, GuppyScreen, or
`confirm-good` - per the mission's own noted "Input log limitation," every future validated build
must capture a complete boot through steady idle plus one clean shutdown/reboot, not just this
kernel-only slice.

## Known-working state at freeze time (re-confirmed live, not assumed)

- `Linux 6.6.18-rt23` boots on real hardware, custom slot (`ota:kernel2`).
- eMMC (`mmcblk0`, `HS200`, all 10 partitions) enumerates correctly.
- Wi-Fi SDIO enumerates; `BCM43430/1` firmware `7.46.58.13` loads via the generic (non-board-specific)
  filename fallback.
- Moonraker `/server/info` returns `klippy_connected: true` (re-confirmed this same boot,
  `wget` to `127.0.0.1:7125`).
- `ota:kernel2` marker confirmed via `dd` readback immediately before this baseline was recorded.
- `S99confirm-good` had already run successfully on this boot (per its own log line seen at login:
  "Moonraker confirmed healthy, ota marker flipped forward").

## Scope note

This baseline intentionally does not re-run a fresh build - the currently-flashed, currently-running
image (verified minutes earlier) is treated as the frozen starting point for the boot-cleanup work
that follows. Every subsequent phase's fixes will be layered on top of `d945c07f1` /
`3b179f5c17cc07f5616bbcf7b11dc5901631ac45`, one isolated commit and one hardware-validation cycle at
a time, per the mission's own commit discipline.
