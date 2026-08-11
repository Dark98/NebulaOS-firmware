# PRTouch MCU timer incident — forensics, source-correspondence audit, and next diagnostic plan

Audit date: 2026-08-10. Scope: a live no-trigger `Z_OFFSET_CALIBRATION` test (configured for a
1mm descent that could not physically reach the bed) ended in a real MCU shutdown
(`sentinel timer called`, preceded by five `Timer too close` warnings) and an audibly abnormal
motor sound. This document is the autonomous zero-motion follow-up: it establishes what can and
cannot be proven about the firmware actually running on the device, reconstructs the incident
timeline with explicit confidence labels, resolves the second-JSON-RPC-request question as far as
evidence allows, records the non-reentrancy guard added as a result, and specifies (but does not
execute) the smallest safe next motion experiment.

No gcode was sent to the real printer during this session. Every finding below came from
SSH-based read-only inspection (files, logs, Moonraker/Klipper status queries, `READ_PRES`),
static source inspection, and offline unit tests. The printer was left idle, unhomed, heaters
off, motors de-energized throughout.

---

## 1. Source ↔ running-firmware correspondence

**Question: is `vendor/klipper/src/sched.c` (or any source in this repo) provably the code that
built the MCU firmware currently running on this printer's `F005` mainboard?**

**No — and there is now positive evidence it is not.**

- Live MCU identify string: `Loaded MCU 'mcu' 116 commands
  (38d96adc-dirty-20231016_135251-longer-virtual-machine / gcc 9.2.1 [ARM/arm-9-branch] ...)`,
  `MCU=gd32f303xe`, `CLOCK_FREQ=120000000`, connected via real UART (`serial: /dev/ttyS1` in
  `[mcu]` — not a Linux-software-MCU, a genuine separate microcontroller).
- `38d96adc` does not exist as a commit anywhere in `vendor/klipper`'s git history
  (`git cat-file -t 38d96adc` → "Not a valid object name"). `vendor/klipper` HEAD is an unrelated
  commit (`0e5785da`, 2026-08-07). The firmware build date (Oct 2023) predates this whole project.
- `vendor/klipper/src/sched.c` was vendored wholesale in one commit ("add ender 3 v3 firmware
  blobs", `386fde4`, pellcorp/creality import) alongside **precompiled** firmware blobs at
  `fw/*/mcu0_*.bin` — i.e. this repo's own history already treats the mainboard MCU firmware as a
  separate, binary-only artifact from the buildable `src/` tree.
- This device's board code is `F005` (independently confirmed elsewhere in this repo's
  `FIRMWARE.md` via `/etc/ota_info` and U-Boot's own `nvram model: F005` output), matching
  `fw/F005/mcu0_001_G32-mcu0_007_000.bin`. That file is present both in this repo and on the live
  device (`/usr/data/nebulaos/apps/klipper/fw/F005/...`, byte-identical path/name). `file` reports
  it as raw opaque "data" (no ELF header); `strings -n 4` finds **zero** readable text anywhere in
  it — no "klipper", "prtouch", "timer", "shutdown", nothing. This is almost certainly an
  encrypted/obfuscated Creality OTA package, not a directly-inspectable compiled image.
- **No consumer of `fw/*.bin` exists anywhere on the live custom OS** (`grep -rl "fw/F005\|mcu0_"`
  across the whole `klipper` app tree matches only `.git/index`). **No `gd32` build target exists**
  in this Klipper source tree's `src/` at all (only `atsam, stm32, lpc176x, hc32f460, simulator,
  ar100, generic, linux, atsamd, rp2040, pru, avr`). **No file anywhere in the reachable custom-OS
  filesystem mentions "gd32"/"GD32" in any form.** The mainboard MCU update mechanism, if one
  exists, is not part of NebulaOS/SimpleAF at all — it almost certainly lives in Creality's
  separate stock firmware/OS partition, which was not booted into (a real OS-switch/reboot,
  explicitly out of scope for this zero-motion session).
- `reference/prtouch_v2.c` defines `PR_VERSION (307)`, which exactly matches `'version': 307`
  echoed in every live `debug_prtouch` MCU response — real corroboration that *the prtouch command
  layer specifically* is genuine. But that same file's header comment (`// Report on user
  interface buttons ... Copyright (C) 2018 Kevin O'Connor`) is verbatim upstream Klipper's
  unrelated `buttons.c` header — this file was made by editing an existing template, not a
  pristine Creality drop, and its provenance for anything beyond the prtouch command layer is
  unconfirmed.
- **Direct behavioral contradiction, not just a version mismatch**: `vendor/klipper/src/sched.c`
  implements `try_shutdown("Timer too close")` →
  `sched_try_shutdown()` (only guard: "not already shutting down") → `sched_shutdown()` →
  `irq_disable(); longjmp(shutdown_jmp, reason);` — an **immediate, unconditional hard shutdown on
  the very first call**. The real device instead printed five `Timer too close` `#output` lines
  across three full attempt cycles, with completely normal sensor reads, no-trigger detection, and
  recovery lifts in between each one, before a distinct `sentinel timer called` shutdown much
  later. If this exact `sched.c` governed the real firmware, the first `Timer too close` should
  have hard-stopped the MCU immediately. It did not. **This is concrete evidence that whatever
  scheduler code is actually running differs from this repo's `vendor/klipper/src/sched.c`.**
- A targeted web search found a Creality Wiki "Firmware Open Source" page for this exact model,
  but it is JS-rendered and yielded no extractable links via automated fetch. No further public
  Creality GPL source release was located from this session.

**Conclusion (superseded — see §7)**: this section originally stopped here, concluding that
static analysis had been exhausted pending either a genuine Creality GPL source release or live
MCU extraction. §7 below found that release. Kept for the historical record of what was
provable from the live device and this repo's own vendored source alone.

---

## 2. Incident timeline, with confidence labels

All times are Klipper `eventtime` (reactor-monotonic), read directly from
`klippy.log` (`Received`/`debug_prtouch`/`#output` lines are all in this same clock domain; the
one `Requested toolhead position at shutdown time 1748.877217` line is in the *separate*
`print_time` domain and must not be compared directly against `eventtime` — an error made and
corrected during this investigation).

| eventtime | Event | Confidence |
|---|---|---|
| 1743.594545 | `Received` `gcode/script` `Z_OFFSET_CALIBRATION` (id `1945934128`) — the one HTTP call made | FACT |
| 1744.366–367 | Attempt 1 armed: pres config echo, step-down echo `oid=5 dir=0 send_ms=10 step_cnt=200 step_us=1000 acc_ctl_cnt=50` | FACT |
| ~1744.4–1747.1 | `repairing pres samples, got 0/32` → `no pressure channel reported a trigger ... attempt 1/10` | FACT |
| 1747.152 | `Timer too close` (1st) | FACT |
| 1747.152–154 | disarm step/pres, recovery lift armed: `oid=5 dir=1 step_cnt=200 step_us=2500` | FACT |
| — | `repairing step samples, got 4/32` | FACT |
| ~1747.15 | `Timer too close` (2nd) | FACT |
| 1749.887 | Attempt 2 armed (down): identical params to attempt 1 | FACT |
| — | `no pressure channel reported a trigger ... attempt 2/10` | FACT |
| 1754.383 | `Timer too close` (3rd) | FACT |
| 1754.385 | recovery lift for attempt 2 armed | FACT |
| — | `Timer too close` (4th) | FACT |
| 1757.082 | Attempt 3 armed (down): identical params | FACT |
| — | `no pressure channel reported a trigger ... attempt 3/10` | FACT |
| 1761.591 | `Timer too close` (5th) | FACT |
| 1761.593 | recovery lift for attempt 3 armed — its own disarm/completion is never logged | FACT |
| 1748.808983 | `Received` `gcode/script` `Z_OFFSET_CALIBRATION` (id `1956010320`) — second, distinct request | FACT |
| shortly after 1761.593 | `Transition to shutdown state: MCU shutdown` → `MCU 'mcu' shutdown: sentinel timer called` | FACT |
| — | Motors reported by the operator as sounding abnormal during the test | FACT (direct observation) |
| — | `sched_shutdown`'s `longjmp` is immediate on first call, in the *source read*; real device tolerated 5 warnings before the real shutdown | FACT (of the source) / STRONG_INFERENCE (that the real firmware therefore differs — see §1) |
| — | The raw step-generation timing/cadence itself (not concurrency) is implicated, since attempt 1 alone produced 2 of the 5 warnings before the second RPC ever existed | STRONG_INFERENCE |
| — | Something specific to the third attempt's recovery-lift dispatch is where the firmware actually stalled long enough to trip the sentinel (~18s of the MCU's own 100ms heartbeat not running, per `sentinel_timer.waketime = periodic_timer.waketime + 0x80000000` at 120MHz — again only provably true of the *source read*, not confirmed for the real firmware) | HYPOTHESIS |
| — | Exact firmware-level mechanism that stalls the scheduler for that long | UNKNOWN — needs source correspondence (§1) or live instrumentation to resolve |
| — | Origin of the second RPC request | UNKNOWN as to *source*, but see §3 for what has been ruled out with evidence |

