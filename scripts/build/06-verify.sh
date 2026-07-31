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

# Vendor pin drift check (SimpleAF backend integration, 2026-07-29, see docs/
# NEBULAOS_SIMPLEAF_BACKEND_INTEGRATION.md) - 00-fetch-vendor-sources.sh only
# clones+checks-out a pin the FIRST time a vendor/ dir is absent; nothing
# previously re-verified that an already-present checkout's HEAD still
# matches its recorded pin (e.g. after a stray `git pull` run by hand inside
# vendor/, or a stale checkout left over from before a pin was bumped). Keep
# these SHAs in sync with 00-fetch-vendor-sources.sh's own clone_pinned calls
# - duplicated here deliberately (same convention as blank_required_option's
# two copies below) rather than sourcing the fetch script, which also
# performs real network clones and shouldn't be pulled into a read-only
# verify pass.
echo "=== vendor source pin drift ==="
# Extended 2026-07-31 (NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md's vendor-pin
# audit): now also verifies the origin remote URL (catches a checkout quietly
# repointed at a fork/mirror) and working-tree cleanliness against an
# explicit per-repo allowlist of paths this project's own build scripts
# deterministically modify (e.g. buildroot-x2000's vendor-patches copy-in) -
# an allowed path showing as different is NOT silently ignored as "fine
# either way", it's explicitly named so a reader knows exactly why it's
# expected, same convention as the rest of this project's "corrected in
# place with a note" pattern.
check_vendor_pin() {
	vp_name="$1"
	vp_expected="$2"
	vp_expected_url="$3"
	shift 3
	vp_dir="$REPO_ROOT/vendor/$vp_name"
	if [ ! -d "$vp_dir/.git" ]; then
		echo "MISS vendor/$vp_name is not a git checkout - cannot verify its pin"
		return
	fi
	vp_actual=$(git -C "$vp_dir" rev-parse HEAD 2>/dev/null || echo "unknown")
	if [ "$vp_actual" = "$vp_expected" ]; then
		echo "OK   vendor/$vp_name HEAD matches its pinned commit ($vp_expected)"
	else
		echo "MISS vendor/$vp_name HEAD is $vp_actual, expected pinned commit $vp_expected"
	fi
	if [ -n "$vp_expected_url" ]; then
		vp_remotes=$(git -C "$vp_dir" remote -v 2>/dev/null)
		if printf '%s\n' "$vp_remotes" | grep -qF "$vp_expected_url"; then
			echo "OK   vendor/$vp_name has a remote matching $vp_expected_url"
		else
			echo "MISS vendor/$vp_name has no remote matching expected URL $vp_expected_url"
		fi
	fi
	vp_dirty=$(git -C "$vp_dir" status --porcelain -uall 2>/dev/null)
	for vp_allow in "$@"; do
		vp_dirty=$(printf '%s\n' "$vp_dirty" | grep -v -F "$vp_allow" || true)
	done
	vp_dirty=$(printf '%s\n' "$vp_dirty" | sed '/^$/d')
	if [ -z "$vp_dirty" ]; then
		echo "OK   vendor/$vp_name working tree has no unexplained changes"
	else
		echo "MISS vendor/$vp_name has unexplained working-tree changes:"
		printf '%s\n' "$vp_dirty" | sed 's/^/     /'
	fi
}
# klipper: pin bumped 2026-07-31 to d839d0375 in 00-fetch-vendor-sources.sh
# (previously stuck one real, already-shipped commit behind - see that
# script's own comment). `klippy/chelper/c_helper.so` is expected to differ
# (the correctly cross-compiled MIPS binary vs. whatever's tracked in git -
# same allowlisted-path convention as make-seed-archive.sh's own dirty-tree
# guard fix).
check_vendor_pin klipper d839d0375a31327e57e0a35e99e70ba60814ec05 \
	https://github.com/coreflake1/NebulaOS-klipper.git \
	klippy/chelper/c_helper.so
check_vendor_pin moonraker d5ee17128bb88434aacdab90c2e9e990e2b64e4a \
	https://github.com/Arksine/moonraker.git
check_vendor_pin pellcorp-creality d18d354456a89c20507e574feaa34d6389e679ca \
	https://github.com/pellcorp/creality.git
# buildroot-x2000: the .mk change and board/halley5-nebulaos-* files are
# deterministically copied in by 02-configure-buildroot.sh from tracked
# sources in this repo (scripts/build/vendor-patches/, this project's own
# config layer) - expected every time, not accidental drift.
check_vendor_pin buildroot-x2000 74d020081096972857acdb9e76c6c5335455d430 \
	https://github.com/lone0/buildroot-x2000.git \
	package/python-matplotlib/python-matplotlib.mk \
	board/halley5-nebulaos-busybox-fragment.config \
	board/halley5-nebulaos-fragment.config \
	board/halley5-nebulaos-overlay/ \
	board/halley5-nebulaos-wheels/
