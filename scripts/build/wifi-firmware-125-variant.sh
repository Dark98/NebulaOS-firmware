#!/bin/sh
#
# CYW43430 Wi-Fi firmware engineering-test variant (2026-08-08): stages the
# Infineon 7.45.98.125 firmware + matching CLM blob into the overlay,
# overriding what fetch-wifi-firmware.sh (control .bin, extracted live from
# stock) and Buildroot's own linux-firmware package (control .clm_blob,
# generic upstream copy) would otherwise place at the exact same paths.
#
# THIS IS ENGINEERING-TEST-ONLY. Not one of the 8 accepted baseline
# variants, not wired into apply-qualified-baseline.sh - must be invoked
# explicitly, by hand, for a one-off WIFI-FW-125 test build, never as part
# of a normal ./build.sh run. `revert` restores the normal control
# lookup: the .bin override is removed (fetch-wifi-firmware.sh's own
# stock-extracted copy, already gitignored and staged separately, takes
# over again on the next real build), and the .clm_blob override is
# removed (Buildroot's own linux-firmware package's generic 43430 CLM
# blob takes over again, exactly matching the current shipping baseline -
# see docs/NEBULAOS_WIFI_125_ENGINEERING_TEST.md for the full provenance
# record and control-vs-test hash table).
#
# Source: github.com/Infineon/ifx-linux-firmware, tag
# release-v5.10.9-2022_0909 (resolves to commit
# 4334275b5801bcf5256c3101395e7bc983ce640d - an annotated tag, git
# dereferences it to this commit automatically).
#   firmware/cyfmac43430-sdio.bin
#   firmware/cyfmac43430-sdio.clm_blob
# Runtime version embedded in the .bin itself (confirmed via `strings`,
# not just trusted from the filename): "7.45.98.125 (5b7978c CY) ...
# FWID 01-f420b81d" - byte-for-byte matches this script's own pinned
# SHA256, so a corrupted or substituted source file is caught before
# ever reaching the overlay, independent of the embedded string check.
#
# Deliberately does NOT touch:
#   - scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.txt
#     (board NVRAM - stays whatever fetch-wifi-firmware.sh staged from
#     the real device; this script never writes that path)
#   - kernel, brcmfmac driver, DT, ROAMOFF1, IRQ priority, power-save,
#     MAC provisioning, regulatory/CLM-country config - none of this
#     script's business; it only ever writes the two firmware-blob paths
#     listed above.
#
# Usage:
#   sh scripts/build/wifi-firmware-125-variant.sh apply /path/to/cyfmac43430-sdio.bin /path/to/cyfmac43430-sdio.clm_blob
#   sh scripts/build/wifi-firmware-125-variant.sh revert

set -eu

ACTION="${1:?usage: $0 <apply SRC_BIN SRC_CLM|revert>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
BIN_DEST="$REPO_ROOT/scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.bin"
CLM_DEST="$REPO_ROOT/scripts/build/overlay/lib/firmware/cypress/cyfmac43430-sdio.clm_blob"
# Engineering-test metadata: the ONE file that actually arms
# S98nebulaos-wifi-125-failsafe (that script is a no-op, by construction,
# whenever this file is absent - true for every normal canonical build).
SENTINEL_DEST="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-wifi-125-test-marker"
CONTROL_BIN_MARKER="$REPO_ROOT/build-work/wifi-firmware-125-variant-control-bin.sha256"
MARKER="$REPO_ROOT/build-work/wifi-firmware-125-variant-applied.txt"

# Pinned expected hashes of the genuine Infineon release-v5.10.9-2022_0909
# files - verified once, live, against the actual fetched repo (see
# docs/NEBULAOS_WIFI_125_ENGINEERING_TEST.md). apply() refuses anything
# that doesn't match, so a wrong/corrupted/substituted source file can
# never silently become "the .125 variant."
EXPECT_BIN_SHA256=82ed67a211877efa47aff4aab83d6d2d1ccf3d5d0f5c396df97f292ade01de9e
EXPECT_CLM_SHA256=1dbe1a396b68786bb189b7c255318ae546fd2e9d15f70ccc8ecbdc52b6cd4c47

