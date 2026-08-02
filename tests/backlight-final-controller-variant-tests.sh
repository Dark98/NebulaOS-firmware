#!/bin/sh
#
# Offline, repeatable tests for
# scripts/build/backlight-final-controller-variant.sh (DISPLAY-B-FINAL
# post-incident backlight controller redesign, 2026-08-02+). Operates
# against the real vendor kernel checkout's tracked source/DTS files and
# the tracked Kconfig fragment.
#
# These tests prove what is provable OFFLINE, by source inspection and
# compile-time structure alone: that the toggle script is idempotent, that
# it NEVER touches the shared &pwm node's own pinctrl-0 (the literal root
# cause of the real incident this driver's file header documents), that
# probe() never acquires GPC0/PC22/PWM0, that the state machine's
# transition-validity rules are enforced in source, and that the watchdog/
# restore discipline matches the same arm-before-apply ordering already
# proven correct for CONFIG_NEBULAOS_BACKLIGHT_PROBE_DIAG. They do NOT and
# CANNOT prove real hardware behavior - see the driver's own file header
# for what remains UNKNOWN_UNTIL_HARDWARE.
#
# IMPORTANT: do not run this suite while any build against the vendor
# kernel checkout is in flight - see the warning in
# scripts/build/backlight-final-controller-variant.sh.
#
# Usage: sh tests/backlight-final-controller-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/backlight-final-controller-variant.sh"
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"
DTS_REL="kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts"
DTS="$KERNEL_DIR/$DTS_REL"
DRIVER_REL="kernel/kernel-6.6/module_drivers/drivers/misc/nebulaos_backlight_final_controller.c"
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
PRETEST_PWM_BLOCK=$(sed -n '/^&pwm {/,/^};/p' "$DTS")

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

# --- Test 1: FINAL0 leaves the affected files git-clean, no driver file,
# no fragment block. ---
sh "$VARIANT_SCRIPT" FINAL0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "FINAL0 did not produce clean affected files: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if [ -f "$DRIVER" ]; then
	fail "FINAL0 left the controller driver file present"
else
	pass
fi
if grep -q 'NEBULAOS_BACKLIGHT_FINAL_CONTROLLER' "$FRAGMENT"; then
	fail "FINAL0 left CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER in the fragment"
else
	pass
fi

# --- Test 2: FINAL1 applies the patch - driver file created, Kconfig
# option added to source, fragment selects it exactly once. ---
sh "$VARIANT_SCRIPT" FINAL1 >/dev/null
if [ -f "$DRIVER" ]; then
	pass
else
	fail "FINAL1 did not create $DRIVER_REL"
fi
if grep -q 'config NEBULAOS_BACKLIGHT_FINAL_CONTROLLER' \
	"$KERNEL_DIR/kernel/kernel-6.6/module_drivers/drivers/misc/Kconfig"; then
	pass
else
	fail "FINAL1 did not add the NEBULAOS_BACKLIGHT_FINAL_CONTROLLER Kconfig option to source"
fi
count=$(grep -c '^CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER=y$' "$FRAGMENT")
if [ "$count" = "1" ]; then
	pass
else
	fail "FINAL1 produced $count CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER=y lines, expected exactly 1"
fi

# --- Test 3: FINAL1 adds exactly one DT node referencing the candidate
# PWM channel 0, GPC0-as-GPIO, and PC22. ---
node_count=$(grep -c 'nebulaos_backlight_final: nebulaos_backlight_final' "$DTS")
if [ "$node_count" = "1" ]; then
	pass
else
	fail "FINAL1 produced $node_count nebulaos_backlight_final nodes, expected exactly 1"
fi
if grep -q 'compatible = "nebulaos,backlight-final-controller"' "$DTS" && \
   grep -q 'pwms = <&pwm 0 20000>;' "$DTS" && \
   grep -q 'backlight-gpios = <&gpc 0 GPIO_ACTIVE_HIGH INGENIC_GPIO_NOBIAS>;' "$DTS" && \
   grep -q 'enable-gpios = <&gpc 22 GPIO_ACTIVE_HIGH INGENIC_GPIO_NOBIAS>;' "$DTS"; then
	pass