check_vendor_pin k1-ustreamer 18e30bb313d54b1b01dd995bd31ce5a3d5adffd6 \
	https://github.com/pellcorp/k1-ustreamer.git
# k1-ustreamer's own real git submodules (jpeg-9d, ustreamer) - pinned via
# the parent commit's own recorded submodule SHAs, so a plain `git status`
# on the parent won't show submodule drift; `submodule status` is the real
# check (a leading '+' means checked out at a different SHA than recorded,
# '-' means not initialized).
if [ -d "$REPO_ROOT/vendor/k1-ustreamer/.git" ]; then
	ku_submodules=$(git -C "$REPO_ROOT/vendor/k1-ustreamer" submodule status 2>/dev/null)
	if printf '%s\n' "$ku_submodules" | grep -qE '^[+-]'; then
		echo "MISS vendor/k1-ustreamer submodules are not at their pinned commits:"
		printf '%s\n' "$ku_submodules" | sed 's/^/     /'
	else
		echo "OK   vendor/k1-ustreamer submodules (jpeg-9d, ustreamer) match their pinned commits"
	fi
fi
# v4l-utils: pinned to the exact commit v4l-utils-1.20.0 resolves to (not the
# tag name) as of the 2026-07-31 pin audit; messages.mo is a harmless
# untracked compiled gettext artifact.
check_vendor_pin v4l-utils 3b22ab02b960e4d1e90618e9fce9b7c8a80d814a \
	https://git.linuxtv.org/v4l-utils.git \
	messages.mo
# x2000_kernel_6.6: same enforcement as 00-fetch-vendor-sources.sh's own
# X2000_KERNEL_6_6_PIN and 01-apply-kernel-patches.sh's independent check -
# duplicated here on purpose (this script never re-fetches, so it can't
# accidentally paper over drift the other two scripts would have caught).
# Remote name is "nebulaos" here, not "origin" - check_vendor_pin's URL check
# greps all remotes, so this is remote-name-agnostic.
check_vendor_pin x2000_kernel_6.6 f7ff80a8aa21886a32783dab167e451298c60a8d \
	https://github.com/coreflake1/NebulaOS.git

echo "=== release artifact provenance (docs/NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md) ==="
check_artifact_sha256() {
	ca_path="$REPO_ROOT/$1"
	ca_expected="$2"
	if [ ! -f "$ca_path" ]; then
		echo "MISS $1 does not exist - cannot verify its hash"
		return
	fi
	ca_actual=$(sha256sum "$ca_path" | awk '{print $1}')
	if [ "$ca_actual" = "$ca_expected" ]; then
		echo "OK   $1 sha256 matches recorded provenance ($ca_expected)"
	else
		echo "MISS $1 sha256 is $ca_actual, expected recorded provenance $ca_expected"
	fi
}
check_artifact_sha256 vendor/mainsail-dist/mainsail.zip \
	df2ba7c301f7bfc8ac9f122741a6ba08356d679ecfa1f62f898d0337802d5de5
check_artifact_sha256 artifacts/guppyscreen-mips/guppyscreen \
	810d895675198b3f73cd8552656f5bfbe593b8faca5883c201807d006e2bdbe4
check_artifact_sha256 artifacts/guppyscreen-mips/guppybeep \
	4a2a719411944e5c2d0f7a9231440487073ce454e398d61f27181a821f2a9d76
check_artifact_sha256 scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.bin \
	60dbb5b77b2c232e513322e0ff4350ab5dab5a9fcad0e26e80a2f089e652d720
check_artifact_sha256 scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.txt \
	78fee458ab69c0a66ea462f6d6769e15b36f73582693f4dbb5a0e8e8be3cfb0a
check_artifact_sha256 scripts/build/overlay/lib/firmware/regulatory.db \
	0a4abd7ae20d07bb70642937ccb2293a72a6504730eea45a698882599f586368
check_artifact_sha256 scripts/build/overlay/lib/firmware/regulatory.db.p7s \
	bcd81aed039ea6b9b6f3726fbf26911a0caf4a5d894210e0fa2effb384d6b326

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

check_absent() {
	path="$1"
	if debugfs -R "stat $path" /img/rootfs.ext2 2>&1 | grep -q "Inode:"; then
		echo "MISS $path is present but should have been removed as obsolete"
	else
		echo "OK   $path is absent"
	fi
}

echo "=== kernel modules (still loadable, not built-in) ==="
# Production optimization mission, Phase 9 (2026-07-30): Bluetooth HCI UART
# transport is now removed entirely (CONFIG_BT is not set - uart3, its only
# wired transport, is permanently disabled in this board own DTS due to a
# real pin conflict with the NS2009 touch controller i2c4 bus, so it could
# never actually attach regardless). These modules are now expected
# ABSENT, not present - inverted from the check this section used before.
check_absent /lib/modules/6.6.18-rt23/kernel/drivers/bluetooth/hci_uart.ko
check_absent /lib/modules/6.6.18-rt23/kernel/drivers/bluetooth/btbcm.ko

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

