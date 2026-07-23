# Printer Mainboard Pre-Connection Checklist

Part of the Nebula Pad stock-parity / board-port audit, Phase 10A (brought forward per the mission's
own instruction, ahead of the full board audit). The printer mainboard is physically disconnected
for this entire document - every row below is configuration/idle-state analysis, not a live
communication test.

**Status (updated 2026-07-23, software-only equivalence pass): `CONNECTION_GATE_PASS_SOFTWARE_EQUIVALENCE`
for the SoC-side signal path.** Every criterion that can be proven from software (pin-controller,
GPIO-register, clock, reset, UART-register, driver-ownership, protocol identity) now matches stock.
Proof boundary: this covers the SoC pin/register/driver layer only, not independent PCB routing or
analog voltage measurement, which is accepted from the known-working stock design per this pass's
own acceptance standard (no oscilloscope/multimeter available). **This is not yet authorization to
physically connect a mainboard** - see "Phase F conclusion" and "Still required before Phase G"
below; that step needs an explicit, separate human decision regardless of gate status.

## RESOLVED: `uart1` (the printer MCU link) no longer conflicts with `lcd_vdd_en`

Kernel fork commit `970bd6b83` narrows `uart1`'s `pinctrl-0` to a new board-local 2-pin group
(`uart1_pc_txrx`, `gpc 23-24` only), matching stock exactly. Verified on real hardware after
rebuild+reflash:

- `GPC-23`/`GPC-24`: claimed only by `uart1` (`function uart1-pin group uart1-pc-txrx`).
- `GPC-21`: `(MUX UNCLAIMED)` - no longer touched by `uart1`. Live GPIO dump confirms `lcd_vdd_en`
  is its sole owner.
- `GPC-22`: fully unclaimed by anything, matching stock.
- Zero regressions: WiFi re-associated (real DHCP lease), Moonraker `/server/info` healthy,
  `PRAGMA integrity_check` returns `ok`, `S99confirm-good` auto-confirmed the boot.

The original finding (kept below for the record) remains accurate as a description of what was
wrong and why it mattered.

## Original finding (now fixed): `uart1` actively conflicted with `lcd_vdd_en` on custom

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

**Fixed and verified** - see "RESOLVED" above.

## Printer connector signal inventory (what's known so far)

