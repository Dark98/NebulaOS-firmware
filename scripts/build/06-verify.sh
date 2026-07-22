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
KERNEL_CONFIG="$REPO_ROOT/vendor/buildroot-x2000/output/build/linux-custom/.config"

if [ ! -f "$IMAGES/rootfs.ext2" ]; then
	echo "rootfs.ext2 not found - run 05-final-build.sh first" >&2
	exit 1
fi

# ns2009, the display panel, brcmfmac and the RNG are all built statically
# into vmlinux (=y, not =m) - see halley5-openke-fragment.config's own
# comments for why each one was switched. A built-in driver produces no
# separate .ko file under /lib/modules at all, so these are checked against
# the actual built kernel .config instead of debugfs'd out of rootfs.ext2 -
# checking for a .ko file here would silently and permanently report MISS
# for correctly-working built-in support.
echo "=== built-in kernel drivers (not loadable modules) ==="
if [ -f "$KERNEL_CONFIG" ]; then
	check_builtin() {
		sym="$1"
		if grep -q "^${sym}=y$" "$KERNEL_CONFIG"; then
			echo "OK   $sym=y (built-in)"
		else
			echo "MISS $sym"
		fi
	}
	check_builtin CONFIG_TOUCHSCREEN_NS2009
	check_builtin CONFIG_STAGE_OPENKE_GENERAL_480X272
	check_builtin CONFIG_BRCMFMAC
	check_builtin CONFIG_INGENIC_HW_RANDOM
	# Two competing WiFi drivers were a real, previously-hit bug (FIRMWARE.md
	# sec 24/36) - confirm the vendor's out-of-tree one stays disabled.
	if grep -q "^CONFIG_BCMDHD=y$" "$KERNEL_CONFIG"; then
		echo "MISS CONFIG_BCMDHD is set - conflicts with CONFIG_BRCMFMAC for the same SDIO chip"
	else
		echo "OK   CONFIG_BCMDHD not set (brcmfmac is the only WiFi driver)"
	fi
	# FIRMWARE.md sec 53: CONFIG_BRCMFMAC=y means brcmfmac's own firmware
	# request happens before the real rootfs is mounted - embedding the
	# firmware in the kernel image itself is what actually makes WiFi work,
	# not just having the files present in rootfs.ext2 (checked separately
	# below - both need to be true).
	if grep -q "^CONFIG_EXTRA_FIRMWARE=\"brcm/brcmfmac43430-sdio.bin brcm/brcmfmac43430-sdio.txt\"$" "$KERNEL_CONFIG"; then
		echo "OK   CONFIG_EXTRA_FIRMWARE set (WiFi firmware embedded in the kernel image)"
	else
		echo "MISS CONFIG_EXTRA_FIRMWARE not set as expected - did fetch-wifi-firmware.sh run before 02-configure-buildroot.sh?"
	fi
	# FIRMWARE.md sec 23 (2026-07-23): the base vendor defconfig has this off
	# (a kernel-size trim, not deliberate for this project) - without it,
	# flock()/fcntl locking fail kernel-wide (ENOSYS/EACCES on a brand new,
	# uncontended file, confirmed on real hardware), which broke Moonraker
	# with sqlite3.OperationalError: database is locked on its very first
	# database open. Affects anything using file locks, not just sqlite.
	check_builtin CONFIG_FILE_LOCKING
else
	echo "MISS $KERNEL_CONFIG not found - run 03-build-kernel-and-rootfs.sh first"
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

echo "=== kernel modules (still loadable, not built-in) ==="
check /lib/modules/6.6.18-rt23/kernel/drivers/bluetooth/hci_uart.ko
check /lib/modules/6.6.18-rt23/kernel/drivers/bluetooth/btbcm.ko

echo "=== WiFi firmware (FIRMWARE.md sec 53 - proprietary, not committed, staged by fetch-wifi-firmware.sh) ==="
check /lib/firmware/brcm/brcmfmac43430-sdio.bin
check /lib/firmware/brcm/brcmfmac43430-sdio.txt

echo "=== camera ==="
check /usr/bin/ustreamer
check /etc/init.d/S50webcam

echo "=== app stack ==="
# FIRMWARE.md sec 23 (2026-07-23): real, previously-silent bug - the
# gcc-final packages INSTALL_TARGET_CMDS step (copies libstdc++.so* into
# the rootfs) is gated on a Buildroot package stamp that does not get
# invalidated just because BR2_INSTALL_LIBSTDCPP became load-bearing
# later - a stale stamp from the very first build meant this was
# silently missing from every build for days while Klipper (needs it via
# greenlet) died instantly with no log line at all.
# 03-build-kernel-and-rootfs.sh now forces gcc-final-reinstall; this
# check is the permanent guard against that regressing silently again.
check /usr/lib/libstdc++.so.6
# FIRMWARE.md sec 23 (2026-07-23): real, previously-silent bug found right
# after the libstdc++ fix above let Moonraker actually import far enough to
# hit it - importlib_metadata (a real Moonraker dependency) imports zipp at
# runtime, but 04-cross-compile-app-stack.sh downloaded it with --no-deps,
# so zipp itself was never fetched. Moonraker died with
# ModuleNotFoundError: No module named zipp, before opening its own log.
check /usr/lib/python3.11/site-packages/zipp
# FIRMWARE.md sec 23 (2026-07-23): numpy is a soft/lazy Klipper dependency -
# shaper_calibrate.py only raises a clean, user-facing error if it is
# missing (not a crash), and only when a user actually runs resonance
# testing. Not launch-blocking, but a real completeness gap for a near-
# universal Klipper workflow, and available as a ready Buildroot package
# (BR2_PACKAGE_PYTHON_NUMPY), so enabled rather than left missing.
check /usr/lib/python3.11/site-packages/numpy
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
for f in "kernel/drivers/bluetooth/hci_uart.ko"; do
	debugfs -R "dump /lib/modules/6.6.18-rt23/$f /tmp/x.ko" /img/rootfs.ext2 >/dev/null 2>&1
	echo "$f: $(file -b /tmp/x.ko)"
done
'

echo "== verification complete - review any MISS lines above =="
