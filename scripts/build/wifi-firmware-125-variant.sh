#!/bin/sh
#
# CYW43430 Wi-Fi firmware engineering-test variant (2026-08-08, corrected
# 2026-08-09): stages the Infineon 7.45.98.125 firmware + its OWN matching
# CLM blob into the overlay, overriding what fetch-wifi-firmware.sh
# (control .bin, extracted live from stock) and fetch-linux-firmware-
# clm.sh (control .clm_blob, generic upstream copy) would otherwise place
# at the exact same paths.
#
# 2026-08-09 correction: the .clm_blob override now goes to
# lib/firmware/brcm/brcmfmac43430-sdio.clm_blob - the exact same path
# CONFIG_EXTRA_FIRMWARE embeds into the kernel image (see
# artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config)
# and the exact same path brcmfmac itself requests (confirmed directly
# from source: drivers/net/wireless/broadcom/brcm80211/brcmfmac/sdio.c's
# brcmf_sdio_prepare_fw_request(), fwnames[] = { ..., { ".clm_blob",
# bus->sdiodev->clm_name } }, combined with the "brcm/brcmfmac43430-sdio"
# base name from brcmf_fw_alloc_request()). The previous version staged
# it at lib/firmware/cypress/cyfmac43430-sdio.clm_blob instead - a path
# nothing ever reads before rootfs mount, meaning the .125 candidate was
# never actually tested with its own CLM data available at the point
# brcmfmac requests it. See docs/NEBULAOS_WIFI_125_ENGINEERING_TEST.md
# for the full incident writeup.
#
# THIS IS ENGINEERING-TEST-ONLY. Not one of the 8 accepted baseline
# variants, not wired into apply-qualified-baseline.sh - must be invoked
# explicitly, by hand, for a one-off WIFI-FW-125 test build, never as part
# of a normal ./build.sh run. `revert` restores the normal control
# lookup: the .bin override is removed (fetch-wifi-firmware.sh's own
# stock-extracted copy, already gitignored and staged separately, takes
# over again on the next real build), and the .clm_blob override is
# removed (re-run fetch-linux-firmware-clm.sh to restore the control CLM
# at the same path).
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
# Also applies a small, scoped, TEMPORARY kernel diagnostic (2026-08-09):
# brcmf_c_download_blob()'s own successful clmload_status read
# (drivers/.../brcmfmac/common.c) only ever reaches brcmf_dbg(INFO, ...),
# which compiles to a true no-op (no_printk()) unless CONFIG_BRCMDBG or
# CONFIG_BRCM_TRACING is set - neither is, in this baseline, and enabling
# either would be broad debug logging, explicitly not wanted. Swaps just
# that one call for bphy_err() (already used elsewhere in the same
# function for the two adjacent, always-visible error lines), so a
# genuine clmload_status value reaches dmesg - and therefore S98nebulaos-
# wifi-125-failsafe's own persisted /usr/data diagnostics - without
# enabling any broader driver debug output. Deliberately does NOT use
# `git checkout -- common.c` to reset before patching (unlike wifi-
# roamoff-disable-variant.sh's own pattern for this same file) - that
# would silently wipe ROAMOFF1's already-applied brcmf_roamoff=1 change
# if this script runs after it. Scoped sed within brcmf_c_download_blob()
# only; ROAMOFF1's own change lives near the top of the file, in a
# completely different function, so the two never overlap.
#
# Deliberately does NOT touch:
#   - scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.txt
#     (board NVRAM - stays whatever fetch-wifi-firmware.sh staged from
#     the real device; this script never writes that path)
#   - DT, ROAMOFF1's own module_param default, IRQ priority, power-save,
#     MAC provisioning, regulatory/CLM-country config, SDIO bus config -
#     none of this script's business.
#
# Usage:
#   sh scripts/build/wifi-firmware-125-variant.sh apply /path/to/cyfmac43430-sdio.bin /path/to/cyfmac43430-sdio.clm_blob
#   sh scripts/build/wifi-firmware-125-variant.sh revert

set -eu

ACTION="${1:-}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
BIN_DEST="$REPO_ROOT/scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.bin"
CLM_DEST="$REPO_ROOT/scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.clm_blob"
# Overridable for tests/wifi-firmware-125-variant-tests.sh - real use
# never sets this, so ":=" always resolves to the real vendor path.
COMMON_C="${COMMON_C:-$REPO_ROOT/vendor/x2000_kernel_6.6/kernel/kernel-6.6/drivers/net/wireless/broadcom/brcm80211/brcmfmac/common.c}"
# Engineering-test metadata: the ONE file that actually arms
# S98nebulaos-wifi-125-failsafe (that script is a no-op, by construction,
# whenever this file is absent - true for every normal canonical build).
SENTINEL_DEST="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-wifi-125-test-marker"
CONTROL_BIN_MARKER="$REPO_ROOT/build-work/wifi-firmware-125-variant-control-bin.sha256"
CONTROL_CLM_MARKER="$REPO_ROOT/build-work/wifi-firmware-125-variant-control-clm.sha256"
MARKER="$REPO_ROOT/build-work/wifi-firmware-125-variant-applied.txt"

# Pinned expected hashes of the genuine Infineon release-v5.10.9-2022_0909
# files - verified once, live, against the actual fetched repo (see
# docs/NEBULAOS_WIFI_125_ENGINEERING_TEST.md). apply() refuses anything
# that doesn't match, so a wrong/corrupted/substituted source file can
# never silently become "the .125 variant."
EXPECT_BIN_SHA256=82ed67a211877efa47aff4aab83d6d2d1ccf3d5d0f5c396df97f292ade01de9e
EXPECT_CLM_SHA256=1dbe1a396b68786bb189b7c255318ae546fd2e9d15f70ccc8ecbdc52b6cd4c47

