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
#
# IMPORTANT: this always force-cleans and rebuilds the kernel from scratch
# (`make linux-dirclean` before `make`), rather than relying on plain `make`
# alone. A real, previously-silent bug this session (FIRMWARE.md sec 24):
# LINUX_OVERRIDE_SRCDIR points Buildroot at this project's own kernel
# checkout, but Buildroot's own .stamp_built/.stamp_rsynced files don't
# detect source changes there - a plain `make` after editing a DTS/Kconfig
# file will silently keep using the last-built kernel binary, reporting
# success while shipping stale, unpatched code. The dirclean costs a slower,
# full kernel rebuild every time this script runs, which is a real, deliberate
# tradeoff in favor of correctness - re-run 02-configure-buildroot.sh first
# if scripts/build/overlay/ or the config artifacts changed, since this
# script does not re-sync those itself.
#
# IMPORTANT: also force-cleans wpa_supplicant specifically, for the same
# reason but a different, more general cause (FIRMWARE.md sec 24/27):
# Buildroot does not automatically rebuild an already-built *package* just
# because its own Kconfig options (BR2_PACKAGE_WPA_SUPPLICANT_CTRL_IFACE/
# _CLI in this case) changed after it was first built - only source changes
# for override-srcdir packages get this same treatment, and even that needs
# an explicit dirclean as above. This bit us for real: wpa_supplicant was
# already built once with CTRL_IFACE/CLI disabled, the .config was fixed to
# enable them, and a later plain `make` silently kept shipping the old,
# disabled build - passing every check except `06-verify.sh`'s explicit
# `wpa_cli` presence check. If any other package's Kconfig options get
# changed after it's already been built once, the same `<pkg>-dirclean`
# treatment is needed - this project has hit this exact class of bug twice
# now, for two different packages, for the same underlying reason.
#
# IMPORTANT: also force-reinstalls gcc-final specifically, a third instance of
# the same underlying bug (found 2026-07-23, real-hardware testing): this
# project's base defconfig has always had BR2_INSTALL_LIBSTDCPP=y, but the
# very first build's gcc-final .stamp_target_installed predates whatever
# point that became load-bearing (greenlet, Klipper's own C extension
# dependency, needs libstdc++.so.6 at runtime) - every build since silently
# kept reusing that stamp, so gcc-final's own INSTALL_TARGET_CMDS (the step
# that actually copies libstdc++.so* into the rootfs) never ran again, even
# though libstdc++ was genuinely compiled and sitting in the toolchain's own
# sysroot the whole time. Symptom: Klipper (and anything else linking a C++
# extension) fails ImportError: libstdc++.so.6: cannot open shared object
# file, with no log line at all (dies before its own log file opens).
# `gcc-final-reinstall` re-runs just the install steps (cheap - the compiler
# itself doesn't need rebuilding), unlike `gcc-final-dirclean` which would
# force a full toolchain rebuild for no reason.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

# 2026-07-23: see 02-configure-buildroot.sh for why this lock exists.
exec 9>"$REPO_ROOT/.openke-build.lock"
flock -n 9 || { echo "another build stage already owns $REPO_ROOT/.openke-build.lock" >&2; exit 1; }
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
make linux-dirclean
make wpa_supplicant-dirclean
make gcc-final-reinstall
make
'

echo "== kernel + base rootfs built: $BUILDROOT_DIR/output/images/{uImage,rootfs.ext2} =="
