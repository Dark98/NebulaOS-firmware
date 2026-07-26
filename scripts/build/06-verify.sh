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
# into vmlinux (=y, not =m) - see halley5-nebulaos-fragment.config's own
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
	# NebulaOS Memory Resilience Gate: real bug this catches if regressed -
	# the original OOM/no-swap incident happened precisely because these
	# were silently absent from the kernel; a plain rootfs file check
	# can't see kernel config at all, so this is the only place a clean
	# build can catch this specific regression.
	check_builtin CONFIG_SWAP
	check_builtin CONFIG_ZRAM
	check_builtin CONFIG_CRYPTO_LZ4
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
	if grep -q '^CONFIG_EXTRA_FIRMWARE="brcm/brcmfmac43430-sdio\.bin brcm/brcmfmac43430-sdio\.txt' "$KERNEL_CONFIG"; then
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

# Functional production-baseline mission, Phase 4: assert the packaged, real,
# fully-resolved production DTB (not the layered .dts source, which would
# need this script to reimplement override-precedence itself) keeps every
# intentionally-disabled reference-design block disabled, and every required
# product device enabled. Decompiles with the dtc host tool Buildroot already
# builds (output/host/bin/dtc) - no Docker/network needed for this check.
DTB="$REPO_ROOT/vendor/buildroot-x2000/output/build/linux-custom/module_drivers/dts/x2000/halley5_v30.dtb"
DTC="$REPO_ROOT/vendor/buildroot-x2000/output/host/bin/dtc"
echo "=== production DTB capability assertions ==="
if [ -f "$DTB" ] && [ -x "$DTC" ]; then
	DECOMPILED=$(mktemp)
	"$DTC" -I dtb -O dts "$DTB" 2>/dev/null > "$DECOMPILED"

	# Prints the "status" value of the first node whose header line matches
	# $1, scoped to that node's own body only (stops descending into the
	# first child node it hits). No explicit status property = "okay" (the
	# devicetree spec default).
	node_status() {
		awk -v pat="$1" '
			BEGIN { found = 0; depth = 0; status = "okay" }
			found && depth >= 1 {
				if (match($0, /status = "[a-z]+"/)) {
					s = substr($0, RSTART, RLENGTH)
					gsub(/status = "|"/, "", s)
					status = s
					found = 2
				}
			}
			$0 ~ pat && /\{[ \t]*$/ && found == 0 { found = 1 }
			found >= 1 {
				o = gsub(/\{/, "{"); c = gsub(/\}/, "}")
				depth += o - c
				if (found == 1 && depth == 0) { found = 3 }
				else if (depth <= 0) { exit }
			}
			END { print status }
		' "$DECOMPILED"
	}

	assert_status() {
		name="$1"; pat="$2"; want="$3"
		got=$(node_status "$pat")
		case "$want" in
			enabled)
				if [ "$got" = "okay" ] || [ "$got" = "ok" ]; then
					echo "OK   $name enabled (status=$got)"
				else
					echo "MISS $name expected enabled, got status=$got"
				fi
				;;
			disabled)
				if [ "$got" = "disabled" ] || [ "$got" = "disable" ]; then
					echo "OK   $name disabled (status=$got)"
				else
					echo "MISS $name expected disabled, got status=$got"
				fi
				;;
		esac
	}

	echo "--- must stay disabled (unused reference-design blocks) ---"
	assert_status "mac1 (unpopulated Ethernet)"      'mac@134a0000 {'      disabled
	assert_status "msc2 (unused MMC controller)"      'msc@13490000 {'      disabled
	assert_status "sfc (unpopulated SPI-NOR/NAND)"    'sfc@13440000 {'      disabled
	assert_status "mscaler0 (unused v4l2_subdev)"     'mscaler@13702300 {'  disabled
	assert_status "mscaler1 (unused v4l2_subdev)"     'mscaler@13802300 {'  disabled
	assert_status "uart3 (guaranteed pin conflict)"   'serial@10033000 {'   disabled
	assert_status "as-dmic (no product mic array)"    'as-dmic {'           disabled
	assert_status "as-baic (BAIC0/4, no stock ALSA use)" 'as-baic {'        disabled
	assert_status "as-platform (ALSA DMA frontend)"   'as-platform {'       disabled
	assert_status "as-fmtcov (ALSA format conv)"      'as-fmtcov {'         disabled
	assert_status "as-dsp (ALSA DSP/LO_MUX)"          'as-dsp {'            disabled
	assert_status "as-mixer (ALSA aux mixer)"         'as-mixer {'          disabled
	assert_status "as-spdif (ALSA SPDIF)"             'as-spdif {'          disabled
	assert_status "icodec (on-chip audio codec)"      'icodec@10020000 {'   disabled

	echo "--- must stay enabled (required product devices) ---"
	assert_status "msc0/eMMC"           'msc@13450000 {'   enabled
	assert_status "msc1/WiFi SDIO"      'msc@13460000 {'   enabled
	assert_status "uart1 (printer MCU link)" 'serial@10031000 {' enabled
	assert_status "uart4 (console)"     'serial@10034000 {' enabled
	assert_status "i2c4 (touchscreen)"  'i2c@10054000 {'    enabled
	assert_status "dpu (display)"       'dpu@[0-9a-fx]+ {'  enabled
	assert_status "pwm (beeper channel)" 'pwm@134c0000 {'   enabled
	assert_status "otg (USB)"           'otg@13500000 {'    enabled
	assert_status "rtc"                 'rtc@10003000 {'    enabled
	assert_status "watchdog"            'watchdog@10002000 {' enabled

	rm -f "$DECOMPILED"
