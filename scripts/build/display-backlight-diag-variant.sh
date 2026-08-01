#!/bin/sh
# Applies the DISPLAY-B0-DIAG compile-only bounded backlight probe
# diagnostic (display hardware analysis mission follow-on, 2026-08-01+ -
# see docs/NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md,
# build-work/display-analysis/backlight-path-analysis.txt, and
# scripts/build/patches/display-backlight-probe-diag.patch) to the vendor
# kernel checkout, for a compile test only. NEVER apply this to a build
# destined for the active/production slot.
#
#   DIAG0 (default/today): no probe diagnostic driver, no DT node for it.
#       Identical to today's real baseline.
#   DIAG1 (prototype): applies scripts/build/patches/display-backlight-
#       probe-diag.patch (a new platform driver,
#       module_drivers/drivers/misc/nebulaos_backlight_probe_diag.c, plus
#       its Kconfig/Makefile wiring - all guarded by
#       #ifdef/depends-on CONFIG_NEBULAOS_BACKLIGHT_PROBE_DIAG so the
#       compiled tree is unaffected unless the option is also selected in
#       the Kconfig fragment, which THIS script does as a separate step),
#       selects CONFIG_NEBULAOS_BACKLIGHT_PROBE_DIAG=y in the tracked
#       Kconfig fragment, and adds a new DT node instantiating the
#       diagnostic driver against the two candidate hardware resources
#       (PWM channel 0 / pwm0_pc, and enable-gpios on candidate PC22) -
#       neither is proven correct, both are documented hypotheses only,
#       see backlight-path-analysis.txt.
#
#       This DTS edit repoints the existing &pwm node's pinctrl-0 from
#       the unused channel-1 pin to the real candidate channel-0 pin,
#       exactly like scripts/build/display-backlight-variant.sh's own S1
#       - the two scripts touch the same &pwm block in the same shared
#       DTS file and are NOT meant to be combined. Whichever variant
#       script runs last wins (each does a full `git checkout --` of the
#       DTS before editing) - this is the same tradeoff
#       display-backlight-variant.sh/wifi-sdio-variant.sh already make.
#
#       The diagnostic driver itself never touches PWM/GPIO state at
#       module bind time - it only records whatever state it can read at
#       that point (see the hardening-pass caveat below). Every probe is
#       opt-in via a bounded debugfs command interface (default 2s/max
#       3s timeout, longer rejected), arms the kernel-owned restore
#       watchdog BEFORE applying the one candidate hardware state, and
#       auto-restores via that workqueue timer regardless of whether an
#       explicit "restore" command ever arrives or the calling process
#       is still alive. See the driver's own file header comment for the
#       full safety-property list.
#
#       Hardening-pass honesty note (do not weaken/remove this): the
#       candidate enable-GPIO's recorded state IS a genuine hardware
#       readback (this board's gpio_chip .get callback reads the live
#       PxPIN register every time) and its restore is exact. The
#       candidate PWM channel's recorded "state" is NOT a hardware
#       readback - this board's bound PWM driver (pwm-ingenic-v2.c)
#       implements no .get_state callback, so the kernel's cached
#       pwm_device state for a channel nothing has ever requested before
#       is a synthetic disabled/zero value, not whatever the bootloader
#       actually left running. Its "restore" is a deliberate, documented
#       SAFE DEFAULT (disable the PWM), never claimed as an exact
#       reconstruction. See nebulaos_backlight_probe_diag.c's
#       "RESTORATION EXACTNESS" section and its debugfs
#       .../status pwm_restore_is_exact / gpio_restore_is_exact fields.
#
# Same "always reset to the real git-committed baseline first" pattern as
# the sibling variant scripts (display-vsync-variant.sh/
# touch-irq-variant.sh) - `git checkout --` on every affected file before
# deciding what DIAG0/DIAG1 needs, so repeated switches never drift or
# accumulate partial edits.
#
# IMPORTANT: never run this script while any build against this same
# vendor kernel checkout is in flight - a build's own source-tree
# fingerprint check (05-final-build.sh) will correctly refuse to trust
# artifacts built from a tree that changed mid-build. Apply the desired
# variant BEFORE starting a build, not during one.
#
# Usage: sh scripts/build/display-backlight-diag-variant.sh <DIAG0|DIAG1>

set -eu

VARIANT="${1:?usage: $0 <DIAG0|DIAG1>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
PATCH="$SCRIPT_DIR/patches/display-backlight-probe-diag.patch"
DTS_REL="kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts"
DTS="$KERNEL_DIR/$DTS_REL"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"
MARKER="$REPO_ROOT/build-work/display-backlight-diag-variant-applied.txt"

