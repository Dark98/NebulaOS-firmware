#!/bin/sh
# Applies the TOUCH-QUALIFICATION unified poll/IRQ-observe/IRQ-assist
# runtime-selectable diagnostic (display/touch investigation mission
# unification, 2026-08-01+ - see
# scripts/build/patches/touch-qualification-unified.patch) to the vendor
# kernel checkout, for a compile test only.
#
# THIS IS THE ONLY SCRIPT ALLOWED TO TOUCH
#   kernel/kernel-6.6/drivers/input/touchscreen/Kconfig
#   kernel/kernel-6.6/drivers/input/touchscreen/ns2009.c
# FROM NOW ON.
#
# Background: three earlier, separate scripts (touch-d0-diag-variant.sh,
# touch-i0-diag-variant.sh, and the older touch-irq-variant.sh) all did a
# full `git checkout --` of these same two files as their own "off" step,
# then applied their own single patch. Because all three targeted the
# identical two files, applying one and then reverting a *different* one
# silently discarded the first one's patch too - including its Kconfig
# option's own definition - with ZERO error anywhere in the build
# (Buildroot's Kconfig fragment merge silently drops now-unknown symbols
# rather than failing). This already caused one real, silent,
# feature-missing package earlier in this project.
#
# TOUCH-QUALIFICATION retires that entire failure mode: it subsumes both
# TOUCH-D0-DIAG's read-only poll counters and TOUCH-I0-DIAG's IRQ
# observation in ONE Kconfig symbol
# (CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION) and ONE unified driver, plus a
# new runtime-selectable irq-assist mode, so there is only ever one patch,
# one toggle script, and one set of tests governing these two files from
# here on. touch-d0-diag-variant.sh, touch-i0-diag-variant.sh, and
# touch-irq-variant.sh are now DEPRECATED (see the header comment added to
# each) - do not run any of them against this checkout, and never compose
# any of them with this script.
#
#   QUAL0 (default/today): baseline ns2009.c, no qualification feature.
#   QUAL1 (prototype): applies
#       scripts/build/patches/touch-qualification-unified.patch (Kconfig
#       option + struct fields + a runtime mode switch exposed via
#       debugfs, all guarded by #ifdef
#       CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION so the compiled code is
#       byte-for-byte identical to QUAL0 unless the option is also
#       selected in the Kconfig fragment - which THIS script does as its
#       second step), and selects
#       CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION=y in the tracked Kconfig
#       fragment.
#
#       The feature always boots into poll-only mode (byte-for-byte
#       identical to the original, unmodified 30ms poll path - no GPIO IRQ
#       requested). Two further runtime modes are selectable via
#       /sys/kernel/debug/ns2009_qualification/mode ("irq-observe",
#       "irq-assist") - see the patch/Kconfig help text for the full
#       design and fail-safe behavior of each.
#
# IMPORTANT: never run this script while any build against this same
# vendor kernel checkout is in flight - see the equivalent warning in the
# other touch-*-variant.sh scripts.
#
# Usage: sh scripts/build/touch-qualification-variant.sh <QUAL0|QUAL1>

set -eu

VARIANT="${1:?usage: $0 <QUAL0|QUAL1>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
PATCH="$SCRIPT_DIR/patches/touch-qualification-unified.patch"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"
MARKER="$REPO_ROOT/build-work/touch-qualification-variant-applied.txt"

AFFECTED_FILES="
kernel/kernel-6.6/drivers/input/touchscreen/Kconfig
kernel/kernel-6.6/drivers/input/touchscreen/ns2009.c
"

BEGIN_MARK="#--- NEBULAOS_TOUCH_QUALIFICATION_VARIANT_BEGIN ---"
END_MARK="#--- NEBULAOS_TOUCH_QUALIFICATION_VARIANT_END ---"

case "$VARIANT" in
	QUAL0|QUAL1) ;;
	*)
		echo "unknown variant '$VARIANT' - must be one of QUAL0 QUAL1" >&2
		exit 1
		;;
esac

[ -f "$PATCH" ] || {
	echo "FATAL: $PATCH not found" >&2
	exit 1
}
[ -f "$FRAGMENT" ] || {
	echo "FATAL: $FRAGMENT not found" >&2
	exit 1
}

# 2026-08-07 baseline-repair mission: this script's own header already
# documents QUAL0 as the accepted state and warns not to compose it with
# the other three deprecated touch-*-diag/-irq scripts - but it did not
# guard against the one composition that actually matters now:
# touch-final-qualification-variant.sh's FINALQUAL1, which IS part of the
# accepted baseline apply-qualified-baseline.sh composes. The blanket
# checkout below would silently wipe FINALQUAL1's Kconfig symbol and
# ns2009.c changes with zero error - refuse instead.
if grep -qF "config TOUCHSCREEN_NS2009_FINAL_QUALIFICATION" \
	"$KERNEL_DIR/kernel/kernel-6.6/drivers/input/touchscreen/Kconfig" 2>/dev/null; then
	echo "FATAL: touch-final-qualification-variant.sh's accepted FINALQUAL1 state is already applied." >&2
	echo "This script (a superseded prototype) would silently discard it. Refusing to run." >&2
	echo "Start from a pristine checkout (00-fetch-vendor-sources.sh only) if you genuinely need QUAL1." >&2
	exit 1
fi

git -C "$KERNEL_DIR" checkout -- $AFFECTED_FILES

if grep -qF "$BEGIN_MARK" "$FRAGMENT"; then
	sed -i "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/d" "$FRAGMENT"
fi

if [ "$VARIANT" = "QUAL1" ]; then
	( cd "$KERNEL_DIR" && git apply "$PATCH" )
	{
		echo "$BEGIN_MARK"
		echo "# Display/touch investigation mission unification (2026-08-01+) -"
		echo "# TOUCH-QUALIFICATION unified poll/irq-observe/irq-assist variant."
		echo "CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION=y"
		echo "$END_MARK"
	} >> "$FRAGMENT"
fi

mkdir -p "$(dirname "$MARKER")"
printf '%s\n' "$VARIANT" > "$MARKER"
echo "== touch-qualification-variant: $VARIANT applied =="