else
	echo "MISS DTB or dtc not found ($DTB / $DTC) - run 03-build-kernel-and-rootfs.sh first"
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
check /etc/init.d/S01persistent-datastore
check /etc/init.d/S99confirm-good
check /etc/ota_marker.sh
check /opt/printer_data/config/GuppyScreen/scripts/static_ip.py

echo "=== NebulaOS memory resilience (docs/NEBULAOS_MEMORY_RESILIENCE.md) ==="
check /sbin/mkswap
check /sbin/swapon
check /sbin/swapoff
check /usr/bin/free
check /etc/init.d/S00zram-swap
check /etc/init.d/S03nebulaos-diskswap
check /etc/init.d/S02nebulaos-namespace
check /etc/init.d/S04nebulaos-factory-seed
check /etc/init.d/S05nebulaos-activate
check /etc/init.d/S45nebulaos-cleanup
check /etc/nebulaos-retention.sh
check /etc/nebulaos-healthcheck.sh
check /opt/nebulaos-seeds/klipper.bundle
check /opt/nebulaos-seeds/moonraker.bundle
check /opt/nebulaos-seeds/seed-manifest.json
check /usr/sbin/ntpd
check /etc/init.d/S40nebulaos-ntpsync
check /etc/nebulaos-update-supervisor.sh
check /etc/init.d/S59nebulaos-update-supervisor

# Phase 7 live qualification: Moonraker machine.py needs real iproute2
# JSON output (`ip -json -det address`), which BusyBox ip cannot produce
# at all (confirmed live). /sbin/ip must be the real iproute2 ELF binary,
# not still the busybox multi-call symlink - debugfs stat prints
# "Fast link dest" only for symlinks, so its presence (and pointing at
# busybox) is what would indicate the fix did not take.
check /sbin/ip
stat_out=$(debugfs -R "stat /sbin/ip" /img/rootfs.ext2 2>&1)
case "$stat_out" in
	*"Fast link dest"*busybox*)
		echo "MISS /sbin/ip is still the busybox applet symlink"
		;;
	*)
		echo "OK   /sbin/ip is a real binary, not the busybox symlink"
		;;
esac
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