NEW_DRIVER_REL="kernel/kernel-6.6/module_drivers/drivers/misc/nebulaos_backlight_probe_diag.c"
AFFECTED_FILES="
kernel/kernel-6.6/module_drivers/drivers/misc/Kconfig
kernel/kernel-6.6/module_drivers/drivers/misc/Makefile
$NEW_DRIVER_REL
$DTS_REL
"

BEGIN_MARK="#--- NEBULAOS_BACKLIGHT_PROBE_DIAG_VARIANT_BEGIN ---"
END_MARK="#--- NEBULAOS_BACKLIGHT_PROBE_DIAG_VARIANT_END ---"

case "$VARIANT" in
	DIAG0|DIAG1) ;;
	*)
		echo "unknown variant '$VARIANT' - must be one of DIAG0 DIAG1" >&2
		exit 1
		;;
esac

[ -f "$PATCH" ] || {
	echo "FATAL: $PATCH not found" >&2
	exit 1
}
[ -f "$DTS" ] || {
	echo "FATAL: $DTS not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
}
[ -f "$FRAGMENT" ] || {
	echo "FATAL: $FRAGMENT not found" >&2
	exit 1
}

# Always reset the affected files to their real, git-committed baseline
# first - never trust that a previous invocation (or another variant
# script's edits to the same shared DTS) was cleanly undone. The new
# driver file is untracked when absent, so `git checkout --` on it alone
# would fail with "did not match any files" - remove it directly instead,
# then let a fresh `git apply` recreate it if DIAG1 was requested.
git -C "$KERNEL_DIR" checkout -- \
	kernel/kernel-6.6/module_drivers/drivers/misc/Kconfig \
	kernel/kernel-6.6/module_drivers/drivers/misc/Makefile \
	"$DTS_REL"
rm -f "$KERNEL_DIR/$NEW_DRIVER_REL"

if ! grep -q '^&pwm {' "$DTS"; then
	echo "FATAL: could not find the &pwm node in $DTS - has the board DTS changed?" >&2
	exit 1
fi

# Strip any previously-applied fragment block first, unconditionally -
# same idempotent pattern as preempt-variant.sh/display-vsync-variant.sh.
# Marker text here has no BRE-special characters, so a direct address is
# safe as-is.
if grep -qF "$BEGIN_MARK" "$FRAGMENT"; then
	sed -i "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/d" "$FRAGMENT"
fi

if [ "$VARIANT" = "DIAG1" ]; then
	( cd "$KERNEL_DIR" && git apply "$PATCH" )

	# Repoint the existing &pwm node from the unused channel-1 pin to
	# the real candidate backlight channel-0 pin - same repointing
	# display-backlight-variant.sh's S1 already does, since both need
	# the same physical PWM channel actually pin-muxed to be usable.
	sed -i 's/pinctrl-0 = <&pwm1_pc>;/pinctrl-0 = <\&pwm0_pc>;/' "$DTS"

	{
		echo ""
		echo "/* Display hardware analysis mission follow-on (2026-08-01+) -"
		echo " * DISPLAY-B0-DIAG bounded backlight probe diagnostic. Candidate"
		echo " * PWM channel 0 (pwm0_pc, 20000ns/50kHz) and candidate enable-gpios"
		echo " * PC22 (stock's own pwm_backlight.sh power_gpio) - neither is"
		echo " * proven correct, both are documented hypotheses only, see"
		echo " * backlight-path-analysis.txt. This diagnostic exists specifically"
		echo " * to let a human resolve that question safely, through a bounded,"
		echo " * self-restoring debugfs command interface. NEVER enable this on a"
		echo " * production/active-slot build - see"
		echo " * scripts/build/display-backlight-diag-variant.sh. */"
		echo "/ {"
		echo "	nebulaos_backlight_diag: nebulaos_backlight_diag {"
		echo "		compatible = \"nebulaos,backlight-probe-diag\";"
		echo "		pwms = <&pwm 0 20000>;"
		echo "		enable-gpios = <&gpc 22 GPIO_ACTIVE_HIGH INGENIC_GPIO_NOBIAS>;"
		echo "		status = \"okay\";"
		echo "	};"
		echo "};"
	} >> "$DTS"

	{
		echo "$BEGIN_MARK"
		echo "# Display hardware analysis mission follow-on (2026-08-01+) -"
		echo "# DISPLAY-B0-DIAG bounded backlight probe diagnostic variant."
		echo "CONFIG_NEBULAOS_BACKLIGHT_PROBE_DIAG=y"
		echo "$END_MARK"
	} >> "$FRAGMENT"
fi

mkdir -p "$(dirname "$MARKER")"
printf '%s\n' "$VARIANT" > "$MARKER"
echo "== display-backlight-diag-variant: $VARIANT applied =="