else
	fail "FINAL1's DT node does not reference the expected GPC0/PWM0/PC22 candidate properties"
fi

# --- Test 4: THE critical regression test for this whole redesign - the
# shared &pwm controller node's own pinctrl-0 property is BYTE-IDENTICAL
# before and after FINAL1 is applied (and after it is reverted). This is
# the literal root cause of the real incident this driver exists because
# of - see nebulaos_backlight_final_controller.c's file header. ---
POSTAPPLY_PWM_BLOCK=$(sed -n '/^&pwm {/,/^};/p' "$DTS")
if [ "$PRETEST_PWM_BLOCK" = "$POSTAPPLY_PWM_BLOCK" ]; then
	pass
else
	fail "the &pwm node's own block changed after FINAL1 was applied - THIS IS THE EXACT BUG CLASS THAT CAUSED THE REAL INCIDENT. before:
$PRETEST_PWM_BLOCK
after:
$POSTAPPLY_PWM_BLOCK"
fi
if grep -q 'pinctrl-0 = <&pwm1_pc>;' "$DTS" && ! grep -q 'pinctrl-0 = <&pwm0_pc &pwm1_pc>;' "$DTS"; then
	pass
else
	fail "&pwm's pinctrl-0 no longer reads <&pwm1_pc> after FINAL1 - it must NEVER be repointed"
fi
# The new DT node's OWN pinctrl-0 (a different property, on a different
# node) is allowed and expected to reference pwm0_pc - that line existing
# somewhere in the file is fine; what must never happen is &pwm's own
# block containing it. Confirm the new node's own state name is NOT
# "default"/"init" (the only two names the device core auto-selects).
if grep -q 'pinctrl-names = "pwm-active";' "$DTS"; then
	pass
else
	fail "the new DT node's pinctrl-names is not the expected non-auto-selected \"pwm-active\""
fi
if sed -n '/nebulaos_backlight_final: nebulaos_backlight_final {/,/^	};/p' "$DTS" | \
   grep -Eq 'pinctrl-names = "(default|init)"'; then
	fail "the new DT node names its pinctrl state \"default\" or \"init\" - the device core's " \
		"automatic pinctrl_bind_pins() would select it at probe time, recreating the incident"
else
	pass
fi

# --- Test 5: source inspection - probe() never acquires GPC0/PC22/PWM0.
# The probe() function body must contain ZERO calls to
# gpiod_get()/devm_gpiod_get()/pwm_get()/devm_pwm_get()/
# pinctrl_get_select()/pinctrl_select_state() for any resource. ---
driver_no_comments=$(grep -v '^[[:space:]]*\*' "$DRIVER" | grep -v '^[[:space:]]*/\*')
probe_body=$(echo "$driver_no_comments" | awk '/^static int nblc_probe\(/,/^}/')
if [ -n "$probe_body" ]; then
	pass
else
	fail "could not extract nblc_probe() body"
fi
if echo "$probe_body" | grep -Eq 'gpiod_get|devm_gpiod_get|pwm_get|devm_pwm_get|pinctrl_get|pinctrl_select_state'; then
	fail "nblc_probe() acquires a GPIO/PWM/pinctrl resource at bind time - this must NEVER happen"
else
	pass
fi
if echo "$probe_body" | grep -q 'NBLC_STATE_BOOT_PRESERVE'; then
	pass
else
	fail "nblc_probe() does not initialize state to NBLC_STATE_BOOT_PRESERVE"
fi