case "$ACTION" in
	apply)
		SRC_BIN="${2:?usage: $0 apply SRC_BIN SRC_CLM}"
		SRC_CLM="${3:?usage: $0 apply SRC_BIN SRC_CLM}"

		[ -f "$SRC_BIN" ] || { echo "FATAL: $SRC_BIN not found" >&2; exit 1; }
		[ -f "$SRC_CLM" ] || { echo "FATAL: $SRC_CLM not found" >&2; exit 1; }

		actual_bin=$(sha256sum "$SRC_BIN" | cut -d' ' -f1)
		actual_clm=$(sha256sum "$SRC_CLM" | cut -d' ' -f1)
		[ "$actual_bin" = "$EXPECT_BIN_SHA256" ] || {
			echo "FATAL: $SRC_BIN sha256 $actual_bin does not match pinned $EXPECT_BIN_SHA256 - refusing to stage an unverified binary" >&2
			exit 1
		}
		[ "$actual_clm" = "$EXPECT_CLM_SHA256" ] || {
			echo "FATAL: $SRC_CLM sha256 $actual_clm does not match pinned $EXPECT_CLM_SHA256 - refusing to stage an unverified binary" >&2
			exit 1
		}

		[ -f "$BIN_DEST" ] || {
			echo "FATAL: $BIN_DEST does not exist yet - run scripts/build/fetch-wifi-firmware.sh first (this script only ever OVERRIDES the control .bin, never creates the control baseline itself)" >&2
			exit 1
		}

		mkdir -p "$REPO_ROOT/build-work"
		# Record the CONTROL .bin's own hash before overwriting it, so
		# `revert` can prove it actually restored the exact pre-variant
		# bytes, not just "some other file."
		sha256sum "$BIN_DEST" | cut -d' ' -f1 > "$CONTROL_BIN_MARKER"
		cp -f "$SRC_BIN" "$BIN_DEST"

		mkdir -p "$(dirname "$CLM_DEST")"
		cp -f "$SRC_CLM" "$CLM_DEST"

		mkdir -p "$(dirname "$SENTINEL_DEST")"
		printf 'WIFI-FW-125 engineering test - see docs/NEBULAOS_WIFI_125_ENGINEERING_TEST.md\n' > "$SENTINEL_DEST"

		printf 'WIFI-FW-125\n' > "$MARKER"
		echo "== wifi-firmware-125-variant: APPLIED =="
		echo "   $BIN_DEST -> $(sha256sum "$BIN_DEST" | cut -d' ' -f1)"
		echo "   $CLM_DEST -> $(sha256sum "$CLM_DEST" | cut -d' ' -f1)"
		echo "   $SENTINEL_DEST created - arms S98nebulaos-wifi-125-failsafe"
		echo "   NVRAM (.txt) untouched - control baseline value preserved"
		;;
	revert)
		if [ -f "$CONTROL_BIN_MARKER" ]; then
			echo "== wifi-firmware-125-variant: reverting - control .bin hash was $(cat "$CONTROL_BIN_MARKER") =="
		fi
		rm -f "$CLM_DEST"
		rmdir "$(dirname "$CLM_DEST")" 2>/dev/null || true
		rm -f "$SENTINEL_DEST"
		rm -f "$CONTROL_BIN_MARKER" "$MARKER"
		echo "== wifi-firmware-125-variant: REVERTED =="
		echo "   $CLM_DEST removed - Buildroot's own linux-firmware package supplies the control CLM again"
		echo "   $SENTINEL_DEST removed - S98nebulaos-wifi-125-failsafe reverts to its normal no-op state"
		echo "   $BIN_DEST left as-is - re-run scripts/build/fetch-wifi-firmware.sh to restore the real control .bin from stock"
		;;
	*)
		echo "unknown action '$ACTION' - must be 'apply' or 'revert'" >&2
		exit 1
		;;
esac
