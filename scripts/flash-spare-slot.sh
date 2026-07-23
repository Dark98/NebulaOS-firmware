#!/bin/sh
#
# Writes the custom xImage/rootfs.squashfs to the spare kernel2/rootfs2 slot
# (FIRMWARE.md sec 19/23) and verifies every write against a checksum before
# reporting success - deliberately never touches p5/p7 (the currently active,
# currently-booted stock slot) and never flips the ota marker itself (that's
# a separate, deliberate step - see S00revert-safety for what happens once
# the custom image actually boots).
#
# Run this ON the device, from the currently-running stock OS, e.g.:
#   scp flash-spare-slot.sh root@<printer-ip>:/tmp/
#   ssh root@<printer-ip> 'sh /tmp/flash-spare-slot.sh /path/to/xImage /path/to/rootfs.squashfs [/path/to/build-manifest.txt]'
#
# Every check below aborts loudly rather than guessing or proceeding on a
# mismatch - this script is the one place where a silent mistake could
# overrun into a neighboring partition, so nothing here is allowed to be
# approximate.
#
# 2026-07-23: the optional 3rd argument (build-manifest.txt, produced by
# 05-final-build.sh) is checked against BEFORE writing anything, closing a
# real gap found this session - a 55MB rootfs transfer got killed mid-flight
# by an over-tight SCP wrapper timeout once, leaving a truncated file on the
# device that this script's own write-verify loop couldn't have caught (it
# only proves the device matches whatever local file it was given, not that
# the local file matches what the build host actually produced). Strongly
# recommended; the script still runs without it (matching every previous
# real use this session) but skips this specific class of check.

set -e

KERNEL_IMG="$1"
ROOTFS_IMG="$2"
MANIFEST="$3"

KERNEL_DEV=/dev/mmcblk0p6
ROOTFS_DEV=/dev/mmcblk0p8
KERNEL_LABEL_LINK=/dev/disk/by-partlabel/kernel2
ROOTFS_LABEL_LINK=/dev/disk/by-partlabel/rootfs2

# Real, confirmed partition capacities (FIRMWARE.md sec 4b/19) - not
# recomputed from /proc/partitions at runtime, so a corrupted or unexpected
# partition table can't silently change what this script considers "safe".
KERNEL_PART_BYTES=8388608
ROOTFS_PART_BYTES=524288000

die() {
	echo "ABORT: $1" 1>&2
	exit 1
}

[ -n "$KERNEL_IMG" ] && [ -n "$ROOTFS_IMG" ] || \
	die "usage: $0 <xImage> <rootfs.squashfs>"
[ -f "$KERNEL_IMG" ] || die "$KERNEL_IMG does not exist"
[ -f "$ROOTFS_IMG" ] || die "$ROOTFS_IMG does not exist"

# 1. Confirm the partition-label symlinks resolve to exactly the device
#    nodes this script hardcodes - if the GPT ever changes, this must fail
#    loudly rather than silently write to the wrong partition.
[ "$(readlink -f "$KERNEL_LABEL_LINK")" = "$KERNEL_DEV" ] || \
	die "kernel2 label resolves to $(readlink -f "$KERNEL_LABEL_LINK"), expected $KERNEL_DEV"
[ "$(readlink -f "$ROOTFS_LABEL_LINK")" = "$ROOTFS_DEV" ] || \
	die "rootfs2 label resolves to $(readlink -f "$ROOTFS_LABEL_LINK"), expected $ROOTFS_DEV"

# 2. Confirm we are NOT about to write to whatever is currently mounted as
#    root - the entire point of using the spare slot is that it's idle.
CURRENT_ROOT_SRC=$(awk '$2 == "/" {print $1}' /proc/mounts)
[ "$CURRENT_ROOT_SRC" != "$KERNEL_DEV" ] || die "$KERNEL_DEV is the current root device - refusing"
[ "$CURRENT_ROOT_SRC" != "$ROOTFS_DEV" ] || die "$ROOTFS_DEV is the current root device - refusing"

# 3. Confirm the source images actually fit, with size compared as real
#    numbers, not assumed.
KERNEL_SIZE=$(wc -c < "$KERNEL_IMG")
ROOTFS_SIZE=$(wc -c < "$ROOTFS_IMG")
[ "$KERNEL_SIZE" -gt 0 ] || die "$KERNEL_IMG is empty"
[ "$ROOTFS_SIZE" -gt 0 ] || die "$ROOTFS_IMG is empty"
[ "$KERNEL_SIZE" -le "$KERNEL_PART_BYTES" ] || \
	die "xImage is $KERNEL_SIZE bytes, exceeds kernel2 partition capacity of $KERNEL_PART_BYTES bytes"
