#!/bin/sh
# Clone/download every third-party source this build needs, pinned to the
# exact refs this project used. See FIRMWARE.md for why each one was chosen.
#
# 2026-08-07 baseline-repair mission: pins now live in one authoritative
# file, manifests/dependencies.conf, sourced below - not scattered as
# hardcoded values across this script. See that file's own header for the
# reasoning and the format.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
VENDOR="$REPO_ROOT/vendor"
MANIFEST="$REPO_ROOT/manifests/dependencies.conf"

[ -f "$MANIFEST" ] || {
	echo "FATAL: $MANIFEST not found - this is the one authoritative dependency pin file, required to build at all" >&2
	exit 1
}
. "$MANIFEST"

require_pin() {
	var_name="$1"
	eval "val=\${$var_name:-}"
	if [ -z "$val" ] || [ "$val" = "UNPINNED_MUST_SET_BEFORE_BUILD" ]; then
		echo "FATAL: $var_name is missing or unset in $MANIFEST - every dependency must have a real pin, no defaults" >&2
		exit 1
	fi
}

for required in KERNEL_REPO KERNEL_BRANCH KERNEL_PIN BUILDROOT_REPO BUILDROOT_PIN \
	PELLCORP_CREALITY_REPO PELLCORP_CREALITY_PIN KLIPPER_REPO KLIPPER_BRANCH KLIPPER_PIN \
	MOONRAKER_REPO MOONRAKER_PIN K1_USTREAMER_REPO K1_USTREAMER_PIN \
	V4L_UTILS_REPO V4L_UTILS_PIN MAINSAIL_TAG MAINSAIL_SHA256 \
	WIFI_FIRMWARE_BIN_SHA256 WIFI_FIRMWARE_TXT_SHA256 \
	GUPPYSCREEN_REPO GUPPYSCREEN_BRANCH GUPPYSCREEN_PIN GUPPYSCREEN_VERSION GUPPYSCREEN_THEME; do
	require_pin "$required"
done
echo "== all required pins present in $MANIFEST =="

# 2026-08-07 baseline-repair mission: the proprietary WiFi firmware/NVRAM
# (see manifests/dependencies.conf's own comment on WIFI_FIRMWARE_*_SHA256
# for why this can't be a normal network pin) is required to even COMPILE
# the kernel (CONFIG_EXTRA_FIRMWARE builds it in) - not just to boot. A
# missing or wrong file here used to surface as a cryptic "No rule to make
# target" error roughly two hours into a kernel compile (hit for real
# during this mission's own clean-room reproducibility test). Checked here,
# first, before anything expensive runs.
WIFI_FW_DIR="$REPO_ROOT/scripts/build/overlay/lib/firmware/brcm"
WIFI_FW_BIN="$WIFI_FW_DIR/brcmfmac43430-sdio.bin"
WIFI_FW_TXT="$WIFI_FW_DIR/brcmfmac43430-sdio.txt"
if [ ! -f "$WIFI_FW_BIN" ] || [ ! -f "$WIFI_FW_TXT" ]; then
	echo "FATAL: $WIFI_FW_BIN and/or $WIFI_FW_TXT missing." >&2
	echo "These are gitignored proprietary files, not fetched by this script - a fresh clone never has them." >&2
	echo "Run: sh scripts/build/fetch-wifi-firmware.sh [user@stock-device-host]" >&2
	exit 1
fi
actual_bin_sha256=$(sha256sum "$WIFI_FW_BIN" | awk '{print $1}')
actual_txt_sha256=$(sha256sum "$WIFI_FW_TXT" | awk '{print $1}')
if [ "$actual_bin_sha256" != "$WIFI_FIRMWARE_BIN_SHA256" ]; then
	echo "FATAL: $WIFI_FW_BIN sha256 is $actual_bin_sha256, expected pinned $WIFI_FIRMWARE_BIN_SHA256" >&2
	echo "Either re-run fetch-wifi-firmware.sh against the correct device, or this is a deliberate," >&2
	echo "reviewed bump - if so, update WIFI_FIRMWARE_BIN_SHA256 in $MANIFEST." >&2
	exit 1
