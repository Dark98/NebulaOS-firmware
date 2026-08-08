#!/bin/sh
# Stages cypress/cyfmac43430-sdio.clm_blob (as brcm/brcmfmac43430-sdio.clm_blob,
# matching the relative path brcmfmac actually requests) under scripts/build/
# overlay/lib/firmware/ so CONFIG_EXTRA_FIRMWARE can bake it directly into
# the kernel image (see artifacts/buildroot-halley5-v30-image/
# halley5-nebulaos-fragment.config) - exactly the same rootfs-not-mounted-
# yet timing gap already fixed for the .bin/.txt/regulatory.db entries in
# that same file (see this script's own header comment there), just never
# closed for the CLM blob until now.
#
# CYW43430 Wi-Fi firmware engineering test (2026-08-09, see docs/
# NEBULAOS_WIFI_125_ENGINEERING_TEST.md): live diagnostics from the
# WIFI-FW-125 test boot proved brcmfmac's early CLM request fails with the
# identical "error -2" on every single boot, control or test - confirmed
# from the actual pinned kernel source (this exact rootfs-timing class of
# bug) rather than assumed. Control's own 7.46.58.13 firmware happens to be
# built without the clm_min/noclminc flags (confirmed via `strings` on the
# real .bin), so it tolerates the missing external CLM with just a
# warning; a firmware build that DOES depend on external CLM data (like the
# .125 candidate) never brings the interface up at all when this request
# fails. Closing this gap benefits every WiFi firmware this platform ever
# loads, not just the one candidate that happened to expose it.
#
# Deliberately mirrors the exact version Buildroot's own linux-firmware
# package pins (vendor/buildroot-x2000/package/linux-firmware/
# linux-firmware.mk, LINUX_FIRMWARE_VERSION), fetched from the same
# BR2_KERNEL_MIRROR-relative path, so the copy staged here and the copy
# Buildroot installs into the rootfs (BR2_PACKAGE_LINUX_FIRMWARE_CYPRESS_
# CYW43XXX, already enabled) are byte-identical - not two independently-
# sourced CLM blobs that happen to agree today. Verified live: this
# script's own pinned CLM_SHA256 matches the real device's already-running
# /lib/firmware/cypress/cyfmac43430-sdio.clm_blob exactly.
#
# Unlike wireless-regdb (ISC), Cypress's own LICENCE.cypress is a EULA, not
# a permissive open-source license - but it explicitly grants "a
# non-exclusive, non-transferable license... to reproduce and distribute
# the Software in object code form... solely for use in connection with
# Cypress integrated circuit products," which this device's real CYW43430
# chip squarely is. Treated the same cautious way as the proprietary WiFi
# .bin/.txt fetch-wifi-firmware.sh handles regardless: fetched and
# hash-verified at build time, never committed as a binary in git history
# (see .gitignore).
#
# Usage: ./scripts/firmware/fetch-linux-firmware-clm.sh [cached-tarball-path]
# With no argument, downloads fresh. With an argument, verifies and uses
# that local file instead of hitting the network (offline-cache path) -
# still checked against the same pinned hash either way.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
DEST="$REPO_ROOT/scripts/build/overlay/lib/firmware/brcm"

# Pinned to match vendor/buildroot-x2000/package/linux-firmware/
# linux-firmware.mk exactly - keep these two in sync if that package's
# version ever changes.
LINUX_FIRMWARE_VERSION="20231030"
LINUX_FIRMWARE_MIRROR="https://cdn.kernel.org/pub/linux/kernel/firmware"
LINUX_FIRMWARE_TARBALL="linux-firmware-${LINUX_FIRMWARE_VERSION}.tar.xz"

# Fixed hashes for the exact upstream release - computed once, directly,
# from a real download of this exact URL (not copied from an unverified
# third party). A version bump means re-deriving these deliberately, not
# editing them to make a mismatch go away.
TARBALL_SHA256="c98d200fc4a3120de1a594713ce34e135819dff23e883a4ed387863ba25679c7"
CLM_SHA256="3376b9c9b32d16bf762e21c7fafb665365070ae240d092498d0d1987c22022aa"
LICENSE_SHA256="ae0db6cc4db33941148df0f67de53e76a77b1b5a46b3165edb7040aa2750015f"

die() {
	echo "ABORT: $1" >&2
	exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

TARBALL_PATH="$WORK/$LINUX_FIRMWARE_TARBALL"

if [ -n "$1" ]; then
	echo "Using cached tarball: $1"
	[ -f "$1" ] || die "cached tarball $1 does not exist"
	cp "$1" "$TARBALL_PATH"
else
	echo "Fetching $LINUX_FIRMWARE_MIRROR/$LINUX_FIRMWARE_TARBALL ..."
	if command -v wget >/dev/null 2>&1; then
		wget -q -O "$TARBALL_PATH" "$LINUX_FIRMWARE_MIRROR/$LINUX_FIRMWARE_TARBALL" || die "download failed"
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$TARBALL_PATH" "$LINUX_FIRMWARE_MIRROR/$LINUX_FIRMWARE_TARBALL" || die "download failed"
	else
		die "neither wget nor curl is available"
	fi
fi

ACTUAL_TARBALL_SHA256=$(sha256sum "$TARBALL_PATH" | awk '{print $1}')
[ "$ACTUAL_TARBALL_SHA256" = "$TARBALL_SHA256" ] || \
	die "tarball sha256 mismatch: got $ACTUAL_TARBALL_SHA256, expected $TARBALL_SHA256 - refusing to use an unverified/stale/tampered file"

# Extract only the two files actually needed - the full tarball is ~300MB
# of firmware for hardware this device doesn't have.
SRC_DIR="linux-firmware-$LINUX_FIRMWARE_VERSION"
tar xf "$TARBALL_PATH" -C "$WORK" \
	"$SRC_DIR/cypress/cyfmac43430-sdio.clm_blob" \
	"$SRC_DIR/LICENCE.cypress"
SRC="$WORK/$SRC_DIR"
[ -d "$SRC" ] || die "expected directory $SRC not found after extraction"

for pair in "cypress/cyfmac43430-sdio.clm_blob:$CLM_SHA256" "LICENCE.cypress:$LICENSE_SHA256"; do
	f="${pair%%:*}"
	expect="${pair##*:}"
	[ -f "$SRC/$f" ] || die "$f missing from extracted tarball"
	actual=$(sha256sum "$SRC/$f" | awk '{print $1}')
	[ "$actual" = "$expect" ] || die "$f sha256 mismatch: got $actual, expected $expect"
done

mkdir -p "$DEST"
cp "$SRC/cypress/cyfmac43430-sdio.clm_blob" "$DEST/brcmfmac43430-sdio.clm_blob"
cp "$SRC/LICENCE.cypress" "$DEST/brcmfmac43430-sdio.clm_blob.LICENCE"

echo
echo "Staged (linux-firmware $LINUX_FIRMWARE_VERSION cypress/cyfmac43430-sdio.clm_blob, hash verified):"
sha256sum "$DEST/brcmfmac43430-sdio.clm_blob"
echo
echo "This is gitignored (see .gitignore) - re-run this script after a fresh"
echo "checkout, or whenever CONFIG_EXTRA_FIRMWARE's staged copy needs refreshing,"
echo "rather than expecting it to already be present."
