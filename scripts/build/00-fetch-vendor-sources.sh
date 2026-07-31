#!/bin/sh
# Clone/download every third-party source this build needs, pinned to the
# exact refs this project used. See FIRMWARE.md for why each one was chosen.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
VENDOR="$REPO_ROOT/vendor"
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
	expected=$(git -C "$name" rev-parse "$ref" 2>/dev/null) || {
		echo "FATAL: vendor/$name - could not resolve pin '$ref' to a commit at all (bad ref, or needs a fetch)" >&2
		exit 1
	}
	actual=$(git -C "$name" rev-parse HEAD)
	if [ "$actual" != "$expected" ]; then
		echo "FATAL: vendor/$name HEAD is $actual, expected pinned ref '$ref' ($expected)" >&2
		echo "Either this checkout drifted (git -C vendor/$name checkout $expected to fix), or the pin needs a deliberate, reviewed bump in this script." >&2
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
# Pin enforcement (2026-07-31, NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md's
# vendor-pin audit): every other clone_pinned call below pins to an exact
# commit SHA; this one used to check out the `openke` branch by name only,
# which meant a future upstream push to that branch would be silently picked
# up by any fresh fetch with no error. The branch is still used to locate and
# clone the right ref (it identifies which fork history this is), but the
# actual pin enforced here is the exact SHA below - if `openke` has moved past
# it, this script now fails loudly instead of silently building different
# kernel source. Bump X2000_KERNEL_6_6_PIN deliberately (in a dedicated commit)
# when you actually want to pick up new upstream `openke` commits.
X2000_KERNEL_6_6_PIN=f7ff80a8aa21886a32783dab167e451298c60a8d
if [ ! -d "x2000_kernel_6.6/.git" ]; then
	echo "== cloning x2000_kernel_6.6 (sparse: kernel/kernel-6.6 only) =="
	git clone --filter=blob:none --sparse \
		https://github.com/coreflake1/NebulaOS.git \
		x2000_kernel_6.6
	git -C x2000_kernel_6.6 sparse-checkout set kernel/kernel-6.6
	git -C x2000_kernel_6.6 checkout openke
else
	echo "== x2000_kernel_6.6 already present, skipping clone =="
fi
kernel_actual=$(git -C x2000_kernel_6.6 rev-parse HEAD)
if [ "$kernel_actual" != "$X2000_KERNEL_6_6_PIN" ]; then
	echo "FATAL: vendor/x2000_kernel_6.6 HEAD is $kernel_actual, expected pinned commit $X2000_KERNEL_6_6_PIN" >&2
	echo "The openke branch has moved (or this checkout was never on the pinned commit)." >&2
	echo "If this is a deliberate, reviewed pin bump, update X2000_KERNEL_6_6_PIN in this script." >&2
	echo "Otherwise: git -C vendor/x2000_kernel_6.6 checkout $X2000_KERNEL_6_6_PIN" >&2
	exit 1
fi
echo "== x2000_kernel_6.6 pinned commit verified ($X2000_KERNEL_6_6_PIN) =="

# Buildroot config for this board family (Phase 0's find).
clone_pinned buildroot-x2000 https://github.com/lone0/buildroot-x2000.git \
	74d020081096972857acdb9e76c6c5335455d430

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
clone_pinned pellcorp-creality https://github.com/pellcorp/creality.git \
	d18d354456a89c20507e574feaa34d6389e679ca

# NebulaOS's own fork of SimpleAF's Klipper (coreflake1/NebulaOS-klipper,
# `nebulaos` branch) - Track 1's "SimpleAF + the probe" decision applies here
# too: pellcorp/klipper @ 386fde4 is still the base this whole app stack
# targets, but every klippy_extras/ file this project needs (tmcstatus,
# guppy_config_helper, guppy_module_loader, calibrate_shaper_config,
# prtouch_v2 + companions, z_compensate) is now committed into this fork's
# own tracked history on top of that commit, instead of being copied in as
# untracked files by 04-cross-compile-app-stack.sh after every fetch (see
# that script's own comment, now removed, for the gap this replaces).
#
# Pin bumped 2026-07-31 (NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md's vendor-
# pin audit): this pin was stuck one real commit behind the actual, already-
# shipped fork state - d839d0375 ("chelper: replace incompatible upstream
# c_helper.so with NebulaOS's own build") had been pushed and was already
# what every real build depended on, but a fresh fetch would have silently
# checked out the older b3d5ab2 and missed it. 06-verify.sh's check_vendor_pin
# already caught and documented this exact MISS; this bump resolves it.
clone_pinned klipper https://github.com/coreflake1/NebulaOS-klipper.git \
	d839d0375a31327e57e0a35e99e70ba60814ec05

