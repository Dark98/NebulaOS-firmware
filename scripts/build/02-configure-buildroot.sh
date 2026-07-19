#!/bin/sh
# Wire up Buildroot's configuration: the real, already-verified .config this
# project produced (artifacts/buildroot-halley5-v30-image/buildroot.config),
# the kernel config fragment (FIRMWARE.md sec 10-12's additions on top of
# the vendor x2000_halley5_v30_linux defconfig), the LINUX_OVERRIDE_SRCDIR
# pointer, and this repo's own hand-written overlay content.
#
# Reusing the exact verified .config here (rather than re-deriving every
# BR2_PACKAGE_* option from scratch) is deliberate: several of those options
# hit a real class of bug this session where a naive `echo "X=y" >> .config`
# landed on a duplicate line that a later `make olddefconfig` pass then lost
# to the file's *other*, unedited copy of the same symbol (see FIRMWARE.md
# sec 14) - copying the known-good, already-normalized file sidesteps that
# whole class of mistake rather than risking reintroducing it.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
BUILDROOT_DIR="$REPO_ROOT/vendor/buildroot-x2000"
ARTIFACTS="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"

if [ ! -d "$BUILDROOT_DIR/.git" ]; then
	echo "vendor/buildroot-x2000 not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
fi

cp "$ARTIFACTS/buildroot.config" "$BUILDROOT_DIR/.config"
mkdir -p "$BUILDROOT_DIR/board"
cp "$ARTIFACTS/halley5-openke-fragment.config" "$BUILDROOT_DIR/board/halley5-openke-fragment.config"

# LINUX_OVERRIDE_SRCDIR points Buildroot's kernel package at the patched
# source instead of downloading/re-cloning it - must match the Docker mount
# path used in every later stage's docker run (/kernel_6_6/kernel/kernel-6.6).
cat > "$BUILDROOT_DIR/local.mk" <<'EOF'
LINUX_OVERRIDE_SRCDIR = /kernel_6_6/kernel/kernel-6.6
EOF

# This repo's own hand-written init scripts/configs (init.d scripts, nginx
# reverse-proxy config, printer.cfg/moonraker.conf). The rest of the overlay
# (Klipper/Moonraker source, Mainsail's static build, cross-compiled extras)
# gets assembled by 04-cross-compile-app-stack.sh - this stage only lays
# down what this project actually wrote by hand.
rm -rf "$BUILDROOT_DIR/board/halley5-openke-overlay"
mkdir -p "$BUILDROOT_DIR/board/halley5-openke-overlay"
cp -r "$SCRIPT_DIR/overlay/." "$BUILDROOT_DIR/board/halley5-openke-overlay/"
mkdir -p "$BUILDROOT_DIR/board/halley5-openke-overlay/opt/printer_data/comms" \
         "$BUILDROOT_DIR/board/halley5-openke-overlay/opt/printer_data/logs" \
         "$BUILDROOT_DIR/board/halley5-openke-overlay/opt/printer_data/gcodes"

echo "== normalizing .config (resolves any derived Kconfig selects) =="
docker run --rm --user root \
	-v "$REPO_ROOT/vendor/x2000_kernel_6.6/kernel/kernel-6.6:/kernel_6_6/kernel/kernel-6.6" \
	-v "$BUILDROOT_DIR:/src" -w /src pellcorp/k1-bash-build bash -c '
apt-get -qq update >/dev/null 2>&1
apt-get install -y -qq python3 bc cpio rsync unzip bison flex libncurses5-dev file build-essential libssl-dev libelf-dev >/dev/null 2>&1
make olddefconfig
'

echo "== buildroot configured =="
