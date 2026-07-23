# DTB Parity Report

Part of the Nebula Pad stock-parity / board-port audit. Phase 2: semantic comparison of the stock
live device tree (`vendor/device-backups/stock-live-device-tree-decoded.dts`, pulled from a real,
running stock device via `/sys/firmware/fdt`) against the *exact packaged* custom DTB from the
frozen baseline (`artifacts/parity/baseline/baseline-packaged.dtb`, decompiled to
`artifacts/parity/custom/custom-packaged.dts`).

**Methodology note**: phandle numbers are per-compilation and mean nothing across the two trees -
every phandle reference below was resolved to its real node (bank letter, pin group) by direct
lookup in the specific file it came from, not inferred from a previous session's numbers. One real
mistake was caught and corrected during this pass: phandle `0x08` was initially misremembered as
`gpc` from an earlier investigation; direct lookup in the exact same file shows `0x08` is actually
`gpa`, and `0x07` is `gpc`. The uart6/7 conclusions below reflect the corrected identity.

Live pinctrl claim state (`(MUX UNCLAIMED)` vs. a real `function ... group ...` binding) comes from
the `41`/`42`/`43` debugfs captures in `artifacts/parity/{stock,custom}/`, not from DT intent alone -
per the mission's own instruction, DT equivalence does not prove equivalent hardware state.

## `i2c0` (`10050000.i2c`)

| | Stock | Custom |
|---|---|---|
| `status` | `okay` | not present as a distinct node/instance |
| `pinctrl-names`/`pinctrl-0` | **absent entirely** | n/a |
| Live pinctrl claim | No entry at all in `42-debugfs-pinctrl-pinmux-pins.txt` - never requested | n/a |

