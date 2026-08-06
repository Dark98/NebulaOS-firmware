#!/bin/sh
# Phase 2 baseline assertions (baseline-canonicalization-and-z_compensate-
# deployment mission, 2026-08-06/07). Fails loudly and immediately if any
# qualified-baseline feature is missing - "do not accept script exit status
# as proof" (the mission's own words): apply-qualified-baseline.sh exiting
# 0 only means each variant script itself didn't error, not that the
# resulting *build* actually contains what it's supposed to. This script
# checks the real, resolved artifacts instead.
#
# Two modes:
#   sh scripts/build/assert-baseline-config.sh pre-build
#     Run AFTER apply-qualified-baseline.sh, BEFORE 02/03/05 - checks the
#     vendor kernel tree's source-level state (Kconfig symbols exist, DTS
#     nodes present) so a missing patch is caught before spending build time.
#   sh scripts/build/assert-baseline-config.sh post-build
#     Run AFTER 05-final-build.sh - checks the actual resolved
#     kernel.config/halley5_v30.dts that got baked into the real image,
#     which is the only real proof anything actually compiled in.
#
# Usage: sh scripts/build/assert-baseline-config.sh <pre-build|post-build>

set -eu

MODE="${1:?usage: $0 <pre-build|post-build>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
ARTIFACT_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"

FAILED=0
check() {
	desc="$1"
	if [ "$2" = "0" ]; then
		echo "  PASS: $desc"
	else
		echo "  FAIL: $desc"
		FAILED=1
	fi
}

case "$MODE" in
pre-build)
	echo "== Phase 2 pre-build assertions (source-level) =="

	# Kconfig symbol definitions must exist somewhere in the patched kernel
	# tree - if a patch failed to apply, the symbol simply won't be defined
	# anywhere, and later feeding it into a fragment would just be silently
	# dropped by `make olddefconfig` (exactly the 2026-08-06 regression).
	grep -rlq "NEBULAOS_BACKLIGHT_FINAL_CONTROLLER" "$KERNEL_DIR" 2>/dev/null
	check "backlight-final-controller Kconfig symbol defined in kernel tree" $?

	grep -rlq "TOUCHSCREEN_NS2009_FINAL_QUALIFICATION" "$KERNEL_DIR" 2>/dev/null
	check "touch-final-qualification Kconfig symbol defined in kernel tree" $?

	grep -rlq "PWM_INGENIC_V2_GET_STATE" "$KERNEL_DIR" 2>/dev/null
	check "pwm-state-readback Kconfig symbol defined in kernel tree" $?

	grep -rlq "FB_INGENIC_PAN_VSYNC_GATE" "$KERNEL_DIR" 2>/dev/null
	check "display-vsync (DISPLAY-V1) Kconfig symbol defined in kernel tree" $?

	[ -f "$KERNEL_DIR/kernel/kernel-6.6/module_drivers/drivers/misc/nebulaos_backlight_final_controller.c" ]
	check "nebulaos_backlight_final_controller.c driver file present" $?

	[ -f "$KERNEL_DIR/kernel/kernel-6.6/drivers/input/touchscreen/ns2009_final_qualification.c" ]
	check "ns2009_final_qualification.c driver file present" $?

	grep -q "nebulaos_backlight_final:" "$KERNEL_DIR/kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts" 2>/dev/null
	check "nebulaos_backlight_final DT node present" $?

	msc1_block=$(sed -n '/^&msc1 {/,/^};/p' "$KERNEL_DIR/kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts" 2>/dev/null)
	echo "$msc1_block" | grep -q 'cap-sd-highspeed;'
	check "W3 cap-sd-highspeed present in &msc1" $?
	echo "$msc1_block" | grep -q 'cap-sdio-irq;'
	check "W3 cap-sdio-irq present in &msc1" $?

	# The tracked Kconfig fragment should now (post apply-qualified-baseline.sh,
	# pre 02) carry every accepted variant's marker block.
	FRAGMENT="$ARTIFACT_DIR/halley5-nebulaos-fragment.config"
	grep -q "CONFIG_PREEMPT_RT=y" "$FRAGMENT" 2>/dev/null
	check "CONFIG_PREEMPT_RT=y present in tracked fragment" $?
	;;

