#!/bin/sh
# Applies the DISPLAY-P1 compile-only backlight-class prototype (display
# hardware analysis mission, 2026-08-01 - see
# docs/NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md and
# build-work/display-analysis/backlight-path-analysis.txt) to the tracked
# vendor DTS, for a compile test only. NEVER apply this to a build destined
# for the active/production slot - see the live qualification plan
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
# Idempotent, same pattern as preempt-variant.sh/wifi-sdio-variant.sh: always
# strips any previously-applied S1 block first, then re-adds it only if S1
# was requested.
#
# Usage: sh scripts/build/display-backlight-variant.sh <S0|S1>

set -eu

VARIANT="${1:?usage: $0 <S0|S1>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
DTS="$REPO_ROOT/vendor/x2000_kernel_6.6/kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts"
MARKER="$REPO_ROOT/build-work/display-backlight-variant-applied.txt"

BEGIN_MARK="/* --- NEBULAOS_DISPLAY_BACKLIGHT_VARIANT_BEGIN --- */"
END_MARK="/* --- NEBULAOS_DISPLAY_BACKLIGHT_VARIANT_END --- */"
# BEGIN_MARK/END_MARK contain "*" and "/" (C-comment syntax), both BRE
# metacharacters - used verbatim as a sed address they would not match the
# literal text (an unescaped "*" means "zero or more of the preceding atom",
# not a literal star), so the strip-previous-block step below would silently
# match nothing and every re-application would append a duplicate block.
# Escape every BRE-special character before using either string as a sed
# address pattern; grep -qF (used only for cheap presence detection) is
# unaffected either way since -F already treats its argument as a fixed
# string.
escape_for_sed() {
	printf '%s' "$1" | sed 's/[.[\*^$/]/\\&/g'
}
BEGIN_MARK_RE=$(escape_for_sed "$BEGIN_MARK")
END_MARK_RE=$(escape_for_sed "$END_MARK")

case "$VARIANT" in
	S0|S1) ;;
	*)
		echo "unknown variant '$VARIANT' - must be one of S0 S1" >&2
		exit 1
		;;
esac

[ -f "$DTS" ] || {
	echo "FATAL: $DTS not found" >&2
	exit 1
}

# Strip any previously-applied S1 block first, unconditionally - the one
# safe way to guarantee idempotence regardless of which variant was applied
# last. Markers are plain text with no regex-special characters, so a direct
# /pattern/,/pattern/d range delete is safe as-is.
if grep -qF "$BEGIN_MARK" "$DTS"; then
	sed -i "\@^${BEGIN_MARK_RE}\$@,\@^${END_MARK_RE}\$@d" "$DTS"
fi
# Also revert any previously-applied pwm1_pc->pwm0_pc repoint, unconditionally,
# before deciding what S1 needs - so re-running S0 after S1 is a clean revert.
sed -i 's/pinctrl-0 = <&pwm0_pc>; \/\* NEBULAOS_DISPLAY_BACKLIGHT_VARIANT pwm repoint \*\//pinctrl-0 = <\&pwm1_pc>;/' "$DTS"

if [ "$VARIANT" = "S1" ]; then
	# Repoint the existing &pwm node from the unused channel1 pin to the
	# real backlight channel0 pin.
	sed -i 's/pinctrl-0 = <&pwm1_pc>;/pinctrl-0 = <\&pwm0_pc>; \/* NEBULAOS_DISPLAY_BACKLIGHT_VARIANT pwm repoint *\//' "$DTS"

	{
		echo ""
		echo "$BEGIN_MARK"
		echo "/* Display hardware analysis mission (2026-08-01) - DISPLAY-P1"
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
		echo "$END_MARK"
	} >> "$DTS"
fi

mkdir -p "$(dirname "$MARKER")"
printf '%s\n' "$VARIANT" > "$MARKER"
echo "== display-backlight-variant: $VARIANT applied to $DTS =="
