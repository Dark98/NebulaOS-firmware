#!/bin/sh
# Final rootfs build - bakes everything stage 4 assembled in the overlay
# (Klipper, Moonraker, ustreamer, Mainsail, the cross-compiled extras) into
# the actual rootfs.ext2. The kernel itself doesn't need rebuilding here -
# only the rootfs-assembly steps rerun, since nothing kernel-side changed
# since stage 3.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
BUILDROOT_DIR="$REPO_ROOT/vendor/buildroot-x2000"
KERNEL_MOUNT="$REPO_ROOT/vendor/x2000_kernel_6.6/kernel/kernel-6.6"

docker run --rm --user root \
	-v "$KERNEL_MOUNT:/kernel_6_6/kernel/kernel-6.6" \
	-v "$BUILDROOT_DIR:/src" -w /src pellcorp/k1-bash-build bash -c '
apt-get -qq update >/dev/null 2>&1
apt-get install -y -qq python3 bc cpio rsync unzip bison flex libncurses5-dev file \
	build-essential libssl-dev libelf-dev >/dev/null 2>&1
make
'

mkdir -p "$REPO_ROOT/artifacts/buildroot-halley5-v30-image"
cp "$BUILDROOT_DIR/output/images/uImage" "$REPO_ROOT/artifacts/buildroot-halley5-v30-image/uImage"
cp "$BUILDROOT_DIR/output/images/rootfs.ext2" "$REPO_ROOT/artifacts/buildroot-halley5-v30-image/rootfs.ext2"
cp "$BUILDROOT_DIR/.config" "$REPO_ROOT/artifacts/buildroot-halley5-v30-image/buildroot.config"
cp "$BUILDROOT_DIR/output/build/linux-custom/.config" "$REPO_ROOT/artifacts/buildroot-halley5-v30-image/kernel.config"

echo "== final build complete, artifacts copied to artifacts/buildroot-halley5-v30-image/ =="
