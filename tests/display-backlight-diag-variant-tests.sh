#!/bin/sh
#
# Offline, repeatable tests for scripts/build/display-backlight-diag-variant.sh
# (DISPLAY-B0-DIAG prototype, display hardware analysis mission follow-on,
# 2026-08-01+). Operates against the real vendor kernel checkout's tracked
# source/DTS files and the tracked Kconfig fragment.
#
# These tests prove what is provable OFFLINE, by source inspection and
# compile-time structure alone: that the toggle script is idempotent, that
# the patch adds exactly the documented safeguards, and that specific
# dangerous patterns (e.g. calling pwm_apply_state()/gpiod_direction_output()
# from probe()) are absent. They do NOT and CANNOT prove that the safeguards
# behave correctly on real hardware at runtime (e.g. that the workqueue
# timer really fires, that a real PWM/GPIO write really takes effect, that
# a killed shell really cannot block the restore) - see the mission's final
# report for which claims remain SUPPORTED_INFERENCE vs PROVEN_BY_COMPILE_TEST
# vs requiring live hardware.
#
# IMPORTANT: do not run this suite while any build against the vendor
# kernel checkout is in flight - see the warning in
# scripts/build/display-backlight-diag-variant.sh.
#
# Usage: sh tests/display-backlight-diag-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/display-backlight-diag-variant.sh"
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"
DTS_REL="kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts"
DTS="$KERNEL_DIR/$DTS_REL"
DRIVER_REL="kernel/kernel-6.6/module_drivers/drivers/misc/nebulaos_backlight_probe_diag.c"
DRIVER="$KERNEL_DIR/$DRIVER_REL"
AFFECTED_FILES="kernel/kernel-6.6/module_drivers/drivers/misc/Kconfig kernel/kernel-6.6/module_drivers/drivers/misc/Makefile $DTS_REL"

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
PRETEST_DRIVER_EXISTED=0
[ -f "$DRIVER" ] && PRETEST_DRIVER_EXISTED=1

