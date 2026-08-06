#!/bin/sh
# Authoritative, single-command reproduction of the qualified NebulaOS
# production baseline (tag nebulaos-display-baseline-vsync-pwm-sleep-2026-08-03,
# commit f9dc10f594cd7591e1146317cda877f75165934b) on top of a pristine
# vendor kernel checkout.
#
# WHY THIS SCRIPT EXISTS (2026-08-06/07 baseline canonicalization mission):
# the individual *-variant.sh scripts under this directory are deliberately
# experimental/toggleable A-B tools - each one's "off" state resets ONLY the
# files it owns to the real git-committed baseline first, and the tracked
# Kconfig fragment (artifacts/buildroot-halley5-v30-image/
# halley5-nebulaos-fragment.config) is reset to not-selected after every
# real qualification build, on purpose, so an unreviewed experiment can
# never silently become the new invisible default (see each script's own
# header for this rationale). The side effect: nobody had a single command
# that reproduces "every ACCEPTED variant, all at once, from a clean
# checkout" - running the base 00-06 pipeline alone silently regresses to
# pre-variant defaults, which is exactly the bug this script closes (found
# live 2026-08-06 attempting a routine GuppyScreen-only rebuild: PREEMPT_RT,
# the backlight-final-controller DT node, and the touch final-qualification
# driver all silently disappeared from a "clean" rebuild).
#
# This script does NOT invent new configuration - every one of the 7 calls
# below applies a change already independently verified present in the real,
# tracked, currently-deployed artifacts/buildroot-halley5-v30-image/
# {kernel.config,halley5_v30.dts} (see docs/NEBULAOS_QUALIFIED_BASELINE_
# VARIANT_AUDIT.md for the full per-script audit this was derived from,
# including which scripts/arguments were deliberately excluded and why).
#
# Explicitly NOT applied here (audited and excluded, not merely forgotten):
#   - touch-qualification-variant.sh (QUAL0/QUAL1) - QUAL0 (off) is the
#     accepted state (CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION is absent from
#     the tracked kernel.config). Not invoked at all, on purpose: its own
#     "off" step does an unconditional blanket `git checkout --` of files
#     touch-final-qualification-variant.sh also owns, which would silently
#     wipe that script's content if run afterward (documented in that
#     script's own header). A pristine fresh checkout is already QUAL0.
#   - touch-irq-variant.sh, touch-d0-diag-variant.sh, touch-i0-diag-variant.sh,
#     display-backlight-variant.sh, display-backlight-diag-variant.sh -
#     diagnostic/prototype tools only; none of their Kconfig symbols appear
#     in the tracked kernel.config, confirming their accepted state is the
#     default/off value. Not invoked.
#   - wifi-roamoff-disable-variant.sh - real and accepted, but for the LATER
#     nebulaos-wifi-camera-irq-fix-2026-08-04 baseline, not this mission's
#     pinned nebulaos-display-baseline-vsync-pwm-sleep-2026-08-03 source.
#     Out of scope for this profile by the mission's own explicit baseline
#     pin, not an oversight.
#
# Usage: sh scripts/build/apply-qualified-baseline.sh
# Run AFTER 00-fetch-vendor-sources.sh (needs a real vendor/x2000_kernel_6.6
# checkout) and BEFORE 02-configure-buildroot.sh, exactly like any other
# variant script.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

echo "== apply-qualified-baseline: applying every accepted baseline variant =="

# No inter-script ordering dependency exists among these seven calls (each
# owns disjoint kernel source files, or edits the shared DTS/fragment via
# its own uniquely-marked, append-only region rather than a blanket
# rewrite - verified per-script during the audit, see the doc referenced
# above). Listed here in the order the underlying missions were originally
# accepted, for readability only.
sh "$SCRIPT_DIR/preempt-variant.sh" R1
sh "$SCRIPT_DIR/wifi-sdio-variant.sh" W3
sh "$SCRIPT_DIR/display-vsync-variant.sh" V1
sh "$SCRIPT_DIR/pinctrl-ownership-fix-variant.sh" FIX1
sh "$SCRIPT_DIR/backlight-final-controller-variant.sh" FINAL1
sh "$SCRIPT_DIR/pwm-state-readback-variant.sh" GETSTATE1
sh "$SCRIPT_DIR/touch-final-qualification-variant.sh" FINALQUAL1

echo "== apply-qualified-baseline: all 7 accepted variants applied =="
