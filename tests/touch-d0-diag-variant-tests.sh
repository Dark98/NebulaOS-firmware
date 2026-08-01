#!/bin/sh
#
# Offline, repeatable tests for scripts/build/touch-d0-diag-variant.sh
# (TOUCH-D0-DIAG prototype, display/touch investigation mission follow-on,
# 2026-08-01+). Same pattern as tests/touch-irq-variant-tests.sh.
#
# IMPORTANT: do not run this suite while any build against the vendor
# kernel checkout is in flight - see the warning in
# scripts/build/touch-d0-diag-variant.sh.
#
# Usage: sh tests/touch-d0-diag-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/touch-d0-diag-variant.sh"
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"
AFFECTED_FILES="kernel/kernel-6.6/drivers/input/touchscreen/Kconfig kernel/kernel-6.6/drivers/input/touchscreen/ns2009.c"
NS2009="$KERNEL_DIR/kernel/kernel-6.6/drivers/input/touchscreen/ns2009.c"

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$FRAGMENT" ] || { echo "SKIP: $FRAGMENT not present"; exit 0; }

PRETEST_FRAGMENT=$(mktemp)
cp "$FRAGMENT" "$PRETEST_FRAGMENT"
PRETEST_KERNEL_SNAPSHOT=$(mktemp -d)
for f in $AFFECTED_FILES; do
	mkdir -p "$PRETEST_KERNEL_SNAPSHOT/$(dirname "$f")"
	cp "$KERNEL_DIR/$f" "$PRETEST_KERNEL_SNAPSHOT/$f"
done

cleanup() {
	cp "$PRETEST_FRAGMENT" "$FRAGMENT"
	for f in $AFFECTED_FILES; do
		cp "$PRETEST_KERNEL_SNAPSHOT/$f" "$KERNEL_DIR/$f"
	done
	rm -f "$PRETEST_FRAGMENT"
	rm -rf "$PRETEST_KERNEL_SNAPSHOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Test 1: D0 leaves the affected files git-clean and no fragment block. ---
sh "$VARIANT_SCRIPT" D0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "D0 did not produce clean affected files: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if grep -q 'CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG' "$FRAGMENT"; then
	fail "D0 left CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG in the fragment"
else
	pass
fi

# --- Test 2: D1 applies the patch and selects the option exactly once. ---
sh "$VARIANT_SCRIPT" D1 >/dev/null
if grep -q 'config TOUCHSCREEN_NS2009_POLL_DIAG' \
	"$KERNEL_DIR/kernel/kernel-6.6/drivers/input/touchscreen/Kconfig"; then
	pass
else
	fail "D1 did not add the TOUCHSCREEN_NS2009_POLL_DIAG Kconfig option to source"
fi
count=$(grep -c '^CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG=y$' "$FRAGMENT")
if [ "$count" = "1" ]; then
	pass
else
	fail "D1 produced $count CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG=y lines, expected exactly 1"
fi

# --- Test 3: D1 adds the diagnostic hook call sites at the poll tick and
# both transition points, and leaves the existing poll/report logic
# structurally untouched (still exactly one input_report_key(..., 1) and
# one input_report_key(..., 0) call, and the always-on poll registration
# call unchanged). ---
if grep -q 'ns2009_diag_on_poll(data)' "$NS2009" && \
   grep -q 'ns2009_diag_on_touch_down(data)' "$NS2009" && \
   grep -q 'ns2009_diag_on_touch_release(data)' "$NS2009"; then
	pass
else
	fail "D1 did not wire all three diagnostic hook call sites (poll/down/release)"
fi
down_reports=$(grep -c 'input_report_key(data->input, BTN_TOUCH, 1)' "$NS2009")
up_reports=$(grep -c 'input_report_key(data->input, BTN_TOUCH, 0)' "$NS2009")
if [ "$down_reports" = "1" ] && [ "$up_reports" = "1" ]; then
	pass
else
	fail "D1 changed the number of BTN_TOUCH report call sites (down=$down_reports, up=$up_reports, expected 1 each) - zero behavior change was required"
fi
if grep -q 'input_setup_polling(data->input, ns2009_ts_poll)' "$NS2009"; then
	pass
else
	fail "D1 removed or altered the existing always-on poll registration - this must remain unconditional"
fi

# --- Test 4: D1 exposes read-only status + an explicit-only reset file,
# and the reset handler never touches the live transition-tracking state
# (diag_raw_level/diag_last_transition_was_down/diag_last_down_jiffies/
# diag_last_up_jiffies), only counters/min-max. ---
if grep -q 'debugfs_create_file("status", 0444' "$NS2009" && \
   grep -q 'debugfs_create_file("reset", 0200' "$NS2009"; then
	pass
else
	fail "D1 did not expose both a read-only status file and a write-only reset file"
fi
reset_body=$(awk '/^static ssize_t ns2009_diag_reset_write/,/^}/' "$NS2009")
if echo "$reset_body" | grep -Eq 'diag_raw_level|diag_last_transition_was_down|diag_last_down_jiffies|diag_last_up_jiffies'; then
	fail "the reset handler touches live transition-tracking state, not just counters - it must only zero counters/min-max"
else
	pass
fi
if echo "$reset_body" | grep -q 'diag_poll_count = 0'; then
	pass
else
	fail "the reset handler does not zero diag_poll_count"
fi

# --- Test 5: re-applying D1 twice is idempotent. ---
if sh "$VARIANT_SCRIPT" D1 >/dev/null 2>&1; then
	count=$(grep -c '^CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG=y$' "$FRAGMENT")
	if [ "$count" = "1" ]; then
		pass
	else
		fail "re-applying D1 produced $count fragment lines, expected exactly 1 (not idempotent)"
	fi
else
	fail "re-applying D1 a second time failed - not idempotent"
fi

# --- Test 6: switching from D1 back to D0 restores clean affected files
# and an empty fragment block. ---
sh "$VARIANT_SCRIPT" D0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "switching from D1 back to D0 left the affected files modified: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if grep -q 'CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG' "$FRAGMENT"; then
	fail "switching from D1 back to D0 left CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG in the fragment"
else
	pass
fi

# --- Test 7: an unknown variant name is rejected, not silently applied. ---
if sh "$VARIANT_SCRIPT" D9 >/dev/null 2>&1; then
	fail "an unknown variant name 'D9' was accepted instead of rejected"
else
	pass
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
