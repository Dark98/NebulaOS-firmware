#!/bin/sh
# Extracts the stock CYW43438/BCM43430 WiFi firmware + board NVRAM live off
# a running stock device (read-only) and stages them under
# scripts/build/overlay/lib/firmware/brcm/ using the filenames brcmfmac
# actually requests, ready for 02-configure-buildroot.sh to pick up.
#
# Why an extraction step instead of committing the files (FIRMWARE.md sec
# 53): these are Cypress/Broadcom proprietary binary firmware blobs with no
# accompanying license file found anywhere on the device - unlike this
# project's own hand-written overlay content, there's no clear basis to
# redistribute them through this repo. Running this script against your own
# device, for your own build, is a completely different question from
# publishing the blob - so the build depends on this script, not on a
# committed binary. The NVRAM (.txt) is plain board-configuration text with
# no device-unique data (its own real macaddr field is an explicitly-labeled
# placeholder - the real per-device MAC comes from elsewhere at runtime, not
# from this file), but it's still vendor-authored board bring-up data, so
# it's treated the same way for consistency rather than splitting hairs.
#
# Confirmed real filenames (FIRMWARE.md sec 45's own boot log): stock's
# cywdhd.ko reads the SDIO card's own CIS tuples at runtime and picks
# /lib/firmware/wifi_bcm/cyw43438-7.46.58.13.bin +
# /lib/firmware/wifi_bcm/nvram_azw372.txt specifically for this board's real
# Azurewave-branded module (confirmed via the "Got the chip vendor, tuple
# code=0x81, Azurewave Module" line already captured in this investigation) -
# not the sibling ap6212a files also present on the device, which are for a
# different, unused module variant.
#
# Usage: STOCK_ROOT_PW=... ./scripts/build/fetch-wifi-firmware.sh [user@host]
# Defaults to root@192.168.0.231 (this project's own dev unit, see NETWORKING.md).

set -e

HOST="${1:-root@192.168.0.231}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DEST="$SCRIPT_DIR/overlay/lib/firmware/brcm"

mkdir -p "$DEST"

echo "Fetching stock WiFi firmware + NVRAM from $HOST (read-only) ..."
scp -o StrictHostKeyChecking=accept-new \
	"$HOST:/lib/firmware/wifi_bcm/cyw43438-7.46.58.13.bin" \
	"$DEST/brcmfmac43430-sdio.bin"
scp -o StrictHostKeyChecking=accept-new \
	"$HOST:/lib/firmware/wifi_bcm/nvram_azw372.txt" \
	"$DEST/brcmfmac43430-sdio.txt"

echo
echo "Staged:"
sha256sum "$DEST/brcmfmac43430-sdio.bin" "$DEST/brcmfmac43430-sdio.txt"
echo
echo "These two files are gitignored (see .gitignore) - re-run this script"
echo "after a fresh checkout rather than expecting them to already be present."
