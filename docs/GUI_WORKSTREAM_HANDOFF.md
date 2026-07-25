# GUI Workstream Handoff (Display + Touch)

Display and touch work on the Nebula Pad / Ender-3 V3 KE custom Linux 6.6.18-rt23 image ends here.
This document is the single, concise handoff record for whoever picks up the next workstream.

**Classification: `FUNCTIONAL_GUI_BASELINE`, `DISPLAY_DRIVER_FUNCTIONAL_BASELINE`,
`TOUCH_DRIVER_FUNCTIONAL_BASELINE`, `USERSPACE_GUI_FUNCTIONAL`.** Display root cause and touch root
cause are both confirmed and fixed, physically validated on real hardware. Not manufacturing
qualified, not reliability validated, not security hardened - those are separate, later milestones.

## GUI baseline

| | |
|---|---|
| Tag (both repos) | `functional-gui-baseline-2026-07-25` |
| Kernel fork commit | `f7ff80a8aa21886a32783dab167e451298c60a8d` |
| Kernel config SHA-256 | `5a3c6ad0211b04ff2209bdbeffb62c23542ffb3229b029797fed8c096dd479f4` |
| Buildroot config SHA-256 | `c4ade03f2d40872bd5f2b2ebcc008d8403a9dd5a248472e1312b6c43e68eb03b` |
| Final rootfs (squashfs) SHA-256 | `c4765acb3fa5ea82a70f8b05db67b7254be2e5c5769673bdec17891f88da58e4` |
| Final kernel image (xImage) SHA-256 | `2f8e023f2de2402a1a9874fedacffb61e7d78985ae4b0a5b363f58447b9cfdcf` |
| Build manifest | `artifacts/buildroot-halley5-v30-image/build-manifest.txt` |

## Display: root cause confirmed and fixed

Panel output mode is **RGB565** (`TFT_LCD_MODE_PARALLEL_565`), proven from stock's own live
`DC_TFT_CFG` register (physical `0x13059010` = DPU base `0x13050000` + offset `0x9010`) while stock
was booted and running - not inferred, not guessed. Two prior guesses (`PARALLEL_888`, then
`PARALLEL_666` with and without dithering) were tested and reverted; both were wrong bus widths. The
real value decodes to `0b010` under this driver's own `dpu_reg.h` bitfield definitions
(`DC_MODE_LBIT=0`, `DC_MODE_HBIT=2`).

Cache/DMA coherency and DPU FIFO/underrun were both ruled out with live evidence before touching bus
mode: a full-frame-rewrite experiment (`fbrefresh`) while GuppyScreen ran physically changed nothing,
and the DPU's own interrupt counters (`CONFIG_FB_INGENIC_DUMP=y`,
`/sys/devices/platform/ahb0/13050000.dpu/debug/dump_irqcnts`) showed `tft_under: 0` / `wdma_over: 0`
across tens of thousands of real interrupts with GuppyScreen active.

**GPIO 85 / PC21 must remain unmanaged** (no `ingenic,vdd-en-gpio` DT property) - this is the earlier,
separately-confirmed fix for the completely-dark-panel defect and is unrelated to the RGB565 fix. Do
not reopen it without new direct evidence.

Two other real stock/custom register divergences were found during this investigation and
deliberately left alone, since the display is already fixed and matching them for parity alone would
add risk to a working configuration:

- `DC_SYNC_DL` (`DC_TFT_CFG` bit 8): stock=1, custom=0.
- CGU pixel-clock-inversion bit (physical `0x10000064`, bit 26): stock=1, custom=0.

## Touch: root cause confirmed and fixed

Custom's generic upstream `ns2009.c` driver gates touch detection on the NS2009 chip's Z1 pressure
ADC channel (`>=80` threshold) - proven, via temporary rate-limited kernel instrumentation, to read
exactly `0` on every single poll on this real board regardless of touch state. Stock's closed
`ns2009_touch.ko` never uses Z1 at all; it's interrupt-driven instead, confirmed via
relocation-verified MIPS disassembly (`gpio_to_desc(79)` → `gpiod_to_irq()` →
`devm_request_threaded_irq()`) and a real `Unbalanced enable for IRQ 74` kernel warning captured live
during stock's own `ns2009_open()`. Stock's I2C read commands for X/Y (`0xc0`/`0xd0`) are
byte-identical to custom's - the coordinate read path itself was never the problem, only how a press
is detected.

**Touch pendown GPIO: GPIOC pin 15 / global GPIO 79, active-low** (`pendown-gpios = <&gpc 15
GPIO_ACTIVE_LOW INGENIC_GPIO_NOBIAS>` on the `ns2009@48` node in `halley5_v30.dts`). Custom's
`ns2009.c` gates `ns2009_ts_report()`'s pen-down detection on this GPIO's level when the property is
present.

**Touch fallback: Z1 polling remains for any other board using this driver without a `pendown-gpios`
property** - the original upstream behavior is untouched when the property is absent, so this change
is board-specific and doesn't alter the generic driver's behavior elsewhere.

Physically validated twice: all four corners and center activate accurately (no offset, no missed
taps), matching stock - once on the initial fix, and again on the final build after removing the
temporary diagnostic logging used during investigation.

## Calibration

Custom's `guppyconfig.json` touch calibration coefficients were separately found to be wildly wrong
(magnitudes 9-380x off stock's) and corrected to match stock's proven values exactly, via a verified
backup + atomic write (temp file, `fsync`, rename, directory `fsync`). This alone did not fix touch
(the real defect was zero coordinate events reaching userspace at all) but is a real, necessary,
low-risk correction now that events flow correctly. Stock's own `guppyconfig.json` was never modified
(hash-verified unchanged before and after).

## Remaining items - not blockers

- **Cold power-on** (as opposed to a software reboot) was not independently tested - no remote power
  control on this hardware. This is a validation gap, not an unresolved design issue; perform it the
  next time physical power cycling is convenient.
- **`DC_SYNC_DL` and the CGU pixel-clock-inversion divergences** (see above) are known, nonblocking,
  deliberately untouched.
- **Calibration persistence** across reboots already survived earlier reboots during this
  investigation; a future routine reboot can reconfirm it without a dedicated investigation.

## Final assessment

| | |
|---|---|
| Display root cause | CONFIRMED AND FIXED |
| Touch root cause | CONFIRMED AND FIXED |
| Stock data integrity | PRESERVED |
| A/B recovery | PRESERVED |
| Application stack | HEALTHY |
| GUI workstream | COMPLETE |

The next workstream should start from this frozen baseline rather than reopening display or touch.
