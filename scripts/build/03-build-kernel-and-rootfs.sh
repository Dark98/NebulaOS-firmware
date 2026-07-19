#!/bin/sh
# Main kernel + base rootfs build - touch, display, WiFi, Bluetooth, camera-
# kernel-side, and Core SoC infra (RNG/MMC/I2C/DMA) all come from this one
# pass, since they're all just kernel config + device-tree, nothing
# cross-compiled outside Buildroot's own package builds.
#
# IMPORTANT: always mount the buildroot-x2000 directory at /src, exactly as
# here. A real bug this session (FIRMWARE.md sec 14): several of Buildroot's
# own host tools (e.g. glib-compile-schemas) get built with their RUNPATH
# hardcoded to whatever mount path was used *the first time* they were
# built - a later stage that mounts at a different path will fail with
# "cannot open shared object file" even though nothing about the build
# itself changed. Pick one path and never deviate.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
BUILDROOT_DIR="$REPO_ROOT/vendor/buildroot-x2000"
KERNEL_MOUNT="$REPO_ROOT/vendor/x2000_kernel_6.6/kernel/kernel-6.6"

if [ ! -f "$BUILDROOT_DIR/.config" ]; then
	echo "buildroot not configured - run 02-configure-buildroot.sh first" >&2
	exit 1
fi

docker run --rm --user root \
	-v "$KERNEL_MOUNT:/kernel_6_6/kernel/kernel-6.6" \
	-v "$BUILDROOT_DIR:/src" -w /src pellcorp/k1-bash-build bash -c '
apt-get -qq update >/dev/null 2>&1
apt-get install -y -qq python3 bc cpio rsync unzip bison flex libncurses5-dev file \
	build-essential libssl-dev libelf-dev libffi-dev zlib1g-dev libsqlite3-dev \
	libexpat1-dev libbz2-dev liblzma-dev libreadline-dev libgdbm-dev uuid-dev \
	pkg-config autoconf automake libtool gettext texinfo help2man \
	libjpeg-dev libpng-dev libtiff-dev libwebp-dev libopenjp2-7-dev >/dev/null 2>&1
make
'

echo "== kernel + base rootfs built: $BUILDROOT_DIR/output/images/{uImage,rootfs.ext2} =="
