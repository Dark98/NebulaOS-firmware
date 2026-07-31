#!/bin/sh
#
# Alpha baseline freeze mission (2026-08-01): authoritative artifact-level
# proof that a built image actually contains the NEBULAOS-ALPHA-MAX-RT
# composition (W3 SDIO + R1 PREEMPT_RT + P1 Wi-Fi power-save-off +
# C2 camera idle-pause + CID-derived MAC + c03757e factory-seed fix),
# rather than trusting a source-level marker, a test suite's exit status,
# or a build command's own exit code.
#
# Real motivation: the first Alpha-Max-RT build attempt this session
# selected W3+R1 correctly at the source level, but a real defect (test
# suites resetting the real tracked files to W0/R0 - see
# tests/variant-state-preservation-tests.sh) silently discarded that
# selection before the build ever ran. The build's own exit code was 0
# and every existing check passed; only direct inspection of the built
# kernel.config/DTS caught it. This script makes that direct inspection
# a first-class, repeatable, build-failing gate instead of something
# done ad hoc after the fact.
#
# Usage: sh scripts/build/assert-alpha-baseline.sh [artifact-dir]
#   artifact-dir defaults to artifacts/buildroot-halley5-v30-image
#   (the direct build output - run this right after 05-final-build.sh,
#   before or alongside 06-verify.sh, and before packaging).
#
# Exits non-zero if ANY required baseline property is missing.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
ART="${1:-$REPO_ROOT/artifacts/buildroot-halley5-v30-image}"

FAIL=0
ok() { echo "OK   $1"; }
bad() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }
require_line() {
	# $1: file, $2: exact line/pattern (grep -F), $3: description
	if grep -qF "$2" "$1" 2>/dev/null; then
		ok "$3"
	else
		bad "$3 (expected to find '$2' in $1)"
	fi
}
require_absent() {
	# $1: file, $2: pattern (grep -F), $3: description
	if grep -qF "$2" "$1" 2>/dev/null; then
		bad "$3 (found forbidden '$2' in $1)"
	else
		ok "$3"
	fi
}

echo "=== Alpha baseline composition assertions: $ART ==="

for f in xImage rootfs.squashfs kernel.config halley5_v30.dts build-manifest.txt buildroot.config; do
	[ -f "$ART/$f" ] || { bad "$ART/$f is missing entirely - cannot assert composition"; }
done
if [ "$FAIL" -gt 0 ]; then
	echo "=== assertion aborted: required artifact files missing ==="
	exit 1
fi

echo "--- kernel config ---"
require_line "$ART/kernel.config" "CONFIG_PREEMPT_RT=y" "CONFIG_PREEMPT_RT=y selected"
require_line "$ART/kernel.config" "CONFIG_HZ=100" "CONFIG_HZ=100 unchanged"
if grep -qxF "CONFIG_PREEMPT=y" "$ART/kernel.config" 2>/dev/null; then
	bad "plain CONFIG_PREEMPT=y is selected instead of/alongside CONFIG_PREEMPT_RT=y"
else
	ok "plain CONFIG_PREEMPT=y is not selected"
fi
for dep in CONFIG_MMC CONFIG_BRCMFMAC CONFIG_USB_DWC2; do
	if grep -qE "^${dep}=[ym]" "$ART/kernel.config" 2>/dev/null; then
		ok "$dep still enabled (runtime dependency for the printer stack)"
	else
		bad "$dep is not enabled - required by the existing printer stack"
	fi
done

echo "--- device tree (SDIO / W3) ---"
DTS="$ART/halley5_v30.dts"
msc1_block() { sed -n '/^&msc1 {/,/^};/p' "$DTS"; }
msc1_props=$(msc1_block | grep -E 'cap-sdio-irq;|cap-sd-highspeed;|cap-mmc-highspeed;')
if printf '%s' "$msc1_props" | grep -qF 'cap-sdio-irq;'; then ok "cap-sdio-irq present"; else bad "cap-sdio-irq missing"; fi
if printf '%s' "$msc1_props" | grep -qF 'cap-sd-highspeed;'; then ok "cap-sd-highspeed present"; else bad "cap-sd-highspeed missing"; fi
if printf '%s' "$msc1_props" | grep -qF 'cap-mmc-highspeed;'; then bad "cap-mmc-highspeed still present (W3 must remove it)"; else ok "cap-mmc-highspeed absent"; fi

