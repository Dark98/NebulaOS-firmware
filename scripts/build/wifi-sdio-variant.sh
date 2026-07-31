#!/bin/sh
# Applies one of the Wi-Fi SDIO device-tree qualification variants
# (W0/W1/W2/W3) to the mounted kernel source tree's halley5_v30.dts, for
# the later hardware A/B plan defined in docs/NEBULAOS_CAMERA_USB_RT_
# SOURCE_ANALYSIS.md sec 18.6-7/18.18 (pre-qualification mission Phase A4,
# 2026-07-31).
#
#   W0: baseline - msc1 unchanged from its current committed state
#       (already includes the stable-MAC fix from Phase A3, which lives
#       entirely in userspace and is unaffected by any of this).
#   W1: W0 + cap-sdio-irq added (lets the SDIO core use in-band IRQ
#       instead of polling - the generic sdhci core already implements
#       the enable_sdio_irq/ack_sdio_irq ops this needs, unused only
#       because this one DT boolean is missing).
#   W2: W0 + cap-mmc-highspeed replaced with cap-sd-highspeed (the
#       generic MMC core's SDIO high-speed-switch path checks
#       MMC_CAP_SD_HIGHSPEED specifically; the currently-set capability
#       is for eMMC/MMC cards and is never consulted for an SDIO card,
#       so high-speed mode negotiation for the Wi-Fi chip is currently
#       never attempted at all).
#   W3: W0 + both W1 and W2.
#
# Deliberately scoped to ONLY the &msc1 node (Wi-Fi), never msc0 (the
# real eMMC boot storage) or msc2 (SD slot, disabled) - both msc0 and
# msc1 carry a verbatim-identical `cap-mmc-highspeed;` line, so a naive
# whole-file substitution would incorrectly also touch the boot storage
# node. Uses sed's own /pattern/,/pattern/ range addressing (re-evaluated
# fresh against current file content on every invocation) rather than
# precomputed line numbers, so repeated variant switches never drift out
# of sync with a previous edit's line-count changes.
#
# Idempotent and always starts from the real, git-committed baseline
# (`git checkout` inside the vendor tree) before applying the requested
# variant, so variants can be switched back and forth with zero
# accumulated drift. Does not commit anything to the kernel fork's own
# git history - these are exploratory, may-all-be-rejected experiments;
# only a variant that passes real hardware A/B testing (Phase B5) becomes
# a real, reviewed commit on the fork afterward, matching this project's
# own "every real change is one reviewable commit" convention.
#
# Usage: sh scripts/build/wifi-sdio-variant.sh <W0|W1|W2|W3>

set -eu

VARIANT="${1:?usage: $0 <W0|W1|W2|W3>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
DTS_REL="kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts"
DTS="$KERNEL_DIR/$DTS_REL"
MARKER="$REPO_ROOT/build-work/wifi-sdio-variant-applied.txt"

case "$VARIANT" in
	W0|W1|W2|W3) ;;
	*)
		echo "unknown variant '$VARIANT' - must be one of W0 W1 W2 W3" >&2
		exit 1
		;;
esac

[ -f "$DTS" ] || {
	echo "FATAL: $DTS not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
}

# Always reset to the real, git-committed baseline first - never trust
# that a previous invocation's edits were cleanly undone.
git -C "$KERNEL_DIR" checkout -- "$DTS_REL"

if ! grep -q '^&msc1 {' "$DTS"; then
	echo "FATAL: could not find the &msc1 node in $DTS - has the board DTS changed?" >&2
	exit 1
fi

apply_cap_sdio_irq() {
	if sed -n '/^&msc1 {/,/^};/p' "$DTS" | grep -q 'cap-sdio-irq;'; then
		return 0
	fi
	sed -i '/^&msc1 {/,/^};/{
		s/^\(\tcap-mmc-highspeed;\)$/\1\n\tcap-sdio-irq;/
	}' "$DTS"
}

apply_sd_highspeed_swap() {
	sed -i '/^&msc1 {/,/^};/{
		s/^\tcap-mmc-highspeed;$/\tcap-sd-highspeed;/
	}' "$DTS"
}

case "$VARIANT" in
	W0) : ;;
	W1) apply_cap_sdio_irq ;;
	W2) apply_sd_highspeed_swap ;;
	W3) apply_cap_sdio_irq; apply_sd_highspeed_swap ;;
esac

mkdir -p "$(dirname "$MARKER")"
printf '%s\n' "$VARIANT" > "$MARKER"

echo "== wifi-sdio-variant: $VARIANT applied =="
echo "== msc1 node after applying $VARIANT: =="
sed -n '/^&msc1 {/,/^};/p' "$DTS"