**Classification: `STOCK_ENABLED_BUT_UNUSED` (likely vendor-DT residue).** `status = "okay"` with no
`pinctrl-0` at all is the same class of gap this project already found and fixed once before, for a
different bus (`i2c4`, `FIRMWARE.md` sec 32: "pinctrl-0 was missing entirely here... without this,
the bus may not actually be muxed to the real physical pins at all"). Here, unlike `i2c4`, nobody
has added the missing pinctrl - and live evidence confirms it: these pins are never claimed by
anything on the real, running stock device. No real stock function to preserve; custom's omission is
not a regression.

## `uart5`, `uart6`, `uart7`

| | Stock | Custom |
|---|---|---|
| `status` | `okay` (all three) | not present |
| `pinctrl-0` | Real, distinct phandles per UART (`uart5-pc`, `uart6-pa`, `uart7-pa`) | n/a |
| `uart5` pins | `gpc` (phandle `0x07`) pins 5-6 = `GPC-5`/`GPC-6` (gpio 69/70) | - |
| `uart6` pins | `gpa` (phandle `0x08`) pins 6-7 = `GPA-6`/`GPA-7` (gpio 6/7) | - |
| `uart7` pins | `gpa` (phandle `0x08`) pins 8-9 = `GPA-8`/`GPA-9` (gpio 8/9) | - |
| Live pinctrl claim (stock) | `10035000.serial ... function uart5-pin group uart5-pc` (and the equivalent for 6/7) - **genuinely, actively claimed** | All six pins: `(MUX UNCLAIMED) (GPIO UNCLAIMED)` |

**Classification: `STOCK_ENABLED_PURPOSE_UNKNOWN`** (revised from `STOCK_ENABLED_BUT_UNUSED` - a
disconnected printer mainboard proves nothing about why stock muxes these pins, only that nothing
was observed talking over them during this session). Unlike `i2c0`, this is **not** vendor-DT
residue - each UART has its own real, distinct pin group and the live debugfs capture proves the
pinctrl core genuinely committed the mux on the real running stock device. Follow-up evidence
gathered:

- `/proc/interrupts` on stock lists only `uart4`'s IRQ line - `uart5`/`6`/`7` never appear at all.
  8250-family UART drivers request their IRQ on `open()`, not at probe time, so this means nothing on
  stock has ever opened `/dev/ttyS5`/`6`/`7` during this session's uptime, not that the hardware can't
  fire an interrupt.
- `/dev/ttyS5`, `/dev/ttyS6`, `/dev/ttyS7` all exist as real device nodes (`crw-rw---- dialout`),
  confirming the driver bound successfully - consistent with "real, working, currently idle", not
  "broken" or "never initialized".

Likely candidates remain factory test points, a debug header, or reserved for a board variant not
populated on this SKU - none confirmed. **Do not enable in custom** without a positively identified
purpose - enabling three real, working UARTs with no known consumer just for DT-visual parity is
exactly the "configuration-checkbox parity" the mission explicitly says not to chase.

## `spi_gpio`

| | Stock | Custom |
|---|---|---|
| Pins | `GPE-16`/`17`/`18` (SCK/MOSI/MISO, bit-banged) + `GPE-21` (chip-select, named `spi2.0`) | Not present |
| Live pinctrl claim | `(MUX UNCLAIMED)` on all four - **expected and correct** for a bit-banged SPI bus, which drives pins as plain GPIO, never through a dedicated SPI alternate function | n/a |
| Live GPIO claim | All four actively claimed and named: `spi_gpio` (x3) and `spi2.0` (chip-select) - see `40-debugfs-gpio.txt` | n/a |

**Classification: `FACTORY_TEST_DEVICE` (moderate confidence).** Identified via
`/sys/bus/spi/devices/spi2.0/uevent` on the real, running stock device:

```
DRIVER=spidev
OF_NAME=spidev
OF_FULLNAME=/spi_gpio/spidev@0
OF_COMPATIBLE_0=rohm,dh2228fv
```

`rohm,dh2228fv` is a well-known Linux kernel/vendor idiom: a generic, non-specific compatible string
used specifically to bind the generic `spidev` driver (raw userspace SPI access via
`/dev/spidevX.Y`), not a real, function-specific kernel driver. `/dev/spidev2.0` exists, root-only
(`crw------- root root`). This pattern - a raw userspace-accessible SPI bus, no dedicated driver, and
root-only access - is the standard shape of a factory calibration/test tool interface, not an
end-user product feature. No consumer binary was positively identified in this bounded pass (a
broader `grep -r` across `/etc`/`/usr` repeatedly hit the SSH session's own timeout on this device
and was not completed - genuinely inconclusive, not negative evidence). Flagged for the Phase 4
SPI/QSPI audit if a full identification is ever needed. Per the safety rules, no SPI transactions
were sent and none should be until the child device's real function is confirmed.

## `MSC2` (`13490000.msc`)

| | Stock | Custom |
|---|---|---|
| `status` | Not present as an enabled node in the decoded live tree | `okay` |
| `cd-gpio` | n/a | `<0x08 0x0c 0x01 0x00>` = bank `gpa`... **correction**: resolving `0x08` in the *custom* packaged DTB (a separate compilation, own phandle numbering) - see below |
| `ingenic,sdr-gpio` | n/a | `<0x08 0x00 0x00 0x00>` |

**Important: the custom packaged DTB's phandle `0x08` was checked separately** (it is a different
compilation from the stock tree above, so its phandle numbering is independent) by cross-referencing
against the live `40-debugfs-gpio.txt` capture rather than assumed:

- `ingenic,sdr-gpio`'s pin `0x00` → bank position 0. `cd-gpio`'s pin `0x0c` (12) → bank position 12.
- Live debugfs shows `gpio-64` (labelled `ingenic,sdr`, `out hi`) and `gpio-76` (labelled `cd`,
  `in hi IRQ ACTIVE LOW`). `64` and `76` are both in the `GPC` range (base 64), at offsets 0 and 12 -
  **exact match** to the DT's pin `0` and pin `12` above. This confirms custom's MSC2 phandle `0x08`
  is `gpc`, independently, from live evidence (not by assuming it matches the stock tree's own
  numbering, which - as the `0x08 = gpa` correction above shows - would have been wrong to assume).

