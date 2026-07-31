#!/bin/sh
#
# Offline, repeatable tests for scripts/build/wifi-sdio-variant.sh
# (pre-qualification mission Phase A4, 2026-07-31).
#
# Unlike this repo's other offline test suites, this one operates
# against the real vendor/x2000_kernel_6.6 checkout rather than a
# fixture - the script's whole job is editing that real file via git-
# scoped sed ranges, and a fixture DTS would need to duplicate its exact
# msc0/msc1 structure to be meaningful, risking drifting out of sync with
# the real file. Safety net: a trap guarantees the checkout is always
# reset to a clean W0 baseline on exit, pass or fail, so this suite never
# leaves the real vendor tree in a modified state even if interrupted.
#
# Skips (not fails) if vendor/x2000_kernel_6.6 isn't fetched yet.
#
# Usage: sh tests/wifi-sdio-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/wifi-sdio-variant.sh"
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
DTS="$KERNEL_DIR/kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts"

if [ ! -f "$DTS" ]; then
	echo "SKIP: $DTS not present - run 00-fetch-vendor-sources.sh first to exercise this suite"
	exit 0
fi

PASS=0
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=$((FAIL + 1))
}

pass() {
	PASS=$((PASS + 1))
}

cleanup() {
	sh "$VARIANT_SCRIPT" W0 >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

msc1_props() {
	sed -n '/^&msc1 {/,/^};/p' "$DTS" | grep -E 'cap-sdio-irq;|cap-sd-highspeed;|cap-mmc-highspeed;'
}

msc0_props() {
	sed -n '/^&msc0 {/,/^};/p' "$DTS" | grep -E 'cap-sdio-irq;|cap-sd-highspeed;|cap-mmc-highspeed;'
}

msc0_baseline=$(msc0_props)

# --- Test 1: W0 leaves the tree git-clean. ---
sh "$VARIANT_SCRIPT" W0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain)" ]; then
	pass
else
	fail "W0 did not produce a git-clean tree"
fi

# --- Test 2: W1 adds cap-sdio-irq, keeps cap-mmc-highspeed, no cap-sd-highspeed. ---
sh "$VARIANT_SCRIPT" W1 >/dev/null
props=$(msc1_props)
if printf '%s' "$props" | grep -q 'cap-sdio-irq;' \
	&& printf '%s' "$props" | grep -q 'cap-mmc-highspeed;' \
	&& ! printf '%s' "$props" | grep -q 'cap-sd-highspeed;'; then
	pass
else
	fail "W1 did not produce the expected property set: $props"
fi

# --- Test 3: W2 replaces cap-mmc-highspeed with cap-sd-highspeed, no cap-sdio-irq. ---
sh "$VARIANT_SCRIPT" W2 >/dev/null
props=$(msc1_props)
if printf '%s' "$props" | grep -q 'cap-sd-highspeed;' \
	&& ! printf '%s' "$props" | grep -q 'cap-mmc-highspeed;' \
	&& ! printf '%s' "$props" | grep -q 'cap-sdio-irq;'; then
	pass
else
	fail "W2 did not produce the expected property set: $props"
fi

# --- Test 4: W3 has both cap-sdio-irq and cap-sd-highspeed, no cap-mmc-highspeed. ---
sh "$VARIANT_SCRIPT" W3 >/dev/null
props=$(msc1_props)
if printf '%s' "$props" | grep -q 'cap-sdio-irq;' \
	&& printf '%s' "$props" | grep -q 'cap-sd-highspeed;' \
	&& ! printf '%s' "$props" | grep -q 'cap-mmc-highspeed;'; then
	pass
else
	fail "W3 did not produce the expected property set: $props"
fi

# --- Test 5: msc0 (the real eMMC boot storage) is never touched by any
# variant - confirmed unchanged after applying all four in sequence. ---
if [ "$(msc0_props)" = "$msc0_baseline" ]; then
	pass
else
	fail "msc0's cap-* properties changed after applying Wi-Fi SDIO variants (must never happen): before='$msc0_baseline' after='$(msc0_props)'"
fi

# --- Test 6: re-applying the same variant twice is idempotent (no
# duplicate properties, no error). ---
sh "$VARIANT_SCRIPT" W1 >/dev/null
first_count=$(msc1_props | grep -c 'cap-sdio-irq;')
sh "$VARIANT_SCRIPT" W1 >/dev/null
second_count=$(msc1_props | grep -c 'cap-sdio-irq;')
if [ "$first_count" = "1" ] && [ "$second_count" = "1" ]; then
	pass
else
	fail "applying W1 twice did not stay idempotent (counts: $first_count then $second_count)"
fi

# --- Test 7: switching back to W0 after any other variant returns to a
# byte-identical, git-clean baseline. ---
sh "$VARIANT_SCRIPT" W3 >/dev/null
sh "$VARIANT_SCRIPT" W0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain)" ]; then
	pass
else
	fail "switching from W3 back to W0 did not produce a git-clean tree"
fi

# --- Test 8: an unknown variant name is rejected, not silently applied. ---
if sh "$VARIANT_SCRIPT" W9 >/dev/null 2>&1; then
	fail "an unknown variant name 'W9' was accepted instead of rejected"
else
	pass
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