# --- Test 6: source inspection - the ONLY three functions that may call
# gpiod_get()/pwm_get()/pinctrl_get_select() for GPC0/PC22/PWM0 are the
# explicit transition functions, never probe() and never the command
# dispatcher directly. ---
gpc0_gpiod_get_count=$(echo "$driver_no_comments" | grep -c 'gpiod_get(n->dev, "backlight"')
pc22_gpiod_get_count=$(echo "$driver_no_comments" | grep -c 'gpiod_get(n->dev, "enable"')
pinctrl_select_count=$(echo "$driver_no_comments" | grep -c 'pinctrl_get_select(n->dev, "pwm-active")')
if [ "$gpc0_gpiod_get_count" -ge 1 ] && [ "$pc22_gpiod_get_count" -ge 1 ] && [ "$pinctrl_select_count" -ge 1 ]; then
	pass
else
	fail "expected acquisition call sites for GPC0/PC22/pwm-active pinctrl not found " \
		"(gpc0=$gpc0_gpiod_get_count pc22=$pc22_gpiod_get_count pinctrl=$pinctrl_select_count)"
fi
# None of those calls may appear inside nblc_command_write() itself (the
# dispatcher) - only inside the dedicated per-operation functions it calls.
command_write_body=$(echo "$driver_no_comments" | awk '/^static ssize_t nblc_command_write/,/^}/')
if echo "$command_write_body" | grep -Eq 'gpiod_get\(|pwm_get\(|pinctrl_get_select\('; then
	fail "nblc_command_write() itself acquires a hardware resource - acquisition must be " \
		"confined to the dedicated transition functions"
else
	pass
fi

# --- Test 7: state-machine transition validity - pwm-active is only
# entered from safe-on (never boot-preserve or safe-off-test directly).
# safe-off-test is likewise only entered from safe-on. ---
pwm_active_cmd_body=$(echo "$driver_no_comments" | awk '/^static int nblc_cmd_pwm_active/,/^}/')
if echo "$pwm_active_cmd_body" | grep -q 'n->state != NBLC_STATE_SAFE_ON' && \
   echo "$pwm_active_cmd_body" | grep -q '\-EPERM'; then
	pass
else
	fail "nblc_cmd_pwm_active() does not reject entry from any state other than safe-on"
fi
safe_off_cmd_body=$(echo "$driver_no_comments" | awk '/^static int nblc_cmd_safe_off_test/,/^}/')
if echo "$safe_off_cmd_body" | grep -q 'n->state != NBLC_STATE_SAFE_ON' && \
   echo "$safe_off_cmd_body" | grep -q '\-EPERM'; then
	pass
else
	fail "nblc_cmd_safe_off_test() does not reject entry from any state other than safe-on"
fi

