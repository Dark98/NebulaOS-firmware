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
	V4L_UTILS_REPO V4L_UTILS_PIN V4L_UTILS_ARCHIVE_URL V4L_UTILS_ARCHIVE_SHA256 \
	MAINSAIL_TAG MAINSAIL_SHA256 \
	WIFI_FIRMWARE_RELEASE_TAG WIFI_FIRMWARE_RELEASE_URL WIFI_FIRMWARE_ARCHIVE_SHA256 \
	WIFI_FIRMWARE_TXT_SHA256 WIFI_FIRMWARE_BIN_SHA256 WIFI_FIRMWARE_CLM_SHA256 \
	GUPPYSCREEN_REPO GUPPYSCREEN_BRANCH GUPPYSCREEN_PIN GUPPYSCREEN_VERSION GUPPYSCREEN_THEME; do
	require_pin "$required"
done
echo "== all required pins present in $MANIFEST =="

# 2026-08-07 baseline-repair mission: wireless-regdb (regulatory.db, its
# .p7s signature, and its LICENSE) is ISC-licensed and freely fetchable -
# unlike the proprietary WiFi firmware below, this one already had a
# complete, correct, hash-verified fetch script
# (scripts/firmware/fetch-wireless-regdb.sh) that simply was never called
# from anywhere in the actual build pipeline. Also required to compile the
# kernel (same CONFIG_EXTRA_FIRMWARE mechanism as the WiFi firmware) - a
# genuinely fresh clone hit this as a second, immediately-following
# "No rule to make target" failure once the first one (below) was fixed.
sh "$SCRIPT_DIR/../firmware/fetch-wireless-regdb.sh"

# 2026-08-09 (WiFi .125 promotion): canonical CYW43430 .bin + CLM, fetched
# directly from Infineon's own upstream repo and hash-verified inside that
# script itself (WIFI_FIRMWARE_BIN_SHA256/WIFI_FIRMWARE_CLM_SHA256 above).
# Required to compile the kernel (CONFIG_EXTRA_FIRMWARE embeds both - see
# artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config),
# not just to boot. See docs/NEBULAOS_WIFI_125_ENGINEERING_TEST.md for the
# full qualification history behind this pin.
sh "$SCRIPT_DIR/../firmware/fetch-cyw43430-wifi-firmware.sh"

# Board NVRAM (.txt) - real per-board calibration data extracted from this
# project's own hardware, redistribution explicitly authorized by the
# repository owner (see LICENSES/WIFI-FIRMWARE-NOTICE.md), published as a
# GitHub Release asset on this repo and fetched the same way Mainsail is
# above: pinned tag + URL + archive sha256, individual file hash checked
# after extraction. Unrelated to which .bin/CLM firmware is running -
# stays byte-identical across the 2026-08-09 .125 promotion.
WIFI_FW_DIR="$REPO_ROOT/scripts/build/overlay/lib/firmware/brcm"
WIFI_FW_TXT="$WIFI_FW_DIR/brcmfmac43430-sdio.txt"
mkdir -p "$WIFI_FW_DIR"
if [ ! -f "$WIFI_FW_TXT" ]; then
	echo "== downloading WiFi firmware release $WIFI_FIRMWARE_RELEASE_TAG (NVRAM only) =="
	WIFI_FW_ARCHIVE="$REPO_ROOT/vendor-downloads/nebulaos-wifi-firmware.tar.gz"
	mkdir -p "$(dirname "$WIFI_FW_ARCHIVE")"
	curl -sL -o "$WIFI_FW_ARCHIVE" "$WIFI_FIRMWARE_RELEASE_URL"
	archive_actual_sha256=$(sha256sum "$WIFI_FW_ARCHIVE" | awk '{print $1}')
	# Clean-Update + Virgin Baseline mission, Phase 8 (2026-08-08): this
	# repos own visibility is still PRIVATE (a GitHub repo-visibility
	# change is one of the action categories this projects own tooling
	# cannot perform itself, confirmed persistently blocked, not a
	# transient failure). A plain unauthenticated curl against a private
	# repos release asset 404s regardless of the URL looking like a normal
	# public download link - confirmed real, first hit during this
	# missions own attempt at a genuinely fresh clone build. Fall back to
	# the GitHub CLIs own authenticated release-download flow, which works
	# against a private repo as long as the invoking environment has gh
	# authenticated with read access - exactly what every build
	# environment used by this project actually has. If gh is unavailable
	# or unauthenticated too, this falls through to the same FATAL check
	# below, now correctly diagnosing the real cause.
	if [ "$archive_actual_sha256" != "$WIFI_FIRMWARE_ARCHIVE_SHA256" ] && command -v gh >/dev/null 2>&1; then
		echo "== plain curl fetch did not match the pinned hash - retrying via gh release download (private repo) =="
		gh release download "$WIFI_FIRMWARE_RELEASE_TAG" \
			--repo coreflake1/NebulaOS-firmware \
			--pattern "$(basename "$WIFI_FIRMWARE_RELEASE_URL")" \
			--output "$WIFI_FW_ARCHIVE" --clobber \
			|| echo "WARNING: gh release download also failed - see the FATAL check below for the real error" >&2
		archive_actual_sha256=$(sha256sum "$WIFI_FW_ARCHIVE" | awk '{print $1}')
	fi
	if [ "$archive_actual_sha256" != "$WIFI_FIRMWARE_ARCHIVE_SHA256" ]; then
		echo "FATAL: $WIFI_FW_ARCHIVE sha256 is $archive_actual_sha256, expected pinned $WIFI_FIRMWARE_ARCHIVE_SHA256" >&2
		echo "Either the download is corrupt/tampered, gh is missing or unauthenticated and the repo is still" >&2
		echo "private, or this is a deliberate, reviewed bump - if so, update WIFI_FIRMWARE_ARCHIVE_SHA256 in" >&2
		echo "$MANIFEST." >&2
		exit 1
	fi
	tar xzf "$WIFI_FW_ARCHIVE" -C "$(dirname "$WIFI_FW_ARCHIVE")"
	cp "$(dirname "$WIFI_FW_ARCHIVE")"/nebulaos-wifi-firmware-*/brcmfmac43430-sdio.txt "$WIFI_FW_TXT"
	echo "== WiFi NVRAM extracted from release archive =="
