#!/bin/sh
# Verify this project's kernel-source changes (touch DT wiring, the new
# display panel driver, the new Bluetooth H5 Broadcom vendor extension,
# WiFi/BT/display Kconfig, the ported NS2009 driver, the binder.h build fix)
# are present in the checked-out kernel tree.
#
# FIRMWARE.md sec 39: these changes used to be applied here at build time from
# patches/x2000_kernel_6.6-openke.patch. They're now real, reviewable commits
# on the `openke` branch of a genuine fork (github.com/coreflake1/NebulaOS,
# forked from the original upstream Llixuma/ingenic-linux-kernel6.6-x2000-
# v1.0-20250221) - 00-fetch-vendor-sources.sh checks out that branch directly,
# so there's nothing left to apply here. This script stays as stage "01" (kept
# numbered/in-sequence on purpose, so existing docs/muscle-memory still work)
# purely as a sanity check that the fork's content actually landed correctly.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"

if [ ! -d "$KERNEL_DIR/.git" ]; then
	echo "vendor/x2000_kernel_6.6 not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
fi

cd "$KERNEL_DIR"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "openke" ]; then
	echo "vendor/x2000_kernel_6.6 is on branch '$BRANCH', expected 'openke' - re-run 00-fetch-vendor-sources.sh against a clean checkout" >&2
	exit 1
fi

# Defense in depth (2026-07-31, NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md's
# vendor-pin audit): 00-fetch-vendor-sources.sh already enforces this exact
# pin and fails loudly on drift, but this script shouldn't silently trust
# that it ran first/correctly - keep the same pin constant here and verify
# independently, so a hand-run `git pull` inside this checkout between the
# two scripts still gets caught.
X2000_KERNEL_6_6_PIN=295b7101d751fd888ae39e6f1746a4a940664a5f
ACTUAL_SHA=$(git rev-parse HEAD)
if [ "$ACTUAL_SHA" != "$X2000_KERNEL_6_6_PIN" ]; then
	echo "vendor/x2000_kernel_6.6 HEAD is $ACTUAL_SHA, expected pinned commit $X2000_KERNEL_6_6_PIN - re-run 00-fetch-vendor-sources.sh (it will refuse to proceed and explain why)" >&2
	exit 1
fi

echo "== confirming the openke branch's real changes are present =="
test -f kernel/kernel-6.6/drivers/input/touchscreen/ns2009.c
test -f kernel/kernel-6.6/module_drivers/drivers/video/fbdev/ingenic/displays/panel-openke-general-480x272.c
grep -q "openke,bcm4343x-bt" kernel/kernel-6.6/drivers/bluetooth/hci_h5.c
grep -q "ns2009@48" kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts
echo "== kernel source verified =="
