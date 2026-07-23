# BAIC4 / DMIC Audio Investigation

Part of the "Nebula Pad beeper and audio-pin conflict investigation" (2026-07-23). Covers Phases
5-7 of that mission: whether BAIC4 has any real product consumer, what its GPD pins actually carry,
and why DMIC never registers. See `docs/BEEPER_CONTROL_PATH.md` for the separate, independently-
proven finding that the hardware beeper is entirely unrelated to any of this.

## Phase 6: BAIC4's GPD pins, decoded from source (not inferred)

`&as_be_baic` (`ingenic,as-baic`, `x2000.dtsi`) is a **single physical device** covering all 5 BAIC
channels via `ingenic,dai-array = <0>, <1>, <2>, <3>, <4>;` - "BAIC0" and "BAIC4" are two channels of
the *same* controller, not separate devices:

| Channel | DT `dai-mode` | Data pins | Real consumer (per `halley5_v20.c`) |
|---|---|---|---|
| BAIC0 | `PCM/DSP/I2S` | 1 | `inno_icodec` - CPU DAI `"BAIC0"` + CODEC `"10020000.icodec"` (on-chip codec) |
| BAIC4 | `PCM/DSP/I2S` | 1 | `baic4_bt` - CPU DAI `"BAIC4"` + `COMP_DUMMY()` (external, no on-chip codec) |

The DAI link variable name itself - `baic4_bt` - identifies BAIC4 as the Bluetooth SCO/voice-audio
PCM backend for the WiFi/BT combo chip, not a speaker or microphone input. `&as_be_baic`'s single
`pinctrl-0 = <&baic4_pd>` property (`ingenic,pinmux = <&gpd 2 5>`, `x2000-pinctrl.dtsi:576`) is BAIC4's
own external routing - `GPD-2`/`GPD-3` are the bit/frame clock and data lines to the external combo
chip, `GPD-4`/`GPD-5` double as `wlan_reg_on`/`bt_reg_on` on this board. BAIC0/icodec doesn't use any
of these pins at all: it talks to an **on-chip** codec, and `as-baic.c` (the driver backing both
channels) never calls into the pinctrl API anywhere in its own source - the `pinctrl-0` property is
applied automatically by the Linux driver-core's generic `pinctrl_bind_pins()` mechanism before
`->probe()` runs, entirely independent of what the driver code itself does with any channel.

**This is why removing `pinctrl-0` from `&as_be_baic` is safe**: the driver has no explicit
dependency on it succeeding or existing, and BAIC0's own signal path is physically internal.

## Phase 5: does BAIC4 have any real, reachable product consumer?

No - on every dimension checked:

- **No ALSA card registers at all on custom**, confirmed live: `/proc/asound/cards` → `--- no
  soundcards ---`, `/proc/asound/pcm` → empty. This was true *before* today's fix too - the DMIC
  DAI link's perpetual `-EPROBE_DEFER` blocked the entire card's registration, so even the
  confirmed-real BAIC0/icodec path was never actually reachable through ALSA either, despite its own
  `dev_info` "Sound Card successed" printing at an earlier, non-final stage.
- **`as-dma` IRQ counter stayed `0`/`0`** across a real, controlled beeper test (see
  `docs/BEEPER_CONTROL_PATH.md`) - no audio-subsystem DMA activity from anything on this boot.
- **Bluetooth's own HCI transport doesn't work on this board** (separate, already-documented
  `uart3`/`i2c4` pin conflict, `FIRMWARE.md` §54) - BAIC4's only plausible purpose (Bluetooth SCO
  voice audio) has no working transport underneath it to ever be reached from, regardless of the
  ASoC/pinctrl question.
- **Product category**: this is a 3D-printer control pad, not a phone or headset - Bluetooth SCO
  voice audio is not a sensible feature for this product even if Bluetooth transport is fixed later.

**Classification: `UNUSED_REFERENCE_DESIGN_BLOCK`** for the BAIC4 *endpoint and its external pin
claim* specifically (not for `as_be_baic`/BAIC0 as a whole, which stays enabled).

## Phase 7: DMIC deferred-probe root cause

The `"DMIC"` DAI link's CPU-side component can only ever come from `&as_dmic`
(`compatible = "ingenic,as-dmic"`). A prior session (`FIRMWARE.md` §43) disabled `&as_dmic` for a
real, confirmed reason: it was claiming `GPC-21`, needed for `uart1`/the printer MCU link
(`"pin GPC-21 already requested by 134da000.as-dmic; cannot claim for 10031000.serial"` on a real
boot). That fix was correct and is not reconsidered here. But the DMIC DAI link itself, in
`halley5_v20.c`'s static `x2000_dais[]` array, was never made conditional on `&as_dmic` actually
being present - so with no DT node left to ever register a `"DMIC"` component, `snd_soc_register_card()`
retried that one link forever, keeping the *entire* card (including the real, working BAIC0/icodec
path) permanently unregistered.

**Classification: `INVALID_REFERENCE_DESIGN_LINK`** - not a missing driver or Kconfig gap, a static
DAI link with no possible producer given this board's own already-correct DT configuration.

## Fix implemented

Kernel fork commit `cafd5986c`: removed the `"DMIC"` and `"BAIC4"` DAI link entries (and their
now-unused `SND_SOC_DAILINK_DEFS`) from `halley5_v20.c`'s `x2000_dais[]`, and removed
`&as_be_baic`'s `pinctrl-0 = <&baic4_pd>` from the board DTS. `BAIC0`/`icodec` - the only DAI link
with a real, confirmed, on-chip consumer - is untouched. The beeper (`docs/BEEPER_CONTROL_PATH.md`)
is entirely separate from all of this and is unaffected either way.

## Not touched, and why

- **`as_be_baic` itself stays enabled** (only its now-orphaned `pinctrl-0` was removed) - BAIC0's
  real function depends on the device probing successfully.
- **`DMA0`-`DMA9` front-end DAI links, `as-platform`/`as-dsp`/`as-mixer`/`as-spdif`/`icodec`** - all
  untouched, all part of BAIC0's real, working signal path or otherwise unrelated to this
  investigation's scope.
- **The beeper's `guppybeep`/PWM/GPC-3 path** - proven entirely independent, not touched.