fi
if [ "$actual_txt_sha256" != "$WIFI_FIRMWARE_TXT_SHA256" ]; then
	echo "FATAL: $WIFI_FW_TXT sha256 is $actual_txt_sha256, expected pinned $WIFI_FIRMWARE_TXT_SHA256" >&2
	exit 1
fi
echo "== WiFi firmware + NVRAM present and pin-verified =="

mkdir -p "$VENDOR"
cd "$VENDOR"

clone_pinned() {
	name="$1"; url="$2"; ref="$3"; extra="$4"
	if [ -d "$name/.git" ]; then
		echo "== $name already present, verifying pin (not re-cloning) =="
	else
		echo "== cloning $name @ $ref =="
		git clone $extra "$url" "$name"
		git -C "$name" fetch origin "$ref" 2>/dev/null || true
		git -C "$name" checkout "$ref"
	fi
	# Pin enforcement (2026-07-31, NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md's
	# vendor-pin audit): previously this function only checked out the pinned
	# ref the FIRST time a vendor/ dir was absent - an already-present checkout
	# (e.g. after a stray `git pull` run by hand, or a stale checkout left over
	# from before a pin was bumped) was never re-verified. Resolve the pin
	# (branch/tag/SHA - all valid `ref` forms used by callers below) to its
	# exact commit and fail loudly on any mismatch, every run, not just on
	# first clone.
	#
	expected=$(git -C "$name" rev-parse "$ref" 2>/dev/null) || {
		echo "FATAL: vendor/$name - could not resolve pin '$ref' to a commit at all (bad ref, or needs a fetch)" >&2
		exit 1
	}
	actual=$(git -C "$name" rev-parse HEAD)
	if [ "$actual" != "$expected" ]; then
		echo "FATAL: vendor/$name HEAD is $actual, expected pinned ref '$ref' ($expected)" >&2
		echo "Either this checkout drifted (git -C vendor/$name checkout $expected to fix), or the pin needs a deliberate, reviewed bump in $MANIFEST." >&2
		exit 1
	fi
	echo "== $name pinned commit verified ($expected) =="
}

# X2000 kernel SDK, OpenKE fork (FIRMWARE.md sec 39): coreflake1/NebulaOS is a
# real GitHub fork of the original upstream (Llixuma/ingenic-linux-kernel6.6-
# x2000-v1.0-20250221 @ a98c2e1, "initial release"), with every OpenKE change
# (NS2009 touch, the display panel driver, BT H5 vendor ext, watchdog fix, DTS
# wiring, arch/mips/Kconfig compression selects) as one real, reviewable commit
# on the `openke` branch, rather than a patch file applied at build time -
# `main` on the fork tracks upstream unmodified. Sparse-checked-out to
# kernel/kernel-6.6 only (the full repo is ~684MB).
#
# Special-cased (not clone_pinned) because of the sparse-checkout step - the
# pin itself still comes from the manifest (KERNEL_PIN), enforced the same
# fail-loudly way.
if [ ! -d "x2000_kernel_6.6/.git" ]; then
	echo "== cloning x2000_kernel_6.6 (sparse: kernel/kernel-6.6 only) =="
	git clone --filter=blob:none --sparse \
		"$KERNEL_REPO" \
		x2000_kernel_6.6
	git -C x2000_kernel_6.6 sparse-checkout set kernel/kernel-6.6
	git -C x2000_kernel_6.6 checkout "$KERNEL_BRANCH"
else
	echo "== x2000_kernel_6.6 already present, skipping clone =="
fi
kernel_actual=$(git -C x2000_kernel_6.6 rev-parse HEAD)
if [ "$kernel_actual" != "$KERNEL_PIN" ]; then
	echo "FATAL: vendor/x2000_kernel_6.6 HEAD is $kernel_actual, expected pinned commit $KERNEL_PIN" >&2
	echo "The $KERNEL_BRANCH branch has moved (or this checkout was never on the pinned commit)." >&2
	echo "If this is a deliberate, reviewed pin bump, update KERNEL_PIN in $MANIFEST." >&2
	echo "Otherwise: git -C vendor/x2000_kernel_6.6 checkout $KERNEL_PIN" >&2
	exit 1