### On "0/32" and "4/32" sample-repair counts
`repairing pres samples, got 0/32` appears on every attempt's down-phase (no pressure trigger
ever arrived, consistent with a load cell that genuinely never triggered against open air — matches
the intentional design of this test). `repairing step samples, got 4/32` appears once, on attempt
1's *recovery lift* specifically (not its down-phase, and not on attempts 2 or 3's lifts, which show
`0/32`) — i.e. the MCU did report 4 real step samples for that one lift before the buffer needed
repair, while every other repair event reports zero. This is the single asymmetric data point in
the whole sequence. It temporally lines up with the first `Timer too close` overall (which also
occurs during attempt 1's transition into that same recovery lift). **STRONG_INFERENCE**: this
one partially-populated buffer marks the first point at which MCU response timing genuinely
degraded — consistent with, but not proof of, the recovery-lift path being where things start
going wrong. Not proven as causal; recorded as the most concrete anomaly available for any future
firmware-level investigation to explain first.

---

## 3. The second JSON-RPC request

Two distinct `Received gcode/script Z_OFFSET_CALIBRATION` lines exist in `klippy.log`'s
connection dump, with different ids, 5.2s apart (1743.59 / 1748.81) — this is a real, structural
fact, not a parsing artifact (Klippy's own retrospective 20-request dump lists both by their
genuine original timestamps).

**Ruled out, with evidence, as the source:**
- **Moonraker's own request layer duplicating the call.** Read directly from
  `/opt/moonraker/moonraker/components/klippy_connection.py`: `_request_standard()` creates
  exactly one `KlippyRequest` object (keyed by Python `id()`) and schedules exactly one write to
  Klippy per call (`self.event_loop.register_callback(self._write_request, base_request)`, once).
  `KlippyRequest.wait()`'s "pending" retry-logging path (the mechanism behind the unrelated
  `Request 'gcode/script' pending: 60.00 seconds` lines seen earlier and 20 minutes before this
  incident) re-awaits the *same* future via `asyncio.shield(self._fut)` — it structurally cannot
  create a second request. **This is proof, not inference: a single HTTP POST cannot produce two
  `Received` lines through this code path.**
- **Moonraker's own HTTP access log** (`application.py:log_request()`) shows exactly one relevant
  POST: `17:50:12,500 400 POST /printer/gcode/script?script=Z_OFFSET_CALIBRATION (127.0.0.1)
  20864.56ms` — the one call made during this investigation.
- **GuppyScreen's UI/wizard.** Its own application log
  (`/usr/data/nebulaos/printer_data/logs/guppyscreen.log`) shows a completely unrelated,
  already-finished `RecalibrationWizardPanel` session (stock BLTouch `TESTZ`-based calibration,
  *not* our custom `Z_OFFSET_CALIBRATION` command at all) ending at `17:30:32`, then **total
  silence** until a fresh process restart at `18:16:04` (consistent with GuppyScreen's connection
  being killed by the MCU shutdown and auto-restarting afterward). Zero log activity of any kind
  during the 17:43–17:50 incident window.
- **Mainsail.** Its websocket (`ID 1956252112`) closed at `17:47:22`, over a minute before this
  session's own curl call was even issued.
- **Full websocket enumeration** across the entire `moonraker.log`: only three connections ever
  opened — GuppyScreen's local one (open throughout, but proven silent above), Mainsail (closed
  before the test), and GuppyScreen's post-crash restart. No other client is visible.

**Not fully resolvable**: Moonraker does not access-log individual websocket JSON-RPC method
calls (only HTTP requests go through `log_request()`), so a raw, un-instrumented websocket call
cannot be 100% excluded on log evidence alone. However every specific, checkable candidate has
been checked and ruled out with positive evidence (not merely left untested), and GuppyScreen —
the only client with a connection open throughout — is independently proven silent by its own
application log.

**Causally irrelevant regardless of origin**: the first `Timer too close` (1747.15) predates the
second request (1748.81) by 1.6s, and the real shutdown occurs roughly 13s *after* the second
request, following a full additional clean attempt cycle (attempt 3) with no visible interference.
Whatever sent the second request, it did not cause this incident.

---

## 4. Reference material confidence reassessment

