# NebulaOS Display Prototype Readiness

Companion to [NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md](NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md) §11,
[NEBULAOS_DISPLAY_LIVE_READ_ONLY_REPORT.md](NEBULAOS_DISPLAY_LIVE_READ_ONLY_REPORT.md), and
[NEBULAOS_DISPLAY_OFFLINE_IMPLEMENTATION_PLAN.md](NEBULAOS_DISPLAY_OFFLINE_IMPLEMENTATION_PLAN.md).
Powered-on display/touch investigation mission, 2026-08-01. Final readiness classification for
each of the three candidates, per the mission's own stated per-candidate rules.

## DISPLAY-B1 (kernel backlight-class integration)

**Status: BLOCKED_PENDING_HARDWARE_PROOF**

| Rule | Met? | Evidence |
|---|---|---|
| Real hardware path proven | **NO** | No software backlight ever existed to test; GPC-0/GPC-22's raw electrical behavior could not be read even live (this kernel's debugfs GPIO/pinctrl interfaces are absent) - see hardware-test-matrix.tsv HT-01 |
| Real DT compile passed | **YES** | Genuine `make dtbs` via `docker run --user root ... make ARCH=mips ... dtbs` produced `halley5_v30.dtb`; decompiled and confirmed `nebulaos_backlight{compatible="pwm-backlight"; pwms=<&pwm 0 20000>; ...}` present exactly as designed |
| Backlight node appears exactly once | YES | Confirmed via the decompiled DTB and the 9 passing offline tests |
| Safe initial values chosen | YES | `default-brightness-level=8` (mid-range of 0-15), not full-on/full-off |
| No unresolved polarity conflict | YES | This prototype deliberately does not wire an enable-GPIO, sidestepping that question entirely |

**What would unblock it**: HT-01 (a read-only devmem/gpioinfo check of GPC-0/GPC-22, or a kernel
rebuild with debugfs GPIO/pinctrl enabled) followed by HT-09 (spare-slot deployment, confirming
`/sys/class/backlight/*/brightness` actually changes physical panel brightness). Both are
already defined in `docs/NEBULAOS_DISPLAY_LIVE_QUALIFICATION_PLAN.md`.

**Remaining unknowns**: whether GPC-0/GPC-22 are genuinely wired to a real backlight circuit at
all, or whether the panel's illumination is tied to an always-on rail with no software control
possible - UNKNOWN_UNTIL_HARDWARE, unchanged since the offline mission.

## DISPLAY-V1 (VSYNC-synchronized pan_display)

**Status: READY_FOR_ISOLATED_DEPLOYMENT**