echo "=== process launch arguments and config-path consistency (mainline print-controls mission addendum, 2026-07-29) ==="
# A newly reported Mainsail "Config Files -> config folder appears empty"
# report required proving Klipper, Moonraker, and Mainsail all resolve to
# the exact same canonical config directory - not inferring it from any
# one of them alone. Live investigation against the real device found the
# architecture already correct end to end (same inode on both the
# persistent and bind-mounted runtime path, Moonrakers own
# /server/files/roots reporting the canonical path with rw, a full
# create/read/edit/delete cycle through the real file-manager API); these
# checks exist to keep it that way, catching a future regression at build
# time rather than live on a real printer.
S55_CONTENT=$(debugfs -R "cat /etc/init.d/S55klipper" /img/rootfs.ext2 2>/dev/null)
S56_CONTENT=$(debugfs -R "cat /etc/init.d/S56moonraker" /img/rootfs.ext2 2>/dev/null)
S01_CONTENT=$(debugfs -R "cat /etc/init.d/S01persistent-datastore" /img/rootfs.ext2 2>/dev/null)
if echo "$S55_CONTENT" | grep -qE "^CONFIG=/opt/printer_data/config/printer.cfg$"; then
	echo "OK   S55klipper launches Klipper against the canonical /opt/printer_data/config/printer.cfg"
else
	echo "MISS S55klipper does not launch Klipper against the canonical printer.cfg path"
fi
if echo "$S56_CONTENT" | grep -qE "^DATAPATH=/opt/printer_data$"; then
	echo "OK   S56moonraker launches Moonraker with the canonical -d /opt/printer_data data path"
else
	echo "MISS S56moonraker does not launch Moonraker with the canonical data path"
fi
if echo "$S56_CONTENT" | grep -qE "^CONFIG=/opt/printer_data/config/moonraker.conf$"; then
	echo "OK   S56moonraker launches Moonraker against the canonical moonraker.conf"
else
	echo "MISS S56moonraker does not launch Moonraker against the canonical moonraker.conf path"
fi
if echo "$S55_CONTENT" | grep -qi "/usr/data/openke\|/opt/openke" || echo "$S56_CONTENT" | grep -qi "/usr/data/openke\|/opt/openke"; then
	echo "MISS S55klipper or S56moonraker still references an obsolete openke path"
else
	echo "OK   S55klipper and S56moonraker contain no obsolete openke path reference (comment mentions of the historical OpenKE project name are fine)"
fi
if echo "$S01_CONTENT" | grep -qE "mount --bind ..PDATA. /opt/printer_data"; then
	echo "OK   S01persistent-datastore bind-mounts the persistent printer_data tree onto /opt/printer_data"
else
	echo "MISS S01persistent-datastore does not bind-mount printer_data onto /opt/printer_data as expected"
fi
if echo "$S01_CONTENT" | grep -qE "^DATA_ROOT=/usr/data/nebulaos$"; then
	echo "OK   S01persistent-datastore uses the canonical persistent backing root /usr/data/nebulaos"
else
	echo "MISS S01persistent-datastore does not use /usr/data/nebulaos as the persistent backing root"
fi

echo "=== Moonraker update_manager / camera defaults (final implementation mission, 2026-07-27) ==="
check /usr/libexec/nebulaos-seed-camera
check /etc/init.d/S57nebulaos-camera-seed

# Content checks against the actual shipped moonraker.conf, not just its
# presence - the whole point of this mission was that a real, previously
# undetected content-level defect (unsupported options under the reserved
# klipper/moonraker update_manager sections; an active, permanently
# un-editable config-sourced default camera) shipped in a build that
# passed every existence-only check that came before it. debugfs extracts
# the real file content from the built image itself, not from the source
# tree, so a build where the overlay sync silently dropped or mismatched
# the edit will not pass this check.
#
# NOTE for future edits to this section: everything in this file from the
# earlier "docker run ... bash -c" line through its own matching close
# further below is one single-quoted string as far as the real, top-level
# shell running this script is concerned - a literal single-quote
# character anywhere in this region (even inside a # comment) would
# terminate that outer quoting early and corrupt the rest of the file.
# Use double quotes for every string/pattern added below instead - none
# of them need a literal dollar sign or backtick, so double-quoting is
# always safe here.
MOONRAKER_CONF_CONTENT=$(debugfs -R "cat /opt/printer_data/config/moonraker.conf" /img/rootfs.ext2 2>/dev/null)