echo "--- device tree (invariants that must never change) ---"
msc1_text=$(msc1_block)
for prop in 'max-frequency = <100000000>;' 'bus-width = <4>;' 'voltage-ranges = <1800 3300>;' 'vmmc-supply = <&wifi_bt_power>;' 'wlan-reg-on-gpios = <&gpd 4 GPIO_ACTIVE_HIGH INGENIC_GPIO_NOBIAS>;' 'pinctrl-0 = <&msc1_4bit>;' 'non-removable;'; do
	if printf '%s' "$msc1_text" | grep -qF "$prop"; then
		ok "msc1 invariant unchanged: $prop"
	else
		bad "msc1 invariant changed or missing: $prop"
	fi
done
# Compared against the git-tracked baseline reference DTS (which every
# W-variant script leaves untouched by design) rather than a hardcoded
# string here - msc0 must be byte-identical to that reference regardless
# of which SDIO/preemption variant this artifact represents.
BASELINE_DTS="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5_v30.dts"
msc0_actual=$(sed -n '/^&msc0 {/,/^};/p' "$DTS")
msc0_baseline=$(sed -n '/^&msc0 {/,/^};/p' "$BASELINE_DTS" 2>/dev/null)
if [ -n "$msc0_baseline" ] && [ "$msc0_actual" = "$msc0_baseline" ]; then
	ok "msc0 (eMMC boot storage) byte-identical to the tracked baseline reference DTS"
else
	bad "msc0 (eMMC boot storage) differs from the tracked baseline reference DTS - must NEVER be touched by any Wi-Fi variant"
fi

echo "--- Wi-Fi (P1, CID MAC, fixed association, country) ---"
require_line "$REPO_ROOT/scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.txt" "ccode=CN" "ccode=CN unchanged in NVRAM"
for expected_hash_field in wifi_firmware_sha256 wifi_nvram_sha256 regulatory_db_sha256; do
	if grep -q "^${expected_hash_field}=" "$ART/build-manifest.txt" 2>/dev/null; then
		ok "$expected_hash_field recorded in manifest"
	else
		bad "$expected_hash_field missing from manifest"
	fi
done

echo "--- rootfs contents (extracting, this takes a moment) ---"
ROOTFS_EXTRACT=$(mktemp -d)
if unsquashfs -q -d "$ROOTFS_EXTRACT/root" -f "$ART/rootfs.squashfs" >/dev/null 2>&1; then
	ok "rootfs.squashfs extracted for inspection"
else
	bad "rootfs.squashfs failed to extract - cannot inspect contents"
	rm -rf "$ROOTFS_EXTRACT"
	echo ""
	echo "$FAIL assertion failure(s)"
	exit 1
fi
R="$ROOTFS_EXTRACT/root"

# Wi-Fi
[ -f "$R/etc/nebulaos-stable-mac.sh" ] && ok "CID-derived stable-MAC script present" || bad "CID-derived stable-MAC script missing"
if grep -q "nebulaos_stabilize_iface_mac" "$R/etc/init.d/S01wifi" 2>/dev/null; then
	ok "stable-MAC boot integration present in S01wifi"
else
	bad "stable-MAC boot integration missing from S01wifi"
fi
[ -f "$R/etc/nebulaos-wifi-power-save.sh" ] && ok "Wi-Fi power-save script present" || bad "Wi-Fi power-save script missing"
if grep -q "^\s*sleep 2\s*$\|nebulaos_wifi_boot_wait" "$R/etc/init.d/S01wifi" 2>/dev/null; then
	ok "fixed association sequence call site present in S01wifi (default path, not event-driven-forced)"
else
	bad "expected fixed-association call site not found in S01wifi"
fi
for f in "$R/lib/firmware/brcm/brcmfmac43430-sdio.bin" "$R/lib/firmware/brcm/brcmfmac43430-sdio.txt" "$R/lib/firmware/regulatory.db"; do
	[ -f "$f" ] && ok "$(basename "$f") present in rootfs" || bad "$(basename "$f") missing from rootfs"
done
if [ -f "$R/lib/firmware/brcm/brcmfmac43430-sdio.txt" ]; then
	require_line "$R/lib/firmware/brcm/brcmfmac43430-sdio.txt" "ccode=CN" "packaged NVRAM still has ccode=CN"
fi
grep -rE '45010044473430303801d7ce3f2c9a00|16:3b:5d:14:20:90|fc:ee:11:00:4c:14' "$R/etc" "$R/usr" 2>/dev/null > "$ROOTFS_EXTRACT/leaked-identifiers.txt"
if [ -s "$ROOTFS_EXTRACT/leaked-identifiers.txt" ]; then
	bad "a unit-specific CID or MAC appears to be hardcoded in the image: $(cat "$ROOTFS_EXTRACT/leaked-identifiers.txt")"
else
	ok "no unit-specific CID or MAC hardcoded in the image"
fi