# Official Moonraker - not a fork, no reason to deviate.
clone_pinned moonraker https://github.com/Arksine/moonraker.git \
	d5ee17128bb88434aacdab90c2e9e990e2b64e4a

# Camera pipeline - a real GPLv3-licensed uStreamer port for this board
# family (the vendored ustreamer/LICENSE is the full GPLv3 text - this repo
# previously, incorrectly, called it MIT-licensed; corrected 2026-07-26).
clone_pinned k1-ustreamer https://github.com/pellcorp/k1-ustreamer.git \
	18e30bb313d54b1b01dd995bd31ce5a3d5adffd6 "--recurse-submodules"
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
# Pinned to the tag's exact resolved commit (not the tag name) as of
# 2026-07-31 (NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md's vendor-pin audit) -
# every other clone_pinned call in this script pins an exact SHA; a tag name
# is normally immutable for a release but is not a hard guarantee the way a
# commit SHA is. Confirmed via `git describe --tags` that this SHA is exactly
# what v4l-utils-1.20.0 resolves to.
clone_pinned v4l-utils https://git.linuxtv.org/v4l-utils.git \
	3b22ab02b960e4d1e90618e9fce9b7c8a80d814a

# Mainsail - a built Vue app, fetched as a real release archive, not built
# from source here (no Node.js toolchain needed for this build at all).
#
# Pin enforcement (2026-07-31, NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md's
# vendor-pin audit): this used to download from .../releases/latest/..., a
# URL that silently points at whatever GitHub considers "latest" at fetch
# time - the single least-reproducible dependency in this whole build, worse
# than the kernel's moving-branch issue, since there wasn't even a way to
# detect drift after the fact. Pinned to an explicit release tag (the exact
# .version this project's last real build actually shipped, confirmed by
# extracting the downloaded zip's own .version file) plus a SHA-256 check on
# the downloaded archive itself, failing loudly on either a wrong tag or a
# byte-for-byte different artifact under that tag.
MAINSAIL_PIN_TAG=v2.18.2
MAINSAIL_PIN_SHA256=df2ba7c301f7bfc8ac9f122741a6ba08356d679ecfa1f62f898d0337802d5de5
mkdir -p mainsail-dist
if [ ! -f mainsail-dist/mainsail.zip ]; then
	echo "== downloading Mainsail $MAINSAIL_PIN_TAG =="
	curl -sL "https://github.com/mainsail-crew/mainsail/releases/download/$MAINSAIL_PIN_TAG/mainsail.zip" \
		-o mainsail-dist/mainsail.zip
fi
mainsail_actual_sha256=$(sha256sum mainsail-dist/mainsail.zip | awk '{print $1}')
if [ "$mainsail_actual_sha256" != "$MAINSAIL_PIN_SHA256" ]; then
	echo "FATAL: mainsail-dist/mainsail.zip sha256 is $mainsail_actual_sha256, expected pinned $MAINSAIL_PIN_SHA256 for $MAINSAIL_PIN_TAG" >&2
	echo "Either the download is corrupt/tampered, or this is a deliberate version bump - if deliberate, update MAINSAIL_PIN_TAG/MAINSAIL_PIN_SHA256 in this script after reviewing the new release." >&2
	exit 1
fi
echo "== Mainsail $MAINSAIL_PIN_TAG sha256 verified =="
rm -rf mainsail-dist/dist
mkdir -p mainsail-dist/dist
unzip -q mainsail-dist/mainsail.zip -d mainsail-dist/dist

# mainsail-crew's own installer repo - only used for its real, canonical
# nginx reverse-proxy config template (already baked into scripts/build/
# overlay/etc/nginx/nginx.conf), not needed again unless you're re-deriving
# that config. Left commented out - uncomment if you want to re-check it.
# clone_pinned kiauh https://github.com/dw-0/kiauh.git HEAD

echo "== all vendor sources fetched =="