fi
echo "== x2000_kernel_6.6 pinned commit verified ($KERNEL_PIN) =="

# Buildroot config for this board family (Phase 0's find).
clone_pinned buildroot-x2000 "$BUILDROOT_REPO" "$BUILDROOT_PIN"

# SimpleAF's real workflow/config/installer repo (pellcorp/creality) - this
# project's own vocabulary has always used "SimpleAF" to mean this repo, not
# just the pellcorp/klipper engine fork above, but until the 2026-07-29
# SimpleAF backend integration mission it had only ever been fetched live via
# WebFetch/GitHub-API for comparison, never actually vendored - the resulting
# gap is documented in docs/NEBULAOS_SIMPLEAF_BACKEND_INTEGRATION.md. Resolved
# and pinned to its real HEAD at fetch time (2026-07-29) rather than tracking
# `main`, per this project's own "never analyze/build against a moving
# branch" rule. No LICENSE/COPYING file exists anywhere in this repo, and
# GitHub's API reports "license": null - vendored anyway per an explicit,
# recorded user decision (see this project's own memory record
# feedback_simpleaf_license_risk_accepted.md), not a default assumption of
# rights. Only a handful of its config/*.cfg files are actually vendored into
# this project's own overlay (scripts/build/overlay/opt/printer_data/config/
# simpleaf/) - see that directory's own per-file header comments for exactly
# which ones and why (e.g. config/bltouch.cfg's placeholder hardware values
# are deliberately NOT used, this project's own physically-qualified
# printer.cfg hardware section is authoritative instead). k1/internal_macros.cfg
# is deliberately not vendored at all - every command in it targets Creality-
# installer-only paths (/usr/data/pellcorp/...), systemctl (no systemd here),
# or a different camera architecture than NebulaOS's own database-seeded one.
clone_pinned pellcorp-creality "$PELLCORP_CREALITY_REPO" "$PELLCORP_CREALITY_PIN"

# NebulaOS's own fork of SimpleAF's Klipper (coreflake1/NebulaOS-klipper,
# `nebulaos` branch) - Track 1's "SimpleAF + the probe" decision applies here
# too: pellcorp/klipper @ 386fde4 is still the base this whole app stack
# targets, but every klippy_extras/ file this project needs (tmcstatus,
# guppy_config_helper, guppy_module_loader, calibrate_shaper_config,
# prtouch_v2 + companions, z_compensate) is committed into this fork's own
# tracked history on top of that commit, instead of being copied in as
# untracked files by 04-cross-compile-app-stack.sh after every fetch.
clone_pinned klipper "$KLIPPER_REPO" "$KLIPPER_PIN"

# Official Moonraker - not a fork, no reason to deviate.
clone_pinned moonraker "$MOONRAKER_REPO" "$MOONRAKER_PIN"

# Camera pipeline - a real GPLv3-licensed uStreamer port for this board
# family (the vendored ustreamer/LICENSE is the full GPLv3 text - this repo
# previously, incorrectly, called it MIT-licensed; corrected 2026-07-26).
clone_pinned k1-ustreamer "$K1_USTREAMER_REPO" "$K1_USTREAMER_PIN" "--recurse-submodules"
git -C k1-ustreamer submodule update --init --recursive

# v4l2-ctl (USB/webcam stock-parity mission, 2026-07-26): the camera macro
# warning found earlier ("v4l2-ctl: command not found") needs a real,
# genuinely-present binary, not a suppressed error - and this vendored
# Buildroot tree (a trimmed vendor BSP subset) has no v4l-utils package at
# all. Pinned to v1.20.0, the last release before v4l-utils' 1.22 meson
# migration - the container this project already uses for the Buildroot-
# toolchain cross-compiles (pellcorp/k1-bash-build) has no python3/meson/
# ninja, so staying on the plain autotools ./configure && make build here
# avoids adding that whole toolchain just for one diagnostic utility.
clone_pinned v4l-utils "$V4L_UTILS_REPO" "$V4L_UTILS_PIN"

