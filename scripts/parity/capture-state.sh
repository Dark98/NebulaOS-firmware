#!/bin/sh
# Nebula Pad stock-parity audit (see FIRMWARE.md) - read-only runtime state
# capture. Safe to run on stock OR custom: every command is best-effort
# (missing tools/paths are recorded as "N/A", never fatal) since stock's
# BusyBox and this project's Buildroot rootfs don't carry the same tool
# set. Nothing here writes to any device, partition, or hardware register -
# every command is a read (cat/find/ls/dump), never a write or toggle.
#
# Usage: sh capture-state.sh <output-dir>
# Run once on stock, once on custom (same physical device, same boot
# stage), then diff the two output directories.

OUT="${1:-/tmp/parity-capture}"
mkdir -p "$OUT"

# Real bug found running this on stock (FIRMWARE.md): `bluetoothctl show`
# hangs indefinitely with no TTY/interactive session (BlueZ D-Bus handshake
# never completes), and this BusyBox build has no `timeout` applet to bound
# it with. Every capture below is bounded by this portable watchdog instead -
# background the real command, race it against a sleep+kill sidecar, whichever
# finishes first wins. 8s is generous for what should all be instant reads;
# a command that needs longer than that to inventory hardware state has
# itself become the finding worth investigating.
run() {
	# $1: output file name (relative to $OUT)  $2..: command
	name="$1"
	shift
	if ! command -v "$1" >/dev/null 2>&1 && [ "$1" != "cat" ] && [ "$1" != "find" ]; then
		echo "N/A: '$1' not present on this system" > "$OUT/$name"
		return
	fi
	"$@" > "$OUT/$name" 2>&1 &
	cmd_pid=$!
	( sleep 8; kill -9 "$cmd_pid" 2>/dev/null ) &
	watchdog_pid=$!
	if ! wait "$cmd_pid" 2>/dev/null; then
		echo "TIMEOUT_OR_ERROR: '$name' did not complete within 8s or exited non-zero" >> "$OUT/$name"
	fi
	kill "$watchdog_pid" 2>/dev/null
	wait "$watchdog_pid" 2>/dev/null
}

echo "== capturing to $OUT =="

# --- core /proc/sys inventory ---
run 01-uname.txt uname -a
run 02-cmdline.txt cat /proc/cmdline
run 03-cpuinfo.txt cat /proc/cpuinfo
run 04-meminfo.txt cat /proc/meminfo
run 05-interrupts.txt cat /proc/interrupts
run 06-iomem.txt cat /proc/iomem
run 07-devices.txt cat /proc/devices
run 08-mounts.txt cat /proc/mounts
run 09-crypto.txt cat /proc/crypto
run 10-lsmod.txt lsmod
run 11-dmesg.txt dmesg
run 12-dev-tree.txt find /dev -maxdepth 3
run 13-platform-devices.txt find /sys/bus/platform/devices -maxdepth 1
run 14-sys-class.txt find /sys/class -maxdepth 3

# --- subsystem-specific tools (best-effort, many wont exist on stock) ---
run 20-lsusb.txt lsusb
run 21-lsusb-tree.txt lsusb -t
run 22-tty-serial.txt cat /proc/tty/driver/serial
run 23-i2cdetect-list.txt i2cdetect -l
run 24-v4l2-devices.txt v4l2-ctl --list-devices
run 25-media-ctl.txt media-ctl -p
run 26-iw-phy.txt iw phy
run 27-iw-dev.txt iw dev
run 28-iw-reg.txt iw reg get
run 29-rfkill.txt rfkill list
run 30-bluetoothctl.txt bluetoothctl show

# --- debugfs (best-effort - path may not be mounted, or may need mount) ---
if [ ! -d /sys/kernel/debug/gpio ] && [ -d /sys/kernel/debug ]; then
	mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
fi
run 40-debugfs-gpio.txt cat /sys/kernel/debug/gpio
run 41-debugfs-pinctrl-pins.txt cat /sys/kernel/debug/pinctrl/*/pins
run 42-debugfs-pinctrl-pinmux-pins.txt cat /sys/kernel/debug/pinctrl/*/pinmux-pins
run 43-debugfs-pinctrl-pingroups.txt cat /sys/kernel/debug/pinctrl/*/pingroups
run 44-debugfs-clk-summary.txt cat /sys/kernel/debug/clk/clk_summary
run 45-debugfs-regulator-summary.txt cat /sys/kernel/debug/regulator_summary
run 46-debugfs-wakeup-sources.txt cat /sys/kernel/debug/wakeup_sources
run 47-debugfs-mmc.txt find /sys/kernel/debug/mmc0 /sys/kernel/debug/mmc1 /sys/kernel/debug/mmc2 -type f -exec sh -c 'echo "== {} =="; cat {}' \;
run 48-debugfs-dma.txt find /sys/kernel/debug/dma -type f -exec sh -c 'echo "== {} =="; cat {}' \;

# --- printer/app-stack service state (custom-only, harmless N/A on stock) ---
run 50-ps.txt ps
run 51-wpa-status.txt wpa_cli -i wlan0 status
run 52-wlan0-addr.txt ip -4 addr show wlan0

echo "== capture complete: $OUT =="