fi
actual_txt_sha256=$(sha256sum "$WIFI_FW_TXT" | awk '{print $1}')
if [ "$actual_txt_sha256" != "$WIFI_FIRMWARE_TXT_SHA256" ]; then
	echo "FATAL: $WIFI_FW_TXT sha256 is $actual_txt_sha256, expected pinned $WIFI_FIRMWARE_TXT_SHA256" >&2
	exit 1
fi
echo "== WiFi firmware + CLM + NVRAM present and pin-verified =="

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
#
# Virgin-Baseline Fix + Rebuild mission (2026-08-08): NOT clone_pinned - a
# live clone from git.linuxtv.org (the canonical upstream, still the
# source of truth for V4L_UTILS_REPO/PIN's identity) had a real, observed
# outage mid-build, twice, on separate fresh-clone attempts, putting a
# third-party server's uptime on this build's critical path for one
# diagnostic utility. Fetches a deterministic, SHA256-pinned archive of
# the exact same pinned commit instead - see manifests/dependencies.conf's
# own comment on how that archive's content was independently verified
# before publishing. Same re-verify-every-run property as clone_pinned
# (HEAD/origin checked below unconditionally, not just on first fetch).
if [ ! -d v4l-utils/.git ]; then
	echo "== fetching v4l-utils @ $V4L_UTILS_PIN (pinned archive, not a live clone) =="
	V4L_UTILS_ARCHIVE="$REPO_ROOT/vendor-downloads/v4l-utils-pinned-src.tar.gz"
	mkdir -p "$(dirname "$V4L_UTILS_ARCHIVE")"
	curl -sL -o "$V4L_UTILS_ARCHIVE" "$V4L_UTILS_ARCHIVE_URL"
	v4l_archive_actual_sha256=$(sha256sum "$V4L_UTILS_ARCHIVE" | awk '{print $1}')
	# Same private-repo fallback as the WiFi firmware fetch above.
	if [ "$v4l_archive_actual_sha256" != "$V4L_UTILS_ARCHIVE_SHA256" ] && command -v gh >/dev/null 2>&1; then
		echo "== plain curl fetch did not match the pinned hash - retrying via gh release download (private repo) =="
		gh release download v4l-utils-vendor-src-3b22ab0 \
			--repo coreflake1/NebulaOS-firmware \
			--pattern "$(basename "$V4L_UTILS_ARCHIVE_URL")" \
			--output "$V4L_UTILS_ARCHIVE" --clobber \
			|| echo "WARNING: gh release download also failed - see the FATAL check below for the real error" >&2
		v4l_archive_actual_sha256=$(sha256sum "$V4L_UTILS_ARCHIVE" | awk '{print $1}')
	fi
	if [ "$v4l_archive_actual_sha256" != "$V4L_UTILS_ARCHIVE_SHA256" ]; then
		echo "FATAL: $V4L_UTILS_ARCHIVE sha256 is $v4l_archive_actual_sha256, expected pinned $V4L_UTILS_ARCHIVE_SHA256" >&2
		echo "Either the download is corrupt/tampered, gh is missing or unauthenticated and the repo is still" >&2
		echo "private, or this is a deliberate, reviewed bump - if so, update V4L_UTILS_ARCHIVE_SHA256 in $MANIFEST." >&2
		exit 1
	fi
	rm -rf v4l-utils
	mkdir -p v4l-utils
	tar xzf "$V4L_UTILS_ARCHIVE" -C v4l-utils
	echo "== v4l-utils pinned archive verified and extracted =="
fi
v4l_utils_actual=$(git -C v4l-utils rev-parse HEAD 2>/dev/null || echo "unknown")
if [ "$v4l_utils_actual" != "$V4L_UTILS_PIN" ]; then
	echo "FATAL: vendor/v4l-utils HEAD is $v4l_utils_actual, expected pinned commit $V4L_UTILS_PIN" >&2
	exit 1
fi
v4l_utils_origin=$(git -C v4l-utils remote get-url origin 2>/dev/null || echo "")
if [ "$v4l_utils_origin" != "$V4L_UTILS_REPO" ]; then
	echo "FATAL: vendor/v4l-utils origin is '$v4l_utils_origin', expected $V4L_UTILS_REPO" >&2
	exit 1
fi
echo "== v4l-utils pinned commit verified ($V4L_UTILS_PIN) =="

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