| Item | Classification | Basis |
|---|---|---|
| `reference/prtouch_v2.c` — prtouch command/protocol layer (`PR_VERSION`, field encoding) | CONSISTENT_BUT_UNPROVEN, with one strong corroborating data point | `PR_VERSION=307` matches the live device's own echoed protocol version exactly |
| `reference/prtouch_v2.c` — file provenance/header | RECONSTRUCTED_ONLY | Header is verbatim unrelated upstream Klipper `buttons.c` copyright text |
| `reference/prtouch_v2_wrapper.py` — command cadence (wait-then-disarm, timeout formula) | CONSISTENT_BUT_UNPROVEN | This port's `probe_timeout_seconds()` (`distance/speed + 2.0s`) matches the wrapper's own `down_min_z/use_tri_z_down_spd + 2` formula exactly; structurally equivalent wait/disarm sequencing |
| `vendor/klipper/src/sched.c` — scheduler/timer/shutdown semantics | CONTRADICTED | See §1's `try_shutdown` behavioral contradiction |
| This port's own `prtouch_probe.py`/`prtouch_mcu.py` host-side orchestration | CONFIRMED_BY_REAL_FIRMWARE (structurally) | The live incident's own log output (attempt counters, repair-sample counts, disarm/rearm sequencing) matches exactly what this port's source predicts it would send/log — the port's *host-side* behavior is doing what it was written to do; the *firmware's* response to that behavior is what remains unproven |

---

## 5. Non-reentrancy guard (added this session)

Independent of the unresolved timer root cause: `klippy_extras/z_compensate.py`'s
`cmd_z_offset_calibration()` now rejects a second invocation immediately (`command_error:
"Z_OFFSET_CALIBRATION: a calibration is already in progress"`) if one is already running, checked
and set with no yield in between — safe without a lock given Klipper's single-threaded/cooperative
reactor (whichever invocation's handler runs first always sets `"running"` before it can yield via
`reactor.pause()`/`wait_moves()`, so any second invocation is guaranteed to observe the busy state
already set, however it was triggered). The busy state clears on every exit path (success →
`"complete"`, any exception → `"error"`), matching the existing status-contract behavior; four new
regression tests in `test_z_compensate.py::ReentrancyGuardTest` cover rejection-while-running, that
a rejected call doesn't bump `calibration_id` or disturb the in-progress status, and that the guard
correctly clears after both success and failure to allow legitimate sequential reuse.

This is explicitly **not** presented as a fix for the timer incident — the second request was
shown in §3 to be causally irrelevant to it. It closes a real, independently-justified gap (no
motion-capable command should ever be able to overlap another instance of itself on this MCU's raw
step channel) regardless of what actually caused the shutdown.

Scope note: `CRTENSE_NOZZLE_CLEAR`/`NOZZLE_CLEAR` (`cmd_nozzle_clear`) also call `touch_probe()` on
the same shared `PrtouchProbe` instance and carry the same theoretical class of risk, but were not
part of what was asked for here and were left unguarded — flagged for a future, explicitly scoped
pass if wanted.

`UPSTREAM_KLIPPER_CORE_DIFFS: NONE` — this change is entirely within
`klippy_extras/z_compensate.py` (a NebulaOS-owned extra) and its own test file.

---

## 6. Next motion diagnostic — prepared, NOT executed

Do not run any of the following without a fresh, explicit go-ahead.

Given §1–§4: the retry/recovery *cadence itself* is not yet cleared as a factor (attempt 1 alone,
before any retry loop had run twice, already produced two `Timer too close` warnings), so the
right next step is not another `Z_OFFSET_CALIBRATION` run — it's the smallest possible **isolated,
single, non-probing raw step dispatch**, to learn whether even one lone `start_step_prtouch` call
produces `Timer too close` outside of any retry/disarm/rearm cadence. `SAFE_MOVE_Z` already exists,
is genuinely non-probing (no pressure arm, no trigger check, no retry loop — confirmed by direct
code reading earlier this investigation), and is exactly this shape. No new code is needed; this is
a usage plan, not an implementation task.

**Step A — single isolated UP move** (away from the bed; the strictly safer direction):
```
SAFE_MOVE_Z DIR=1 DIS=1 SPD=1
```
- 1mm, at a deliberately slow 1mm/s (well under the ~5mm/s used in the incident) — the smallest,
  slowest raw move this command supports.
- Capture `klippy.log` immediately before and after for any `#output: Timer too close` or shutdown
  transition, and confirm `webhooks.state` stays `"ready"` throughout.
- Confirm via `objects/query` that `toolhead` position and MCU stats look sane afterward.
- **Do not send Step B in the same session/back-to-back** — a deliberate pause and explicit
  human confirmation between the two, specifically because the incident's own cadence (rapid
  disarm-then-immediately-rearm) is one of the still-open hypotheses.

**Step B — single isolated DOWN move**, only after Step A is confirmed clean and only with fresh
authorization:
```
SAFE_MOVE_Z DIR=0 DIS=1 SPD=1
```
- Same 1mm/1mm/s parameters. Since `SAFE_MOVE_Z` has no pressure arm or trigger detection at all,
  this cannot be mistaken for contact detection — it is purely a raw-step-timing probe.

**Explicitly not part of this plan**: no `Z_OFFSET_CALIBRATION`, no `NOZZLE_CLEAR`, no retries, no
`G28`/homing, no persistence, no chaining the two steps together. If Step A alone reproduces
`Timer too close`, that would be strong evidence the issue is inherent to any raw step dispatch on
this real MCU, independent of cadence — a materially different conclusion than if only the
chained/retried case (as in the actual incident) reproduces it.

**NEXT_MOVEMENT_DIAGNOSTIC_EXECUTED: NO** (by design — this document only specifies the plan).

### 6a. Exact static proof (2026-08-10, second session, after the fix)

Ran this device's real, live `[stepper_z]` values (`microsteps: 16`, `rotation_distance: 8`,
200 full steps/rotation → `mm_per_step = 8/(200*16) = 0.0025`) through the real, unmodified
`prtouch_units.py` functions (no fake/test values) to compute exactly what
`SAFE_MOVE_Z DIR=1 DIS=1 SPD=1` will send, now that the guard/settle fix is in place:

```
start_step_prtouch oid=<step_oid> dir=1 send_ms=10 step_cnt=400 step_us=2500 acc_ctl_cnt=200 \
    low_spd_nul=5 send_step_duty=16 auto_rtn=0
collect_step_samples timeout = 6.0s (1.0s expected physical move + 5.0s margin)
settle after disarm = 0.01s (tri_send_ms/1000, the new fix's own yield)
```

Notably, `step_cnt=400, step_us=2500` for this 1mm/1mm/s move is the same order of magnitude as
the incident's own recovery-lift arms (`step_cnt=200, step_us=2500` for its 0.5mm lifts) —
this diagnostic exercises genuinely comparable timing to what actually happened, not an
artificially different regime. With the fix in place, this single call now also exercises
`_own_raw_operation` (rejects any overlapping call) and `_settle_after_disarm` (yields 10ms
after the disarm before returning) — both proven correct offline in
`test_prtouch_raw_op_guard.py`.

**NEXT_MOVEMENT_DIAGNOSTIC_EXECUTED: NO.**

---

## 7. Official Creality source located — the root cause is now proven, not inferred

