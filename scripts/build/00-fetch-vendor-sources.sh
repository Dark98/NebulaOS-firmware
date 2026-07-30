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
		echo "== $name already present, skipping clone =="
		return
	fi
	echo "== cloning $name @ $ref =="
	git clone $extra "$url" "$name"
	git -C "$name" fetch origin "$ref" 2>/dev/null || true
	git -C "$name" checkout "$ref"
}

# X2000 kernel SDK, OpenKE fork (FIRMWARE.md sec 39): coreflake1/NebulaOS is a
# real GitHub fork of the original upstream (Llixuma/ingenic-linux-kernel6.6-
# x2000-v1.0-20250221 @ a98c2e1, "initial release"), with every OpenKE change
# (NS2009 touch, the display panel driver, BT H5 vendor ext, watchdog fix, DTS
# wiring, arch/mips/Kconfig compression selects) as one real, reviewable commit
# on the `openke` branch, rather than a patch file applied at build time -
# `main` on the fork tracks upstream unmodified. Sparse-checked-out to
# kernel/kernel-6.6 only (the full repo is ~684MB).
if [ ! -d "x2000_kernel_6.6/.git" ]; then
	echo "== cloning x2000_kernel_6.6 (sparse: kernel/kernel-6.6 only) =="
	git clone --filter=blob:none --sparse \
		https://github.com/coreflake1/NebulaOS.git \
		x2000_kernel_6.6
	git -C x2000_kernel_6.6 sparse-checkout set kernel/kernel-6.6
	git -C x2000_kernel_6.6 checkout openke
else
	echo "== x2000_kernel_6.6 already present, skipping =="
fi

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
clone_pinned klipper https://github.com/coreflake1/NebulaOS-klipper.git \
	b3d5ab2b9484f1558586c3a2ea43d46ff9a473a7

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
clone_pinned v4l-utils https://git.linuxtv.org/v4l-utils.git v4l-utils-1.20.0

# Mainsail - a built Vue app, fetched as a real release archive, not built
# from source here (no Node.js toolchain needed for this build at all).
mkdir -p mainsail-dist
if [ ! -f mainsail-dist/mainsail.zip ]; then
	echo "== downloading Mainsail's latest release =="
	curl -sL https://github.com/mainsail-crew/mainsail/releases/latest/download/mainsail.zip \
		-o mainsail-dist/mainsail.zip
fi
rm -rf mainsail-dist/dist
mkdir -p mainsail-dist/dist
unzip -q mainsail-dist/mainsail.zip -d mainsail-dist/dist

# mainsail-crew's own installer repo - only used for its real, canonical
# nginx reverse-proxy config template (already baked into scripts/build/
# overlay/etc/nginx/nginx.conf), not needed again unless you're re-deriving
# that config. Left commented out - uncomment if you want to re-check it.
# clone_pinned kiauh https://github.com/dw-0/kiauh.git HEAD

echo "== all vendor sources fetched =="