# --- Test 8: single-operation serialization - a second bounded operation
# is rejected with -EBUSY while one is already active, for all three
# bounded-operation entry points. ---
pc22_cmd_body=$(echo "$driver_no_comments" | awk '/^static int nblc_cmd_pc22_test/,/^}/')
for body_name in "pwm_active_cmd_body:$pwm_active_cmd_body" "safe_off_cmd_body:$safe_off_cmd_body" "pc22_cmd_body:$pc22_cmd_body"; do
	name=${body_name%%:*}
	body=${body_name#*:}
	if echo "$body" | grep -q 'n->active_op != NBLC_OP_NONE' && echo "$body" | grep -q '\-EBUSY'; then
		pass
	else
		fail "$name does not reject a second concurrent operation with -EBUSY"
	fi
done

# --- Test 9: watchdog-before-mutation ordering (same discipline
# nebulaos_backlight_probe_diag.c already established) - in each of the
# three bounded-operation entry points, schedule_delayed_work() must
# appear BEFORE the corresponding hardware-mutating call. ---
check_arm_before() {
	body="$1"; mutate_pattern="$2"; label="$3"
	arm_line=$(echo "$body" | grep -n 'schedule_delayed_work(&n->restore_work' | head -1 | cut -d: -f1)
	mutate_line=$(echo "$body" | grep -n "$mutate_pattern" | head -1 | cut -d: -f1)
	if [ -n "$arm_line" ] && [ -n "$mutate_line" ] && [ "$arm_line" -lt "$mutate_line" ]; then
		pass
	else
		fail "$label: schedule_delayed_work() does not precede the hardware mutation " \
			"(arm_line=$arm_line mutate_line=$mutate_line)"
	fi
}
check_arm_before "$safe_off_cmd_body" 'gpiod_direction_output(n->gpc0_gpio, 0)' "nblc_cmd_safe_off_test"
check_arm_before "$pwm_active_cmd_body" 'nblc_enter_pwm_active_locked(n, duty_pct)' "nblc_cmd_pwm_active"
check_arm_before "$pc22_cmd_body" 'nblc_pc22_test_locked(n, level)' "nblc_cmd_pc22_test"

# --- Test 10: the 2-second hard watchdog cap is compile-time enforced for
# every operation duration via static_assert. ---
if grep -q '^#define NBLC_WATCHDOG_MAX_MS[[:space:]]*2000U$' "$DRIVER" && \
   grep -q 'static_assert(NBLC_SAFE_OFF_TEST_DEFAULT_MS >= NBLC_SAFE_OFF_TEST_MIN_MS &&' "$DRIVER" && \
   grep -q 'static_assert(NBLC_PC22_TEST_MS <= NBLC_WATCHDOG_MAX_MS' "$DRIVER" && \
   grep -q 'static_assert(NBLC_PWM_TEST_MS <= NBLC_WATCHDOG_MAX_MS' "$DRIVER"; then
	pass
else
	fail "the driver does not compile-time bounds-check every operation duration against " \
		"the 2000ms watchdog ceiling"
fi
# The configurable safe_off_test_ms module param is still hard-clamped at
# every use site, regardless of its runtime value.
if grep -q 'static unsigned int nblc_clamped_safe_off_ms(void)' "$DRIVER" && \
   grep -q 'if (ms > NBLC_WATCHDOG_MAX_MS)' "$DRIVER"; then
	pass
else
	fail "safe_off_test_ms is not hard-clamped to the watchdog ceiling at every use site"
fi

# --- Test 11: every restore path converges on the SAME single routine
# (nblc_converge_gpc0_safe_on_locked) - watchdog timeout, explicit
# restore/disarm, enter-pwm-active failure unwind, and remove() all call
# it, rather than each reimplementing its own restore logic. ---
for site in nblc_restore_work nblc_force_restore_now nblc_cmd_enter_safe_on nblc_enter_pwm_active_locked nblc_remove; do
	site_body=$(echo "$driver_no_comments" | awk "/^static (void|int) $site\(/,/^}/")
	if echo "$site_body" | grep -q 'nblc_converge_gpc0_safe_on_locked('; then
		pass
	else
		fail "$site() does not call the shared nblc_converge_gpc0_safe_on_locked() restore routine"
	fi
done

# --- Test 12: the restore routine re-verifies the readback rather than
# assuming the write succeeded, and surfaces a failed verification as a
# hard-stop (restore_failure_count incremented, safe_on_verified cleared,
# last_restore_reason recorded) rather than silently claiming success. ---
converge_body=$(echo "$driver_no_comments" | awk '/^static void nblc_converge_gpc0_safe_on_locked/,/^}/')
if echo "$converge_body" | grep -q 'gpiod_get_value(n->gpc0_gpio) == 1' && \
   echo "$converge_body" | grep -q 'n->safe_on_verified = true;' && \
   echo "$converge_body" | grep -q 'n->safe_on_verified = false;' && \
   echo "$converge_body" | grep -q 'n->restore_failure_count++;'; then
	pass
else
	fail "nblc_converge_gpc0_safe_on_locked() does not re-verify the GPC0 readback and " \
		"honestly record a failed restoration"
fi
# And it must set the internal fault state on any failure, so no other
# code path can later trust "state == safe-on" while gpc0_gpio is not
# actually held.
if echo "$converge_body" | grep -q 'n->state = NBLC_STATE_FAULT;'; then
	pass
else
	fail "nblc_converge_gpc0_safe_on_locked() does not set NBLC_STATE_FAULT on a failed " \
		"convergence - a caller could wrongly trust state==safe-on with no GPIO held"
fi

# --- Test 13: exiting pwm-active always disables the PWM, releases the
# PWM channel, and releases the pinctrl claim, in that order, before
# re-acquiring GPC0 as GPIO - see the file header items (c)/(d). ---
disable_line=$(echo "$converge_body" | grep -n 'st.enabled = false;' | head -1 | cut -d: -f1)
pwm_put_line=$(echo "$converge_body" | grep -n 'pwm_put(n->pwm);' | head -1 | cut -d: -f1)
pinctrl_put_line=$(echo "$converge_body" | grep -n 'pinctrl_put(n->pwm_pinctrl);' | head -1 | cut -d: -f1)
gpio_reacquire_line=$(echo "$converge_body" | grep -n 'gpiod_get(n->dev, "backlight", GPIOD_OUT_HIGH)' | head -1 | cut -d: -f1)
if [ -n "$disable_line" ] && [ -n "$pwm_put_line" ] && [ -n "$pinctrl_put_line" ] && [ -n "$gpio_reacquire_line" ] && \
   [ "$disable_line" -lt "$pwm_put_line" ] && [ "$pwm_put_line" -lt "$pinctrl_put_line" ] && \
   [ "$pinctrl_put_line" -lt "$gpio_reacquire_line" ]; then
	pass
else
	fail "the exit-pwm-active ordering (disable -> release PWM -> release pinctrl -> " \
		"re-acquire GPIO) is not enforced in source order " \
		"(disable=$disable_line pwm_put=$pwm_put_line pinctrl_put=$pinctrl_put_line gpio=$gpio_reacquire_line)"
fi

# --- Test 14: entering pwm-active releases the GPIO claim BEFORE
# selecting the pwm-active pinctrl state - GPC0 must never be
# simultaneously claimed through both subsystems at once. ---
enter_pwm_body=$(echo "$driver_no_comments" | awk '/^static int nblc_enter_pwm_active_locked/,/^}/')
gpio_put_line=$(echo "$enter_pwm_body" | grep -n 'gpiod_put(n->gpc0_gpio);' | head -1 | cut -d: -f1)
pinctrl_select_line=$(echo "$enter_pwm_body" | grep -n 'pinctrl_get_select(n->dev, "pwm-active")' | head -1 | cut -d: -f1)
if [ -n "$gpio_put_line" ] && [ -n "$pinctrl_select_line" ] && [ "$gpio_put_line" -lt "$pinctrl_select_line" ]; then
	pass
else
	fail "nblc_enter_pwm_active_locked() does not release the GPIO claim before selecting " \
		"the pwm-active pinctrl state"
fi
# Every failure path inside this function must unwind through the shared
# converge routine, not leave GPC0 muxed-to-PWM-but-undriven.
if echo "$enter_pwm_body" | grep -q '^unwind:' && \
   echo "$enter_pwm_body" | grep -A3 '^unwind:' | grep -q 'nblc_converge_gpc0_safe_on_locked'; then
	pass
else
	fail "nblc_enter_pwm_active_locked() does not unwind to safe-on on every failure path"
fi

# --- Test 15: PWM duty is restricted to exactly 25/50/75% - 0% and 100%
# are never reachable through the debugfs command interface. ---
if grep -q '"pwm-active-25"' "$DRIVER" && grep -q '"pwm-active-50"' "$DRIVER" && \
   grep -q '"pwm-active-75"' "$DRIVER"; then
	pass
else
	fail "the driver does not recognize exactly the pwm-active-25/50/75 command literals"
fi
if grep -Eq '"pwm-active-0"|"pwm-active-100"' "$DRIVER"; then
	fail "the driver source contains a pwm-active-0/pwm-active-100 command literal - " \
		"0%/100% must never be reachable"
else
	pass
fi
if grep -q 'duty_pct != 25 && duty_pct != 50 && duty_pct != 75' "$DRIVER"; then
	pass
else
	fail "nblc_cmd_pwm_active() does not defensively reject any duty value outside {25,50,75}"
fi

# --- Test 16: the debugfs command whitelist rejects any trailing
# argument, same discipline as nebulaos_backlight_probe_diag.c's hardening
# pass - no arbitrary GPIO/channel/duty/period/timeout can be smuggled
# through. ---
whitelist_check_line=$(echo "$command_write_body" | grep -n 'if (rest && \*rest)' | head -1 | cut -d: -f1)
dispatch_line=$(echo "$command_write_body" | grep -n 'if (!strcmp(cmd, "status"))' | head -1 | cut -d: -f1)
if [ -n "$whitelist_check_line" ] && [ -n "$dispatch_line" ] && [ "$whitelist_check_line" -lt "$dispatch_line" ]; then
	pass
else
	fail "a trailing argument is not rejected before command dispatch"
fi
if echo "$driver_no_comments" | grep -q 'kstrtouint('; then
	fail "the driver calls kstrtouint() - an arbitrary caller-supplied numeric argument " \
		"could be smuggled through"
else
	pass
fi
for word in status enter-safe-on safe-off-test pc22-test-low pc22-test-high pwm-active-25 pwm-active-50 pwm-active-75 disarm restore; do
	if echo "$command_write_body" | grep -q "!strcmp(cmd, \"$word\")"; then
		pass
	else
		fail "nblc_command_write() does not dispatch the documented command \"$word\""
	fi
done

# --- Test 17: legacy /sys/class/gpio sysfs is never USED anywhere in the
# driver's real code or the toggle script - it IS expected and desired for
# the driver's own file header comments to mention the literal path when
# documenting exactly why it's forbidden (same "explain the incident"
# documentation style this project already uses elsewhere), so this checks
# non-comment code only, plus real shell usage in the toggle script. ---
if echo "$driver_no_comments" | grep -q '/sys/class/gpio'; then
	fail "the driver's real code (not just comments) references /sys/class/gpio - forbidden"
else
	pass
fi
if echo "$driver_no_comments" | grep -Eq '\bexport_store\b|gpio_export\('; then
	fail "the driver references legacy sysfs GPIO export internals - forbidden"
else
	pass
fi
variant_script_no_comments=$(grep -v '^[[:space:]]*#' "$VARIANT_SCRIPT")
if echo "$variant_script_no_comments" | grep -q '/sys/class/gpio'; then
	fail "the toggle script's real code (not just comments) references /sys/class/gpio - forbidden"
else
	pass
fi

# --- Test 18: PC22 already-owned detection - gpiod_get() failure (e.g.
# -EBUSY) is checked and refused with a clear warning, never silently
# ignored or crashed into. ---
pc22_test_locked_body=$(echo "$driver_no_comments" | awk '/^static int nblc_pc22_test_locked/,/^}/')
if echo "$pc22_test_locked_body" | grep -q 'IS_ERR(desc)' && \
   echo "$pc22_test_locked_body" | grep -q '\-EBUSY' && \
   echo "$pc22_test_locked_body" | grep -q 'dev_warn'; then
	pass
else
	fail "nblc_pc22_test_locked() does not detect and clearly report an already-owned PC22 " \
		"(-EBUSY from gpiod_get())"
fi
# The initial level capture is honest about direction being unavailable on
# this platform - never fabricates a value.
if grep -q 'pc22_initial_direction_known = false;' "$DRIVER"; then
	pass
else
	fail "the driver does not honestly record PC22's initial direction as unavailable"
fi

# --- Test 19: PC22 test operations are fixed at 1 second, low/high only -
# nothing else exposed. ---
if grep -q '^#define NBLC_PC22_TEST_MS[[:space:]]*1000U$' "$DRIVER"; then
	pass
else
	fail "NBLC_PC22_TEST_MS is not fixed at exactly 1000ms"
fi

# --- Test 20: status exposes every field the mission's runtime interface
# requires: armed, state, active_op, timeout remaining, GPC0 mode/level,
# PWM owned/enabled/period/duty, PC22 state, restore/watchdog-restore/
# restore-failure counts, last restore reason, and safe-on-verified. ---
status_dump_body=$(echo "$driver_no_comments" | awk '/^static void nblc_status_dump/,/^}/')
for field in 'armed:' 'state:' 'active_op:' 'timeout_remaining_ms:' 'gpc0_mode:' 'gpc0_level:' \
	     'pwm_owned:' 'pwm_enabled:' 'pwm_period_ns:' 'pwm_duty_pct:' 'pc22_active:' \
	     'restore_count:' 'watchdog_restore_count:' 'restore_failure_count:' \
	     'last_restore_reason:' 'safe_on_verified:'; do
	if echo "$status_dump_body" | grep -q "\"$field"; then
		pass
	else
		fail "nblc_status_dump() does not expose the required \"$field\" status field"
	fi
done

# --- Test 21: re-applying FINAL1 twice is idempotent. ---
if sh "$VARIANT_SCRIPT" FINAL1 >/dev/null 2>&1; then
	node_count=$(grep -c 'nebulaos_backlight_final: nebulaos_backlight_final' "$DTS")
	frag_count=$(grep -c '^CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER=y$' "$FRAGMENT")
	pwm_block_now=$(sed -n '/^&pwm {/,/^};/p' "$DTS")
	if [ "$node_count" = "1" ] && [ "$frag_count" = "1" ] && [ "$pwm_block_now" = "$PRETEST_PWM_BLOCK" ]; then
		pass
	else
		fail "re-applying FINAL1 produced $node_count DT nodes / $frag_count fragment " \
			"lines, or changed the &pwm block - expected exactly 1 each and an " \
			"unchanged &pwm block"
	fi
else
	fail "re-applying FINAL1 a second time failed - not idempotent"
fi

# --- Test 22: switching from FINAL1 back to FINAL0 restores clean
# affected files, removes the driver file, empties the fragment block, and
# leaves &pwm's block byte-identical to the pristine baseline. ---
sh "$VARIANT_SCRIPT" FINAL0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "switching from FINAL1 back to FINAL0 left the affected files modified: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if [ -f "$DRIVER" ]; then
	fail "switching from FINAL1 back to FINAL0 left the controller driver file present"
else
	pass
fi
if grep -q 'NEBULAOS_BACKLIGHT_FINAL_CONTROLLER' "$FRAGMENT"; then
	fail "switching from FINAL1 back to FINAL0 left CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER in the fragment"
else
	pass
fi
POSTREVERT_PWM_BLOCK=$(sed -n '/^&pwm {/,/^};/p' "$DTS")
if [ "$POSTREVERT_PWM_BLOCK" = "$PRETEST_PWM_BLOCK" ]; then
	pass
else
	fail "&pwm's block is not byte-identical to the pristine baseline after reverting to FINAL0"
fi

# --- Test 23: an unknown variant name is rejected, not silently applied. ---
if sh "$VARIANT_SCRIPT" FINAL9 >/dev/null 2>&1; then
	fail "an unknown variant name 'FINAL9' was accepted instead of rejected"
else
	pass
fi

# --- Test 24: the toggle script itself refuses to proceed if &pwm's
# pinctrl-0 is not the expected pristine <&pwm1_pc> value (e.g. left
# modified by an older/other script) rather than silently building on top
# of an unexpected value. ---
sh "$VARIANT_SCRIPT" FINAL0 >/dev/null
sed -i 's/pinctrl-0 = <&pwm1_pc>;/pinctrl-0 = <\&pwm0_pc>;/' "$DTS"
if sh "$VARIANT_SCRIPT" FINAL1 >/dev/null 2>&1; then
	fail "the toggle script proceeded despite &pwm's pinctrl-0 already being non-pristine"
else
	pass
fi
# Restore for the rest of the suite / cleanup trap.
sed -i 's/pinctrl-0 = <&pwm0_pc>;/pinctrl-0 = <\&pwm1_pc>;/' "$DTS"
sh "$VARIANT_SCRIPT" FINAL0 >/dev/null

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
