# Shared by S00revert-safety and S99confirm-good (FIRMWARE.md sec 21/23) -
# writes the ota partition marker in the exact byte format both Creality's
# own stock ota_utils.sh (mmc_write_str: `echo $str > $dev`) and
# ballaswag/ingenic-usbboot's swap_ota_partition() (writes "ota:kernel\n\n"
# into a zeroed 512-byte buffer) use. Verified byte-for-byte via a local
# regular-file simulation before ever being trusted on real hardware -
# tested output was an exact match for the live device's own raw partition
# dump: "6f 74 61 3a 6b 65 72 6e 65 6c 0a 0a 00 00 ...".
#
# A bare `echo -n "ota:kernel"` (10 bytes, no trailing newline) would NOT
# match usbboot's own read-check (`strncmp(ota, "ota:kernel\n", 11)`) and
# would fall into its "unexpected value" branch unless --force-swap-ota is
# used - this exists specifically to avoid that mismatch.

write_ota_marker() {
	# $1: "ota:kernel" or "ota:kernel2"
	# Plain bs=1 seek/count writes only - avoids relying on dd conv=sync,
	# whose support in this BusyBox build isn't confirmed. Length computed via
	# ${#1} (shell parameter expansion), not command substitution - $(...)
	# strips trailing newlines, which would silently defeat the padding math.
	printf '%s\n\n' "$1" > /dev/mmcblk0p1
	marker_len=$((${#1} + 2))
	remaining=$((512 - marker_len))
	if [ "$remaining" -gt 0 ]; then
		dd if=/dev/zero of=/dev/mmcblk0p1 bs=1 seek="$marker_len" count="$remaining" 2>/dev/null
	fi
}