post-build)
	echo "== Phase 2 post-build assertions (resolved artifacts) =="
	KCONFIG="$ARTIFACT_DIR/kernel.config"
	DTS="$ARTIFACT_DIR/halley5_v30.dts"

	[ -f "$KCONFIG" ] || { echo "FATAL: $KCONFIG not found - run 05-final-build.sh first" >&2; exit 1; }
	[ -f "$DTS" ] || { echo "FATAL: $DTS not found - run 05-final-build.sh first" >&2; exit 1; }

	grep -q "^CONFIG_PREEMPT_RT=y$" "$KCONFIG"
	check "CONFIG_PREEMPT_RT=y" $?

	grep -q "^CONFIG_HZ=100$" "$KCONFIG"
	check "CONFIG_HZ=100" $?

	grep -q "^CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER=y$" "$KCONFIG"
	check "CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER=y (qualified backlight/PWM controller)" $?

	grep -q "^CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION=y$" "$KCONFIG"
	check "CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION=y" $?

	grep -q "^CONFIG_TOUCHSCREEN_NS2009=y$" "$KCONFIG"
	check "CONFIG_TOUCHSCREEN_NS2009=y (base driver present - polling touch retained)" $?

	# Touch must remain polling-based: the OLDER, rejected IRQ-based
	# touch-irq-variant.sh/touch-qualification-variant.sh symbols must NOT
	# be present (would mean an unintended variant got mixed in).
	if grep -q "^CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION=y$" "$KCONFIG" 2>/dev/null; then
		echo "  FAIL: CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION=y present - unexpected IRQ-based touch variant, baseline should be poll-only"
		FAILED=1
	else
		echo "  PASS: CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION absent (touch remains polling-based)"
	fi

	grep -q "^CONFIG_PWM_INGENIC_V2_GET_STATE=y$" "$KCONFIG"
	check "CONFIG_PWM_INGENIC_V2_GET_STATE=y (PWM brightness readback)" $?

	grep -q "^CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y$" "$KCONFIG"
	check "CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y (DISPLAY-V1)" $?

	grep -q "nebulaos_backlight_final:" "$DTS"
	check "nebulaos_backlight_final DT node present in resolved DTS" $?

	msc1_block=$(sed -n '/^&msc1 {/,/^};/p' "$DTS")
	echo "$msc1_block" | grep -q 'cap-sd-highspeed;'
	check "W3 cap-sd-highspeed present in resolved &msc1" $?
	echo "$msc1_block" | grep -q 'cap-sdio-irq;'
	check "W3 cap-sdio-irq present in resolved &msc1" $?

	# Byte-for-byte proof against the pinned baseline tag's own tracked
	# copies - the strongest assertion available: not "does it look right",
	# but "is it identical to what was actually qualified".
	for f in kernel.config halley5_v30.dts buildroot.config; do
		if git -C "$REPO_ROOT" diff --quiet f9dc10f594cd7591e1146317cda877f75165934b -- "artifacts/buildroot-halley5-v30-image/$f" 2>/dev/null; then
			echo "  PASS: $f byte-identical to pinned baseline tag f9dc10f"
		else
			echo "  FAIL: $f differs from pinned baseline tag f9dc10f"
			FAILED=1
		fi
	done
	;;
*)
	echo "unknown mode '$MODE' - must be pre-build or post-build" >&2
	exit 1
	;;
esac

if [ "$FAILED" = "1" ]; then
	echo "== Phase 2 assertions: FAILED - refusing to proceed =="
	exit 1
fi
echo "== Phase 2 assertions: all PASSED =="
