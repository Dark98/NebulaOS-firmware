# Frozen baseline - boot-cleanup continuation (Phase 3/5b/15/9/18, 2026-07-23)

Recorded before any change in this continuation cycle. This is the exact currently-running,
already-validated image from the previous cycle - no rebuild needed to establish this baseline.

## Git commits

| Repo | HEAD |
|---|---|
| Main repo (`ke-mainline-klipper`) | `f75ce0b6c7bc1db641be84822357f14a0e040cc0` |
| Kernel fork (`vendor/x2000_kernel_6.6`, branch `openke`) | `9d32ff87ed56192472010bf70fd0e9b8a14c0555` |

Working tree carries the same pre-existing, unrelated, externally-modified
`scripts/build/overlay/opt/guppyscreen/guppyscreen` (not part of this or any prior session's own
work) - not touched, not part of this baseline's scope.

## Artifact hashes (currently flashed and running on real hardware, custom slot `ota:kernel2`)

```
built_at=2026-07-23T14:03:14Z
kernel_config_sha256=722bb0fa892de870639ec9def4550a7f93437bb538791357e304c5dbc1310295
buildroot_config_sha256=a167f6ea07bf4c11a6d6995020a985cb8cb984a5ddc2009e7dd2e1e8108e3b1a
xImage_size=6520896
xImage_sha256=00c5914b01c9c9a809c79403c7811bcbc553cd41f971552bf56a0a5c1aff4bba
rootfs_squashfs_size=53952512
rootfs_squashfs_sha256=a9648b2e198c8b3a1443def7723ffc4bfcd1b731baead07b4e8ab4de47ca57dd
```

## Complete serial log at freeze time

`artifacts/parity/baseline-2026-07-23-boot-cleanup/dmesg-after-phase2-5-6-12.txt` - captured at the
end of the previous cycle, re-confirmed live (Moonraker healthy, `klippy_connected: true`) as the
starting point for this cycle. This is the baseline the Phase 3/5b/15/9 fixes below are layered on.

## Known-working state re-confirmed at this freeze point

- eMMC (`mmcblk0`, HS200, all 10 partitions), Wi-Fi SDIO (BCM43430/1 fw 7.46.58.13), display,
  backlight, touch (`ns2009_ts`), USB host, Moonraker (`/server/info` healthy), SQLite integrity,
  Klipper config parsing, GuppyScreen, `S99confirm-good`, automatic fallback - all previously proven
  and not re-broken by the previous cycle's fixes (confirmed via the post-fix dmesg capture and a
  live Moonraker health check at the end of that cycle).
- Printer UART1 software-equivalence gate: `CONNECTION_GATE_PASS_SOFTWARE_EQUIVALENCE` (unchanged,
  not touched by any work since that pass - see `docs/PRINTER_MAINBOARD_PRECONNECTION_CHECKLIST.md`).

## Scope note

No new build is performed to establish this baseline - the artifacts above are the real, currently
flashed, currently running system. Every subsequent phase's fixes in this cycle build on top of
`9d32ff87e` / `f75ce0b6c`, one isolated commit and hardware-validation cycle at a time.