| Signal | Purpose | Pin (SoC) | Stock idle state | Custom idle state | Status |
|---|---|---|---|---|---|
| UART TX | MCU serial, host→MCU | `GPC-24` (`uart1_pc_txrx`) | Muxed to `uart1` alt-fn, not separately GPIO-claimed | Muxed to `uart1` alt-fn (`uart1_pc_txrx`), not separately GPIO-claimed | Matches stock |
| UART RX | MCU serial, MCU→host | `GPC-23` (`uart1_pc_txrx`) | Muxed to `uart1` alt-fn | Muxed to `uart1` alt-fn (`uart1_pc_txrx`) | Matches stock |
| (was mistakenly claimed by `uart1`) | Hardware flow control (unused by Klipper's protocol) | `GPC-22` | Unclaimed on stock | **Fixed**: fully unclaimed, matches stock | Resolved |
| `lcd_vdd_en` | LCD power enable | `GPC-21` | n/a on stock (pin unused by stock's `uart1`) | **Fixed**: `lcd_vdd_en` is the sole owner, no more `uart1` contention | Resolved |
| Ground | - | Not a SoC pin - board-level | n/a | n/a | Not yet identified (needs schematic/PCB inspection, out of scope for register-level audit) |
| Power (connector supply rail) | - | Not a SoC pin | n/a | n/a | Not yet identified |
| Reset/boot/enable (if any) | MCU reset or bootloader-select | Not found | No pin in either system's capture is labelled `reset`/`boot`/`mcu` | Same | `UNKNOWN` - either this board has no such line (a plausible, common design for a simple UART-connected MCU) or it exists but isn't visible as a named GPIO consumer in this capture. Not resolved this pass. |

## Voltage domain - RESOLVED (software-only, no instrument needed)

`GPC` (where `uart1` lives) has no software-configurable voltage-domain property at all: the
pinctrl driver (`pinctrl-ingenic.c:1966-1992`) only ever parses `ingenic,gpa_voltage` and
`ingenic,gpe_msc_voltage` by hardcoded name - there is no `gpc_voltage` (or equivalent) property
anywhere in the driver for any other bank. `GPC`'s I/O voltage is therefore a fixed hardware
characteristic of this SoC, not something either stock's or custom's devicetree can set
independently - **stock and custom structurally cannot differ here**, closing this criterion without
a multimeter. Full detail: `docs/PIN_OWNERSHIP_MAP.md`, "`uart1` register-level... equivalence
proof" section.

## Printer MCU signal identity - RESOLVED (Phase D, software-only, 2026-07-23)

Found via read-only inspection of stock's own vendor firmware (`/etc/init.d/S13mcu_update`,
`/usr/bin/mcu_util`) - the single most direct evidence available: stock's own board-detection logic
(`get_sn_mac.sh board` → `NEBULA V1.0.0.1`, `get_sn_mac.sh model` → `F005`, both confirmed matching
this exact device) selects `mcu0_serial=/dev/ttyS1` - i.e. **`uart1` is officially, by stock's own
firmware, the printer/toolhead MCU link**, not a guess or an inference from pin geometry.

- Protocol: `mcu_handshake()` calls `mcu_util -i /dev/ttyS1 -c` at boot (`S13mcu_update`, part of
  `rcS`). This ran automatically during our stock capture (no mainboard attached) and its own log
  (`/tmp/mcu_update.log`) shows: `usart_rec_Process: select time out, state = 2` ... `handshake
  /dev/ttyS1 fail, ret=1`. **This is the single most valuable piece of evidence in this pass**:
  stock's own reference firmware, with no mainboard physically attached, handles that exact
  condition as a clean protocol timeout - not a hang, not a crash, not a bus fault. "No mainboard
  connected" is a normal, anticipated, gracefully-handled state in the known-good firmware, which is
  exactly the state our bench setup is in.
- Custom's own `printer.cfg` independently targets the same physical UART for the same purpose:
  `[mcu] serial: /dev/ttyS1`, `baud: 230400`, `restart_method: command` - i.e. custom's own Klipper
  config was already written assuming `uart1` = printer MCU link, before this audit ever started.
- Reset/boot/enable signal: grepped `S13mcu_update` and `strings`-scanned `/usr/bin/mcu_util` for
  `reset|gpio|boot|mcu_en|mcu_power` - **zero matches**. No separate hardware reset/boot-select GPIO
  is used by stock's own MCU-update flow; the handshake/flash protocol appears to be entirely
  UART-native (a bootloader-over-serial pattern, consistent with this being Klipper firmware on the
  mainboard MCU too). Classification: **`NO_SOFTWARE_CONTROL_SIGNAL_IDENTIFIED`** for a discrete
  reset/boot pin - not "unknown, might exist", but "actively searched, stock's own tooling doesn't
  use one."
- Transmission safety (Phase C): on custom, no process currently holds `/dev/ttyS1` open (`/proc/*/fd/*`
  scan empty), and `uart1` does not appear in `/proc/interrupts` on either stock or custom while
  idle - consistent with "nothing is actively driving this line right now" on both systems. Console
  remains on `ttyS4`/`uart4` on both stock and custom - `uart1` is not reused as a getty/debug
  console on either system.

## Printer connector signal inventory (updated)

| Signal | Purpose | Pin (SoC) | Stock idle state | Custom idle state | Status |
|---|---|---|---|---|---|
| UART TX | MCU serial, host→MCU | `GPC-24` (`uart1_pc_txrx`) | Muxed to `uart1` alt-fn, not separately GPIO-claimed | Muxed to `uart1` alt-fn (`uart1_pc_txrx`), not separately GPIO-claimed | **MATCH** |
| UART RX | MCU serial, MCU→host | `GPC-23` (`uart1_pc_txrx`) | Muxed to `uart1` alt-fn | Muxed to `uart1` alt-fn (`uart1_pc_txrx`) | **MATCH** |
| (was mistakenly claimed by `uart1`) | Hardware flow control (unused by Klipper's protocol) | `GPC-22` | Unclaimed by `uart1` on stock | Fixed: fully unclaimed, matches stock | **RESOLVED** |
| `lcd_vdd_en`/`lcd_power_en` | LCD power enable (not a printer signal) | `GPC-21` | Not claimed by `uart1` | Not claimed by `uart1` | **MATCH** (not `uart1`'s concern either way) |
| UART protocol/purpose | Printer MCU link identity | n/a | Confirmed by `S13mcu_update`/`mcu_util`, board="NEBULA V1.0.0.1" model="F005" | `printer.cfg` `[mcu] serial: /dev/ttyS1 baud: 230400` targets the same UART for the same purpose | **MATCH** |
| Reset/boot/enable (MCU) | MCU reset or bootloader-select | Searched, not found | No such GPIO used by stock's own MCU-update tooling | Same - not implemented, not needed to match stock | `NO_SOFTWARE_CONTROL_SIGNAL_IDENTIFIED` (resolved: confirmed absent in stock's own reference, not an open unknown) |
| Voltage domain (`GPC`) | - | Not a DT/software-configurable property on this SoC | n/a | n/a | **RESOLVED** - structurally cannot differ, see above |
| Ground | - | Not a SoC pin - board-level | n/a | n/a | Still not identified - connector/PCB fact, not a software-observable one; accepted from the known-working stock design per this pass's own scope (same physical connector, untouched by any of our work) |
| Power (connector supply rail) | - | Not a SoC pin | n/a | n/a | Same as ground - connector/PCB fact, accepted from stock's known-working design, not independently re-verified |

## Phase F conclusion

**`CONNECTION_GATE_PASS_SOFTWARE_EQUIVALENCE`** for the SoC-side `uart1` signal path specifically:
pin-controller ownership, register semantics, clock, IRQ, MMIO base, voltage-domain determinism, and
protocol/purpose identity all match stock, verified live on real hardware, with zero remaining
`CUSTOM_REGRESSION` or `UNKNOWN_SOFTWARE_INVISIBLE` classifications for any printer-facing signal.
No printer-facing pin in the table above is classified `CUSTOM_REGRESSION`.

This gate conclusion is scoped exactly as this pass defined it: proof of *software-visible*
equivalence at the pin-controller/GPIO-register/clock/reset/UART-register/driver-ownership boundary.
It is explicitly **not** an independent verification of PCB routing, connector pinout, or analog
voltage - those are accepted from the known-working stock design because the physical board itself
has not been modified by any of this project's work.

## Still required before Phase G (physical connection) - separate from the software gate

1. **Explicit human sign-off.** A software gate pass is not, by itself, authorization to physically
   connect a mainboard. This is a real, hard-to-reverse action with no independent instrumentation
   available to catch a mistake - it needs to be a deliberate decision, made with this report in
   hand, not an automatic next step.
2. **Connector pinout identification.** Which physical pins on the wiring-harness connector carry
   TX/RX/GND/power still needs official documentation (service manual, schematic, or connector part
   number lookup) - this is a connector fact, unrelated to any of this project's software changes,
   and out of reach of a register-level audit.
3. If approved, follow the mission's staged connection protocol (3 stages, strict blocklist on
   heaters/steppers/fans/BLTouch) - not a single all-at-once connection.
