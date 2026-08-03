#!/bin/sh
# Applies the pinctrl-ingenic.c ownership-tracking fix (NebulaOS Pinctrl
# Cleanup Mission, 2026-08-03 - see
# scripts/build/patches/pinctrl-ownership-fix.patch) to the vendor kernel
# checkout.
#
# THIS IS THE ONLY SCRIPT ALLOWED TO TOUCH
#   kernel/kernel-6.6/module_drivers/drivers/pinctrl/pinctrl-ingenic.c
#   kernel/kernel-6.6/module_drivers/drivers/pinctrl/pinctrl-ingenic.h
# FROM NOW ON - same overlapping-variant-script discipline as the other
# *-variant.sh scripts (see touch-qualification-variant.sh's own header
# for the real, silent-data-loss bug class this convention prevents
# project-wide).
#
# Background (Display Baseline Closeout Mission): pinctrl-ingenic.c's
# .dt_node_to_map callback (ingenic_dt_node_to_map()) unconditionally
# OR'd every pinctrl group's pin bitmap into used_pins_bitmap while
# building a pinctrl_map - which happens for EVERY pinctrl-N property a
# device declares, whether or not that state is ever actually selected.
# This conflated "a map was parsed" with "this pin is actively claimed":
# a device declaring a deliberately-never-auto-selected named alternate
# state (e.g. nebulaos_backlight_final's own "pwm-active", chosen
# specifically to avoid pinctrl_bind_pins()'s automatic "default"/"init"
# selection - see backlight-final-controller-variant.sh) got that state's
# pin silently pre-marked used at probe time. The SAME pin's genuine
# first-ever runtime claim (a real gpiod_get()) then found the bit
# already set and logged a false "gpio functions has redefinition"
# warning + call trace - live-reproduced during this mission's own
# acceptance testing (4 occurrences, all during ordinary S97-triggered
# and touch-wake-driven safe-on/pwm-active/sleep transitions), even
# though nothing ever actually held the pin concurrently and every
# operation succeeded regardless.
#
# Fix: remove the bitmap marking from map-parse time entirely. Real
# ownership is now tracked only at the two genuine runtime claim points -
# ingenic_gpio_request()/ingenic_gpio_free() for GPIO (unchanged,
# already-correct symmetric pair), and a NEW, separate
# pinmux_used_bitmap field, checked-and-set in ingenic_pinmux_enable()
# (the real .set_mux activation, only called on an actual
# pinctrl_select_state()) for pinmux ownership. A live GPIO request for a
# pin currently marked pinmux-active is treated as a legitimate hand-off
# (exactly the pinctrl_put() -> gpiod_get() sequence
# nebulaos_backlight_final_controller.c uses to leave PWM-active mode)
# and silently clears the pinmux-side mark rather than warning; two
# genuinely simultaneous, unreleased claims of the SAME kind (two live
# GPIO requests, or two live pinmux activations, on the same pin without
# an intervening release) still warn exactly as before. Nothing here is
# specific to GPC0, the backlight driver, or any other NebulaOS-added
# code - this is a generic pinctrl-ingenic.c correctness fix that would
# apply to any driver on this SoC using the same
# named-non-default-alternate-state pattern.
#
# FIX0 (default/pristine): baseline pinctrl-ingenic.c/.h, unmodified -
#     the false-positive warning is reproducible.
# FIX1: applies scripts/build/patches/pinctrl-ownership-fix.patch.
#     Unconditional C code change (no new Kconfig option - this is a
#     correctness fix, not an experimental/toggleable feature; FIX0/FIX1
#     naming kept only for consistency with this project's other variant
#     scripts and to let the regression suite compile/compare both
#     states).
#
# Same "always reset to the real git-committed baseline first" pattern as
# the sibling variant scripts - `git checkout --` on every affected file
# before deciding what FIX0/FIX1 needs, so repeated switches never drift
# or accumulate partial edits.
#
# IMPORTANT: never run this script while any build against this same
# vendor kernel checkout is in flight - see the equivalent warning in the
# other *-variant.sh scripts (05-final-build.sh's source-tree fingerprint
# check will correctly refuse to trust artifacts built from a tree that
# changed mid-build).
#
# Usage: sh scripts/build/pinctrl-ownership-fix-variant.sh <FIX0|FIX1>

set -eu

VARIANT="${1:?usage: $0 <FIX0|FIX1>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
PATCH="$SCRIPT_DIR/patches/pinctrl-ownership-fix.patch"
MARKER="$REPO_ROOT/build-work/pinctrl-ownership-fix-variant-applied.txt"

AFFECTED_FILES="
kernel/kernel-6.6/module_drivers/drivers/pinctrl/pinctrl-ingenic.c
kernel/kernel-6.6/module_drivers/drivers/pinctrl/pinctrl-ingenic.h
"

case "$VARIANT" in
	FIX0|FIX1) ;;
	*)
		echo "unknown variant '$VARIANT' - must be one of FIX0 FIX1" >&2
		exit 1
		;;
esac

[ -f "$PATCH" ] || {
	echo "FATAL: $PATCH not found" >&2
	exit 1
}

git -C "$KERNEL_DIR" checkout -- $AFFECTED_FILES

if [ "$VARIANT" = "FIX1" ]; then
	( cd "$KERNEL_DIR" && git apply "$PATCH" )
fi

mkdir -p "$(dirname "$MARKER")"
printf '%s\n' "$VARIANT" > "$MARKER"
echo "== pinctrl-ownership-fix-variant: $VARIANT applied =="