| Rule | Met? | Evidence |
|---|---|---|
| VSYNC IRQ semantics proven | **YES** | Live: DPU IRQ (hwirq 31, "lcdc-1") measured ~60.3Hz over a 10s sample. Source: `ingenicfb_set_vsync_value()` re-read directly confirms `wake_up_interruptible()` fires unconditionally on every real vsync event (a correction to this mission's own earlier mischaracterization - see the offline implementation plan) |
| Locking reviewed | YES | Reuses the exact `unlock_fb_info()`/`wait_event_interruptible_timeout()`/`lock_fb_info()` pattern this driver's own `FBIO_WAITFORVSYNC` ioctl handler already uses - no raw spinlock held while sleeping, no new synchronization primitive introduced |
| Bounded timeout exists | YES | 34ms (~2 frame periods at ~59.98Hz) |
| Fallback exists | YES | Applies the frame switch immediately on timeout/interruption/blank - never blocks indefinitely |
| Compile succeeds | **YES** | Genuine `make module_drivers/.../ingenicfb.o` via docker, with `CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y` selected - zero errors, zero warnings |
| Tests pass | YES | 10/10 (`tests/display-vsync-variant-tests.sh`) |
| Only pan-display path changes | YES | `ingenicfb_pan_display()` + the vsync sequence counter bump in `ingenicfb_set_vsync_value()` (same subsystem) |

**All criteria met.** A full authoritative build (W3 SDIO + R1 PREEMPT_RT + DISPLAY-V1,
changing only the named feature relative to the alpha baseline) was produced and packaged - see
"Deployment package" below.

**Remaining unknowns**: whether the closed tearing race was ever actually user-visible in
practice (GuppyScreen's own pan-display calling pattern is unknown - binary only, no source
vendored) - this prototype closes a proven race regardless of whether it was previously
perceptible, and the live qualification plan's HT-04 remains the way to observe any visible
before/after difference.

## TOUCH-I1 (IRQ-assisted touch-down)

**Status: BLOCKED_PENDING_HARDWARE_PROOF**

| Rule | Met? | Evidence |
|---|---|---|
| GPIO79 wiring sufficiently proven | **PARTIAL** | Live: confirmed no existing IRQ claim anywhere in the system-wide `/proc/interrupts` table, and the pin is real/connected (already used for level-based polling, physically validated in a prior mission). NOT confirmed: raw pinmux/IRQ-capability of GPIO79 specifically (this kernel's debugfs GPIO/pinctrl interfaces are absent) |
| IRQ trigger proven | **NO** | The active-high/low and edge-direction semantics were never established from source/disassembly alone, and this prototype deliberately works around that (requesting both edges) rather than confirming it |
| Driver requests IRQ successfully in source/DT design | YES (design) | `ns2009_setup_pendown_irq()` correctly attempts `gpiod_to_irq()` + `devm_request_threaded_irq()`; whether it *succeeds* on real hardware is unconfirmed |
| Polling fallback exists | YES | The existing 30ms poll is never modified, disabled, or made conditional - it is unconditionally active regardless of IRQ outcome |
| Storm handling exists | YES | Rolling 1-second/50-edge threshold, permanent fallback to poll-only on trip |
| Compile succeeds | **YES** | Genuine `make drivers/input/touchscreen/ns2009.o` via docker, with `CONFIG_TOUCHSCREEN_NS2009_PENDOWN_IRQ=y` selected - zero errors, zero warnings |
| Tests pass | YES | 12/12 (`tests/touch-irq-variant-tests.sh`) |

**Per the mission's own explicit rule ("when wiring remains ambiguous, mark it blocked")**, this
is classified BLOCKED despite compiling cleanly and passing every test - the IRQ trigger
polarity genuinely was never proven, only safely worked around. This is not the same as saying
the prototype is unsafe to test: its whole design exists specifically so that an unconfirmed or
wrong trigger assumption cannot produce a wrong touch state or a loss of input (see the offline
implementation plan's "why edge-triggering makes 'remains asserted' safe by construction"
section) - it is safe to deploy for the specific purpose of resolving this exact blocker
(HT-05 in the live qualification plan), just not yet classified "ready" in the formal sense this
mission defines.

**What would unblock it**: a kernel rebuild with debugfs GPIO/pinctrl enabled (to directly read
GPIO79's live pinmux/trigger-capability before ever touching hardware), or a spare-slot
deployment of this exact prototype with the debugfs `irq_count`/`irq_active` counters watched
during real touch use (HT-05).

## Deployment package (DISPLAY-V1 only)

Per the mission's own rule ("a blocked candidate may receive a source-only report but no
deployment recommendation"), only DISPLAY-V1 (the sole READY candidate) was built and packaged.
DISPLAY-B1 and TOUCH-I1 remain source-only (patch + toggle script + tests, all compile-verified,
no full image built) pending their respective hardware-proof steps.

Package location: `build-work/deploy-packages/NEBULAOS-DISPLAY-V1-<timestamp>/` (gitignored,
matching this project's established convention for build outputs). Contents: `xImage`,
`rootfs.squashfs`, `halley5_v30.dts`, `kernel.config`, `build-manifest.txt`, `SHA256SUMS`,
`variant-difference.txt` (documents the one change relative to the alpha baseline: DISPLAY-V1
only - W3/R1/CID-MAC/C2 all unchanged from the tagged baseline composition). See
`docs/NEBULAOS_DISPLAY_LIVE_QUALIFICATION_PLAN.md`'s test guide section for the exact deployment
(spare slot only), rollback, and live test sequence.

## Summary

```
READY_FOR_ISOLATED_DEPLOYMENT:
    DISPLAY_B1=NO
    DISPLAY_V1=YES
    TOUCH_I1=NO
```
