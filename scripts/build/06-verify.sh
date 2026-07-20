#!/bin/sh
# Confirm every piece actually landed in the built rootfs.ext2, the same way
# this whole project verified things without real hardware: debugfs presence
# checks plus readelf/file architecture checks on anything compiled. This is
# NOT a substitute for the real boot test (needs the user present) - it only
# proves the image contains what it's supposed to.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
IMAGES="$REPO_ROOT/vendor/buildroot-x2000/output/images"

if [ ! -f "$IMAGES/rootfs.ext2" ]; then
	echo "rootfs.ext2 not found - run 05-final-build.sh first" >&2
	exit 1
fi

docker run --rm --user root -v "$IMAGES:/img" pellcorp/k1-bash-build bash -c '
apt-get -qq update >/dev/null 2>&1
apt-get install -y -qq e2fsprogs >/dev/null 2>&1

check() {
	path="$1"
	if debugfs -R "stat $path" /img/rootfs.ext2 2>&1 | grep -q "Inode:"; then
		echo "OK   $path"
	else
		echo "MISS $path"
	fi
}

echo "=== kernel modules ==="
check /lib/modules/6.6.18-rt23/kernel/drivers/input/touchscreen/ns2009.ko
check /lib/modules/6.6.18-rt23/kernel/module_drivers/drivers/video/fbdev/ingenic/displays/panel-openke-general-480x272.ko
check /lib/modules/6.6.18-rt23/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko
check /lib/modules/6.6.18-rt23/kernel/drivers/bluetooth/hci_uart.ko
check /lib/modules/6.6.18-rt23/kernel/drivers/bluetooth/btbcm.ko
check /lib/modules/6.6.18-rt23/kernel/module_drivers/drivers/char/hw_random/ingenic-rng.ko

echo "=== camera ==="
check /usr/bin/ustreamer
check /etc/init.d/S50webcam

echo "=== app stack ==="
check /usr/bin/python3.11
check /opt/klipper/klippy/klippy.py
check /opt/klipper/klippy/chelper/c_helper.so
check /opt/moonraker/moonraker/server.py
check /usr/lib/python3.11/site-packages/streaming_form_data
check /usr/sbin/nginx
check /usr/share/mainsail/index.html
check /etc/init.d/S55klipper
check /etc/init.d/S56moonraker
check /etc/init.d/S50nginx
check /opt/printer_data/config/printer.cfg
check /opt/printer_data/config/moonraker.conf

echo "=== SSH/console/recovery (FIRMWARE.md sec 18/21/22/24) ==="
check /usr/sbin/dropbear
check /usr/sbin/wpa_cli
check /etc/init.d/S00revert-safety
check /etc/init.d/S01tmpfs-datastore
check /etc/init.d/S99confirm-good
check /etc/ota_marker.sh
check /usr/data/printer_data/config/GuppyScreen/scripts/static_ip.py
'

echo "=== architecture spot-checks (host objdump has no MIPS backend - using the k1-bash-build toolchain) ==="
docker run --rm --user root -v "$IMAGES:/img" pellcorp/k1-bash-build bash -c '
apt-get -qq update >/dev/null 2>&1; apt-get install -y -qq e2fsprogs file >/dev/null 2>&1
for f in "kernel/module_drivers/drivers/video/fbdev/ingenic/displays/panel-openke-general-480x272.ko" \
         "kernel/drivers/bluetooth/hci_uart.ko"; do
	debugfs -R "dump /lib/modules/6.6.18-rt23/$f /tmp/x.ko" /img/rootfs.ext2 >/dev/null 2>&1
	echo "$f: $(file -b /tmp/x.ko)"
done
'

echo "== verification complete - review any MISS lines above =="
