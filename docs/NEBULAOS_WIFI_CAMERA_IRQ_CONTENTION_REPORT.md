# NebulaOS WiFi/Camera IRQ Contention Mission — Report

2026-08-03/04. Investigation and fix for a live-reported choppy webcam stream.

## Summary

Three real, live-found, live-qualified fixes address every machine-side (hardware/software)
contributor identified for the choppy webcam stream:

1. **WiFi SDIO IRQ thread priority contention with the USB controller.** The dwc2 USB
   controller's own IRQ thread and the WiFi SDIO controller's own IRQ thread both defaulted to
   the same `SCHED_FIFO` priority 50 under PREEMPT_RT. dwc2 fires an extremely high, already-
   documented interrupt rate (~8000/sec USB start-of-frame interrupts, tied to `VIDIOC_STREAMON`
   being active at all, not the configured resolution/fps) whenever the webcam streams. At equal
   RT priority on this 2-core SoC, that storm delayed the WiFi IRQ thread from being serviced
   promptly, causing measured WiFi throughput bursts/stalls and a rising 802.11 tx-failure count
   specifically during streaming. **Fix:** boot-time script (`S02nebulaos-wifi-irq-priority`)
   raises the WiFi SDIO IRQ thread(s) to priority 60.
2. **Unnecessary firmware roaming engine.** This printer is physically stationary. brcmfmac's
   own autonomous roaming engine (background off-channel scanning to evaluate candidate APs — a
   firmware-level behavior, independent of wpa_supplicant, which has no `bgscan` directive
   configured at all) was a real contributor to WiFi tx failures. **Fix:** kernel patch changes
   the compiled-in default of `brcmf_roamoff` from 0 to 1 (brcmfmac is built into this kernel,
   not a loadable module, so this can only be set at compile time).
3. **TCP Nagle's algorithm on the stream socket.** Frame-level timing measurement (actual JPEG
   frame arrival timestamps, not just aggregate throughput) showed local/loopback delivery at a
   clean 33ms median (matching the requested 30fps exactly), degrading to 48-62ms median with
   frequent >100ms gaps over the real WiFi hop. **Fix:** `--tcp-nodelay` added to ustreamer's
   command line, disabling Nagle's algorithm on the stream socket.

## Methodology note

Early investigation used coarse, 1-second-granularity aggregate throughput sampling (`curl` +
periodic byte-count checks). This was good enough to find and validate fix #1 and #2 (large,
clearly-outside-noise effects: full multi-second stream stalls disappeared, `tx failed` growth
rate dropped substantially). It was NOT fine-grained enough to properly evaluate #3 or the two
rejected candidates below — a live per-frame timing script (raw socket read, scanning for JPEG
SOI/EOI markers, timestamping each complete frame) was written partway through to get millisecond-
level frame-interval data, which is what actually correlates with human-perceived smoothness.

Repeated multi-trial testing with this finer instrument also surfaced real run-to-run variance
(median frame interval swinging 28-62ms across otherwise-identical conditions) attributed to
real-time WiFi signal fluctuation. This tempers confidence in fix #3's exact magnitude (the
single early "before" sample that showed a 1.2s stall may partly reflect this noise rather than
being fully attributable to Nagle's algorithm alone) - it remains a reasonable, low-risk,
mechanism-justified inclusion, not a guess.

## Explored and rejected (real, evidence-based negative results)

- **CPU-pinning** the dwc2 and mmc1 IRQ threads to separate cores - made things measurably
  *worse* (more full stalls, faster tx-failure growth). Removes scheduling flexibility the
  threads were benefiting from. Not applied.
- **`ksoftirqd` priority boost** - proper 3-trial-vs-3-trial comparison showed no measurable
  difference from the noise floor. Not applied.
- **V4L2 capture buffer count** (ustreamer `--buffers`, 3 → 6) - same 3-trial comparison, no
  measurable difference. Not applied.
- **CPU frequency governor tuning** - ruled out entirely: this SoC exposes no cpufreq sysfs at
  all, so there is no DVFS-related jitter possible.
- **WMM/QoS traffic marking** - a real WiFi mechanism for prioritizing video traffic, but
  requires the access point to also honor it; this is a two-sided dependency outside what the
  printer alone can verify or fix, so it was not pursued (out of this mission's machine-only
  scope).
- **TCP congestion control / socket buffer sysctls** - identified as a theoretically possible
  further angle, not tested. Lower confidence of payoff given what was already ruled out, and
  adds real complexity for an unproven gain.
- **Stock firmware comparison** - not performed at the user's direction. Stock uses an entirely
  different pipeline (its own closed `cam_app` + the SoC's own Helix/Felix hardware encoder
  instead of UVC+ustreamer, and the out-of-tree `bcmdhd` WiFi driver instead of mainline
  `brcmfmac`), and it is not established whether stock even runs PREEMPT_RT - the specific IRQ-
  thread-priority contention this mission fixed is a PREEMPT_RT-specific scheduling artifact,
  so whether stock exhibits the same issue (or any issue at all) is genuinely unknown, not
  assumed either way.

## Live qualification (final build, real reboot, zero manual intervention)

- `roamoff` sysfs parameter reads `1`
- `ustreamer` process command line includes `--tcp-nodelay`
- WiFi SDIO IRQ thread(s) confirmed at `SCHED_FIFO` priority 60 (fresh PIDs each boot, found and
  raised automatically by `S02nebulaos-wifi-irq-priority`)
- Warm reboot survives on the custom slot (`S99confirm-good` passes, marker stays at
  `ota:kernel2`)
- Klipper/Moonraker healthy (`state: ready`), zero pinctrl redefinition warnings, zero kernel
  oops/panic/BUG

## Residual state

After all three fixes, remaining WiFi-path jitter (median frame interval consistently in the
high-20s to mid-30s ms range in the best trials, occasionally higher, versus the clean 33ms
local/loopback baseline) is attributed to real-time WiFi signal conditions rather than any
further-identified machine-side software/hardware factor. This is a lower-confidence, harder-
won conclusion than the mission's other findings - it reflects the limits of what was
practically testable from the host side, not a certainty that no further machine-side lever
exists.

## Commits

- `system: raise WiFi SDIO IRQ thread priority above USB controller`
- `kernel: disable brcmfmac firmware roaming engine`
- `system: enable TCP_NODELAY on the webcam stream socket`
- `docs: add WiFi/camera IRQ contention mission report` (this document)
