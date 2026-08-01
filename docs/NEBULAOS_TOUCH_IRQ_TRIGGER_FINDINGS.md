# GPIO79 (ns2009 pendown) Electrical Behavior - Live Findings

Display/touch investigation mission follow-on (2026-08-01). This document records what
TOUCH-D0-DIAG's live data actually shows about GPIO79's electrical behavior, for the separate
TOUCH-I0 (IRQ-observation) finalization step to use as evidence. **This document does not decide
TOUCH-I0's trigger mode** - that decision (and whether both-edge triggering is actually correct) is
explicitly out of scope here; this is a report of observed behavior only.

## What was actually measured vs. inferred

The diagnostic has two logically separate data sources that must not be conflated:

1. **Raw GPIO79 samples** (`diag_raw_level`, `diag_raw_high_count`/`diag_raw_low_count`, exposed as
   `raw_level`/`idle_level_inferred`) - taken via `gpiod_get_raw_value_cansleep()` on *every* poll
   tick (every 30ms), completely independent of whether a touch is in progress. This is the only
   direct window onto GPIO79 itself.
2. **Touch-presence transition counters** (`touch_down_count`/`release_count`/`bounce_count`/
   contact durations) - these fire at the *existing* driver's ADC Z1-pressure-threshold-based
   `pen_down` transitions, not directly from GPIO79. They are a reasonable proxy for real human
   touch events (since Z1-threshold crossing should correlate with actual finger contact), but they
   are not a direct GPIO79 readout.

This distinction matters for classification confidence below.

## Live evidence

Four independent `status` reads across the live test (see
`docs/NEBULAOS_TOUCH_D0_LIVE_TEST_REPORT.md` for full context and exact counter values):

| Reading | `raw_level` | `idle_level_inferred` | Context |
|---|---|---|---|
| 1 | `1` | `1` | Idle baseline, screen untouched for 142s |
| 2 | `1` | `1` | Immediately after the full touch sequence (70 events), screen settled |
| 3 | `1` | `1` | Fresh boot after warm reboot |
| 4 | `1` | `1` | After the post-reboot follow-up touch check (8 events) |

**PROVEN_FROM_LIVE_TEST**: GPIO79's idle level is consistently HIGH across all four independent
readings, spanning two separate boots and thousands of raw samples each. `idle_level_inferred` is a
majority vote over the full sample population (`raw_high_count >= raw_low_count`), and idle time
vastly dominates total elapsed time in every reading, so this is a robust, reproducible
measurement of the *idle* level specifically.

**Touch-presence signal behavior (PROVEN_FROM_LIVE_TEST, via the Z1-threshold proxy)**: across 78
total touch events (70 in the main sequence + 8 in the follow-up), `touch_down_count` exactly
equalled `release_count` every time, and `unexpected_transition_count` was `0` in both passes -
meaning the down/release state machine's own invariant (a down transition is always followed by
exactly one release before the next down) held with zero violations, even during the busiest
gestures (20 rapid taps + 5 drags in immediate succession). Contact durations were physically
sane and bimodal-appropriate: as short as 40ms (quick taps) and as long as 3900ms (a long press),
never fragmented into implausible sub-poll-interval bursts that would indicate chattering during a
held contact.

**What was NOT directly measured**: no `status` read was taken *synchronized to an in-progress
touch* - all four readings above were taken either before touching began or after the screen had
already settled back to idle. There is therefore no direct "`raw_level` = X while a finger is
actually on the glass" observation in this dataset.

## Classification

**IDLE_HIGH_ACTIVE_LOW**

**Confidence: moderate-high**, with an explicit split between what's proven and what's inferred:

- **PROVEN_FROM_LIVE_TEST**: idle level is HIGH, reproducibly, across two boots.
- **PROVEN_FROM_LIVE_TEST**: the touch-presence signal (Z1-threshold proxy) changes exactly once on
  touch-down, remains asserted for the full held duration (durations up to 3900ms observed with no
  intermediate chatter), and changes exactly once on release - ruling out "produces repeated
  transitions while held" as the correct description of this signal's behavior.
- **SUPPORTED_INFERENCE, not directly measured**: that the specific *active* level is LOW. This is
  inferred by elimination (idle is confirmed HIGH) and by the conventional pull-up/normally-open
  wiring pattern typical for a pendown-style GPIO on this class of hardware - not from a captured
  `raw_level` sample taken during an actual touch. A future diagnostic pass that logs `raw_level`
  specifically at the moment `pen_down` becomes true (rather than only exposing the last-polled
  value in a point-in-time status read) would upgrade this from inference to direct proof.
- Real, bounded contact bounce was observed (12 of 70 events in the main sequence, ~17%; 0 of 8 in
  the slower follow-up check) - consistent with ordinary electromechanical contact bounce during
  fast/rapid-tap interaction, not a pervasively unstable line. This is why the classification is
  **not** UNSTABLE_OR_BOUNCING: bounce was present but clearly bounded to specific fast-interaction
  moments (already separately counted and explained), not dominant, not present at all during the
  slower follow-up check, and never associated with a state-machine violation.

## Explicit non-decision

This document intentionally does not conclude whether IRQ-based touch detection should use
both-edge triggering, level-triggering, or any other mode - that is TOUCH-I0's own finalization
decision, informed by but not made by this evidence. The data above supports (but does not by
itself prove) a simple level-based read being sufficient to describe this signal's behavior; it
does not establish that both-edge IRQ triggering is either necessary or correct, and no such
conclusion should be drawn from this document alone.
