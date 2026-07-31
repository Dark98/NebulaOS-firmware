# NebulaOS Alpha Integration Baseline

**This is not a production release.** It is the common integrated development
platform against which future NebulaOS experiments for the Creality Ender-3
V3 KE + Nebula Pad are measured, starting 2026-08-01. Individual components
below have differing levels of evidence behind them — see "Confirmed live
behavior" and "Known limitations." Accepting this as the baseline means
accepting it as an integrated, functionally-healthy platform, not a completed
performance conclusion for every component.

## Baseline identity

```
Name:                   NEBULAOS-ALPHA-MAX-RT
Frozen:                 2026-08-01
Kernel source pin:      295b7101d751fd888ae39e6f1746a4a940664a5f (unchanged
                        across both builds below)
Build command:          sh scripts/build/build-alpha-baseline.sh
Composition assertion:  sh scripts/build/assert-alpha-baseline.sh
Deployment report:      docs/NEBULAOS_ALPHA_MAX_RT_DEPLOYMENT_REPORT.md

DEPLOYED (the actual image running on real hardware):
  main repo commit:      d479161f8a0a1d18207870a32316d45b434e6244
  kernel.config sha256:  68eaeaa70f8c9e0fc99bf11d809c20f2e22d866a4821d434e2533575fdd36fff
  device tree sha256:    910e0ccec08c8da8c69a9921e0fdf587abb36ca786ffd684dc1db88eb182b7f0
  xImage sha256:         51f1bd1b2c6737251b50fe2f5ef1413db029192a9c42673c03d601b0c4ec622b
  rootfs.squashfs sha256: 3216389b4d05c4b3ce92c96032d75ea90190a379101e405be2c6e2dc01205c77
  package: build-work/deploy-packages/NEBULAOS-ALPHA-MAX-RT-20260731T215619Z/

CLEAN REBUILD (produced fresh, after Phases 2-5's fixes, to prove
reproducibility - not deployed):
  main repo commit:      aa0fcc580cbeb57b705c4f52d882c2a9ce662031
  kernel.config sha256:  68eaeaa70f8c9e0fc99bf11d809c20f2e22d866a4821d434e2533575fdd36fff  (IDENTICAL)
  device tree sha256:    910e0ccec08c8da8c69a9921e0fdf587abb36ca786ffd684dc1db88eb182b7f0  (IDENTICAL)
  xImage sha256:         12a0250b2598f07645ba1eaad9ce8ab95e9165301b7228dc906a0803e1d31930  (differs)
  rootfs.squashfs sha256: e1110366080effd5d2d89da45ddee923d6f0bbe4c2440042cdfbb7c2add326c7  (differs)
  package: build-work/deploy-packages/ALPHA-BASELINE-20260731T230214Z/

The kernel Kconfig and device tree are BYTE-IDENTICAL between the deployed
image and a from-scratch rebuild days apart - genuine reproducibility at the
configuration level. xImage and rootfs.squashfs differ, but every single
content-level difference was traced and explained (extracted both images
and diffed recursively): BusyBox and OpenSSL's libcrypto each embed their
own exact compile timestamp directly in the binary (confirmed via `strings`:
"BusyBox v1.36.1 (<timestamp>)", "built on: <timestamp>"); every busybox
multi-call symlink/hardlink in /bin,/sbin,/usr/bin inherits that same
difference; Python `.pyc` files embed a source-mtime cache-invalidation
header even when the underlying source is byte-identical; `/etc/shadow`'s
root password hash differs only in its random salt (same credential); the
factory-seed `.tar.gz`/manifest `.json` files differ due to gzip's own
timestamp header and a generation-timestamp field. Zero unexplained
differences.

## Included components

| Component | Selection |
|---|---|
| Kernel preemption | R1 — `CONFIG_PREEMPT_RT=y` |
| Timer frequency | `CONFIG_HZ=100` (unchanged) |
| SDIO | W3 — `cap-sdio-irq` + `cap-sd-highspeed` (`cap-mmc-highspeed` removed) |
| Wi-Fi power save | P1 — off (`iw dev wlan0 set power_save off`, runtime marker) |
| Wi-Fi MAC | existing eMMC-CID-derived, locally-administered, deterministic |
| Wi-Fi association | fixed (non-event-driven) sequence, unchanged |
| Country code | `ccode=CN`, unchanged |
| Camera (active) | 1920x1080 @ 30fps |
| Camera (idle) | C2 — grace-period idle pause/resume, runtime marker |
| First boot | venv seed archives + the `c03757e` factory-seed dirty-tree fix |
| Rootfs | Zstandard SquashFS, Python bytecode-only, native-extension stripping, all previously accepted userspace optimizations |

P1 and C2 are **runtime markers** on `/usr/data/nebulaos/maintenance/`, not
build-time selections — a freshly flashed alpha-baseline image boots with
Wi-Fi power-save on (P0-equivalent default firmware behavior) and the camera
always-active (C0) until those two markers are explicitly written on the
device, exactly as during the real deployment recorded in the deployment
report.

## Confirmed live behavior

All of the following were directly observed on real hardware (Ender-3 V3 KE
+ Nebula Pad), not inferred:

- Boots successfully, both on first flash and across a warm reboot
- Wi-Fi associates with real, active traffic
- Klipper reaches `state: ready`
- Moonraker API responds correctly (`klippy_state: ready`)
- GuppyScreen runs
- Camera streams at 1080p30, and C2's full pause→resume cycle works
  (confirmed: paused → snapshot request → resumed → second snapshot fast)
- Protected user data (gcode files, printer config, macros) verified
  byte-for-byte unchanged across the whole deployment sequence
- Stock firmware was never written — only ever the OTA-marker target
  between custom-slot flashes
- `S00revert-safety`/`S99confirm-good` self-healing rollback confirmed
  working end-to-end (marker only advances after Moonraker is genuinely
  detected healthy)

## Known limitations

- **W3 (SDIO) has no measured performance benefit yet** — functionally
  healthy on live hardware (clean enumeration, real Wi-Fi traffic, no
  MMC/SDIO errors), but no throughput/latency measurement was taken to
  justify it over W0. `docs/NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md`'s own
  Wi-Fi decision matrix still lists W0 as the no-measured-benefit default;
  W3 was selected for this alpha baseline as an integration/coverage choice
  (prove the combination builds and boots), not a performance conclusion.
- **PREEMPT_RT's latency benefit is not quantified.** RT builds, boots, and
  runs the full non-motion stack correctly; the DWC2 USB controller's IRQ is
  confirmed genuinely threaded under RT (the predicted highest-risk
  behavior), and it kept up with the real-time SOF cadence without
  observable failure — but no `cyclictest`-based worst-case scheduler
  latency was measured. RT remains experimental per the mission's own fixed
  decision; this baseline does not claim RT is validated for production.
- **C2 does not reduce the ~8,000/sec DWC2 SOF interrupt rate.** Measured
  directly (~8,036/sec while genuinely paused) — see the correction recorded
  in `docs/NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md` and the
  `C2_PAUSED_IRQ_RATE` field in the deployment report. C2's real, confirmed
  benefit is eliminating idle camera network-stream traffic and the
  associated ustreamer JPEG-encode CPU work — not a USB-interrupt
  mitigation. Do not describe it as one.
- **The real factory `sn_mac` partition (`/dev/mmcblk0p2`) is not yet used by
  NebulaOS.** Found during live Mode B qualification: stock firmware
  correctly reads a real, per-unit factory MAC from this partition; NebulaOS
  still derives its own MAC from the eMMC CID instead. The CID-derived
  mechanism is confirmed working and stable, but per this project's own
  decision rule, a factory-programmed MAC should be preferred when present,
  with the CID-derived method retained only as a fallback. Not yet
  implemented.
- **Event-driven Wi-Fi association is implemented but not enabled** — the
  fixed `sleep 2` sequence remains the default; the event-driven alternative
  exists in the overlay but was never selected for this baseline.
- **True 15fps camera behavior is not fixed.** `v4l2-ctl` confirms the
  camera hardware genuinely supports an exact 15.000fps interval, but
  ustreamer itself negotiates 25fps when asked for 15 — a real,
  ustreamer-level quirk, not yet corrected.
- **Cold-boot (physical power-cycle) testing remains limited** — only warm
  reboots were exercised for the stable-MAC and Alpha-Max-RT validation;
  `COLD_BOOT_MAC_VALIDATION` is still pending a manual power cycle.
- **ModemManager (binary + support files) is still present in every build's
  rootfs this entire project, including this baseline** — found while
  writing this baseline's own artifact-composition assertions
  (`scripts/build/assert-alpha-baseline.sh`). This contradicts this
  project's own historical "ModemManager removed" claim among the accepted
  production optimizations. D-Bus itself is confirmed absent from the
  Buildroot configuration, so ModemManager cannot actually run — this is
  dead weight in the image, not a functional regression, but the historical
  claim is inaccurate and should be corrected or the package actually
  removed in a future mission.
- **Extended and physical print testing remains user-managed** — this
  baseline has not been through any motion, heating, extrusion, or print
  testing. That is explicitly out of scope for how this baseline was
  produced and is left to the user.

## Real engineering findings from freezing this baseline

Two genuine, previously-undetected defects were found and fixed while doing
the work to freeze this baseline (not before) — both are documented in
detail in their own commits and are worth knowing about before extending
this baseline further:

1. **The SDIO/PREEMPT variant test suites used to silently reset the real
   tracked vendor DTS/fragment config to W0/R0 on exit**, discarding
   whatever variant had actually been selected before the suite ran. This
   is exactly what caused the first Alpha-Max-RT build attempt to silently
   ship a plain baseline image despite the source correctly selecting
   W3+R1 beforehand — caught only by inspecting the built artifact's own
   hashes, not by any test's exit status. Fixed in
   `tests/wifi-sdio-variant-tests.sh`, `tests/preempt-variant-tests.sh`, and
   (found again, in the very act of fixing the first two)
   `tests/variant-state-preservation-tests.sh` itself. See
   `scripts/build/assert-alpha-baseline.sh` for the build-failing
   composition gate this whole class of bug motivated.
2. **The tracked `artifacts/buildroot-halley5-v30-image/halley5_v30.dts`
   reference snapshot was drastically stale** — it showed msc0 (the real
   eMMC boot storage) as disabled/4-bit/50MHz, missing ~486 lines of real,
   historical Wi-Fi/msc0 fix work that the actual pinned vendor kernel
   already has. This never broke a real build (builds always read DTS
   content from the live vendor checkout, never this tracked snapshot), but
   every `git checkout --` performed after a variant build this project has
   ever done was unknowingly re-preserving that staleness rather than
   curing it, since no session had re-committed a genuinely fresh snapshot
   since the copy-back mechanism was introduced. Fixed by copying the real,
   current, clean vendor kernel DTS into the tracked path.

## Future experiment rule

**Future optimization experiments should change exactly one variable
relative to this baseline.** Where a combined change is genuinely
unavoidable, the change set must be explicitly documented — every variable
that differs from this baseline, not just the one under test — so a later
reader can tell what was actually being measured.

Do not re-freeze this baseline document for a new configuration without
re-running `scripts/build/assert-alpha-baseline.sh` against the new
artifact and updating both "Included components" and "Known limitations"
to match reality, not aspiration.
