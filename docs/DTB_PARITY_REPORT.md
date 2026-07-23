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

**Classification: `STOCK_ENABLED_BUT_UNUSED` (pin-level), purpose not yet identified.** Unlike
`i2c0`, this is **not** vendor-DT residue - each UART has its own real, distinct pin group and the
live debugfs capture proves the pinctrl core genuinely committed the mux on the real running stock
device. This is deliberate board wiring, not an inherited-and-ignored reference-board default.
However, no evidence of an active *consumer* was found in this pass (`/proc/tty/driver/serial`
doesn't exist on this stock kernel build to check open/usage counts, and no userspace reference was
found in the captured inventory). Likely candidates: factory test points, a debug header, or
reserved for a board variant not populated on this SKU. **Do not enable in custom** without a
positively identified purpose - enabling three real, working UARTs with no known consumer just for
DT-visual parity is exactly the "configuration-checkbox parity" the mission explicitly says not to
chase.

## `spi_gpio`

| | Stock | Custom |
|---|---|---|
| Pins | `GPE-16`/`17`/`18` (SCK/MOSI/MISO, bit-banged) + `GPE-21` (chip-select, named `spi2.0`) | Not present |
| Live pinctrl claim | `(MUX UNCLAIMED)` on all four - **expected and correct** for a bit-banged SPI bus, which drives pins as plain GPIO, never through a dedicated SPI alternate function | n/a |
| Live GPIO claim | All four actively claimed and named: `spi_gpio` (x3) and `spi2.0` (chip-select) - see `40-debugfs-gpio.txt` | n/a |

**Classification: `REAL_STOCK_FUNCTION`, exact child device not yet identified.** The presence of a
distinctly-named, actively-driven chip-select GPIO (`spi2.0`) is strong evidence of a real, bound SPI
child device - this is not vendor-DT residue. What it actually talks to isn't identified in this
pass (would need the DT's `spi@2,0`-style child node inspected directly, not yet located in the
decoded stock tree by address). Flagged for the Phase 4 SPI/QSPI audit. Per the safety rules, no
transactions were sent and none should be until the child device is identified.

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

**Classification: `CUSTOM_ONLY_UNVERIFIED`, real pin conflict with a working peripheral
(backlight PWM).** This matches the mission's own leading hypothesis (inherited Halley5
reference-board MSC2 definition, no physical slot on this board, no stock usage) and adds concrete,
structural evidence beyond "no card responds": the `sd-gpios`/`sdr-gpio` placeholder-that-isn't-
actually-a-placeholder is actively claiming a pin a real, working subsystem needs. **Recommendation:
disable MSC2** (`&msc2 { status = "disabled"; };`) as an isolated commit, then verify eMMC/WiFi/
backlight are all unaffected and the `GPC-0`/`GPC-12` pins return to stock-equivalent unclaimed
state. See `docs/PIN_OWNERSHIP_MAP.md` for the full pin table.

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
| `uart5`/`6`/`7` | `STOCK_ENABLED_BUT_UNUSED` (real pins, unknown consumer) | Leave disabled on custom; documented as a known gap, not a regression |
| `spi_gpio` | `REAL_STOCK_FUNCTION` (child device confirmed, not identified) | Flagged for Phase 4 SPI audit; no transactions sent |
| `MSC2` | `CUSTOM_ONLY_UNVERIFIED`, confirmed pin conflict with `pwm0`/backlight | **Recommend disabling** - see `docs/PIN_OWNERSHIP_MAP.md` |
| `as-dmic` (audio) | `AVAILABLE_DISABLED` (already documented) | No change this pass |
