# NebulaOS Display Live Qualification Plan

Companion to [NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md](NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md)
and [NEBULAOS_DISPLAY_OFFLINE_IMPLEMENTATION_PLAN.md](NEBULAOS_DISPLAY_OFFLINE_IMPLEMENTATION_PLAN.md).
This document defines what happens **after** explicit user confirmation to begin powered-on
work - nothing in this document has been executed. The printer was never contacted, powered on,
or physically touched during this mission.

## Ordering principle

Every test below is READ-ONLY (or spare-slot-only, reversible) until explicitly marked
otherwise. Read-only tests should run before any write/flash test, since several of them
(HT-01, HT-02) directly inform whether a later prototype (DISPLAY-P1) is even electrically
plausible before any engineering time is spent flashing it.

## Test matrix

See `build-work/display-analysis/hardware-test-matrix.tsv` for the full machine-readable
version. Summary, in recommended execution order:

1. **HT-01 (backlight electrical, READ-ONLY)**: read live GPC-0/GPC-22 pin state and any PWM
   register activity via `devmem`/`gpioinfo`, no software changes. Resolves whether these pins
   are actively driven or floating - directly gates whether DISPLAY-P1 is worth deploying at
   all.
2. **HT-02 (panel reset polarity, READ-ONLY)**: read PB16's live level in both the known-working
   steady state and immediately after cold boot. Confirms or corrects the assumed active-high
   polarity in `panel-openke-general-480x272.c`.
3. **HT-07 (stock DPU enablement mechanism, READ-ONLY)**: with stock firmware booted (existing
   stock slot, zero custom-OS changes), read live devicetree/platform-data state for the DPU
   node to resolve the open question in `device-tree-display.txt` (stock's static DTB shows
   `status="disabled"` despite a working display).
4. **HT-06 (boot handoff visual continuity, READ-ONLY, UART passive capture)**: a UART-
   instrumented cold boot, correlating exact panel-visible sequence (logo persistence, any
   blank/flash interval, first-NebulaOS-frame timestamp) against U-Boot/kernel console
   timestamps. This is the mission's own **FIRST_REQUIRED_POWERED_ON_ACTION** candidate - it
   resolves a genuine, real, previously-flagged UNKNOWN_UNTIL_HARDWARE gap
   (`boot-handoff-analysis.txt`), not a formality.
5. **HT-10 (panel timing live re-confirmation, READ-ONLY)**: live `devmem` read of
   `DC_TFT_CFG`/pixel-clock registers to re-derive (not re-trust) that the RGB565/10753KHz
   values this whole analysis relies on still match current running hardware.
6. **HT-03 (DPU underrun/overrun rate, READ-ONLY)**: observe real UI load for a fixed window,
   establishing a baseline for the currently-silent underrun/overrun counters.
7. **HT-04 (pan-display/vsync tearing, READ-ONLY, visual only)**: observe the running UI during
   rapid content changes (e.g. print-progress animation) for visible tearing - determines
   whether the real, source-proven `dpu_ctrl_rdma_change()` vsync race (§4 of the main report)
   is actually user-visible on this panel/refresh-rate combination.
8. **HT-05 (touch poll latency, READ-ONLY)**: timestamp-correlated tap-to-response measurement
   under normal use - quantifies the real-world impact of the fixed 30ms poll interval.
9. **HT-08 (PREEMPT_RT display jitter, READ-ONLY)**: using the already-built-and-proven
   NEBULAOS-ALPHA-MAX-RT experimental image (git-ignored `build-work/deploy-packages/`),
   observe DPU IRQ thread scheduling latency under composer-restart load.
10. **HT-09 (DISPLAY-P1 validation, WRITE - spare slot only, reversible)**: the only write/flash
    test in this plan. Deploy the S1 backlight-class prototype to a **spare slot only** (never
    the active/working slot - see [[reference_device_access]] on this board's single-custom-slot
    architecture), confirm `/sys/class/backlight/*/brightness` actually changes physical panel
    brightness. Only proceed to this test if HT-01 confirms the electrical path is plausible.

## Acceptance criteria

A candidate from `candidate-ranking.tsv` may only move from its current
priority/DEFER/REJECT classification to "approved for production" if:
- Its corresponding hardware test(s) above have run and produced a result consistent with the
  candidate's premise (e.g. DISPLAY-P1 requires HT-01 to show GPC-0/GPC-22 are real,
  controllable pins, and HT-09 to show the prototype actually changes physical brightness).
- The change does not regress any of the alpha-baseline's existing proven-working behavior
  (RGB565 wire format, touch GPIO fix, panel timing) - re-run the existing GUI/touch live
  validation steps from `GUI_WORKSTREAM_HANDOFF.md` after any display-path change, not just the
  new test.
- Any change to the active/production slot is deployed via the project's existing
  `flash-spare-slot.sh` + stock-detour workflow ([[project_nebulaos_prequalification_mission]]),
  never a direct in-place edit of a running system.

## Future A/B variants (S0-S7)

Reserved for a future, separately-authorized live qualification mission, once DISPLAY-P1's
basic electrical viability (HT-01/HT-09) is confirmed:

| Variant | Description | Depends on |
|---|---|---|
| S0 | Today's baseline - no backlight control, current blanking/vsync/touch behavior unchanged | none |
| S1 | DISPLAY-P1 backlight-class + DT integration only | HT-01 plausible |
| S2 | S1 + a real calibrated brightness table (replacing the placeholder 0-15 linear table) | S1 deployed + HT-09 pass + real dimming-curve measurement |
| S3 | S1 + backlight-only blanking (scanout/panel stay active, only backlight gates) | S1 deployed |
| S4 | S3 + deep display powerdown (real panel_ops->disable() GPIO-level reset-hold on blank) | S3 deployed + a demonstrated power/thermal need |
| S5 | Auto vsync-gate before FBIOPAN_DISPLAY | HT-04 confirms visible tearing |
| S6 | IRQ-driven touch pen-down (replacing the 30ms poll) | HT-05 confirms a real latency/power benefit |
| S7 | Combined S1+S3+S5+S6 - a fully realized "OS uses the display to its practical potential" variant, only after each constituent has been independently validated | S1, S3, S5, S6 all individually proven |

No S-variant beyond S0 has been built or deployed. S1 (DISPLAY-P1) is the only one with a
compile-only prototype prepared (see the offline implementation plan); S2-S7 remain design
placeholders pending their stated dependencies.

## Explicit stop condition

This plan does not authorize execution of any test above. Per the mission's own instruction,
work stops here pending explicit user confirmation that the printer may be powered on and
these read-only tests may begin, starting with HT-01/HT-02/HT-07/HT-06 in the order listed
above.
