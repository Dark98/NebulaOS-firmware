#!/bin/sh
#
# Alpha baseline freeze mission (2026-08-01): deterministic, documented
# build command for the NEBULAOS-ALPHA-MAX-RT composition (W3 SDIO +
# R1 PREEMPT_RT + HZ=100 unchanged + CN country unchanged), which the
# user has designated the new alpha integration baseline. See
# docs/NEBULAOS_ALPHA_BASELINE.md for the full composition record and
# docs/NEBULAOS_ALPHA_MAX_RT_DEPLOYMENT_REPORT.md for the live
# deployment this was first validated against.
#
# Deliberately the smallest mechanism that fits this repo's existing
# conventions - it just sequences the two existing variant scripts
# immediately before the real build pipeline (no intervening steps, per
# the real defect this mission fixed in
# tests/variant-state-preservation-tests.sh: running those test suites
# between "apply the variant" and "build" used to silently discard the
# selection), then runs the new artifact-composition assertions
# straight after the build finishes. Not a generic profile framework -
# P1 (Wi-Fi power-save-off) and C2 (camera idle-pause) are NOT part of
# this script, because they are runtime markers on /usr/data (see
# scripts/build/overlay/etc/nebulaos-wifi-power-save.sh and
# nebulaos-camera-idle-controller.sh), not build-time selections; they
# get activated after the image boots, exactly as they were for the
# real Alpha-Max-RT deployment.
#
# Usage: sh scripts/build/build-alpha-baseline.sh
#
# Exits non-zero if the variant application, any build stage, or the
# final composition assertion fails.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

echo "=== nebulaos-alpha-baseline: applying W3 (cap-sdio-irq + cap-sd-highspeed) ==="
sh "$SCRIPT_DIR/wifi-sdio-variant.sh" W3

echo "=== nebulaos-alpha-baseline: applying R1 (PREEMPT_RT, HZ=100 unchanged) ==="
sh "$SCRIPT_DIR/preempt-variant.sh" R1

echo "=== nebulaos-alpha-baseline: confirming the selection landed before building ==="
DTS="$REPO_ROOT/vendor/x2000_kernel_6.6/kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"
sed -n '/^&msc1 {/,/^};/p' "$DTS" | grep -q 'cap-sdio-irq;' || { echo "ABORT: cap-sdio-irq did not land in the DTS" >&2; exit 1; }
sed -n '/^&msc1 {/,/^};/p' "$DTS" | grep -q 'cap-sd-highspeed;' || { echo "ABORT: cap-sd-highspeed did not land in the DTS" >&2; exit 1; }
grep -q '^CONFIG_PREEMPT_RT=y$' "$FRAGMENT" || { echo "ABORT: CONFIG_PREEMPT_RT=y did not land in the fragment config" >&2; exit 1; }

echo "=== nebulaos-alpha-baseline: running the build pipeline ==="
sh "$SCRIPT_DIR/01-apply-kernel-patches.sh"
sh "$SCRIPT_DIR/02-configure-buildroot.sh"
sh "$SCRIPT_DIR/03-build-kernel-and-rootfs.sh"
sh "$SCRIPT_DIR/04-cross-compile-app-stack.sh"
sh "$SCRIPT_DIR/05-final-build.sh"
sh "$SCRIPT_DIR/06-verify.sh"

echo "=== nebulaos-alpha-baseline: asserting the built artifact's composition ==="
sh "$SCRIPT_DIR/assert-alpha-baseline.sh"

echo "=== nebulaos-alpha-baseline: build complete and composition-verified ==="
echo "Package it with: sh scripts/build/package-variant-artifacts.sh ALPHA-BASELINE"
echo "Remember to reset variant markers to baseline afterward:"
echo "  sh scripts/build/wifi-sdio-variant.sh W0"
echo "  sh scripts/build/preempt-variant.sh R0"
echo "P1 (Wi-Fi power-save-off) and C2 (camera idle-pause) are runtime markers,"
echo "activated post-boot on the device itself - see docs/NEBULAOS_ALPHA_BASELINE.md."
