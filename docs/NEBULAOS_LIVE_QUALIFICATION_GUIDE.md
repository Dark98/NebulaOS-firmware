# NebulaOS Unified Touch IRQ and Backlight Qualification - Live Test Guide

Deployment 1 (`NEBULAOS-DISPLAY-QUALIFIED-RUNTIME`) live-testing plan. Covers mission phases
17-24. See `build-work/deploy-packages/NEBULAOS-DISPLAY-QUALIFIED-RUNTIME-*/variant-difference.txt`
for exactly what this package contains, and `deployment-guide.txt`/`rollback-guide.txt` in that
same directory for the flash/rollback procedure.

Evidence classifications used throughout: `PROVEN_FROM_SOURCE`, `PROVEN_FROM_ARTIFACT`,
`PROVEN_BY_COMPILE_TEST`, `PROVEN_FROM_LIVE_TEST`, `SUPPORTED_INFERENCE`, `INCONCLUSIVE`,
`BLOCKED`. A visual or physical-touch result is only ever `PROVEN_FROM_LIVE_TEST` if the human
operator directly reports the observation - never inferred from source or assumed.

## Phase 17 - live irq-observe qualification

Switch: `echo irq-observe > /sys/kernel/debug/ns2009_qualification/mode`

Ask the user to perform: 10 normal taps, 5 long presses, 5 drags, 20 rapid taps, then 10 seconds
untouched.

Capture from `.../ns2009_qualification/status`: IRQ requested result, IRQ number, IRQ count,
touch-down count, release count, events-while-idle, events-while-held, min/max IRQ interval,
storm state, polling state (must remain active), input functionality (does touch still work
normally - it must, this mode never disables the poll path).

PASS when: IRQ request succeeds; falling-edge events correlate with real touch-downs; zero IRQ
events during the final untouched window; no storm fallback; 30ms polling stays active throughout;
coordinates/release stay correct via the unchanged poll path.

On failure: `echo poll-only > .../mode`, record the failure, do NOT proceed to Phase 18. Backlight
testing (Phase 19+) may still proceed independently.

## Phase 18 - live irq-assist qualification (only after Phase 17 passes)

Switch: `echo irq-assist > /sys/kernel/debug/ns2009_qualification/mode`

Ask the user to perform: 20 normal taps, 10 rapid taps, 5 long presses, 5 drags, 4 corner taps,
2 minutes of ordinary UI use, 60 seconds untouched.

Measure: IRQ-to-worker latency, touch-down-to-first-sample latency, active-poll duration, idle
safety-poll count, missed-touch count, fallback count, GuppyScreen usability throughout.

PASS when: no missed ordinary touches, no stuck touch, no false idle touches, no IRQ storm,
coordinates unchanged, release reliable, fallback path remains available, GuppyScreen stays fully
usable.

Return to poll-only (`echo poll-only > .../mode`) before starting any backlight probing, even if
Phase 18 passed - keep touch and backlight testing temporally separated so a failure in one is
never ambiguous with the other.

## Phase 19 - GPIO-only backlight qualification

Prerequisite check (must both be true before arming): `cat .../nebulaos_backlight_probe_diag/status`
shows `gpio_restore_is_exact: 1` and no ownership conflict.

Arm: `echo arm > .../command`. Ask the user to watch the display throughout.

Run separately, 2 seconds each, confirm restore between each:
```
echo probe-enable-low  > .../command   # wait 2s (fixed duration, automatic restore)
echo status            > .../command   # confirm restored
echo probe-enable-high > .../command   # wait 2s
echo status            > .../command   # confirm restored
```

Accepted user observations per probe: BRIGHTER, DIMMER, OFF, NO_CHANGE, FLICKER, UNSURE. Record
verbatim - do not round an UNSURE up to a definite result.

If neither state visibly changes the backlight: mark the PC22 enable-GPIO role `INCONCLUSIVE`, do
not assume it's the real enable line. If one state turns the backlight off and restoration visibly
returns it: record the enable polarity, classify `PROVEN_FROM_LIVE_TEST`.

Disarm (`echo disarm > .../command`) when done - this force-restores any active probe as a
fail-safe even if already idle.

## Phase 20 - PWM qualification gate (re-check before Phase 21, do not assume Phase 8's offline result still applies)

**Known prerequisite blocker**: the DTS `&pwm` node currently only pinmuxes `pwm1_pc` (GPC1), not
`pwm0_pc` (GPC0 - the real `backlight_pwm0` pin). A `probe-pwm-*` command on the currently-built
channel has **no physical effect on the real backlight** until a DTS change adds `pwm0_pc` to
`&pwm`'s `pinctrl-0` and a new package is built and deployed with that change. Do not spend live
test time on Phase 21 until this is resolved - re-read `variant-difference.txt`'s "Known
prerequisite" section for the full finding before attempting this phase.

Once the DTS prerequisite is resolved in a future package, re-check before every PWM probe:
`cat .../nebulaos_backlight_probe_diag/status` must show `pwm_restore_is_exact: 1`,
`snapshot_valid: 1`, no active probe, armed, and the candidate channel unclaimed. If any of these
fail: do not run the PWM probe, mark PWM qualification `BLOCKED`, continue touch finalization
work instead.

## Phase 21 - PWM visual qualification (only when Phase 20's gate passes on a package with the DTS prerequisite resolved)

Ask the user to watch the screen. Run separately, confirming restore between each:
```
echo probe-pwm-25 > .../command   # 2s, then automatic restore
echo probe-pwm-50 > .../command   # 2s, then automatic restore
echo probe-pwm-75 > .../command   # 2s, then automatic restore
```

Record each observation. Determine: does PWM0 control brightness at all; normal or inverted
polarity; does PC22 also need to be held enabled simultaneously; is the response visually stable
(no flicker); is brightness response monotonic across 25/50/75%.

Do not test combined GPIO+PWM states unless the single-resource results indicate it's necessary
AND both resources' restoration paths are independently proven exact.

## Phase 22 - Temporary brightness control (only after PWM path + polarity + enable behavior + restoration are all proven from Phase 19-21)

Out of scope for Deployment 1 - requires new driver work (a temporary backlight-class device using
the now-proven PWM values) not present in this package. Plan this as part of Deployment 2's design
once Phase 19-21 results are known, per Phase 26's decision tree.

## Phase 23 - Backlight-only sleep / Phase 24 - Touch-wake

Both out of scope for Deployment 1, same reasoning as Phase 22 - these require Phase 18 and
Phase 21/22 to have already passed, and require new driver work informed by those results. Not
implemented in this package.

## Result recording

For each phase actually run, record a result in exactly one of: `PASS`, `FAIL`, `INCONCLUSIVE`,
`BLOCKED`, `NOT_TESTED`. Feed these into Phase 25-26 (result classification / final image
composition selection) per the mission's own decision tree - do not include a feature in
Deployment 2 unless its live qualification genuinely passed.
