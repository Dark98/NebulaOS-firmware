#!/bin/sh
#
# Offline, repeatable tests for scripts/build/display-backlight-variant.sh
# (display hardware analysis mission, 2026-08-01, DISPLAY-P1 prototype).
# Operates against the real tracked vendor DTS (vendor/x2000_kernel_6.6/
# kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts) - same pattern
# as tests/wifi-sdio-variant-tests.sh/tests/preempt-variant-tests.sh:
# snapshot the real pre-test state, restore it exactly on exit (success,
# failure, or signal), never assume S0/git-HEAD was the starting state.
#
# Usage: sh tests/display-backlight-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/display-backlight-variant.sh"
DTS="$REPO_ROOT/vendor/x2000_kernel_6.6/kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts"

PASS=0
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=$((FAIL + 1))
}

pass() {
	PASS=$((PASS + 1))
}

[ -f "$DTS" ] || {
	echo "SKIP: $DTS not present"
	exit 0
}

PRETEST_SNAPSHOT=$(mktemp)
cp "$DTS" "$PRETEST_SNAPSHOT"

cleanup() {
	cp "$PRETEST_SNAPSHOT" "$DTS"
	rm -f "$PRETEST_SNAPSHOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Test 1: S0 leaves the tracked DTS git-clean (today's real baseline
# needs no override at all). ---
sh "$VARIANT_SCRIPT" S0 >/dev/null
if [ -z "$(git -C "$REPO_ROOT" status --porcelain -- "$DTS")" ]; then
	pass
else
	fail "S0 did not produce a git-clean DTS file"
fi

# --- Test 2: S1 adds exactly one nebulaos_backlight node. ---
sh "$VARIANT_SCRIPT" S1 >/dev/null
count=$(grep -c 'nebulaos_backlight:' "$DTS")
if [ "$count" = "1" ]; then
	pass
else
	fail "S1 produced $count nebulaos_backlight node(s), expected exactly 1"
fi

# --- Test 3: S1 repoints &pwm's pinctrl-0 to pwm0_pc (real backlight pin),
# not the previously-unused pwm1_pc. ---
if grep -q 'pinctrl-0 = <&pwm0_pc>;' "$DTS"; then
	pass
else
	fail "S1 did not repoint &pwm to pwm0_pc"
fi
if grep -q 'pinctrl-0 = <&pwm1_pc>;' "$DTS"; then
	fail "S1 left a stale pinctrl-0 = <&pwm1_pc>; reference in the DTS"
else
	pass
fi

# --- Test 4: S1's backlight node references PWM channel 0 (not channel 1),
# at 20000ns period (50kHz, matching stock's real pwm_freq=50000). ---
if grep -q 'pwms = <&pwm 0 20000>;' "$DTS"; then
	pass
else
	fail "S1's backlight node does not reference channel 0 at a 20000ns/50kHz period"
fi

# --- Test 5: re-applying S1 twice in a row is idempotent (no duplicate
# blocks/nodes). ---
sh "$VARIANT_SCRIPT" S1 >/dev/null
count=$(grep -c 'nebulaos_backlight:' "$DTS")
if [ "$count" = "1" ]; then
	pass
else
	fail "re-applying S1 produced $count nebulaos_backlight node(s), expected exactly 1 (not idempotent)"
fi

# --- Test 6: switching from S1 back to S0 restores a byte-identical,
# git-clean baseline (no residual blank lines, partial blocks, or a
# dangling pwm0_pc repoint left behind). ---
sh "$VARIANT_SCRIPT" S0 >/dev/null
if [ -z "$(git -C "$REPO_ROOT" status --porcelain -- "$DTS")" ]; then
	pass
else
	fail "switching from S1 back to S0 left the DTS modified: $(git -C "$REPO_ROOT" diff -- "$DTS")"
fi

# --- Test 7: an unknown variant name is rejected, not silently applied. ---
if sh "$VARIANT_SCRIPT" S9 >/dev/null 2>&1; then
	fail "an unknown variant name 'S9' was accepted instead of rejected"
else
	pass
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
