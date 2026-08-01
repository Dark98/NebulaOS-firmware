#!/bin/sh
# Applies the TOUCH-I1 compile-only IRQ-assisted touch-down prototype
# (powered-on display/touch investigation mission, 2026-08-01 - see
# docs/NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md and
# build-work/display-analysis/touch-path-analysis.txt for the baseline this
# builds on: NS2009 pen-down detection is purely 30ms-polled today, despite
# stock's own separate closed driver proving GPIO79/GPIOC15 can generate a
# real interrupt).
#
#   I0 (default/today): baseline ns2009.c, pure 30ms polling only.
#   I1 (prototype): applies scripts/build/patches/touch-irq-gate.patch to
#       the vendor kernel checkout (Kconfig option + struct fields + a
#       threaded IRQ handler + a best-effort probe-time IRQ request, all
#       guarded by #ifdef CONFIG_TOUCHSCREEN_NS2009_PENDOWN_IRQ so the
#       compiled code is byte-for-byte identical to I0 unless the option is
#       also selected in the Kconfig fragment - which THIS script does as
#       its second step), and selects
#       CONFIG_TOUCHSCREEN_NS2009_PENDOWN_IRQ=y in the tracked Kconfig
#       fragment.
#
#       The existing 30ms poll remains ALWAYS ACTIVE and unmodified under
#       I1 - the IRQ is purely an additive latency accelerant (requests
#       BOTH edges on pendown-gpios, since the true active-high/low and
#       edge-direction semantics were never established from source alone;
#       any transition just triggers an immediate out-of-band touch report
#       via the same ns2009_ts_report() the poll already calls - actual
#       down/up state still comes from a fresh GPIO level read inside that
#       function, never from which edge fired). Includes storm protection
#       (permanently disables the IRQ and falls back to poll-only if the
#       pin toggles abnormally often) and a graceful no-op if the IRQ can't
#       be requested at all. Input availability never depends on this path
#       succeeding.
#
# Same "always reset to the real git-committed baseline first" pattern as
# the sibling variant scripts.
#
# IMPORTANT: never run this script while any build against this same vendor
# kernel checkout is in flight - see the equivalent warning in
# display-vsync-variant.sh (this project hit this exact mistake twice while
# preparing these prototypes; both mid-build edits triggered
# 05-final-build.sh's own source-tree fingerprint abort, correctly refusing
# to trust the resulting artifacts).
#
# Usage: sh scripts/build/touch-irq-variant.sh <I0|I1>

set -eu

VARIANT="${1:?usage: $0 <I0|I1>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
PATCH="$SCRIPT_DIR/patches/touch-irq-gate.patch"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"
MARKER="$REPO_ROOT/build-work/touch-irq-variant-applied.txt"

AFFECTED_FILES="
kernel/kernel-6.6/drivers/input/touchscreen/Kconfig
kernel/kernel-6.6/drivers/input/touchscreen/ns2009.c
"

BEGIN_MARK="#--- NEBULAOS_TOUCH_IRQ_GATE_VARIANT_BEGIN ---"
END_MARK="#--- NEBULAOS_TOUCH_IRQ_GATE_VARIANT_END ---"

case "$VARIANT" in
	I0|I1) ;;
	*)
		echo "unknown variant '$VARIANT' - must be one of I0 I1" >&2
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

git -C "$KERNEL_DIR" checkout -- $AFFECTED_FILES

if grep -qF "$BEGIN_MARK" "$FRAGMENT"; then
	sed -i "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/d" "$FRAGMENT"
fi

if [ "$VARIANT" = "I1" ]; then
	( cd "$KERNEL_DIR" && git apply "$PATCH" )
	{
		echo "$BEGIN_MARK"
		echo "# Display/touch investigation mission (2026-08-01) - TOUCH-I1"
		echo "# IRQ-assisted touch-down qualification variant."
		echo "CONFIG_TOUCHSCREEN_NS2009_PENDOWN_IRQ=y"
		echo "$END_MARK"
	} >> "$FRAGMENT"
fi

mkdir -p "$(dirname "$MARKER")"
printf '%s\n' "$VARIANT" > "$MARKER"
echo "== touch-irq-variant: $VARIANT applied =="
