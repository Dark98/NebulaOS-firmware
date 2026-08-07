#!/bin/sh
# Applies the DISPLAY-B1 compile-only backlight-class prototype (display
# hardware analysis mission, 2026-08-01 - see
# docs/NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md and
# build-work/display-analysis/backlight-path-analysis.txt) to the vendor
# kernel's tracked DTS, for a compile test only. NEVER apply this to a build
# destined for the active/production slot - see the live qualification plan
# (docs/NEBULAOS_DISPLAY_LIVE_QUALIFICATION_PLAN.md, test HT-01/HT-09) for
# why the real electrical behavior of GPC-0/GPC-22 must be confirmed on a
# spare slot first.
#
#   S0 (default/today): no backlight DT node exists at all. CONFIG_BACKLIGHT_
#       CLASS_DEVICE/PWM/GPIO are already =y (unrelated to this script,
#       already true in the base defconfig) but nothing in the compiled DTS
#       consumes them - PROVEN_FROM_SOURCE, see backlight-path-analysis.txt.
#   S1 (prototype): adds a real "pwm-backlight" DT node, and repoints the
#       existing &pwm override from the currently-unused GPC-1/channel1 pin
#       (pinctrl-0 = <&pwm1_pc>, zero consumers anywhere) to GPC-0/channel0
#       (pwm0_pc) - the pin stock's own live GPIO dump labels
#       "backlight_pwm0" and stock's own pwm_backlight.sh script drives at
#       50kHz. GPC-0 is confirmed free on this board: the only other claim
#       on it (the first &msc2 override's ingenic,sdr-gpio property) is
#       itself overridden to status="disabled" later in the same file (see
#       the file's own OpenKE 2026-07-23 comment on this exact conflict).
#       This DOES NOT wire a power-enable GPIO (PC22, stock's separate
#       enable line) - that pin's real function is still UNKNOWN_UNTIL_
#       HARDWARE per backlight-path-analysis.txt, so S1 intentionally only
#       adds the PWM brightness path, not an assumed enable-line.
#
# Follow-up correction (powered-on investigation mission, 2026-08-01): the
# original version of this script used a sed marker-strip-then-append
# approach and had two real bugs - unescaped "/* */" BRE metacharacters
# breaking idempotency, and a residual trailing blank line left behind after
# reverting to S0 (invisible to this script's own git-clean check, because
# that check ran `git status` in the OUTER repo, which ignores the whole
# vendor/ tree entirely via .gitignore - a second real bug, since it made
# the "clean revert" test vacuously pass regardless of actual file content).
# Rewritten to match the established, more robust pattern already proven in
# the sibling scripts/build/wifi-sdio-variant.sh: always reset to the real
# git-committed baseline first (`git checkout` inside the vendor tree, not a
# sed-based revert), then apply the requested variant fresh. This eliminates
# the whole class of escaping/residue bugs, since every invocation starts
# from a known-clean state instead of trying to undo a previous edit.
#
# Usage: sh scripts/build/display-backlight-variant.sh <S0|S1>

set -eu

VARIANT="${1:?usage: $0 <S0|S1>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
DTS_REL="kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts"
DTS="$KERNEL_DIR/$DTS_REL"
MARKER="$REPO_ROOT/build-work/display-backlight-variant-applied.txt"

case "$VARIANT" in
	S0|S1) ;;
	*)
		echo "unknown variant '$VARIANT' - must be one of S0 S1" >&2
		exit 1
		;;
esac

[ -f "$DTS" ] || {
	echo "FATAL: $DTS not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
}

# 2026-08-07 baseline-repair mission: this DISPLAY-B1 prototype is
# EXPLICITLY marked above as never for a production/active-slot build (its
# real backlight enable-line electrical behavior was still
# UNKNOWN_UNTIL_HARDWARE when written), and it has since been fully
# superseded by backlight-final-controller-variant.sh's FINAL1, which IS
# part of the accepted baseline apply-qualified-baseline.sh composes. A
# blanket `git checkout -- "$DTS_REL"` right below would silently wipe
# FINAL1's marked DT node with zero error - refuse instead of risking that.
if grep -qF "NEBULAOS_BACKLIGHT_FINAL_CONTROLLER_VARIANT_DTS_BEGIN" "$DTS" 2>/dev/null; then
	echo "FATAL: $DTS already carries backlight-final-controller-variant.sh's accepted FINAL1 state." >&2
	echo "This script (DISPLAY-B1, a superseded compile-only prototype) would silently discard it." >&2
	echo "Refusing to run. If you genuinely need DISPLAY-B1 again, start from a pristine checkout" >&2
	echo "(00-fetch-vendor-sources.sh only, no apply-qualified-baseline.sh), not this one." >&2
	exit 1
fi

# Always reset to the real, git-committed baseline first - never trust that
# a previous invocation's edits were cleanly undone. This does discard any
# other uncommitted change to this file, which is exactly why the guard
# above exists: this script is no longer the only thing editing this file
# outside of a reviewed commit now that FINAL1 is a real, accepted variant.
git -C "$KERNEL_DIR" checkout -- "$DTS_REL"

if ! grep -q '^&pwm {' "$DTS"; then
	echo "FATAL: could not find the &pwm node in $DTS - has the board DTS changed?" >&2
	exit 1
fi

if [ "$VARIANT" = "S1" ]; then
	# Repoint the existing &pwm node from the unused channel-1 pin to the
	# real backlight channel-0 pin.
	sed -i 's/pinctrl-0 = <&pwm1_pc>;/pinctrl-0 = <\&pwm0_pc>;/' "$DTS"

	{
		echo ""
		echo "/* Display hardware analysis mission (2026-08-01) - DISPLAY-B1"
		echo " * compile-only backlight-class prototype. Period 20000ns (50kHz,"
		echo " * matching stock's pwm_backlight.sh pwm_freq=50000). Brightness"
		echo " * table is a starting point ONLY - real dimming curve is"
		echo " * UNKNOWN_UNTIL_HARDWARE, see hardware-test-matrix.tsv HT-01/HT-09."
		echo " * NEVER enable this on a production/active-slot build without"
		echo " * first confirming GPC-0/GPC-22 electrical behavior live. */"
		echo "/ {"
		echo "	nebulaos_backlight: nebulaos_backlight {"
		echo "		compatible = \"pwm-backlight\";"
		echo "		pwms = <&pwm 0 20000>;"
		echo "		brightness-levels = <0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15>;"
		echo "		default-brightness-level = <8>;"
		echo "	};"
		echo "};"
	} >> "$DTS"
fi

mkdir -p "$(dirname "$MARKER")"
printf '%s\n' "$VARIANT" > "$MARKER"
echo "== display-backlight-variant: $VARIANT applied to $DTS =="
