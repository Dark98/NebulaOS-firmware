# Pin Ownership Map (targeted, Phase 3A)

Part of the Nebula Pad stock-parity / board-port audit. Covers only the pins flagged as open
questions by `docs/DTB_PARITY_REPORT.md` - `i2c0`, `uart5`/`6`/`7`, `spi_gpio`, `MSC2`, plus the
already-established WiFi/BT control pins for cross-reference. A full board-wide map (every enabled
pin) is Phase 3B, not attempted here.

All data below is live evidence: `artifacts/parity/{stock,custom}/40-debugfs-gpio.txt` (GPIO claim,
direction, raw level) and `42-debugfs-pinctrl-pinmux-pins.txt` (pinctrl/alt-function claim), captured
at a comparable boot stage on each system per `scripts/parity/capture-state.sh`. Gpio numbering:
`GPA`=0-31, `GPB`=32-63, `GPC`=64-95, `GPD`=96-127, `GPE`=128-159 (`gpio-N` = bank base + offset).

| Pin | Bank/offset | Stock mux claim | Custom mux claim | Stock GPIO owner | Custom GPIO owner | Direction/level (stock) | Direction/level (custom) | Classification |
|---|---|---|---|---|---|---|---|---|
| `GPC-0` | `gpc` offset 0 (`gpio-64`) | `(MUX UNCLAIMED)` at capture time (real alt-function pin for `pwm0`, per `x2000-pinctrl.dtsi`'s `pwm0_pc`) | `(MUX UNCLAIMED)` | `backlight_pwm0`, `in hi` | `ingenic,sdr` (MSC2's `ingenic,sdr-gpio`), `out hi` | in, hi | **out, hi** | **CONFLICT** - custom drives as GPIO output what is `pwm0`'s only real pin on this SoC. See MSC2 finding below. |
| `GPC-12` | `gpc` offset 12 (`gpio-76`) | No claim in stock's capture | `cd` (MSC2's `cd-gpio`), `in hi IRQ ACTIVE LOW` | (none) | `cd` | unclaimed | in, hi, IRQ, active-low | `CUSTOM_ONLY_UNVERIFIED` - MSC2 card-detect. No known physical slot; safety rules forbid probing further without identifying real routing. |
| `GPC-5` | `gpc` offset 5 (`gpio-69`) | `10035000.serial` function `uart5-pin` group `uart5-pc` | `(MUX UNCLAIMED)` | (none named) | (none) | muxed to uart5 alt-fn | fully unclaimed | `STOCK_ENABLED_BUT_UNUSED` |
| `GPC-6` | `gpc` offset 6 (`gpio-70`) | `10035000.serial` function `uart5-pin` group `uart5-pc` | `(MUX UNCLAIMED)` | (none named) | (none) | muxed to uart5 alt-fn | fully unclaimed | `STOCK_ENABLED_BUT_UNUSED` |
| `GPA-6` | `gpa` offset 6 | `10036000.serial` function `uart6-pin` group `uart6-pa` | `(MUX UNCLAIMED)` | (none named) | (none) | muxed to uart6 alt-fn | fully unclaimed | `STOCK_ENABLED_BUT_UNUSED` |
| `GPA-7` | `gpa` offset 7 | `10036000.serial` function `uart6-pin` group `uart6-pa` | `(MUX UNCLAIMED)` | (none named) | (none) | muxed to uart6 alt-fn | fully unclaimed | `STOCK_ENABLED_BUT_UNUSED` |
| `GPA-8` | `gpa` offset 8 | `10037000.serial` function `uart7-pin` group `uart7-pa` | `(MUX UNCLAIMED)` | (none named) | (none) | muxed to uart7 alt-fn | fully unclaimed | `STOCK_ENABLED_BUT_UNUSED` |
| `GPA-9` | `gpa` offset 9 | `10037000.serial` function `uart7-pin` group `uart7-pa` | `(MUX UNCLAIMED)` | (none named) | (none) | muxed to uart7 alt-fn | fully unclaimed | `STOCK_ENABLED_BUT_UNUSED` |
| `i2c0` pins | not resolved - no `pinctrl-0` property exists to resolve | No claim anywhere in `42-debugfs-pinctrl-pinmux-pins.txt` | n/a (not present) | (none) | n/a | fully unclaimed | n/a | `STOCK_ENABLED_BUT_UNUSED` (vendor-DT residue - no pin wiring was ever added) |
| `GPE-16` | `gpe` offset 16 (`gpio-144`) | `(MUX UNCLAIMED)` (expected - bit-banged) | n/a | `spi_gpio`, `out hi` | (none) | out, hi | n/a | `REAL_STOCK_FUNCTION` (SPI SCK or MOSI, bit-banged) |
| `GPE-17` | `gpe` offset 17 (`gpio-145`) | `(MUX UNCLAIMED)` | n/a | `spi_gpio`, `out hi` | (none) | out, hi | n/a | `REAL_STOCK_FUNCTION` |
| `GPE-18` | `gpe` offset 18 (`gpio-146`) | `(MUX UNCLAIMED)` | n/a | `spi_gpio`, `in hi` | (none) | in, hi | n/a | `REAL_STOCK_FUNCTION` (likely MISO) |
| `GPE-21` | `gpe` offset 21 (`gpio-149`) | `(MUX UNCLAIMED)` | n/a | `spi2.0` (chip-select), `out hi` | (none) | out, hi | n/a | `REAL_STOCK_FUNCTION` - named child device confirms a real, bound SPI peripheral exists |
| `GPA-1` | `gpa` offset 1 (`gpio-1`) | (unnamed on stock in this capture format for GPA - see note) | `wifi_bt_power_regula` | `bt_wifi_power`, `out lo` | `out lo, ACTIVE LOW` | out, lo | out, lo (correctly annotated active-low) | `PARITY_CONFIRMED` - shared WiFi/BT rail, same raw electrical state, cross-referenced against this project's own earlier fix (kernel fork history) |
| `GPD-4` | `gpd` offset 4 (`gpio-100`) | `wlan_reg_on`, `out hi` | `wlan-reg-on`, `out hi` | out, hi | out, hi | out, hi | out, hi | `PARITY_CONFIRMED` |
| `GPD-5` | `gpd` offset 5 (`gpio-101`) | `bt_reg_on`, `out hi` | **not present in custom's capture at all** | out, hi | (none) | out, hi | unclaimed | **New finding, see below** |

