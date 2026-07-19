#!/bin/sh
# Apply this project's real kernel-source changes (touch DT wiring, the new
# display panel driver, the new Bluetooth H5 Broadcom vendor extension,
# WiFi/BT/display Kconfig, the ported NS2009 driver, the binder.h build fix)
# to the freshly cloned kernel SDK. See FIRMWARE.md sec 8/10/11 for the full
# story behind each change - this just applies the result.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
PATCH="$REPO_ROOT/patches/x2000_kernel_6.6-openke.patch"

if [ ! -d "$KERNEL_DIR/.git" ]; then
	echo "vendor/x2000_kernel_6.6 not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
fi

cd "$KERNEL_DIR"

if grep -q "openke,bcm4343x-bt" kernel/kernel-6.6/drivers/bluetooth/hci_h5.c 2>/dev/null; then
	echo "== patch already applied, skipping =="
elif git apply --check "$PATCH" 2>/dev/null; then
	git apply "$PATCH"
	echo "== patch applied cleanly =="
else
	echo "patch failed to apply cleanly - check for upstream drift in the kernel SDK ref" >&2
	git apply "$PATCH"
	exit 1
fi

echo "== confirming the patched files are present =="
test -f kernel/kernel-6.6/drivers/input/touchscreen/ns2009.c
test -f kernel/kernel-6.6/module_drivers/drivers/video/fbdev/ingenic/displays/panel-openke-general-480x272.c
grep -q "openke,bcm4343x-bt" kernel/kernel-6.6/drivers/bluetooth/hci_h5.c
grep -q "ns2009@48" kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts
echo "== kernel patches applied and verified =="