# Camera (C2)
[ -f "$R/etc/nebulaos-camera-idle-controller.sh" ] && ok "C2 camera idle controller present" || bad "C2 camera idle controller missing"
[ -f "$R/etc/init.d/S51nebulaos-camera-idle-controller" ] && ok "C2 init script present" || bad "C2 init script missing"
if grep -q "^RESOLUTION=1920x1080" "$R/etc/init.d/S50webcam" 2>/dev/null; then
	ok "camera active resolution (1920x1080) retained"
else
	bad "camera active resolution (1920x1080) not found in S50webcam"
fi
if grep -q "^DESIRED_FPS=30" "$R/etc/init.d/S50webcam" 2>/dev/null; then
	ok "camera active fps (30) retained as default"
else
	bad "camera active fps (30) default not found in S50webcam"
fi
require_line "$R/etc/nebulaos-camera-idle-controller.sh" "NEBULAOS_CAMERA_IDLE_GRACE_SAMPLES" "camera idle grace-period mechanism present"
require_line "$R/etc/nebulaos-camera-idle-controller.sh" "/pause" "ustreamer /pause integration present"
require_line "$R/etc/nebulaos-camera-idle-controller.sh" "/resume" "ustreamer /resume integration present"
if grep -q "nebulaos_camera_idle_run_loop\|resume" "$R/etc/init.d/S51nebulaos-camera-idle-controller" 2>/dev/null; then
	ok "fail-safe resume-on-stop behavior present in the init script"
else
	bad "fail-safe resume-on-stop behavior not found in the init script"
fi

# Factory seed (c03757e)
if grep -q "dirty_exclude" "$R/etc/init.d/S04nebulaos-factory-seed" 2>/dev/null; then
	ok "c03757e dirty_exclude fix present in S04nebulaos-factory-seed"
else
	bad "c03757e dirty_exclude fix missing from S04nebulaos-factory-seed"
fi
[ -f "$R/opt/nebulaos-seeds/klipper-venv-seed.tar.gz" ] && ok "klipper-venv-seed.tar.gz present" || bad "klipper-venv-seed.tar.gz missing"
[ -f "$R/opt/nebulaos-seeds/moonraker-venv-seed.tar.gz" ] && ok "moonraker-venv-seed.tar.gz present" || bad "moonraker-venv-seed.tar.gz missing"
if grep -q "python3 -m venv --system-site-packages" "$R/etc/init.d/S04nebulaos-factory-seed" 2>/dev/null; then
	ok "on-device venv-creation fallback path retained"
else
	bad "on-device venv-creation fallback path missing"
fi

# Existing accepted optimizations
grep -q "^BR2_TARGET_ROOTFS_SQUASHFS4_ZSTD=y" "$ART/buildroot.config" 2>/dev/null \
	&& ok "Zstandard SquashFS selected" || bad "Zstandard SquashFS not selected"
grep -q "^BR2_PACKAGE_PYTHON3_PYC_ONLY=y" "$ART/buildroot.config" 2>/dev/null \
	&& ok "Python bytecode-only precompilation selected" || bad "Python bytecode-only precompilation not selected"
grep -q "^BR2_STRIP_strip=y" "$ART/buildroot.config" 2>/dev/null \
	&& ok "native extension stripping enabled" || bad "native extension stripping not enabled"
grep -qE "^# BR2_PACKAGE_DBUS is not set" "$ART/buildroot.config" 2>/dev/null \
	&& ok "D-Bus package excluded" || bad "D-Bus package is enabled (should remain excluded)"
find "$R" -iname "*modemmanager*" 2>/dev/null | grep -q . \
	&& bad "a ModemManager binary/file was found in the rootfs (should remain removed)" \
	|| ok "no ModemManager binary/file found in the rootfs"
[ -f "$R/usr/sbin/dropbear" ] && ok "Dropbear present (persistent host keys handled elsewhere)" || bad "Dropbear missing"
[ -f "$R/etc/ota_marker.sh" ] && ok "OTA marker mechanism (update/rollback support) present" || bad "OTA marker mechanism missing"
[ -f "$R/etc/init.d/S00revert-safety" ] && [ -f "$R/etc/init.d/S99confirm-good" ] \
	&& ok "revert-safety/confirm-good rollback pair present" || bad "revert-safety/confirm-good rollback pair incomplete"

rm -rf "$ROOTFS_EXTRACT"

echo "--- staleness ---"
build_ts=$(grep '^built_at=' "$ART/build-manifest.txt" 2>/dev/null | cut -d= -f2)
if [ -n "$build_ts" ]; then
	ok "build-manifest.txt built_at=$build_ts recorded"
else
	bad "build-manifest.txt has no built_at timestamp"
fi

echo ""
echo "=== $FAIL assertion failure(s) ==="
[ "$FAIL" -eq 0 ]
