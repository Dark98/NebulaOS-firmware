#!/bin/sh
# *** DEPRECATED (2026-08-01+) - DO NOT RUN AGAINST A CURRENT CHECKOUT ***
# Superseded by scripts/build/touch-qualification-variant.sh
# (CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION), which subsumes this variant's
# IRQ-observation-only diagnostic as its runtime "irq-observe" mode, plus
# TOUCH-D0-DIAG's read-only poll counters and a new irq-assist mode, all
# behind ONE Kconfig symbol.
#
# Kept only for project-history/test reference - DO NOT run this script
# against the vendor kernel checkout, and NEVER compose it with
# touch-qualification-variant.sh, touch-d0-diag-variant.sh, or
# touch-irq-variant.sh in the same build. All four scripts do a full
# `git checkout --` of the exact same two files
# (kernel/kernel-6.6/drivers/input/touchscreen/{Kconfig,ns2009.c}) as their
# own "off" step - applying one and then reverting a DIFFERENT one silently
# discards the first one's patch too, including its Kconfig option's own
# definition, with ZERO error anywhere in the build (this is the precise
# failure mode touch-qualification-variant.sh exists to retire - see its
# own header comment for the full incident history).
#
# Original header follows, describing this now-superseded variant:
#
# Applies the TOUCH-I0-DIAG compile-only IRQ observation diagnostic
# (display/touch investigation mission follow-on, 2026-08-01+ - see
# build-work/display-analysis/touch-path-analysis.txt and
# scripts/build/patches/touch-irq-diag-gate.patch) to the vendor kernel
# checkout, for a compile test only.
#
# This is a DIAGNOSTIC-ONLY variant, distinct from the existing, separate
# TOUCH-I1 production-latency prototype (scripts/build/touch-irq-variant.sh,
# CONFIG_TOUCHSCREEN_NS2009_PENDOWN_IRQ) - it exists purely to observe
# whether GPIO79/pendown-gpios can generate usable IRQ events at all, not
# to accelerate touch-reporting latency. Deliberately uses non-colliding
# variant names (IRQDIAG0/IRQDIAG1, not I0/I1) so it can never be
# confused with touch-irq-variant.sh's own I0/I1 on the command line.
#
#   IRQDIAG0 (default/today): baseline ns2009.c, no diagnostic IRQ.
#   IRQDIAG1 (prototype): applies scripts/build/patches/touch-irq-diag-gate.patch
#       (Kconfig option + struct fields + a threaded, counters-only IRQ
#       handler + a best-effort probe-time IRQ request, all guarded by
#       #ifdef CONFIG_TOUCHSCREEN_NS2009_IRQ_DIAG so the compiled code is
#       byte-for-byte identical to IRQDIAG0 unless the option is also
#       selected in the Kconfig fragment - which THIS script does as its
#       second step), and selects CONFIG_TOUCHSCREEN_NS2009_IRQ_DIAG=y in
#       the tracked Kconfig fragment.
#
#       The existing 30ms poll remains ALWAYS ACTIVE and unmodified under
#       IRQDIAG1 - this patch does not touch ns2009_ts_poll()/
#       ns2009_ts_report() at all. The diagnostic IRQ handler does ZERO
#       I2C transfers and ZERO coordinate processing - it never calls
#       ns2009_ts_report() or any I2C function, only updates in-memory
#       counters (event count, best-effort rising/falling classification,
#       events-while-touched/untouched, min/max IRQ interval). Requests a
#       temporary both-edges trigger purely to observe whether IRQs
#       arrive at all - this is NOT the final production trigger
#       polarity, which remains genuinely unproven. Includes the same
#       storm protection shape as touch-irq-variant.sh's I1 (permanent
#       fallback to poll-only-for-diagnostics on trip; the poll used for
#       actual touch reporting is never affected either way).
#
# Same "always reset to the real git-committed baseline first" pattern as
# the sibling variant scripts. This script and touch-irq-variant.sh/
# touch-d0-diag-variant.sh all touch the same two files
# (Kconfig/ns2009.c) via a full git-checkout-first reset - they are
# mutually exclusive, one-at-a-time variants, not meant to be combined;
# whichever script runs last wins, same tradeoff those sibling scripts
# already make.
#
# IMPORTANT: never run this script while any build against this same
# vendor kernel checkout is in flight - see the equivalent warning in
# touch-irq-variant.sh.
#
# Usage: sh scripts/build/touch-i0-diag-variant.sh <IRQDIAG0|IRQDIAG1>

set -eu

VARIANT="${1:?usage: $0 <IRQDIAG0|IRQDIAG1>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
PATCH="$SCRIPT_DIR/patches/touch-irq-diag-gate.patch"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"
MARKER="$REPO_ROOT/build-work/touch-i0-diag-variant-applied.txt"

AFFECTED_FILES="
kernel/kernel-6.6/drivers/input/touchscreen/Kconfig
kernel/kernel-6.6/drivers/input/touchscreen/ns2009.c
"

BEGIN_MARK="#--- NEBULAOS_TOUCH_IRQ_DIAG_VARIANT_BEGIN ---"
END_MARK="#--- NEBULAOS_TOUCH_IRQ_DIAG_VARIANT_END ---"

case "$VARIANT" in
	IRQDIAG0|IRQDIAG1) ;;
	*)
		echo "unknown variant '$VARIANT' - must be one of IRQDIAG0 IRQDIAG1" >&2
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

if [ "$VARIANT" = "IRQDIAG1" ]; then
	( cd "$KERNEL_DIR" && git apply "$PATCH" )
	{
		echo "$BEGIN_MARK"
		echo "# Display/touch investigation mission follow-on (2026-08-01+) -"
		echo "# TOUCH-I0-DIAG IRQ observation diagnostic variant."
		echo "CONFIG_TOUCHSCREEN_NS2009_IRQ_DIAG=y"
		echo "$END_MARK"
	} >> "$FRAGMENT"
fi

mkdir -p "$(dirname "$MARKER")"
printf '%s\n' "$VARIANT" > "$MARKER"
echo "== touch-i0-diag-variant: $VARIANT applied =="
