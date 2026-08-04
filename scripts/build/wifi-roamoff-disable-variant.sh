#!/bin/sh
# Applies the brcmfmac roamoff-default patch (NebulaOS WiFi/camera IRQ
# contention mission, 2026-08-03 - see
# scripts/build/patches/wifi-roamoff-disable.patch) to the vendor kernel
# checkout.
#
# THIS IS THE ONLY SCRIPT ALLOWED TO TOUCH
#   kernel/kernel-6.6/drivers/net/wireless/broadcom/brcm80211/brcmfmac/common.c
# FROM NOW ON - same overlapping-variant-script discipline as the other
# *-variant.sh scripts.
#
# Background: this printer is physically stationary and never needs to
# roam between APs. brcmfmac's own firmware roaming engine (background
# off-channel scanning to evaluate candidate APs - a firmware-level
# behavior, entirely independent of wpa_supplicant, which has no bgscan
# directive configured here at all) was live-identified as one real,
# machine-side contributor to a small steady rate of WiFi tx failures
# during sustained webcam streaming - on top of the separately-fixed
# USB<->WiFi IRQ priority contention (see
# pinctrl-ownership-fix-variant.sh's sibling mission work the same day -
# no, wrong file, see the S9x IRQ priority init.d script instead).
# brcmfmac is compiled into this kernel (no loadable .ko - lsmod is
# empty), so this could not be live-tested via module reload the way a
# real loadable module's parameters could; it takes effect only via a
# genuine kernel rebuild. Verified from source (cfg80211.c) that roamoff
# only gates WIPHY_FLAG_SUPPORTS_FW_ROAM (the firmware roaming engine
# specifically) - normal connection/association scanning is unaffected.
#
# ROAMOFF0 (default/pristine): baseline brcmfmac, roaming engine enabled
#     (brcmf_roamoff = 0, unchanged from upstream).
# ROAMOFF1: applies scripts/build/patches/wifi-roamoff-disable.patch
#     (brcmf_roamoff = 1 - firmware roaming engine disabled).
#
# Same "always reset to the real git-committed baseline first" pattern as
# the sibling variant scripts.
#
# IMPORTANT: never run this script while any build against this same
# vendor kernel checkout is in flight.
#
# Usage: sh scripts/build/wifi-roamoff-disable-variant.sh <ROAMOFF0|ROAMOFF1>

set -eu

VARIANT="${1:?usage: $0 <ROAMOFF0|ROAMOFF1>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
PATCH="$SCRIPT_DIR/patches/wifi-roamoff-disable.patch"
MARKER="$REPO_ROOT/build-work/wifi-roamoff-disable-variant-applied.txt"

AFFECTED_FILES="
kernel/kernel-6.6/drivers/net/wireless/broadcom/brcm80211/brcmfmac/common.c
"

case "$VARIANT" in
	ROAMOFF0|ROAMOFF1) ;;
	*)
		echo "unknown variant '$VARIANT' - must be one of ROAMOFF0 ROAMOFF1" >&2
		exit 1
		;;
esac

[ -f "$PATCH" ] || {
	echo "FATAL: $PATCH not found" >&2
	exit 1
}

git -C "$KERNEL_DIR" checkout -- $AFFECTED_FILES

if [ "$VARIANT" = "ROAMOFF1" ]; then
	( cd "$KERNEL_DIR" && git apply "$PATCH" )
fi

mkdir -p "$(dirname "$MARKER")"
printf '%s\n' "$VARIANT" > "$MARKER"
echo "== wifi-roamoff-disable-variant: $VARIANT applied =="