cleanup() {
	cp "$PRETEST_FRAGMENT" "$FRAGMENT"
	for f in $AFFECTED_FILES; do
		cp "$PRETEST_KERNEL_SNAPSHOT/$f" "$KERNEL_DIR/$f"
	done
	if [ "$PRETEST_DRIVER_EXISTED" = "0" ]; then
		rm -f "$DRIVER"
	fi
	rm -f "$PRETEST_FRAGMENT"
	rm -rf "$PRETEST_KERNEL_SNAPSHOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Test 1: DIAG0 leaves the affected files git-clean, no driver file,
# no fragment block. ---
sh "$VARIANT_SCRIPT" DIAG0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "DIAG0 did not produce clean affected files: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if [ -f "$DRIVER" ]; then
	fail "DIAG0 left the diagnostic driver file present"
else
	pass
fi
if grep -q 'NEBULAOS_BACKLIGHT_PROBE_DIAG' "$FRAGMENT"; then
	fail "DIAG0 left CONFIG_NEBULAOS_BACKLIGHT_PROBE_DIAG in the fragment"
else
	pass
fi

# --- Test 2: DIAG1 applies the patch - driver file created, Kconfig
# option added to source, fragment selects it exactly once. ---
sh "$VARIANT_SCRIPT" DIAG1 >/dev/null
if [ -f "$DRIVER" ]; then
	pass
else
	fail "DIAG1 did not create $DRIVER_REL"
fi
if grep -q 'config NEBULAOS_BACKLIGHT_PROBE_DIAG' \
	"$KERNEL_DIR/kernel/kernel-6.6/module_drivers/drivers/misc/Kconfig"; then
	pass
else
	fail "DIAG1 did not add the NEBULAOS_BACKLIGHT_PROBE_DIAG Kconfig option to source"
fi
count=$(grep -c '^CONFIG_NEBULAOS_BACKLIGHT_PROBE_DIAG=y$' "$FRAGMENT")
if [ "$count" = "1" ]; then
	pass
else
	fail "DIAG1 produced $count CONFIG_NEBULAOS_BACKLIGHT_PROBE_DIAG=y lines, expected exactly 1"
fi

# --- Test 3: DIAG1 adds exactly one DT node referencing the candidate PWM
# channel 0 and repoints &pwm away from the unused channel-1 pin. ---
node_count=$(grep -c 'nebulaos_backlight_diag: nebulaos_backlight_diag' "$DTS")
if [ "$node_count" = "1" ]; then
	pass
else
	fail "DIAG1 produced $node_count nebulaos_backlight_diag nodes, expected exactly 1"
fi
if grep -q 'compatible = "nebulaos,backlight-probe-diag"' "$DTS" && \
   grep -q 'pwms = <&pwm 0 20000>;' "$DTS"; then
	pass
else
	fail "DIAG1's DT node does not reference the candidate PWM channel 0/20000ns period"
fi
if grep -q 'pinctrl-0 = <&pwm0_pc>;' "$DTS" && ! grep -q 'pinctrl-0 = <&pwm1_pc>;' "$DTS"; then
	pass
else
	fail "DIAG1 did not repoint &pwm to pwm0_pc, or left a stale pwm1_pc reference"
fi

# --- Test 4: source inspection - probe() never applies PWM/GPIO state,
# only reads it. The probe() function body (nebulaos_bl_diag_probe, up to
# its closing brace) must contain pwm_get_state() but must NOT contain
# pwm_apply_state()/gpiod_direction_output()/gpiod_set_raw_value_cansleep(). ---
probe_body=$(awk '/^static int nebulaos_bl_diag_probe/,/^}/' "$DRIVER")
# Strip comment lines first (this check must look only at real code, not
# at comments that happen to mention the very calls they warn against).
probe_code_only=$(echo "$probe_body" | grep -v '^[[:space:]]*\*' | grep -v '/\*')
if echo "$probe_code_only" | grep -q 'pwm_get_state'; then
	pass
else
	fail "nebulaos_bl_diag_probe() does not call pwm_get_state() - cannot confirm it only reads state"
fi
if echo "$probe_code_only" | grep -Eq 'pwm_apply_state|gpiod_direction_output|gpiod_set_raw_value_cansleep'; then
	fail "nebulaos_bl_diag_probe() applies PWM/GPIO state at bind time - this must never happen"
else
	pass
fi

# --- Test 5: source inspection - only 25/50/75 duty values are ever
# accepted; 0 and 100 are never present as accepted literals. ---
if grep -q '!strcmp(value, "25")' "$DRIVER" && \
   grep -q '!strcmp(value, "50")' "$DRIVER" && \
   grep -q '!strcmp(value, "75")' "$DRIVER"; then
	pass
else
	fail "the driver does not accept exactly the 25/50/75 duty literals"
fi
if grep -Eq '"0"|"100"' "$DRIVER"; then
	fail "the driver source contains a literal \"0\" or \"100\" duty string - 0%/100% must never be an accepted request"
else
	pass
fi

# --- Test 6: source inspection - overlapping probes are rejected before
# any hardware is touched (probe_active checked, -EBUSY returned). ---
if grep -q 'diag->probe_active) {' "$DRIVER" && grep -q '\-EBUSY' "$DRIVER"; then
	pass
else
	fail "the driver does not reject an overlapping probe with -EBUSY"
fi

# --- Test 7: source inspection - an out-of-range timeout is rejected
# before any hardware is touched. ---
if grep -q 'NEBULAOS_BL_DIAG_MIN_TIMEOUT_MS' "$DRIVER" && \
   grep -q 'NEBULAOS_BL_DIAG_MAX_TIMEOUT_MS' "$DRIVER" && \
   grep -q 'timeout_ms < NEBULAOS_BL_DIAG_MIN_TIMEOUT_MS ||' "$DRIVER"; then
	pass
else
	fail "the driver does not bounds-check the requested timeout"
fi

# --- Test 8: source inspection - the auto-restore path is a kernel
# workqueue (delayed_work), armed at probe time, independent of any
# calling process. ---
if grep -q 'INIT_DELAYED_WORK(&diag->restore_work, nebulaos_bl_diag_restore_work)' "$DRIVER" && \
   grep -q 'schedule_delayed_work(&diag->restore_work, msecs_to_jiffies(timeout_ms))' "$DRIVER"; then
	pass
else
	fail "the driver does not arm a kernel-owned delayed_work timer for auto-restore"
fi

# --- Test 9: source inspection - remove() forces a synchronous restore
# if a probe is still active, so unbinding never leaves hardware probed. ---
remove_body=$(awk '/^static int nebulaos_bl_diag_remove/,/^}/' "$DRIVER")
if echo "$remove_body" | grep -q 'cancel_delayed_work_sync' && \
   echo "$remove_body" | grep -q 'nebulaos_bl_diag_do_restore'; then
	pass
else
	fail "nebulaos_bl_diag_remove() does not force a restore of any still-active probe"
fi

# --- Test 10: hardening pass - the mission-mandated bounds are exactly
# default=2000ms, max=3000ms (not the prior revision's 3000/10000). ---
if grep -q '^#define NEBULAOS_BL_DIAG_DEFAULT_TIMEOUT_MS[[:space:]]*2000$' "$DRIVER" && \
   grep -q '^#define NEBULAOS_BL_DIAG_MAX_TIMEOUT_MS[[:space:]]*3000$' "$DRIVER"; then
	pass
else
	fail "the driver does not enforce default=2000ms/max=3000ms exactly"
fi

# --- Test 11: hardening pass - a timeout greater than 3 seconds is
# rejected. Source-inspection proof (no live kernel to exercise at test
# time): the bounds check compares the user-supplied timeout_ms against
# NEBULAOS_BL_DIAG_MAX_TIMEOUT_MS (=3000, proven by Test 10) with a
# strict '>' before anything is armed or touched, and this check runs
# before mutex_lock()/probe_active is ever set. ---
probe_cmd_body=$(awk '/^static int nebulaos_bl_diag_cmd_probe/,/^}/' "$DRIVER")
bounds_line=$(echo "$probe_cmd_body" | grep -n 'timeout_ms > NEBULAOS_BL_DIAG_MAX_TIMEOUT_MS' | head -1 | cut -d: -f1)
lock_line=$(echo "$probe_cmd_body" | grep -n 'mutex_lock(&diag->lock)' | head -1 | cut -d: -f1)
if [ -n "$bounds_line" ] && [ -n "$lock_line" ] && [ "$bounds_line" -lt "$lock_line" ]; then
	pass
else
	fail "a timeout_ms > NEBULAOS_BL_DIAG_MAX_TIMEOUT_MS (3s) is not rejected before the probe is armed"
fi

# --- Test 12: hardening pass - ARM-BEFORE-APPLY ordering. Within
# nebulaos_bl_diag_cmd_probe(), schedule_delayed_work() (arming the
# kernel-owned watchdog) must appear BEFORE both hardware-apply calls
# (pwm_apply_state()/gpiod_set_raw_value_cansleep() for the candidate
# state - the gpiod_get_raw_value_cansleep() capture call doesn't count,
# only the later *_set_* apply call does). A crash between "apply" and
# "arm" must never be possible - this was a real bug in an earlier
# revision (apply-then-arm) fixed in this hardening pass. ---
arm_line=$(echo "$probe_cmd_body" | grep -n 'schedule_delayed_work(&diag->restore_work' | head -1 | cut -d: -f1)
apply_gpio_line=$(echo "$probe_cmd_body" | grep -n 'gpiod_set_raw_value_cansleep(diag->enable_gpio, gpio_val)' | head -1 | cut -d: -f1)
apply_pwm_line=$(echo "$probe_cmd_body" | grep -n 'pwm_apply_state(diag->pwm, &new_state)' | head -1 | cut -d: -f1)
if [ -n "$arm_line" ] && [ -n "$apply_gpio_line" ] && [ -n "$apply_pwm_line" ] && \
   [ "$arm_line" -lt "$apply_gpio_line" ] && [ "$arm_line" -lt "$apply_pwm_line" ]; then
	pass
else
	fail "schedule_delayed_work() does not precede both hardware-apply calls in nebulaos_bl_diag_cmd_probe() - arm-before-apply ordering is violated"
fi

# --- Test 13: hardening pass - if pwm_apply_state() fails after the
# watchdog was already armed (per Test 12's ordering), the failure branch
# must unwind by canceling that timer. It must use the NON-blocking
# cancel_delayed_work() (not cancel_delayed_work_sync()) while diag->lock
# is still held - calling the blocking _sync() variant under the lock
# risks deadlocking against a concurrently-running watchdog callback
# blocked on the same lock, and calling it AFTER unlocking (an earlier
# revision's approach) reopened a TOCTOU race where a second thread's
# freshly-scheduled probe on the same delayed_work object could be wiped
# out by this cancel instead. Both the correct call and the two
# documented rationales must be present. ---
if echo "$probe_cmd_body" | grep -A2 'dev_err(diag->dev, "probe pwm %d%% failed to apply' | grep -q 'return ret;' && \
   echo "$probe_cmd_body" | grep -B40 'dev_err(diag->dev, "probe pwm %d%% failed to apply' | grep -q '^[[:space:]]*cancel_delayed_work(&diag->restore_work);$' && \
   echo "$probe_cmd_body" | grep -B40 'dev_err(diag->dev, "probe pwm %d%% failed to apply' | grep -qi 'TOCTOU'; then
	pass
else
	fail "the pwm_apply_state() failure path does not correctly unwind the already-armed watchdog timer with the documented non-blocking cancel + TOCTOU rationale"
fi
# The failure path's actual CODE (not the comments explaining why the
# blocking variant was rejected) must not call cancel_delayed_work_sync().
failure_unwind_code_only=$(echo "$probe_cmd_body" | grep -B40 'dev_err(diag->dev, "probe pwm %d%% failed to apply' | \
	grep -v '^[[:space:]]*\*' | grep -v '^[[:space:]]*/\*')
if echo "$failure_unwind_code_only" | grep -q 'cancel_delayed_work_sync'; then
	fail "the pwm_apply_state() failure path uses the blocking cancel_delayed_work_sync() under the lock - reintroduces a deadlock/TOCTOU risk"
else
	pass
fi

# --- Test 14: hardening pass - no arbitrary PWM channel or GPIO number
# can ever be requested through the debugfs interface. The two hardware
# handles (diag->pwm, diag->enable_gpio) must be acquired exactly once
# each, both inside nebulaos_bl_diag_probe() (module bind), and never
# from the command-write path. ---
driver_code_only=$(grep -v '^[[:space:]]*\*' "$DRIVER" | grep -v '^[[:space:]]*/\*')
pwm_get_count=$(echo "$driver_code_only" | grep -c 'devm_pwm_get(')
gpio_get_count=$(echo "$driver_code_only" | grep -c 'devm_gpiod_get_optional(')
probe_fn_body=$(awk '/^static int nebulaos_bl_diag_probe\(struct platform_device/,/^}/' "$DRIVER")
if [ "$pwm_get_count" = "1" ] && [ "$gpio_get_count" = "1" ] && \
   echo "$probe_fn_body" | grep -q 'devm_pwm_get(' && \
   echo "$probe_fn_body" | grep -q 'devm_gpiod_get_optional('; then
	pass
else
	fail "the candidate PWM/GPIO handles are not acquired exactly once, at module bind time only"
fi
if echo "$probe_cmd_body" | grep -Eq 'devm_pwm_get|devm_gpiod_get|gpio_to_desc|pwm_request'; then
	fail "nebulaos_bl_diag_cmd_probe() itself acquires a PWM/GPIO handle - this would allow requesting an arbitrary channel/GPIO"
else
	pass
fi

# --- Test 15: hardening pass - honest restoration-exactness reporting.
# The debugfs status output must expose both pwm_restore_is_exact (always
# 0 on this board - see Test 16) and gpio_restore_is_exact, and the file
# header must document the RESTORATION EXACTNESS limitation explicitly
# rather than silently relying on a reader noticing it. ---
if grep -q '"pwm_restore_is_exact: 0' "$DRIVER" && \
   grep -q 'gpio_restore_is_exact' "$DRIVER" && \
   grep -q 'RESTORATION EXACTNESS' "$DRIVER"; then
	pass
else
	fail "the driver does not expose honest pwm_restore_is_exact/gpio_restore_is_exact status fields with a documented rationale"
fi

# --- Test 16: hardening pass - the file must NOT claim the PWM restore
# path reads real hardware state. The known-dishonest phrase from an
# earlier revision ("reads the descriptor's cached/hardware state",
# implying a genuine register read for PWM) must not reappear, and the
# header must instead explain that pwm-ingenic-v2.c has no .get_state
# callback so pwm_get_state() cannot return real hardware content here. ---
if grep -q 'reads the descriptor.s cached/hardware state' "$DRIVER"; then
	fail "the driver still contains the overclaiming 'cached/hardware state' phrasing for the PWM restore path"
else
	pass
fi
if grep -q 'implements only the .apply callback' "$DRIVER" || grep -q 'implements no .get_state' "$DRIVER"; then
	pass
else
	fail "the driver does not explain why pwm-ingenic-v2.c cannot supply a real hardware readback for restoration"
fi

# --- Test 17: re-applying DIAG1 twice is idempotent. ---
if sh "$VARIANT_SCRIPT" DIAG1 >/dev/null 2>&1; then
	node_count=$(grep -c 'nebulaos_backlight_diag: nebulaos_backlight_diag' "$DTS")
	frag_count=$(grep -c '^CONFIG_NEBULAOS_BACKLIGHT_PROBE_DIAG=y$' "$FRAGMENT")
	if [ "$node_count" = "1" ] && [ "$frag_count" = "1" ]; then
		pass
	else
		fail "re-applying DIAG1 produced $node_count DT nodes / $frag_count fragment lines, expected exactly 1 each"
	fi
else
	fail "re-applying DIAG1 a second time failed - not idempotent"
fi

# --- Test 18: switching from DIAG1 back to DIAG0 restores clean affected
# files, removes the driver file, and empties the fragment block. ---
sh "$VARIANT_SCRIPT" DIAG0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "switching from DIAG1 back to DIAG0 left the affected files modified: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if [ -f "$DRIVER" ]; then
	fail "switching from DIAG1 back to DIAG0 left the diagnostic driver file present"
else
	pass
fi
if grep -q 'NEBULAOS_BACKLIGHT_PROBE_DIAG' "$FRAGMENT"; then
	fail "switching from DIAG1 back to DIAG0 left CONFIG_NEBULAOS_BACKLIGHT_PROBE_DIAG in the fragment"
else
	pass
fi

# --- Test 19: an unknown variant name is rejected, not silently applied. ---
if sh "$VARIANT_SCRIPT" DIAG9 >/dev/null 2>&1; then
	fail "an unknown variant name 'DIAG9' was accepted instead of rejected"
else
	pass
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