**`ingenic,sdr-gpio` = `GPC-0` (`gpio-64`) is a real, structural pin conflict, not speculation:**
`GPC-0` is the *exact* pin `pwm0_pc` uses for the real PWM alternate function
(`x2000-pinctrl.dtsi`: `pwm0_pc { ingenic,pinmux = <&gpc 0 0>; ... }`), and stock's own live debugfs
shows this same physical pin labelled `backlight_pwm0` (`in hi` at capture time - alt-function pins
read back as GPIO-input-mode in this debugfs format regardless of their real alt-function state, so
this is not itself conclusive, but the *identity* of the pin is: it's the one and only PWM0 pin on
this SoC). On custom, `GPC-0` is claimed *exclusively* by MSC2's `ingenic,sdr-gpio` property, driven
as a plain GPIO output HIGH - there is no separate `backlight_pwm0`-named claim on custom at all.

**Classification: `CUSTOM_ONLY_CONFLICTING` → `CUSTOM_REGRESSION_FIXED`.** Kernel fork commit
`72236226a` disables `&msc2` (`status = "disable"`, matching this codebase's own convention). Verified
on real hardware after rebuild+reflash: `mmc2` no longer appears under `/sys/bus/mmc/devices` (only
`mmc0`/`mmc1`), `GPC-0` and `GPC-12` no longer appear anywhere in the live GPIO claim list, `mmc0`
(eMMC) and `mmc1` (WiFi) probe identically to before with byte-for-byte the same trace evidence, and
WiFi/Moonraker/SQLite/OTA-auto-confirm all remain healthy. One important negative result: the
pre-existing `gpiod_set_value_cansleep: invalid GPIO (errorpointer)` dmesg warnings are **unchanged**
after this fix - confirmed, not assumed, that they were never MSC2-related. See
`docs/PIN_OWNERSHIP_MAP.md` for the full pin table.

## Audio DMIC (`134da000.as-dmic`)

Already documented in `docs/STOCK_PARITY_MATRIX.md` and this project's earlier audio investigation.
Confirmed present as a real node in the *custom* packaged DTB too (the `dtc` decompile emitted
`unit_address_vs_reg` warnings for it, meaning the node exists but its address annotation doesn't
match its `reg` property - a cosmetic DT authoring issue, not evidence either way about whether the
underlying hardware is populated). No new information this pass; still `AVAILABLE_DISABLED` pending
the dedicated Phase 4 audio feasibility study.

## Summary table

| Item | Classification | Action this pass |
|---|---|---|
| `i2c0` | `STOCK_ENABLED_BUT_UNUSED` (vendor-DT residue) | None needed - no real function to preserve |
| `uart5`/`6`/`7` | `STOCK_ENABLED_PURPOSE_UNKNOWN` (real pins, no IRQ activity, no open tty) | Leave disabled on custom; documented as a known gap, not a regression |
| `spi_gpio`/`spi2.0` | `FACTORY_TEST_DEVICE` (moderate confidence - generic `spidev`, root-only, no consumer binary found) | Flagged for Phase 4 SPI audit; no transactions sent |
| `MSC2` | `CUSTOM_REGRESSION_FIXED` - was a confirmed pin conflict with `pwm0`/backlight | **Fixed and verified**, `72236226a` |
| `as-dmic` (audio) | `AVAILABLE_DISABLED` (already documented) | No change this pass |
| `bt_reg_on` (`GPD-5`) | `BT_POWER_REQUIRED` (high confidence, see `docs/PIN_OWNERSHIP_MAP.md`) | Not implemented on custom; flagged for BT feasibility work |
| eFuse (`efuse-string-version`) | Real interface confirmed, consumer binary not identified (see `docs/STOCK_PARITY_MATRIX.md`) | `CONFIG_INGENIC_EFUSE_X2000` stays disabled |