2026-08-10, second session. `gh repo view` confirmed two real, accessible, official Creality
repositories: `CrealityOfficial/Ender-3_V3_KE_Klipper` (`git clone from
https://github.com/Klipper3d/klipper/`, tag `V1.1.0.12` — the exact firmware version this repo's
own `FIRMWARE.md` already cites for this device via `/etc/ota_info`) and
`CrealityOfficial/Ender-3_V3_KE_Annex`. Cloned both. History is only 4 commits total
(`9bdde73 Initial commit`, `a63fb1a update for open source`, plus two dependabot bumps) — a
one-time GPL-compliance snapshot, not a live mirror of Creality's internal build system, so
`38d96adc` (the running firmware's own embedded hash) still does not appear here either. That
specific commit remains unrecoverable — but this is now a materially different, far stronger
kind of evidence than §1's `vendor/klipper`: **Creality's own official source**, not a
third-party fork, containing the *exact same custom PRTouch subsystem* (confirmed below), for
the same board family.

### What's actually there
- `src/prtouch_v2_cm23.o`, `src/prtouch_v2_cm3.o`, `src/prtouch_v2_cm4.o` — real, precompiled,
  **not stripped** ARM ELF relocatable objects (`file`: "ELF 32-bit LSB relocatable, ARM, EABI5
  ... with debug_info, not stripped"), one per Cortex-M variant (M23/M3/M4).
- `src/gd32/` — a real, buildable GD32 target (`Kconfig`, `Makefile`), with
  `config MACH_GD32F303XE` present and selecting `MACH_GD32F30X_HD`/`MACH_GD32F30X` — this
  device's own live-identified chip (`gd32f303xe`) is a named, first-class target here, and the
  GD32F30x family's actual core is Cortex-M4, making `prtouch_v2_cm4.o` the applicable object
  (the Kconfig confirms the chip target; which of the three `.o` files gets linked for it is
  standard Cortex-core selection, not something this session needed to trace further given what
  was found below applies identically to all three).
- `config/F005/factory_printer.cfg` and `config/F005/printer.cfg` — this exact board, with the
  same `[mcu] serial:/dev/ttyS1 baud:230400` as the live device.
- `src/prtouch_v2_compile.c` — just `DECL_COMMAND` declarations + a thin `sendf_info()`; the
  real command implementations live in the precompiled `.o` files, linked via
  `src-$(CONFIG_HAVE_GPIO) += ... prtouch_v2_compile.c` in `src/Makefile`.

### The proof: Creality's own `sched_add_timer()` is NOT stock Klipper's

Diffing this official `src/sched.c` against `vendor/klipper/src/sched.c` (this repo's own
vendored pellcorp/klipper copy, the one §1 already showed is unproven for this device):

```c
 sched_add_timer(struct timer *add)
 {
     uint32_t waketime = add->waketime;
+	uint8_t flags = 0;              // (Creality's own real code, not upstream's)
     irqstatus_t flag = irq_save();
     struct timer *tl = SchedStatus.timer_list;
     if (unlikely(timer_is_before(waketime, tl->waketime))) {
         if (timer_is_before(waketime, timer_read_time()))
+		{
+            //try_shutdown("Timer too close");     <-- COMMENTED OUT in Creality's real source
+			flags = 1;
+			waketime = timer_read_time() + timer_from_us(2);   <-- silently clamped instead
+			add->waketime = waketime;
+		}
         ...
     }
     irq_restore(flag);
+    if(flags)
+	{			
+		output("Timer too close");      <-- plain debug print, NOT a shutdown notification
+		flags = 0;
+	}
 }
```

(diff direction: `+` lines are what upstream/pellcorp's `vendor/klipper/src/sched.c` has; the
lines actually present in Creality's own file are what's left when those are removed — i.e.
Creality's real `sched_add_timer()` has the commented-out `try_shutdown` and the clamp/print
logic, not the stock immediate-`longjmp` behavior.)

**This exactly and completely explains the incident's observed behavior.** §1 found a real
behavioral contradiction: stock `sched.c`'s `try_shutdown` → `sched_shutdown` → `irq_disable();
longjmp(...)` is unconditional and immediate on the very first call, yet the live device
tolerated five separate `Timer too close` warnings with fully normal operation in between each
one before a distinct, later shutdown. Creality's own real firmware source shows exactly why:
**they deliberately commented out the hard-shutdown call and replaced it with a silent
now+2μs clamp and a plain `output()` debug print** — which is precisely what
`mcu 'mcu': #output: Timer too close` in the live log is (a plain debug line, never a shutdown
notification at all, confirmed by the wire-format difference: shutdown reports use `is_shutdown
static_string_id=%hu`, not `#output:`).

A second, independent Creality customization was found in the same diff: the core idle loop
(`sched_main`'s inner `while` in `run_tasks`) has upstream's `irq_wait()` (sleep until an
interrupt) replaced with:
```c
do {
    asm volatile("cpsie i" ::: "memory");
    extern void prtouch_task(void);
    prtouch_task();
} while (SchedStatus.tasks_status != TS_REQUESTED);
```
i.e. whenever the MCU has no pending Klipper task, it **busy-polls a PRTouch-specific function
instead of sleeping**. Disassembling `prtouch_task` in `prtouch_v2_cm4.o`
(`arm-none-eabi-objdump -dr -j .text.prtouch_task`) shows it is a two-instruction dispatcher:
```
00000000 <prtouch_task>:
   0:	b508      	push	{r3, lr}
   2:	f7ff fffe 	bl	0 <prtouch_task>
			2: R_ARM_THM_CALL	prtouch_pres_task
   6:	e8bd 4008 	ldmia.w	sp!, {r3, lr}
   a:	f7ff bffe 	b.w	0 <prtouch_task>
			a: R_ARM_THM_JUMP24	prtouch_step_task
```
— it calls `prtouch_pres_task` then tail-calls `prtouch_step_task`, **the exact two function
names already documented in `reference/prtouch_v2.c`** (its own `prtouch_step_task()`, gated by
`check_delay(&send_dly, send_ms/1000)`, is what paces buffered-sample sends). This is real,
symbol-level, disassembly-confirmed proof that `reference/prtouch_v2.c`'s documented structure
matches Creality's actual compiled firmware, upgrading its confidence rating (see §4) from
"consistent but unproven" to **CONFIRMED_BY_REAL_FIRMWARE at the function/call-graph level**
(not byte-exact instruction correspondence — this session did not attempt full decompilation of
the timer-scheduling internals themselves, judged disproportionate once the `sched.c`-level
proof above was in hand).

### Updated §1 answer

`RUNNING_MCU_SOURCE_FOUND`: a strong, official, function-level match — not the exact `38d96adc`
build (unrecoverable without Creality's internal build history), but Creality's own published
source for this exact board family and firmware line, showing the precise customization that
explains the observed behavior. This is the strongest evidence obtainable without live MCU
extraction, and it was sufficient to reach a real conclusion.

---

## 8. Could the raw-step architecture be replaced instead of patched?

Evaluated per the mission brief's explicit instruction not to preserve Creality's raw-step
primitive "merely for compatibility." Conclusion: **no, not without upstream Klipper
modifications, which are out of scope.** The pressure (load-cell) sampling and the raw step
pulse generation are fused together inside the MCU firmware itself — `prtouch_event()` (the
per-pulse timer callback disassembled/read via `reference/prtouch_v2.c` and confirmed present
by symbol in the official `.o` files) is the single function that both toggles the step GPIO
*and* checks `read_swap_sta()` (the pressure-trigger latch) on every pulse, recording
`send_tri_time` the instant a trigger is detected. Upstream Klipper's own stepper/homing/probe
abstractions (`trsync`, `mcu_endstop`, the trapq-based move queue) have no path to observe this
MCU's pressure channel at all — there is no endstop pin, ADC reading, or any other primitive
upstream Klipper knows how to homing-query that carries this signal. Reimplementing the touch
detection on top of upstream's motion APIs would mean either (a) inventing a new MCU-side
protocol from scratch (modifying the firmware — explicitly excluded) or (b) polling the
pressure sensor from the host during a normal queued move, which cannot achieve trigger-time
resolution anywhere close to the MCU's own per-pulse check and would reintroduce exactly the
kind of unbounded-blind-travel risk the 2026-08-06/09 fixes already closed. The raw-step
primitive is the *only* foundation available for detecting a load-cell trigger without
firmware changes. This session's fix therefore works within that architecture (bounding and
pacing its use) rather than replacing it.

---

## 9. Root cause — final synthesis

| Finding | Confidence |
|---|---|
| The live device's `Timer too close` warnings are plain debug prints, not shutdown attempts, because Creality's own real firmware has `try_shutdown("Timer too close")` commented out | **PROVEN** (official Creality source, `CrealityOfficial/Ender-3_V3_KE_Klipper` tag `V1.1.0.12`, `src/sched.c`) |
| A "too close" timer gets silently clamped to `now + 2µs` and rescheduled, rather than rejected | **PROVEN** (same source) |
| The real, unmodified `sentinel_timer`/`sentinel_event` mechanism (§2) is still present and still capable of independently firing after ~17.9s of the periodic 100ms heartbeat not running | **PROVEN** (same source — this part of `sched.c` is unmodified from stock) |
| Repeated back-to-back disarm-then-immediate-rearm cycling (the incident's own cadence — zero host-side yield between a disarm and the next arm) is what drove the clamp-and-warn path 5 times, and plausibly congested the MCU's timer dispatch enough to eventually starve the periodic timer and trip the still-present sentinel | **STRONG_EVIDENCE** — directly explains every observed timestamp and warning count; the exact congestion mechanism inside `sched_add_timer`'s repeated near-immediate rescheduling was not separately disassembled/simulated, so this final causal link (clamp cascade → sentinel starvation) is strong inference from proven mechanics, not a byte-level proof |
| `reference/prtouch_v2.c`'s documented `prtouch_step_task`/`prtouch_pres_task` structure matches Creality's real compiled firmware | **PROVEN** (disassembly + symbol match, `prtouch_v2_cm4.o`) |
| The second, unexplained `Z_OFFSET_CALIBRATION` JSON-RPC request caused or contributed to the incident | **DISPROVEN** (§2/§3 — the first warning predates it by 1.6s, and the shutdown follows a full additional clean attempt cycle after it) |
| A full replacement of the raw-step architecture with upstream Klipper motion APIs is possible without firmware changes | **DISPROVEN** (§8 — the pressure/step coupling is inside the MCU firmware itself) |

**Likely root cause**: the live incident's own command cadence — disarming a raw step operation
and immediately rearming the next one with no host-side yield — repeatedly triggers Creality's
own real (not stock-Klipper) timer-clamping path in rapid succession, and this repeated
near-immediate rescheduling pressure is what eventually stalled the MCU's timer dispatch loop
long enough to trip the always-present, unmodified sentinel watchdog. This is now grounded in
Creality's own official source for the exact behavior that diverged from what stock
`vendor/klipper/src/sched.c` would predict, not merely inferred from host-side log timing.

**Fix implemented, directly targeting this mechanism**: `_settle_after_disarm()` (§10) inserts
a real host-side yield after every disarm, before the next arm — breaking the exact back-to-back
cadence that drives repeated clamp events on Creality's real firmware.

---

## 10. Fix implemented (2026-08-10, second session)

Real deployment target correction first: this document's own §1–§6 were written against
`ke-mainline-klipper`'s `klippy_extras/`, but the live device's actual running
`prtouch_probe.py`/`z_compensate.py` (verified by line count and distinctive symbol/config-key
match over SSH) matches `/home/tim/Documents/NebulaOS-klipper-loadcell`
(`coreflake1/NebulaOS-klipper`, `master`, commit `4510ee65`) — a separately-cloned, more advanced
checkout with an already-shipped safety-hardening layer (`PrtouchProbeSafetyError`,
`max_probe_travel_mm`, `max_probe_duration_s`, baseline sanity guards) that `ke-mainline-klipper`
does not yet have. The core `_touch_probe()` MCU dispatch sequence is identical between the two
trees (confirmed by direct diff), so this document's incident timeline (built from live log
data, not from source reading) remains valid regardless. The fix below was implemented in
**both** trees — primarily in `NebulaOS-klipper-loadcell` as the real ship target, mirrored into
`ke-mainline-klipper`'s simpler (pre-hardening) file structure.

### Shared raw-operation ownership guard
`PrtouchProbe._own_raw_operation()` (a context manager) wraps the two PUBLIC raw-motion entry
points, `touch_probe()` and `safe_move_z()` — only one may be active at a time, across both,
however a second call is triggered. `_fail()`'s own internal safety lift was refactored to call
a new private `_raw_move()` helper directly (bypassing the public `safe_move_z()` guard
entirely), since it is legitimately nested inside whichever public operation already holds the
guard — without this refactor, `_fail()`'s own cleanup would incorrectly raise
`PrtouchProbeSafetyError` against itself. Checked-and-set with no yield in between, so this is
race-free under Klipper's single-threaded/cooperative reactor without needing a lock.
`z_compensate.py`'s own `cmd_z_offset_calibration()` guard (from the first session, already
committed) is a second, higher-level, complementary guard protecting the whole multi-step
calibration sequence as one logical unit, on top of this lower-level one.

### Evidence-grounded settle after every disarm
`PrtouchProbe._settle_after_disarm()` yields (`reactor.pause()`) for at least one
`tri_send_ms` tick — the protocol's own declared pacing granularity for this exact channel,
not an invented constant — after every disarm, before the next arm. Wired into all four
disarm sites: `_raw_move` (covers `safe_move_z` and `_fail`'s own lift), `_touch_probe`'s own
down-arm disarm, and `_raw_lift` (covers both `_lift_after_down` and
`_recover_after_no_trigger`'s no-trigger recovery). Overridable via `raw_op_settle_s` once real
hardware timing margins are measured; `None` (default) derives from `tri_send_ms`.

### Instrumentation
Every arm/disarm now logs an operation id (incrementing per `touch_probe`/`safe_move_z` call),
direction, `step_cnt`/`step_us`/`acc_ctl_cnt`/`send_ms`, and start/end markers — host-side only,
no additional MCU traffic, low overhead (plain `logging.info` calls matching this codebase's
existing conventions).

### Tests
`test_prtouch_raw_op_guard.py` (new, both repos, 10 tests): shared-ownership rejection across
both entry points in both directions, guard release after success/exception,
`_fail()`'s internal lift not blocked by its own guard (regression proof for the refactor),
settle called exactly once per disarm across a full no-trigger retry sequence (directly
reproduces the incident's own attempt/disarm/rearm pattern against a fake MCU and asserts the
fix is wired into every transition), settle duration default/override, and settle actually
advancing the (virtual) reactor clock. `test_z_compensate_reentrancy_guard.py` (new, in
`NebulaOS-klipper-loadcell` only — `ke-mainline-klipper`'s equivalent guard/tests were added in
the first session as `ReentrancyGuardTest` inside its existing `test_z_compensate.py`): 4 tests
for the calibration-level guard. All pre-existing tests continue to pass in both repos with zero
regressions (162 total in `NebulaOS-klipper-loadcell`, 160 in `ke-mainline-klipper`).

`UPSTREAM_KLIPPER_CORE_DIFFS: NONE` in both repos — every change is confined to
`klippy_extras/`/`klippy/extras/` (NebulaOS-owned) and its own tests.

---

## 11. Physical qualification Stage 1 (2026-08-11) — a new, more serious finding

Executed `docs/NEBULAOS_PRTOUCH_PHYSICAL_QUALIFICATION.md`'s Stage 0/1 for real, live, on the
device (engineering package `integration/prtouch-timer-fix-and-migrate-exec-bit` /
`NebulaOS-klipper` `4ae82620` at the time). Stage 0 passed cleanly. Stage 1
(`SAFE_MOVE_Z DIR=1 DIS=1 SPD=1`) executed with clean MCU/software behavior (single arm/disarm
pair, `_own_raw_operation`/`_settle_after_disarm` both fired correctly, `webhooks.state`
stayed `ready`) — but the printer had never been homed this session, so the Z stepper driver's
own `enable_pin` was never asserted (confirmed: no `enable`/`stepper_enable` reference anywhere
in `prtouch_probe.py`'s raw-move path). **No physical rotation occurred** — Stage 1's own
"did it move, did it sound clean" pass criteria could not be evaluated this session; only the
MCU command dispatch itself was validated.

One `#output: Timer too close` line appeared even for this single, isolated, non-cadenced
operation — new information against §9's "repeated near-immediate rescheduling" causal chain,
since this run had no retry/rearm cadence at all. Consistent with §7's proof that this specific
print is a harmless debug artifact of Creality's own real `sched_add_timer()` (clamp-and-print,
not `try_shutdown`), not evidence this run was unsafe — no sentinel, no shutdown followed.

### The real finding: raw step operations corrupt the pressure-sensor read

Immediately after the single `SAFE_MOVE_Z`, `READ_PRES` (previously stable at ~-256,000)
started returning near-zero garbage (`ch0=-1`), individually finite and far under
`max_baseline_abs` — invisible to the existing single-read guard. Reproduced twice (2/2). Not a
simple "stuck" value: repeated polling showed it drift between `-1`, `-63,923`, `-127,864` —
values suspiciously close to 0/8, 2/8, and 4/8 fractions of the true baseline, consistent with a
mix of genuinely-corrupted and genuinely-valid low-level samples within `deal_avgs_prtouch`'s
own 8-sample trimmed average (`reference/prtouch_v2.c`'s `command_deal_avgs_prtouch`).

Source-level analysis ruled out the obvious host-side explanation: `deal_avgs_prtouch` zeros its
own `tri_avg_vals` baseline at the start of every call, so the corruption is not a stale-tare
artifact — the underlying bit-banged 24-bit acquisition (`read_pres_prtouch`) is producing bad
data at the hardware/timing level, not a Python-side bug.

**Persistence, tested directly**: the corrupted state survived two `S55klipper restart`s and
one full `reboot` (all three reconnect to the MCU over UART but do not power-cycle it) — still
`-1`/degraded after each. A genuine physical power cycle (user action) cleared it completely:
three consecutive clean reads immediately after boot (`-255101`, `-255158`, `-255067`), no
degradation. This is strong, directly-tested evidence the fault is **persistent MCU-internal
state** (most likely inside the GD32F303's own firmware — an ADC/timing reference or similar
disturbed by the raw step pulse train) that only clears on true power-on reset, not something
recoverable from the host side by any means short of a physical power cycle.

**Safety implication**: this is a materially different and more serious risk than anything
§1–§10 identified. A real `touch_probe()`/`Z_OFFSET_CALIBRATION` attempt run any time after a
raw step operation — even much later, even across service restarts — could silently attempt a
blind descent with a non-functional trigger sensor, for however long it takes an operator to
notice and physically power-cycle the machine. The existing pre-motion guard
(`_check_baseline_safe`) could not have caught this: a single `-1` or `-127,864` reading passes
`_evaluate_baseline` outright.

### Fix (2026-08-11, same session)

`PrtouchProbe.check_sensor_consistency()` (`klippy_extras/prtouch_probe.py`,
`klippy/extras/prtouch_probe.py` in `NebulaOS-klipper-loadcell`): takes
`sensor_consistency_reads` (default 3) independent `deal_avgs_prtouch` reads and requires them
to (a) each individually pass the existing plausibility guard, (b) agree with each other within
`sensor_consistency_max_spread` (default 5000 counts — real observed healthy-read spread was
~300), and (c) not drift more than `sensor_baseline_max_drift` (default 10000 counts) from a
session-local, auto-learned healthy baseline (refreshed only on a fully-passing batch, so a
rejected batch can never poison it). Distinguishes `healthy`/`unstable`/`corrupted` rather than
a single ok/not-ok, exposed via `get_status()`'s new `sensor_state` field. Wired into both
`touch_probe()`'s pre-motion guard and its own per-attempt retry-loop check. 9 new tests
reproduce the exact live-observed flicker/drift patterns; all pre-existing tests (117 in
`NebulaOS-klipper-loadcell`, 149 in `ke-mainline-klipper`, both minus 2-3 files with an
unrelated pre-existing absolute-import invocation quirk) continue to pass.

This is explicitly **defense in depth, not a root-cause fix** — the underlying MCU-level
corruption mechanism itself remains unexplained at the register/instruction level (would need
live firmware debugging or an oscilloscope on the sensor's clk/sdo lines during a raw step burst
to pin down further) and is out of scope to fix directly (proprietary Creality MCU firmware,
already established in §8 as not replaceable without upstream Klipper changes).

`UPSTREAM_KLIPPER_CORE_DIFFS: NONE` — confined to `klippy_extras/prtouch_probe.py`/
`prtouch_v2.py` (both repos) and their own tests. `NebulaOS-klipper` `KLIPPER_PIN` bumped
`4ae82620` → `7a755706` (fast-forward).

---

## 12. Root-cause mission (2026-08-12) — disassembly-grounded mechanism found

Follow-up mission, explicitly asked not to stop at another investigation report. Re-cloned
`CrealityOfficial/Ender-3_V3_KE_Klipper` (same tag, `V1.1.0.12`, already used in §7) and
disassembled its real, unstripped `src/prtouch_v2_cm4.o` with `arm-none-eabi-objdump` (both
tools confirmed available this session, unlike §7's assumption that only targeted symbol
disassembly was practical).

### The mechanism: an unprotected HX711 bit-bang transaction, preemptible by the raw-step ISR

`read_pres_prtouch`'s full disassembly (0x208 bytes) was compared instruction-by-instruction
against `reference/prtouch_v2.c`'s structure and matches it exactly — same 24-clock bit-bang
loop, same `is_data_valid`/25ms-staleness gate, same sign-extension (`orr.w r2, r2, #0xff000000`
on bit 23 set), same final `out_buf[i] -= pres_cfg.tri_avg_vals[i]` subtraction loop. This
upgrades `reference/prtouch_v2.c`'s confidence rating for `read_pres_prtouch` specifically from
"consistent but unproven" (§4) to **CONFIRMED_BY_REAL_FIRMWARE at the instruction level** — not
just function/call-graph correspondence like §7's `prtouch_task` finding.

**Critical new finding**: `read_pres_prtouch`'s entire 24-clock GPIO toggle sequence has **zero
interrupt protection** — grepped the whole object file for `irq_disable`/`irq_save`/`cpsid`;
none exist anywhere in it. Disassembling `prtouch_event` (the real per-step-pulse timer ISR,
registered via `sched_add_timer` inside `command_start_step_prtouch`, confirmed by symbol
relocation) shows it is a substantial handler (0x240 bytes): direction-change logic, buffered
sample writes, and floating-point division/multiplication to look up the next waketime from a
sigmoid acceleration table (`__aeabi_dmul`/`__aeabi_d2uiz`/`sigmoid_ary` lookup) before calling
`sched_add_timer` again. This is a real, non-trivial hardware-interrupt handler, not a
two-instruction stub — plausibly tens of microseconds per firing, and it fires repeatedly
throughout the entire duration of any active raw step operation (`SAFE_MOVE_Z`, or
`touch_probe()`'s own down/lift phases). `prtouch_step_task` (the buffered-sample-sending half
of the always-running idle-loop `prtouch_task`) was also checked and confirmed to have **no**
coordination with the pressure path either — the only cross-communication between step and
pressure subsystems anywhere in this object file is the single-bit `read_swap_sta()`/
`write_swap_sta()` trigger latch, not a synchronization primitive.

**The mechanism this proves possible**: if `prtouch_event` (a hardware timer IRQ) fires while
the always-running idle-loop's `prtouch_pres_task()` → `read_pres_prtouch()` call chain is
mid-way through toggling PD_SCK, the ISR preempts it and stretches that specific clock pulse's
width by however long the handler takes — exactly the mechanism this mission's own hypothesis
named (unprotected bit-bang + concurrent timer activity → invalid PD_SCK framing/timing →
corrupted acquisition). This is **STRONG_EVIDENCE**, grounded in real disassembly of both sides
of the race (the unprotected read and the real ISR that can preempt it) — not fully **PROVEN**,
since neither `prtouch_event`'s exact cycle count nor the HX711-family chip's exact power-down
threshold on this specific board was independently measured (would need live firmware tracing
or a scope on the sensor's clk/sdo lines).

### 8-sample hypothesis: CONFIRMED, not just plausible

Reproduced `command_deal_avgs_prtouch`'s exact algorithm (sort ascending, sum indices `[2:6]` of
8, divide by 4) against mixtures of the real ~-256,000 baseline and near-zero corrupted samples:

| valid samples / 8 | computed average | live observation |
|---|---|---|
| 0, 1, or 2 | 0 (the 1-2 real samples land in the trimmed *bottom* two slots, since -256000 sorts below 0, and get discarded as "outliers") | `-1` |
| 3 | -64,000 | `-63,923` (77 off) |
| 4 | -128,000 | `-127,864` (136 off) |
| 6-8 | -256,000 (unaffected) | matches healthy baseline |

The match for 3/8 and 4/8 is exact to within real sensor noise (~0.1-0.2%). **CONFIRMED**: the
live-observed intermediate values are precisely explained by a mix of genuinely-good and
genuinely-corrupted individual `read_pres_prtouch` calls landing in the trimmed average — not a
coincidental resemblance. This also explains why `-1` (not exactly 0) was observed instead of a
clean zero for the worst cases: real sensor noise on the 0-2 "corrupted" samples themselves.

### Persistence across restart/reboot, only cleared by power cycle: still not fully explained

The mechanism above explains a single momentarily-preempted `read_pres_prtouch` call producing
one bad sample. It does **not**, by itself, explain why the corruption persisted for 75+ seconds
across dozens of subsequent, uncollided read attempts (no raw step operation running, no
`prtouch_event` firing) — a single bad sample from timing collision should not on its own
explain a systematically-wrong reading long after the collision window closed. Two candidate
explanations, both **PLAUSIBLE**, neither confirmed:
- The load-cell amplifier chip itself (HX711-family; not independently confirmed as literally an
  HX711 versus a compatible clone) enters a real power-down/latched state if a stretched PD_SCK
  pulse crosses its own datasheet threshold, and the existing firmware has no explicit
  detect-and-recover logic for this condition — only a genuine VDD removal/reapplication (a real
  power cycle) resets the chip's own internal state, independent of anything the GD32 MCU or
  Klipper software can do.
- A GD32 GPIO/peripheral-register-level effect on the MCU side. Judged **less likely**:
  `prtouch_event`'s step pulse uses `gpio_out_toggle_noirq`, and standard Cortex-M/GD32 GPIO
  atomic set/reset (BSRR-style) operations are specifically designed not to require read-modify-
  write, so they should not be able to disturb a sibling pin's configuration even under
  interrupt-context use - but this was not independently verified against this exact toolchain's
  generated code for `gpio_out_toggle_noirq`/`gpio_out_write`.

Both explanations are consistent with the proven experimental fact (§11 above): 2 Klipper
restarts and a full OS reboot all failed to clear it; a genuine physical power cycle did, twice.

### Corrections to prior sessions' findings

- **§1's "almost certainly encrypted/obfuscated"** claim about `fw/F005/mcu0_001_G32-mcu0_007_000.bin`
  was investigated further this mission and found **wrong**: the file is not encrypted at all —
  it decodes cleanly as a standard Klipper `.bin` (valid Cortex-M vector table, Klipper's own
  documented bootloader-entry strings `"Request Serial Bootloader!!"`/`"CanBoot!"`, and a
  zlib-compressed embedded MCU data dictionary that decompresses to valid JSON). However, that
  dictionary reveals `"app": "Klipper"`, `"version": "v0.13.0-164-gc97932188"`,
  `"build_machine_uid": "PELLCORP Apr 22 2026..."` — a generic 2026 pellcorp-fork rebuild for a
  bare `gd32f303xe`, with a pure-vanilla 51-command list (`config_stepper`, `queue_step`,
  `endstop_home`, ...) and **zero** PRTouch commands. This file was never the real Creality
  firmware to begin with, consistent with §1's other finding that nothing in the live custom OS
  ever consumes it - it's simply vendored dead weight, not a lead worth pursuing further for this
  investigation.
- No stock Creality OTA package/`.img` containing the real, PRTouch-enabled MCU firmware was
  found anywhere on this machine, and no public documentation of the OTA package format or a
  GD32 UART bootloader protocol specific to F005 was located. `CrealityOfficial/Ender-3_V3_KE_Klipper`'s
  precompiled `.o` objects (§7, extended this section) remain the strongest evidence obtainable
  without live MCU extraction or Creality's actual internal build history.

### Beeper incident (2026-08-11 physical test) — separately investigated

Exhaustively grepped the official Creality F005 source tree (`src/`, `config/F005/*.cfg`) and
every symbol in all three `prtouch_v2_cm*.o` objects for `beep`/`buzz`/`alarm`/`speaker` — zero
matches anywhere. This printer's own `printer.cfg` has no beeper config either. **STRONG_EVIDENCE**
the mainboard's PRTouch/Klipper-facing MCU firmware does not drive whatever produced the
repeating on/off alarm the operator heard. Community sources (a klipper-macros GitHub discussion,
a Creality forum moderator reply) indicate the Ender-3 V3 KE may not have a factory-populated
mainboard beeper at all — one moderator was explicitly unsure whether this model's beeper (if
any) lives on the mainboard or inside the separate display module. **PLAUSIBLE, not proven**:
the alarm originated from the physically-separate display/touchscreen module (not part of the
Klipper↔F005 UART link, cleanly explaining why it's invisible to both Klipper's and
GuppyScreen's own logs) or an independent hardware watchdog/supervisor circuit. **UNKNOWN**: the
exact circuit or fault-triggering condition — no schematic or teardown was located. This
finding does not block or change the pressure-sensor root-cause conclusion above; the two
incidents remain not proven to share a cause (per this mission's own explicit instruction not to
assume they do).

### Why this cannot be fixed at the root, host-side

The disturbance happens *inside* Creality's proprietary, compiled GD32 MCU firmware, in code
this project has never had buildable source access to (only precompiled `.o` objects from an
official-but-generic board-family repo, not this device's own `38d96adc` build). Adding
interrupt protection around `read_pres_prtouch`'s bit-bang loop, or serializing it against
`prtouch_event`, would require a real firmware patch and reflash of the mainboard's own MCU —
explicitly out of scope for this mission without separate authorization, and not attempted.
§8's already-established finding (the pressure/step coupling is fused inside the MCU firmware
itself, with no upstream Klipper primitive able to observe this signal another way) still holds
and was not re-litigated.

### Root-cause fix implemented (host-side, defense only)

Given a true prevention fix is not available, `check_sensor_consistency()`'s baseline was
upgraded to persist to disk (`/opt/printer_data/prtouch_baseline.json` by default) and survive
Klipper restarts and Linux reboots - closing the specific residual gap the 2026-08-11 session's
purely session-local version had (a corrupted-but-stable reading present at Klipper startup,
with no prior-session reference to compare against, could previously have been learned as
"healthy"). See `klippy_extras/prtouch_probe.py`'s own `_load_persisted_baseline`/
`_save_persisted_baseline`/`check_sensor_consistency` docstrings for the exact policy: a stable-
but-wrong reading is now rejected against the OLD persisted reference and can never overwrite
it, even across a restart - only readings already within tolerance of the trusted reference
(persisted or freshly bootstrapped) are ever recorded as the new one. The one honest remaining
gap - a printer's genuine first-ever boot, with no persisted file yet - is surfaced via a new
`bootstrap` status field rather than silently assumed safe.

### Final synthesis

| Finding | Confidence |
|---|---|
| `read_pres_prtouch`'s compiled machine code matches `reference/prtouch_v2.c` instruction-for-instruction | **PROVEN** (direct disassembly comparison) |
| `read_pres_prtouch`'s 24-clock bit-bang loop has no interrupt-disable/critical-section protection anywhere | **PROVEN** (exhaustive `irq_disable`/`irq_save`/`cpsid` grep across the whole object file: zero hits) |
| `prtouch_event` is a real, substantial (0x240 byte) hardware timer ISR that fires repeatedly throughout any active raw step operation | **PROVEN** (disassembly + `sched_add_timer`/`sched_del_timer` call evidence) |
| `prtouch_event` preempting a concurrent `read_pres_prtouch` call can stretch a PD_SCK pulse and corrupt that individual sample | **STRONG_EVIDENCE** (both halves of the race independently proven; the exact stretch duration vs. the sensor chip's own power-down threshold not independently measured) |
| The live-observed `-1`/`-63,923`/`-127,864` values are produced by a mix of good/corrupted individual samples inside `deal_avgs_prtouch`'s own 8-sample trimmed average | **CONFIRMED** (exact quantitative reproduction: 3/8 valid → -64,000 predicted vs. -63,923 observed; 4/8 valid → -128,000 predicted vs. -127,864 observed) |
| The corruption persists for 75+ seconds across dozens of uncollided reads, clearing only on physical power cycle (not Klipper restart, not OS reboot) | **PROVEN** (directly tested twice), mechanism for the *persistence specifically* (as opposed to the initial trigger) is **PLAUSIBLE**, not proven - see the two candidate explanations above |
| `fw/F005/mcu0_001_G32-mcu0_007_000.bin` is encrypted/obfuscated | **DISPROVEN** this mission (it's a standard, decodable Klipper `.bin` - just for the wrong, generic firmware) |
| A stock Creality OTA package containing the real PRTouch-enabled MCU firmware is recoverable on this machine | **DISPROVEN** (none found; F005 OTA format is undocumented publicly) |
| The mainboard beeper is driven by the PRTouch/Klipper-facing MCU firmware | **STRONG_EVIDENCE against** (zero beeper code/symbols anywhere in the real source or compiled objects) |
| The beeper and the pressure-sensor corruption share one root cause | **UNKNOWN** - not assumed either way, per this mission's own instruction |
| A true host-side fix that prevents the corruption from occurring is achievable without MCU firmware changes | **DISPROVEN** (the disturbance is inside proprietary, unbuildable MCU firmware) |
| The persisted-baseline guard closes the specific "corrupted state learned as healthy across a restart" gap it was built for | **PROVEN** (7 new tests directly reproduce and close this exact failure mode) |

`RAW_OPERATION_STILL_CORRUPTS_SENSOR: YES` (unchanged - no MCU-side fix was made or attempted).
`PRESSURE_PATH_SAFE_FOR_PROBING: YES, in the fail-closed sense` - `touch_probe()` cannot arm a
real descent while the sensor is unstable/corrupted/unknown, now persistently so across restarts
- but the underlying corruption itself is still not prevented, only detected and refused.