## New finding: stock has a dedicated `bt_reg_on` pin custom never claims

Stock's live GPIO dump shows **two separate** reg-on pins: `GPD-4` (`wlan_reg_on`) and `GPD-5`
(`bt_reg_on`), both driven `out hi`. Custom's WiFi work (this project's own, extensively documented
`WL_REG_ON` investigation) only ever identified and drove `GPD-4`. `GPD-5`/`bt_reg_on` does not
appear anywhere in custom's debugfs GPIO capture - it's not claimed by anything.

This is a real, previously-unknown difference, surfaced by this audit rather than the original WiFi
bring-up work (which was scoped to WiFi only, and succeeded without ever needing this pin - the
combo chip's BT side apparently doesn't require its own reg-on toggle to at least power up, since
custom's WiFi works fine without ever touching `GPD-5`). It may explain part of why BT doesn't work
on custom beyond the already-documented `uart3`/`i2c4` pin-sharing conflict - even if the UART pins
were freed up, BT might still need this dedicated enable line raised. **Not acted on in this pass** -
flagged for the Phase 4 audit's Bluetooth feasibility classification. Per the safety rules, this pin
must not be driven experimentally without first confirming its stock-equivalent idle/active levels
and whether raising it has any effect independent of the `uart3` conflict.

## `uart1` (printer MCU link) - fixed and verified

Not in this map's original scope, but found during the same audit and fixed before this document
was finalized: `uart1` claimed a 4-pin group (`GPC-21..24`) where stock only claims 2
(`GPC-23`/`24`), and `GPC-21` was simultaneously claimed by `lcd_vdd_en` as a plain GPIO output - a
real, active conflict, not hypothetical. Fixed in kernel fork commit `970bd6b83` (new board-local
`uart1_pc_txrx` group, `gpc 23-24` only) and verified live: `GPC-21`/`GPC-22` now read
`(MUX UNCLAIMED)`, `lcd_vdd_en` is `GPC-21`'s sole owner, `uart1` claims only `GPC-23`/`24`. Full
details: `docs/PRINTER_MAINBOARD_PRECONNECTION_CHECKLIST.md`.

## MSC2 disable recommendation (from `DTB_PARITY_REPORT.md`)

`GPC-0` and `GPC-12` are the two pins at stake. Disabling `&msc2` should return both to stock's own
unclaimed/PWM-alt-function state. The exact verification steps (before connecting anything else)
belong in a dedicated commit, not this document - see the "Required next checkpoint report" for the
proposed isolated commit and its post-rebuild verification checklist.

## Not yet covered (Phase 3B)

This pass only covers the pins in dispute. The full board pin map (eMMC, WiFi SDIO, display, touch,
USB, camera, all UARTs/I2C/SPI, PWM, ADC, RTC, watchdog, audio, Ethernet, buttons, external
connectors) is Phase 3B, done after the high-risk items above are resolved, per the mission's own
phase ordering.
