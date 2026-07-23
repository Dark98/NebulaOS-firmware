# Printer Mainboard Pre-Connection Checklist

Part of the Nebula Pad stock-parity / board-port audit, Phase 10A (brought forward per the mission's
own instruction, ahead of the full board audit). The printer mainboard is physically disconnected
for this entire document - every row below is configuration/idle-state analysis, not a live
communication test.

**Status: NOT CLEAR TO CONNECT.** One real, active pin conflict was found on the printer-facing
UART's pin group. See "Blocking finding" below before anything else.

## Blocking finding: `uart1` (the printer MCU link) actively conflicts with `lcd_vdd_en` on custom

`printer.cfg`'s `[mcu] serial: /dev/ttyS1` is `uart1`. Live evidence, captured this session:

| | Stock | Custom |
|---|---|---|
| `uart1` `pinctrl-0` pin count | 2 pins (`GPC-23`, `GPC-24` only) | 4 pins (`GPC-21` through `GPC-24`) |
| `GPC-21` pinctrl claim | `(MUX UNCLAIMED)` - **stock never touches this pin for uart1** | `10031000.serial ... function uart1-pin group uart1-pc` |
| `GPC-21` GPIO claim | none | **`lcd_vdd_en`, `out hi`** (the LCD power-enable line) |

Both claims on custom (`uart1`'s pinctrl mux request and `lcd_vdd_en`'s GPIO output request) were
captured from the *same real boot* - this is a genuine, simultaneous, active conflict on the current
working image, not a hypothetical. The kernel fork's own `x2000-pinctrl.dtsi` defines only one
group for `uart1` (`uart1_pc`, `<&gpc 21 24>`) - the SoC vendor SDK offers no narrower alternative -
but **stock's real, running firmware only ever claims 2 of those 4 pins**, meaning stock's actual
kernel build uses a different (narrower, board-specific) group definition not present in this
project's copy of the SDK, or applies flow-control pins conditionally. Either way, the live
evidence is unambiguous: stock does not drive `GPC-21`/`GPC-22` for `uart1`, and custom does.

**Why this hasn't visibly broken anything yet:** `GPC-23`/`GPC-24` (TX/RX, the two pins that matter
for basic serial communication) match stock exactly. `GPC-21`/`GPC-22` are very likely RTS/CTS
(hardware flow control) - Klipper's own MCU serial protocol doesn't use hardware flow control, so
even if these two extra pins are non-functional or contested, `printer.cfg`'s actual communication
may not be affected. This is exactly the kind of thing that looks harmless until it isn't - a
lockdep-relevant double-claim on a live board, whose safe-by-luck-not-by-design status could change
with any future kernel/driver update, and `lcd_vdd_en` is a *power rail enable* line, not something
to leave ambiguous.

**Required before connecting the printer mainboard**: narrow custom's `uart1` `pinctrl-0` to match
stock's real 2-pin group (`GPC-23`/`GPC-24` only), as an isolated DT commit, then re-verify via this
same live-capture method that `GPC-21`/`GPC-22` return to stock's unclaimed state and `lcd_vdd_en`
is the pin's sole owner. This is real, board-specific work (finding or deriving the correct narrower
pinctrl group) that hasn't been done as of this audit pass.

## Printer connector signal inventory (what's known so far)

| Signal | Purpose | Pin (SoC) | Stock idle state | Custom idle state | Status |
|---|---|---|---|---|---|
| UART TX | MCU serial, host→MCU | `GPC-24` (part of `uart1_pc`) | Muxed to `uart1` alt-fn, not separately GPIO-claimed | Muxed to `uart1` alt-fn, not separately GPIO-claimed | Matches stock |
| UART RX | MCU serial, MCU→host | `GPC-23` (part of `uart1_pc`) | Muxed to `uart1` alt-fn | Muxed to `uart1` alt-fn | Matches stock |
| UART RTS or CTS (unconfirmed) | Hardware flow control (unused by Klipper's protocol) | `GPC-22` | Unclaimed on stock | Muxed to `uart1` alt-fn on custom - **not stock-matched** | **Blocking - see above** |
| UART RTS or CTS (unconfirmed) | Hardware flow control | `GPC-21` | Unclaimed on stock | Muxed to `uart1` alt-fn on custom, **and** separately GPIO-claimed as `lcd_vdd_en` | **Blocking - active conflict, see above** |
| Ground | - | Not a SoC pin - board-level | n/a | n/a | Not yet identified (needs schematic/PCB inspection, out of scope for register-level audit) |
| Power (connector supply rail) | - | Not a SoC pin | n/a | n/a | Not yet identified |
| Reset/boot/enable (if any) | MCU reset or bootloader-select | Not found | No pin in either system's capture is labelled `reset`/`boot`/`mcu` | Same | `UNKNOWN` - either this board has no such line (a plausible, common design for a simple UART-connected MCU) or it exists but isn't visible as a named GPIO consumer in this capture. Not resolved this pass. |

## Voltage domain

Not independently re-measured this session (no oscilloscope/multimeter capture taken). The kernel
fork's own history (`FIRMWARE.md`, the GPA voltage-domain fix found while investigating the J1 UART
header) already established Port A is provisioned 3.3V on the real device
(`ingenic,gpa_voltage = <0x02>` = `GPIO_VOLTAGE_3V3`, decoded from the real enum). `GPC` (where
`uart1` lives) was not part of that specific fix - its voltage domain configuration should be
re-checked directly (`ingenic,gpc_voltage` or equivalent property) before connecting anything,
rather than assumed by analogy to `GPA`. Not done in this pass.

## Gate criteria (from the mission brief) - current status

| Criterion | Status |
|---|---|
| printer UART pinmux matches stock | **NO** - see blocking finding above |
| printer UART idle level matches stock | Partially checked - TX/RX pins match; RTS/CTS pins do not (custom claims what stock leaves alone) |
| printer UART voltage domain confirmed | **Not done this pass** |
| no conflicting driver owns those pins | **NO** - `uart1` and `lcd_vdd_en` both claim `GPC-21` on custom right now |
| no unexpected TX activity present | Not measured this pass (would need a scope/logic analyzer capture, not attempted) |
| reset/boot/control pins match stock idle state | No such pin identified in either system yet - `UNKNOWN`, not `PASS` |
| connector power/ground pins identified | **Not done this pass** - needs schematic or physical PCB inspection |
| connector pinout documented | Partial - UART TX/RX/RTS/CTS pins identified at the SoC level; physical connector pin numbering not mapped |
| custom DTB matches intended configuration | **NO** - the `uart1` 4-pin group is the DTB not matching intended (stock-parity) configuration |
| stock/custom live pin-state comparison complete | Complete for the UART pins specifically; connector-level (ground/power) not done |

**Conclusion: do not connect the printer mainboard yet.** Two of the ten gate criteria are hard
failures (pinmux mismatch, active pin conflict), and several others are simply not yet done
(voltage domain re-check, TX idle waveform capture, connector power/ground identification). This
document should be re-run and re-updated after the `uart1` pin-group fix lands and is verified.