# GuppyScreen (project-specific frontend, consumes the z_compensate
# structured status contract) - previously NOT pinned or fetched by this
# script at all (see manifests/dependencies.conf's own comment on this gap);
# the actual cross-compile happens in 04-cross-compile-app-stack.sh, this
# stage only fetches/verifies the pinned source.
clone_pinned nebulaos-guppyscreen "$GUPPYSCREEN_REPO" "$GUPPYSCREEN_PIN"
git -C nebulaos-guppyscreen submodule update --init --depth 1

# Submodule patches (this fork's own documented canonical build procedure,
# wiki/Building-from-Source.md step 2) - lv_drivers' framebuffer-ioctls fix
# is already folded into coreflake1/lv_drivers (a real fork the .gitmodules
# above points at, not upstream), so no patch file for it ships in patches/
# any more; spdlog and lvgl are still plain upstream submodules and need
# their two patches applied on every fresh checkout, or the MIPS build
# below silently builds against unpatched fmt/DPI-scaling behavior. Guarded
# with `git apply --check` first so re-running this script against an
# already-patched, already-present checkout (clone_pinned's "already
# present" branch) is a safe no-op, not a failure.
for entry in "0002-spdlog_fmt_initializer_list.patch spdlog" "0003-lvgl-dpi-text-scale.patch lvgl"; do
	patch_file=${entry% *}
	submodule=${entry#* }
	patch_path="$PWD/nebulaos-guppyscreen/patches/$patch_file"
	if git -C "nebulaos-guppyscreen/$submodule" apply --check "$patch_path" 2>/dev/null; then
		echo "== applying $patch_file to nebulaos-guppyscreen/$submodule =="
		git -C "nebulaos-guppyscreen/$submodule" apply "$patch_path"
	else
		echo "== $patch_file already applied (or does not cleanly apply) to nebulaos-guppyscreen/$submodule, skipping =="
	fi
done

# Mainsail - a built Vue app, fetched as a real release archive, not built
# from source here (no Node.js toolchain needed for this build at all).
#
# Pinned to an explicit release tag (the exact .version this project's last
# real build actually shipped) plus a SHA-256 check on the downloaded
# archive itself, failing loudly on either a wrong tag or a byte-for-byte
# different artifact under that tag - not .../releases/latest/..., which
# would silently point at whatever GitHub considers "latest" at fetch time.
mkdir -p mainsail-dist
if [ ! -f mainsail-dist/mainsail.zip ]; then
	echo "== downloading Mainsail $MAINSAIL_TAG =="
	curl -sL "https://github.com/mainsail-crew/mainsail/releases/download/$MAINSAIL_TAG/mainsail.zip" \
		-o mainsail-dist/mainsail.zip
fi
mainsail_actual_sha256=$(sha256sum mainsail-dist/mainsail.zip | awk '{print $1}')
if [ "$mainsail_actual_sha256" != "$MAINSAIL_SHA256" ]; then
	echo "FATAL: mainsail-dist/mainsail.zip sha256 is $mainsail_actual_sha256, expected pinned $MAINSAIL_SHA256 for $MAINSAIL_TAG" >&2
	echo "Either the download is corrupt/tampered, or this is a deliberate version bump - if deliberate, update MAINSAIL_TAG/MAINSAIL_SHA256 in $MANIFEST after reviewing the new release." >&2
	exit 1
fi
echo "== Mainsail $MAINSAIL_TAG sha256 verified =="
rm -rf mainsail-dist/dist
mkdir -p mainsail-dist/dist
unzip -q mainsail-dist/mainsail.zip -d mainsail-dist/dist

# mainsail-crew's own installer repo - only used for its real, canonical
# nginx reverse-proxy config template (already baked into scripts/build/
# overlay/etc/nginx/nginx.conf), not needed again unless you're re-deriving
# that config. Left commented out - uncomment if you want to re-check it.
# clone_pinned kiauh https://github.com/dw-0/kiauh.git HEAD

echo "== all vendor sources fetched =="