check_conf_absent() {
	pattern="$1"; desc="$2"
	if echo "$MOONRAKER_CONF_CONTENT" | grep -qE "$pattern"; then
		echo "MISS moonraker.conf still contains: $desc"
	else
		echo "OK   moonraker.conf does not contain: $desc"
	fi
}
check_conf_present() {
	pattern="$1"; desc="$2"
	if echo "$MOONRAKER_CONF_CONTENT" | grep -qE "$pattern"; then
		echo "OK   moonraker.conf contains: $desc"
	else
		echo "MISS moonraker.conf missing: $desc"
	fi
}
# SimpleAF backend integration (2026-07-29) needs a real, non-empty
# [file_manager] section (enable_object_processing: True, required for
# exclude_object polygon data) - this check used to forbid the whole
# section outright, which conflicts with that legitimate need. The real
# original worry was narrower: vendor/moonraker/moonraker/components/
# file_manager/file_manager.py only reads two deprecated path-override
# options from this section, config_path and log_path (config.get(...,
# deprecate=True) for both) - anything else here, including
# enable_object_processing, cannot divert the config root away from
# -d /opt/printer_data. Scope the check to just those two options,
# the same way the update_manager section check below scopes to its own
# reserved-option list rather than forbidding the section itself.
FILE_MANAGER_SECTION_BODY=$(echo "$MOONRAKER_CONF_CONTENT" | awk "
	/^\[file_manager\]\$/ { grab=1; next }
	/^\[/ { grab=0 }
	grab { print }
")
if echo "$FILE_MANAGER_SECTION_BODY" | grep -qE "^(config_path|log_path): "; then
	echo "MISS [file_manager] contains a deprecated config_path/log_path override (the config root must keep deriving from -d /opt/printer_data by default, not an override that could diverge from the printer.cfg path Klipper actually reads)"
else
	echo "OK   [file_manager] contains no config_path/log_path override"
fi
# Extracts just the [update_manager klipper] and [update_manager moonraker]
# sections own body (up to the next [section] header) - scoped
# deliberately, since path/type ARE legitimate, needed options under the
# DIFFERENT (generic, type: web) [update_manager mainsail] section; a
# whole-file check would wrongly flag those as a regression.
RESERVED_SECTIONS_BODY=$(echo "$MOONRAKER_CONF_CONTENT" | awk "
	/^\[update_manager klipper\]\$/ || /^\[update_manager moonraker\]\$/ { grab=1; next }
	/^\[/ { grab=0 }
	grab { print }
")

check_conf_absent "^\[webcam " "an active [webcam ...] section"
if echo "$RESERVED_SECTIONS_BODY" | grep -qE "^(type|path|origin|primary_branch|managed_services|virtualenv|requirements): "; then
	echo "MISS [update_manager klipper]/[update_manager moonraker] still contain unsupported options (type/path/origin/primary_branch/managed_services/virtualenv/requirements) - these are reserved slots, see docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md"
else
	echo "OK   [update_manager klipper]/[update_manager moonraker] contain no unsupported options"
fi
check_conf_present "^\[update_manager klipper\]\$" "the reserved [update_manager klipper] section"
check_conf_present "^\[update_manager moonraker\]\$" "the reserved [update_manager moonraker] section"
check_conf_present "^\[update_manager mainsail\]\$" "the Mainsail web updater section"
if echo "$RESERVED_SECTIONS_BODY" | grep -qE "^channel: dev\$"; then
	echo "OK   [update_manager klipper]/[update_manager moonraker] set channel: dev"
else
	echo "MISS [update_manager klipper]/[update_manager moonraker] missing channel: dev"
fi

echo "=== factory-seed git archives (auto-updates-camera-complete mission, 2026-07-28) ==="
# Real bug this whole mission exists to fix: the OLD flattened-synthetic-
# commit seed made every freshly-seeded klipper/moonraker checkout
# diverged=true, is_valid=false, permanently blocking real updates - see
# docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md. Existence-only
# checks cannot see this - it needs the actual archive content dumped out
# of the built image and inspected with real git commands, the same way
# the moonraker.conf content checks above go beyond existence-only.
apt-get install -y -qq git >/dev/null 2>&1
# Real bug found live: the extracted archive keeps the UID it was tarred
# with on the build host, which does not match this containers root user
# - git refuses to operate on it at all ("detected dubious ownership"),
# silently making every symbolic-ref/remote/status command below return
# empty instead of erroring, which made every check misreport a MISS.
# Harmless here (a throwaway verification container, not a real trust
# boundary) - exempt the one fixed extraction path used below.
git config --global --add safe.directory /tmp/seed-check
check_seed_archive() {
	archive_path="$1"; expected_branch="$2"; expected_origin="$3"; label="$4"
	rm -rf /tmp/seed-check
	mkdir -p /tmp/seed-check
	if ! debugfs -R "dump $archive_path /tmp/seed-check.tar" /img/rootfs.ext2 >/dev/null 2>&1; then
		echo "MISS $label archive could not be dumped from the image ($archive_path)"
		return
	fi
	if ! tar -xzf /tmp/seed-check.tar -C /tmp/seed-check 2>/dev/null; then
		echo "MISS $label archive is not a valid tar file"
		return
	fi
	if git -C /tmp/seed-check log --all --format=%s 2>/dev/null | grep -q "NebulaOS factory seed snapshot"; then
		echo "MISS $label archive still contains a synthetic factory-seed wrapper commit"
	else
		echo "OK   $label archive contains no synthetic wrapper commit"
	fi
	actual_branch=$(git -C /tmp/seed-check symbolic-ref --short HEAD 2>/dev/null)
	if [ "$actual_branch" = "$expected_branch" ]; then
		echo "OK   $label archive is on branch $expected_branch"
	else
		echo "MISS $label archive is on branch \"$actual_branch\", expected $expected_branch"
	fi
	actual_origin=$(git -C /tmp/seed-check remote get-url origin 2>/dev/null)
	if [ "$actual_origin" = "$expected_origin" ]; then
		echo "OK   $label archive origin is $expected_origin"
	else
		echo "MISS $label archive origin is \"$actual_origin\", expected $expected_origin"
	fi
	actual_refspec=$(git -C /tmp/seed-check config --get remote.origin.fetch 2>/dev/null)
	if [ "$actual_refspec" = "+refs/heads/*:refs/remotes/origin/*" ]; then
		echo "OK   $label archive origin has the full wildcard fetch refspec"
	else
		echo "MISS $label archive origin fetch refspec is \"$actual_refspec\", expected the full wildcard form (a narrow refspec silently breaks a later git fetch origin from populating origin/$expected_branch, reproducing diverged=true)"
	fi
	# Production optimization mission, Phase 9 (2026-07-30): same pathspec
	# exclusion as the internal clean-tree guard in make-seed-archive.sh -
	# the klipper build own properly cross-compiled+stripped c_helper.so is
	# legitimately, always different from whatever is tracked in git for
	# that path (an untrusted upstream binary). Moonraker has no such
	# path, so this exclusion is a no-op there. Double quotes, not single
	# quotes, around the pathspec magic below - a literal single quote
	# here would close the outer docker bash -c string early exactly like
	# the apostrophe bugs elsewhere in this same file.
	if [ -z "$(git -C /tmp/seed-check status --porcelain -- . ":!klippy/chelper/c_helper.so" 2>/dev/null)" ]; then
		echo "OK   $label archive has a clean working tree"
	else
		echo "MISS $label archive has a dirty working tree"
	fi
	rm -rf /tmp/seed-check /tmp/seed-check.tar
}
check_seed_archive /opt/nebulaos-seeds/klipper.tar.gz master "https://github.com/coreflake1/NebulaOS-klipper.git" "klipper"
check_seed_archive /opt/nebulaos-seeds/moonraker.tar.gz master "https://github.com/Arksine/moonraker.git" "moonraker"

# Real bug this catches if regressed: the c_helper.so committed inside
# vendor/klippers own git history (an upstream binary) is incompatible
# with this image and hangs Klipper indefinitely with no on-device
# compiler to fall back on - only this projects own cross-compiled copy,
# already baked into the immutable /opt/klipper baseline, actually loads.
# Confirms the seed archives copy (the one the persistent, git-updatable
# checkout actually ships) is byte-identical to the proven-working
# immutable one, not silently reverted to the incompatible upstream blob.
rm -rf /tmp/chelper-check
mkdir -p /tmp/chelper-check
debugfs -R "dump /opt/nebulaos-seeds/klipper.tar.gz /tmp/chelper-check.tar.gz" /img/rootfs.ext2 >/dev/null 2>&1
if tar -xzf /tmp/chelper-check.tar.gz -C /tmp/chelper-check ./klippy/chelper/c_helper.so 2>/dev/null; then
	SEED_CHELPER_SHA=$(sha256sum /tmp/chelper-check/klippy/chelper/c_helper.so 2>/dev/null | cut -d" " -f1)
	BASELINE_CHELPER_SHA=$(debugfs -R "cat /opt/klipper/klippy/chelper/c_helper.so" /img/rootfs.ext2 2>/dev/null | sha256sum | cut -d" " -f1)
	if [ -n "$SEED_CHELPER_SHA" ] && [ "$SEED_CHELPER_SHA" = "$BASELINE_CHELPER_SHA" ]; then
		echo "OK   klipper seed archives c_helper.so matches the proven-working immutable baseline"
	else
		echo "MISS klipper seed archives c_helper.so ($SEED_CHELPER_SHA) does not match the immutable baseline ($BASELINE_CHELPER_SHA) - it may be the incompatible upstream binary"
	fi
else
	echo "MISS could not extract klippy/chelper/c_helper.so from the klipper seed archive for comparison"
fi
rm -rf /tmp/chelper-check /tmp/chelper-check.tar.gz
SEED_MANIFEST_CONTENT=$(debugfs -R "cat /opt/nebulaos-seeds/seed-manifest.json" /img/rootfs.ext2 2>/dev/null)
if echo "$SEED_MANIFEST_CONTENT" | grep -q "git_bundle_flattened"; then
	echo "MISS seed-manifest.json still references the removed git_bundle_flattened format"
else
	echo "OK   seed-manifest.json does not reference the removed git_bundle_flattened format"
fi
if echo "$SEED_MANIFEST_CONTENT" | grep -q "git_repo_archive_real_history"; then
	echo "OK   seed-manifest.json records the real-history archive format"
else
	echo "MISS seed-manifest.json missing the real-history archive format record"
fi

echo "=== printer_data config factory seed (Ender-3 V3 KE, auto-updates-camera-complete mission addendum, 2026-07-28) ==="
# Real bug found live: a genuinely wiped printer_data/config left Klipper
# and Moonraker crash-looping forever on FileNotFoundError - nothing had
# ever shipped a seed for these files at a path immune to
# S01persistent-datastores own early, unconditional bind mount of the
# persistent copy over /opt/printer_data. Confirms the dedicated immutable
# seed at /opt/nebulaos-seeds/printer_data-config/ actually landed in the
# packaged image, not just the tracked overlay source.
if debugfs -R "stat /opt/nebulaos-seeds/printer_data-config/printer.cfg" /img/rootfs.ext2 2>&1 | grep -q "Inode:"; then
	echo "OK   /opt/nebulaos-seeds/printer_data-config/printer.cfg is present"
else
	echo "MISS /opt/nebulaos-seeds/printer_data-config/printer.cfg is missing from the packaged seed"
fi
if debugfs -R "stat /opt/nebulaos-seeds/printer_data-config/moonraker.conf" /img/rootfs.ext2 2>&1 | grep -q "Inode:"; then
	echo "OK   /opt/nebulaos-seeds/printer_data-config/moonraker.conf is present"
else
	echo "MISS /opt/nebulaos-seeds/printer_data-config/moonraker.conf is missing from the packaged seed"
fi
if debugfs -R "stat /opt/nebulaos-seeds/printer_data-config/frontend-controls.cfg" /img/rootfs.ext2 2>&1 | grep -q "Inode:"; then
	echo "OK   /opt/nebulaos-seeds/printer_data-config/frontend-controls.cfg is present"
else
	echo "MISS /opt/nebulaos-seeds/printer_data-config/frontend-controls.cfg is missing from the packaged seed"
fi
rm -rf /tmp/printerdata-check
mkdir -p /tmp/printerdata-check/GuppyScreen /tmp/printerdata-check/simpleaf
debugfs -R "dump /opt/nebulaos-seeds/printer_data-config/printer.cfg /tmp/printerdata-check/printer.cfg" /img/rootfs.ext2 >/dev/null 2>&1
debugfs -R "dump /opt/nebulaos-seeds/printer_data-config/moonraker.conf /tmp/printerdata-check/moonraker.conf" /img/rootfs.ext2 >/dev/null 2>&1
debugfs -R "dump /opt/nebulaos-seeds/printer_data-config/frontend-controls.cfg /tmp/printerdata-check/frontend-controls.cfg" /img/rootfs.ext2 >/dev/null 2>&1
debugfs -R "dump /opt/nebulaos-seeds/printer_data-config/GuppyScreen/guppy_cmd.cfg /tmp/printerdata-check/GuppyScreen/guppy_cmd.cfg" /img/rootfs.ext2 >/dev/null 2>&1
# SimpleAF backend integration (2026-07-29, see docs/
# NEBULAOS_SIMPLEAF_BACKEND_INTEGRATION.md) - these 8 files are now what
# printer.cfg actually includes for the print-control/workflow closure;
# frontend-controls.cfg is dumped above only because it is still shipped on
# disk as an unused reference, not because printer.cfg includes it any more.
for simpleaf_f in homing.cfg useful_macros.cfg fan_control.cfg client.cfg start_end.cfg Line_Purge.cfg Smart_Park.cfg bltouch_macro.cfg; do
	debugfs -R "dump /opt/nebulaos-seeds/printer_data-config/simpleaf/$simpleaf_f /tmp/printerdata-check/simpleaf/$simpleaf_f" /img/rootfs.ext2 >/dev/null 2>&1
done
if [ -s /tmp/printerdata-check/printer.cfg ] && grep -q "^#\*# <---------------------- SAVE_CONFIG" /tmp/printerdata-check/printer.cfg 2>/dev/null; then
	echo "MISS packaged printer.cfg seed contains a real SAVE_CONFIG calibration block"
else
	echo "OK   packaged printer.cfg seed contains no SAVE_CONFIG calibration block"
fi
# A bare "key:" is only actually blank if nothing indented follows on the
# next line - moonraker.confs own trusted_clients/cors_domains use this
# multi-line list form legitimately; a naive single-line check flagged
# them as false positives the first time this ran for real. Written to a
# temp file rather than an inline awk single-quote block - this whole
# section already lives inside one big single-quoted docker bash -c
# argument, and a nested single quote here would close that early exactly
# like the apostrophe bugs found earlier in this same mission.
# SimpleAF backend integration (2026-07-29): "gcode:" is explicitly excluded
# below - the gcode_macro directive gcode option is genuinely allowed to be
# blank (a variable-only macro with no action, e.g. the
# [gcode_macro _HOMING_PARAMS] section in simpleaf/homing.cfg), confirmed
# directly against vendor/klipper/klippy/extras/gcode_macro.py, in the
# load_template() function there, which happily wraps an empty string.
# Every other option name is still caught - keep this in sync with the
# identical copy in 04-cross-compile-app-stack.sh.
cat > /tmp/blank-required-option.awk <<'AWKPROG'
{
	if (pending != "") {
		if ($0 !~ /^[ \t]/) { print pending; exit 1 }
		pending = ""
	}
	if ($0 ~ /^[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$/ && $0 !~ /^gcode:[[:space:]]*$/) { pending = $0 }
}
END { if (pending != "") { print pending; exit 1 } }
AWKPROG
blank_required_option() {
	awk -f /tmp/blank-required-option.awk "$1"
}
blank_found=0
for f in /tmp/printerdata-check/printer.cfg /tmp/printerdata-check/moonraker.conf /tmp/printerdata-check/frontend-controls.cfg /tmp/printerdata-check/simpleaf/*.cfg; do
	[ -s "$f" ] || continue
	if ! blank_required_option "$f" >/dev/null; then
		blank_found=1
	fi
done
if [ "$blank_found" = "1" ]; then
	echo "MISS packaged printer.cfg/moonraker.conf/frontend-controls.cfg/simpleaf/*.cfg seed has an option present but syntactically blank"
else
	echo "OK   packaged printer.cfg/moonraker.conf/frontend-controls.cfg/simpleaf/*.cfg seed has no syntactically blank options"
fi

# Print-control config closure validation against the actual packaged
# seed (not just the tracked source) - mainline print-controls mission,
# 2026-07-29, see docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md. The includes
# in printer.cfg are just concatenated here (this codebase only ever uses
# plain literal filenames in its config includes, one level of
# GuppyScreen/ nesting, never glob patterns), so this is a deliberately
# simple closure builder, not a general Klipper config parser. Grep
# patterns below use double quotes only, and the awk program is written
# to a temp file via a quoted heredoc rather than inline - see the
# blank_required_option note above this same docker bash -c block about
# why a literal single quote here would break the outer quoting.
if [ -s /tmp/printerdata-check/printer.cfg ]; then
	# SimpleAF backend integration (2026-07-29, see docs/
	# NEBULAOS_SIMPLEAF_BACKEND_INTEGRATION.md): printer.cfg no longer
	# includes frontend-controls.cfg - simpleaf/client.cfg + simpleaf/
	# start_end.cfg now provide the same required sections instead.
	if grep -q "^\[include simpleaf/client\.cfg\]" /tmp/printerdata-check/printer.cfg && grep -q "^\[include simpleaf/start_end\.cfg\]" /tmp/printerdata-check/printer.cfg; then
		echo "OK   packaged printer.cfg includes simpleaf/client.cfg and simpleaf/start_end.cfg"
	else
		echo "MISS packaged printer.cfg does not include simpleaf/client.cfg and simpleaf/start_end.cfg"
	fi
	cat /tmp/printerdata-check/printer.cfg /tmp/printerdata-check/GuppyScreen/guppy_cmd.cfg /tmp/printerdata-check/simpleaf/*.cfg > /tmp/printerdata-check/closure.txt 2>/dev/null
	vsd_count=$(grep -c -i -E "^\[[[:space:]]*virtual_sdcard[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	pr_count=$(grep -c -i -E "^\[[[:space:]]*pause_resume[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	ds_count=$(grep -c -i -E "^\[[[:space:]]*display_status[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	pause_macro_count=$(grep -c -i -E "^\[[[:space:]]*gcode_macro[[:space:]]+pause[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	resume_macro_count=$(grep -c -i -E "^\[[[:space:]]*gcode_macro[[:space:]]+resume[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	cancel_macro_count=$(grep -c -i -E "^\[[[:space:]]*gcode_macro[[:space:]]+cancel_print[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	closure_ok=1
	if [ "$vsd_count" != "1" ]; then echo "MISS packaged config closure has $vsd_count [virtual_sdcard] sections, need exactly 1"; closure_ok=0; fi
	if [ "$pr_count" != "1" ]; then echo "MISS packaged config closure has $pr_count [pause_resume] sections, need exactly 1"; closure_ok=0; fi
	if [ "$ds_count" != "1" ]; then echo "MISS packaged config closure has $ds_count [display_status] sections, need exactly 1"; closure_ok=0; fi
	if [ "$pause_macro_count" != "1" ]; then echo "MISS packaged config closure has $pause_macro_count [gcode_macro PAUSE] sections, need exactly 1 (Mainsail checks configfile.settings for this section directly)"; closure_ok=0; fi
	if [ "$resume_macro_count" != "1" ]; then echo "MISS packaged config closure has $resume_macro_count [gcode_macro RESUME] sections, need exactly 1 (Mainsail checks configfile.settings for this section directly)"; closure_ok=0; fi
	if [ "$cancel_macro_count" != "1" ]; then echo "MISS packaged config closure has $cancel_macro_count [gcode_macro CANCEL_PRINT] sections, need exactly 1 (Mainsail checks configfile.settings for this section directly)"; closure_ok=0; fi
	if [ "$closure_ok" = "1" ]; then
		echo "OK   packaged config closure has exactly one each of virtual_sdcard/pause_resume/display_status/gcode_macro PAUSE/gcode_macro RESUME/gcode_macro CANCEL_PRINT"
	fi
	cat > /tmp/vsd-path-extract.awk <<'AWKPROG2'
/^\[[[:space:]]*virtual_sdcard[[:space:]]*\]/ { in_vsd = 1; next }
/^\[/ { in_vsd = 0 }
in_vsd && /^[[:space:]]*path[[:space:]]*:/ {
	sub(/^[[:space:]]*path[[:space:]]*:[[:space:]]*/, "")
	gsub(/[[:space:]]+$/, "")
	print
	exit
}
AWKPROG2
	vsd_path=$(awk -f /tmp/vsd-path-extract.awk /tmp/printerdata-check/closure.txt)
	if [ "$vsd_path" = "/opt/printer_data/gcodes" ]; then
		echo "OK   packaged [virtual_sdcard] path is the canonical /opt/printer_data/gcodes"
	else
		echo "MISS packaged [virtual_sdcard] path is $vsd_path, expected /opt/printer_data/gcodes"
	fi
else
	echo "MISS packaged printer.cfg could not be dumped from rootfs.ext2 - cannot validate print-control closure"
fi
rm -rf /tmp/printerdata-check
# Confirms the actual fix logic landed in the packaged init scripts, not
# just the seed content sitting there unused.
S02_CONTENT=$(debugfs -R "cat /etc/init.d/S02nebulaos-namespace" /img/rootfs.ext2 2>/dev/null)
if echo "$S02_CONTENT" | grep -q "seed_printer_data_config"; then
	echo "OK   S02nebulaos-namespace contains the printer_data config seeding logic"
else
	echo "MISS S02nebulaos-namespace is missing the printer_data config seeding logic"
fi
S05_CONTENT=$(debugfs -R "cat /etc/init.d/S05nebulaos-activate" /img/rootfs.ext2 2>/dev/null)
if echo "$S05_CONTENT" | grep -q "config/printer.cfg"; then
	echo "OK   S05nebulaos-activate validates printer_data against the real required files, not just the config directory"
else
	echo "MISS S05nebulaos-activate still validates printer_data against only the config directory - a wiped copy would pass validation empty"
fi

echo "=== obsolete overlay files (must be absent - Buildroots output/target copy is additive-only, see 02-configure-buildroot.sh) ==="
# Real bug found live 2026-07-28: a renamed overlay file (e.g.
# S03nebulaos-factory-seed/S04nebulaos-activate -> S04nebulaos-factory-seed/
# S05nebulaos-activate) leaves the OLD file sitting in Buildroots own
# output/target/ forever unless explicitly cleaned - and it ships in the
# real rootfs right alongside the new one. This is not cosmetic: the old,
# pre-fix activation script sorts earlier and silently wins over the new
# one whenever both are present. rootfs.ext2 and rootfs.squashfs are built
# from the same stale output/target/, so debugfs against rootfs.ext2 here
# does catch a real leftover, not just the tracked overlay source.
# check_absent() is defined once, earlier, right after check() (both used
# from the very first section in this docker block).
check_absent /etc/init.d/S01tmpfs-datastore
check_absent /etc/init.d/S39wifi
check_absent /etc/init.d/S03nebulaos-factory-seed
check_absent /etc/init.d/S04nebulaos-activate

echo "=== SSH/console/recovery (FIRMWARE.md sec 18/21/22/24) ==="
check /usr/sbin/dropbear
check /usr/sbin/wpa_cli
check /etc/init.d/S00revert-safety
check /etc/init.d/S01persistent-datastore
check /etc/init.d/S01wifi
check /etc/nebulaos-stable-mac.sh
check /etc/nebulaos-wifi-power-save.sh
check /usr/libexec/nebulaos-wifi-power-save
check /etc/nebulaos-wifi-boot-wait.sh
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
check /opt/nebulaos-seeds/klipper.tar.gz
check /opt/nebulaos-seeds/moonraker.tar.gz
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
# Production optimization mission, Phase 9 (2026-07-30): this used to spot-
# check hci_uart.ko's architecture - the only loadable kernel module this
# image ever shipped. Bluetooth is now removed entirely (CONFIG_BT is not
# set - see the kernel-modules section above), and nothing else in this
# kernel is built as a loadable module (confirmed live: `lsmod` on the real
# device shows nothing loaded), so there is currently nothing left here to
# spot-check. Left as an empty, documented section rather than deleted
# outright, so a future loadable module addition has an obvious place to
# add its own check back.

echo "== verification complete - review any MISS lines above =="
