#!/bin/sh
# Applies the TOUCH-D0-DIAG compile-only read-only touch GPIO
# characterization diagnostic (display/touch investigation mission
# follow-on, 2026-08-01+ - see
# build-work/display-analysis/touch-path-analysis.txt and
# scripts/build/patches/touch-poll-diag-gate.patch) to the vendor kernel
# checkout, for a compile test only.
#
#   D0 (default/today): baseline ns2009.c, no diagnostic counters.
#   D1 (prototype): applies scripts/build/patches/touch-poll-diag-gate.patch
#       (Kconfig option + struct fields + read-only diagnostic hooks, all
#       guarded by #ifdef CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG so the
#       compiled code is byte-for-byte identical to D0 unless the option
#       is also selected in the Kconfig fragment - which THIS script does
#       as its second step), and selects
#       CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG=y in the tracked Kconfig
#       fragment.
#
#       D1 characterizes the existing pendown-gpios 30ms polling path
#       with ZERO behavior change - it does not alter the poll interval,
#       coordinate reads, calibration, filtering, or input event
#       reporting in any way. It only adds in-memory-only diagnostic
#       counters (debugfs), updated at the exact same call sites the
#       existing code already has (the poll tick, the touch-down
#       transition, the release transition) - never logged per-poll to
#       the kernel log, never influencing any existing decision.
#
# Same "always reset to the real git-committed baseline first" pattern as
# the sibling variant scripts (display-vsync-variant.sh/
# touch-irq-variant.sh). This script and touch-irq-variant.sh/
# touch-i0-diag-variant.sh all touch the same two files
# (Kconfig/ns2009.c) via a full git-checkout-first reset - they are
# mutually exclusive, one-at-a-time variants, not meant to be combined;
# whichever script runs last wins, same tradeoff those sibling scripts
# already make.
#
# IMPORTANT: never run this script while any build against this same
# vendor kernel checkout is in flight - see the equivalent warning in
# touch-irq-variant.sh.
#
# Usage: sh scripts/build/touch-d0-diag-variant.sh <D0|D1>

set -eu

VARIANT="${1:?usage: $0 <D0|D1>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
PATCH="$SCRIPT_DIR/patches/touch-poll-diag-gate.patch"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"
MARKER="$REPO_ROOT/build-work/touch-d0-diag-variant-applied.txt"

AFFECTED_FILES="
kernel/kernel-6.6/drivers/input/touchscreen/Kconfig
kernel/kernel-6.6/drivers/input/touchscreen/ns2009.c
"

BEGIN_MARK="#--- NEBULAOS_TOUCH_POLL_DIAG_VARIANT_BEGIN ---"
END_MARK="#--- NEBULAOS_TOUCH_POLL_DIAG_VARIANT_END ---"

case "$VARIANT" in
	D0|D1) ;;
	*)
		echo "unknown variant '$VARIANT' - must be one of D0 D1" >&2
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

if [ "$VARIANT" = "D1" ]; then
	( cd "$KERNEL_DIR" && git apply "$PATCH" )
	{
		echo "$BEGIN_MARK"
		echo "# Display/touch investigation mission follow-on (2026-08-01+) -"
		echo "# TOUCH-D0-DIAG read-only poll diagnostic variant."
		echo "CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG=y"
		echo "$END_MARK"
	} >> "$FRAGMENT"
fi

mkdir -p "$(dirname "$MARKER")"
printf '%s\n' "$VARIANT" > "$MARKER"
echo "== touch-d0-diag-variant: $VARIANT applied =="