# The exact, unique line inside brcmf_c_download_blob() whose
# success-path status print is currently a compiled-out no-op. Matched
# without anchoring to leading whitespace (kernel source uses tabs;
# matching the fixed substring is more robust than reproducing exact
# indentation by hand). Confirmed unique (grep -c == 1) in the pinned
# kernel source before this script was written.
DIAG_FROM='brcmf_dbg(INFO, "%s=%d\n", statvar, status);'
DIAG_TO='bphy_err(drvr, "ENGINEERING DIAG clmload_status %s=%d\n", statvar, status);'

# GNU sed treats a literal `\n` in both the pattern AND the replacement of
# `s|..|..|` as "match/insert a real newline character" - but the actual
# bytes in the kernel source (and in $DIAG_FROM/$DIAG_TO above) are a
# literal backslash followed by 'n', not a real newline. Real bug found
# writing this script's own test: `grep -qF` (fixed-string, so `\n` really
# does mean two literal bytes there) found the line fine, but the
# subsequent `sed` silently substituted nothing at all, since it was
# hunting for a newline that was never in the file. Doubling every
# backslash before handing the string to sed's regex engine is the
# standard fix - `\\` in a BRE pattern/replacement means one literal
# backslash, so a doubled `\\n` correctly means "backslash then n" again.
sed_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g'
}

apply_diag_patch() {
	[ -f "$COMMON_C" ] || { echo "FATAL: $COMMON_C not found - run 00-fetch-vendor-sources.sh first" >&2; exit 1; }
	if grep -qF "$DIAG_TO" "$COMMON_C"; then
		echo "   (clmload_status diagnostic already applied - idempotent, no-op)"
		return 0
	fi
	grep -qF "$DIAG_FROM" "$COMMON_C" || {
		echo "FATAL: expected line not found in $COMMON_C - kernel source has diverged from what this diagnostic was written against, refusing to guess" >&2
		exit 1
	}
	sed -i "s|$(sed_escape "$DIAG_FROM")|$(sed_escape "$DIAG_TO")|" "$COMMON_C"
	grep -qF "$DIAG_TO" "$COMMON_C" || {
		echo "FATAL: sed substitution did not take effect - $COMMON_C left unmodified, refusing to report success" >&2
		exit 1
	}
	echo "   clmload_status diagnostic applied to common.c (scoped, one line, brcmf_dbg->bphy_err)"
}

revert_diag_patch() {
	[ -f "$COMMON_C" ] || return 0
	if grep -qF "$DIAG_TO" "$COMMON_C"; then
		sed -i "s|$(sed_escape "$DIAG_TO")|$(sed_escape "$DIAG_FROM")|" "$COMMON_C"
		echo "   clmload_status diagnostic reverted in common.c"
	fi
}

# WIFI_125_VARIANT_NO_AUTORUN=1 lets tests/wifi-firmware-125-variant-
# tests.sh source this script to call apply_diag_patch()/revert_diag_patch()
# directly against a fixture COMMON_C, without also running the real
# dispatch below (which requires real pinned-hash-matching firmware files
# and a real vendor kernel checkout).
if [ -z "${WIFI_125_VARIANT_NO_AUTORUN:-}" ]; then

[ -n "$ACTION" ] || { echo "usage: $0 <apply SRC_BIN SRC_CLM|revert>" >&2; exit 1; }

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
		[ -f "$CLM_DEST" ] || {
			echo "FATAL: $CLM_DEST does not exist yet - run scripts/firmware/fetch-linux-firmware-clm.sh first (this script only ever OVERRIDES the control CLM, never creates the control baseline itself)" >&2
			exit 1
		}

		mkdir -p "$REPO_ROOT/build-work"
		# Record the CONTROL .bin/.clm_blob's own hashes before
		# overwriting, so `revert` can prove what it's restoring back to,
		# not just "some other file."
		sha256sum "$BIN_DEST" | cut -d' ' -f1 > "$CONTROL_BIN_MARKER"
		sha256sum "$CLM_DEST" | cut -d' ' -f1 > "$CONTROL_CLM_MARKER"
		cp -f "$SRC_BIN" "$BIN_DEST"
		cp -f "$SRC_CLM" "$CLM_DEST"

		mkdir -p "$(dirname "$SENTINEL_DEST")"
		printf 'WIFI-FW-125 engineering test - see docs/NEBULAOS_WIFI_125_ENGINEERING_TEST.md\n' > "$SENTINEL_DEST"

		echo "== wifi-firmware-125-variant: applying clmload_status diagnostic =="
		apply_diag_patch

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
		if [ -f "$CONTROL_CLM_MARKER" ]; then
			echo "== wifi-firmware-125-variant: reverting - control .clm_blob hash was $(cat "$CONTROL_CLM_MARKER") =="
		fi
		revert_diag_patch
		rm -f "$SENTINEL_DEST"
		rm -f "$CONTROL_BIN_MARKER" "$CONTROL_CLM_MARKER" "$MARKER"
		echo "== wifi-firmware-125-variant: REVERTED =="
		echo "   $SENTINEL_DEST removed - S98nebulaos-wifi-125-failsafe reverts to its normal no-op state"
		echo "   $BIN_DEST left as-is - re-run scripts/build/fetch-wifi-firmware.sh to restore the real control .bin from stock"
		echo "   $CLM_DEST left as-is - re-run scripts/firmware/fetch-linux-firmware-clm.sh to restore the control CLM"
		;;
	*)
		echo "unknown action '$ACTION' - must be 'apply' or 'revert'" >&2
		exit 1
		;;
esac

fi
