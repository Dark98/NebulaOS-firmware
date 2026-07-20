#!/bin/sh
# Final rootfs build - bakes everything stage 4 assembled in the overlay
# (Klipper, Moonraker, ustreamer, Mainsail, the cross-compiled extras) into
# the actual rootfs.ext2/rootfs.squashfs. Assumes 02 and 03 already ran in
# this same session (02 for any overlay/config changes, 03 for any kernel
# source changes with its own forced dirclean) - this script does not
# re-sync the overlay or force a kernel rebuild itself, so a change to
# either that hasn't gone through 02/03 first will silently not appear here.
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
# Copying via a root container, not the host user directly - output/images/*
# is root-owned from the docker --user root build above, and the chown back
# to the real host user/group below needs root too.
HOST_UID=$(id -u)
HOST_GID=$(id -g)
docker run --rm --user root -v "$REPO_ROOT:/repo" pellcorp/k1-bash-build bash -c "
set -e
cp '/repo/vendor/buildroot-x2000/output/images/uImage' '/repo/artifacts/buildroot-halley5-v30-image/uImage'
cp '/repo/vendor/buildroot-x2000/output/images/rootfs.ext2' '/repo/artifacts/buildroot-halley5-v30-image/rootfs.ext2'
cp '/repo/vendor/buildroot-x2000/output/images/rootfs.squashfs' '/repo/artifacts/buildroot-halley5-v30-image/rootfs.squashfs'
cp '/repo/vendor/buildroot-x2000/.config' '/repo/artifacts/buildroot-halley5-v30-image/buildroot.config'
cp '/repo/vendor/buildroot-x2000/output/build/linux-custom/.config' '/repo/artifacts/buildroot-halley5-v30-image/kernel.config'
chown $HOST_UID:$HOST_GID /repo/artifacts/buildroot-halley5-v30-image/*
"

echo "== final build complete, artifacts copied to artifacts/buildroot-halley5-v30-image/ (uImage, rootfs.ext2, rootfs.squashfs) =="