[ "$ROOTFS_SIZE" -le "$ROOTFS_PART_BYTES" ] || \
	die "rootfs.squashfs is $ROOTFS_SIZE bytes, exceeds rootfs2 partition capacity of $ROOTFS_PART_BYTES bytes"

echo "xImage:          $KERNEL_SIZE / $KERNEL_PART_BYTES bytes ($(( KERNEL_SIZE * 100 / KERNEL_PART_BYTES ))% full)"
echo "rootfs.squashfs: $ROOTFS_SIZE / $ROOTFS_PART_BYTES bytes ($(( ROOTFS_SIZE * 100 / ROOTFS_PART_BYTES ))% full)"

# 4. If a build manifest was given, verify the transferred files match the
#    build host's own recorded size+sha256 exactly - catches truncated or
#    otherwise corrupted transfers before they ever reach a real partition.
if [ -n "$MANIFEST" ]; then
	[ -f "$MANIFEST" ] || die "manifest $MANIFEST does not exist"
	get_field() { grep "^$1=" "$MANIFEST" | cut -d= -f2-; }

	EXPECT_KERNEL_SIZE=$(get_field xImage_size)
	EXPECT_KERNEL_SHA256=$(get_field xImage_sha256)
	EXPECT_ROOTFS_SIZE=$(get_field rootfs_squashfs_size)
	EXPECT_ROOTFS_SHA256=$(get_field rootfs_squashfs_sha256)

	[ -n "$EXPECT_KERNEL_SIZE" ] && [ -n "$EXPECT_KERNEL_SHA256" ] || \
		die "manifest $MANIFEST missing xImage_size/xImage_sha256"
	[ -n "$EXPECT_ROOTFS_SIZE" ] && [ -n "$EXPECT_ROOTFS_SHA256" ] || \
		die "manifest $MANIFEST missing rootfs_squashfs_size/rootfs_squashfs_sha256"

	[ "$KERNEL_SIZE" = "$EXPECT_KERNEL_SIZE" ] || \
		die "xImage size $KERNEL_SIZE does not match manifest ($EXPECT_KERNEL_SIZE) - transfer likely truncated or wrong file"
	[ "$ROOTFS_SIZE" = "$EXPECT_ROOTFS_SIZE" ] || \
		die "rootfs.squashfs size $ROOTFS_SIZE does not match manifest ($EXPECT_ROOTFS_SIZE) - transfer likely truncated or wrong file"

	ACTUAL_KERNEL_SHA256=$(sha256sum "$KERNEL_IMG" | awk '{print $1}')
	ACTUAL_ROOTFS_SHA256=$(sha256sum "$ROOTFS_IMG" | awk '{print $1}')
	[ "$ACTUAL_KERNEL_SHA256" = "$EXPECT_KERNEL_SHA256" ] || \
		die "xImage sha256 $ACTUAL_KERNEL_SHA256 does not match manifest ($EXPECT_KERNEL_SHA256)"
	[ "$ACTUAL_ROOTFS_SHA256" = "$EXPECT_ROOTFS_SHA256" ] || \
		die "rootfs.squashfs sha256 $ACTUAL_ROOTFS_SHA256 does not match manifest ($EXPECT_ROOTFS_SHA256)"

	echo "Manifest verified OK: both files match $MANIFEST exactly (size + sha256)"
else
	echo "WARNING: no build manifest given - skipping transfer-integrity verification against the build host" >&2
fi

write_and_verify() {
	src="$1"
	dev="$2"
	size="$3"
	name="$4"

	src_sum=$(md5sum "$src" | awk '{print $1}')

	echo "Writing $name ($size bytes) to $dev ..."
	dd if="$src" of="$dev" bs=1M conv=fsync 2>/dev/null

	# Read back exactly $size bytes (never the whole partition - deliberate,
	# so this comparison can never be fooled by leftover trailing data from a
	# previous, larger image) and compare checksums.
	dev_sum=$(dd if="$dev" bs=1M count=$(( (size + 1048575) / 1048576 )) 2>/dev/null | \
		head -c "$size" | md5sum | awk '{print $1}')

	[ "$src_sum" = "$dev_sum" ] || \
		die "$name write verification FAILED: source md5 $src_sum != device md5 $dev_sum"

	echo "$name write verified OK (md5 $src_sum)"
}

write_and_verify "$KERNEL_IMG" "$KERNEL_DEV" "$KERNEL_SIZE" "xImage"
write_and_verify "$ROOTFS_IMG" "$ROOTFS_DEV" "$ROOTFS_SIZE" "rootfs.squashfs"

echo
echo "Both images written and verified. The ota marker has NOT been touched -"
echo "the device will still boot the current stock slot on the next reboot."
echo "Flipping the marker to actually attempt the custom image is a separate,"
echo "deliberate step."
