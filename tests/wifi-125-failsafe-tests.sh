#!/bin/sh
#
# CYW43430 Wi-Fi 125 engineering test (2026-08-08): offline regression
# coverage for S98nebulaos-wifi-125-failsafe. Never touches a real network
# interface, real /dev/mmcblk0p1, or a real reboot - SYSNET/MARKER_DEV/
# IFACE point at fixture paths, and PATH is prepended with fixture `ip`/
# `ping` binaries so the health check's pass/fail outcome is fully
# controlled and deterministic (a real `ping` to a made-up IP would be
# both slow and flaky - it might even resolve to something real).
#
# Usage: sh tests/wifi-125-failsafe-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
FAILSAFE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S98nebulaos-wifi-125-failsafe"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/wifi-125-failsafe-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# --- Fixture `ip`/`ping` binaries, behavior controlled via env vars -----

FIXTURE_BIN="$WORK/bin"
mkdir -p "$FIXTURE_BIN"

cat > "$FIXTURE_BIN/ip" <<'EOF'
#!/bin/sh
# Minimal fixture standing in for the real `ip` tool - only implements
# the exact two invocations S98nebulaos-wifi-125-failsafe actually makes.
case "$*" in
	"-4 addr show "*)
		[ "${FIXTURE_HAS_IP:-0}" = "1" ] && echo "    inet 192.0.2.50/24 brd 192.0.2.255 scope global wlan0"
		;;
	"-4 route show default dev "*)
		[ "${FIXTURE_HAS_ROUTE:-0}" = "1" ] && echo "default via 192.0.2.1 dev wlan0"
		;;
esac
exit 0
EOF
chmod +x "$FIXTURE_BIN/ip"

cat > "$FIXTURE_BIN/ping" <<'EOF'
#!/bin/sh
exit "${FIXTURE_PING_EXIT:-1}"
EOF
chmod +x "$FIXTURE_BIN/ping"

cat > "$FIXTURE_BIN/wpa_cli" <<'EOF'
#!/bin/sh
echo "wpa_state=FIXTURE_STATE"
EOF
chmod +x "$FIXTURE_BIN/wpa_cli"

# Real, throwaway /sys/class/net-shaped fixture tree.
make_sysnet() {
	dir="$1"; carrier="$2"
	rm -rf "$dir"
	mkdir -p "$dir/wlan0"
	[ -n "$carrier" ] && echo "$carrier" > "$dir/wlan0/carrier"
}

run_start() {
	# $1: SENTINEL present (1/0). $2: SYSNET dir. $3: FIXTURE_HAS_IP.
	# $4: FIXTURE_HAS_ROUTE. $5: FIXTURE_PING_EXIT. $6: timeout. $7: interval.
	sentinel_present="$1"; sysnet="$2"; has_ip="$3"; has_route="$4"; ping_exit="$5"; timeout="$6"; interval="$7"
	sentinel="$WORK/sentinel"
	if [ "$sentinel_present" = "1" ]; then
		: > "$sentinel"
	else
		rm -f "$sentinel"
	fi
	marker="$WORK/marker.bin"
	# 512-byte fixture "partition" - same size class as the real
	# mmcblk0p1 marker area, pre-filled with a DIFFERENT marker so a
	# passing (no-op) run leaves visibly untouched content behind.
	dd if=/dev/zero bs=1 count=512 2>/dev/null | tr '\0' 'X' > "$marker"
	printf 'ota:kernel2\n\n' | dd of="$marker" conv=notrunc 2>/dev/null

	rm -f "$WORK/diagnostics.log"
	PATH="$FIXTURE_BIN:$PATH" \
		SENTINEL="$sentinel" MARKER_DEV="$marker" IFACE=wlan0 SYSNET="$sysnet" \
		WIFI_125_FAILSAFE_TIMEOUT="$timeout" WIFI_125_FAILSAFE_INTERVAL="$interval" \
		FIXTURE_HAS_IP="$has_ip" FIXTURE_HAS_ROUTE="$has_route" FIXTURE_PING_EXIT="$ping_exit" \
		LOGFILE="$WORK/diagnostics.log" \
		S98NEBULAOS_WIFI_125_FAILSAFE_NO_AUTORUN=1 \
		sh -c ". '$FAILSAFE_SCRIPT'; start" > "$WORK/out.log" 2>&1
	echo "$?" > "$WORK/rc"
}

# --- Test 1: no sentinel - pure no-op, marker untouched, exit 0 --------

sysnet1="$WORK/sysnet1"; make_sysnet "$sysnet1" ""
run_start 0 "$sysnet1" 0 0 1 3 1
rc=$(cat "$WORK/rc")
marker_content=$(cat "$WORK/marker.bin")
if [ "$rc" -eq 0 ] && printf '%s' "$marker_content" | grep -q "^ota:kernel2"; then
	pass "no sentinel: pure no-op, marker left completely untouched"
else
	fail "no sentinel: expected no-op (rc=0, marker untouched), got rc=$rc marker=$(cat "$WORK/marker.bin" | head -c 20) ($(cat "$WORK/out.log"))"
fi

# --- Test 2: sentinel present, Wi-Fi healthy immediately - cancels ------
# --- failsafe fast, marker untouched, exit 0 ----------------------------

sysnet2="$WORK/sysnet2"; make_sysnet "$sysnet2" "1"
run_start 1 "$sysnet2" 1 1 0 30 1
rc=$(cat "$WORK/rc")
marker_content=$(cat "$WORK/marker.bin")
if [ "$rc" -eq 0 ] && grep -q "cancelling failsafe" "$WORK/out.log" && printf '%s' "$marker_content" | grep -q "^ota:kernel2"; then
	pass "healthy Wi-Fi: failsafe cancels immediately, marker untouched, boot continues normally"
else
	fail "healthy Wi-Fi: expected fast cancel with marker untouched (rc=$rc): $(cat "$WORK/out.log")"
fi
if [ -f "$WORK/diagnostics.log" ] && grep -q "start (t=0s)" "$WORK/diagnostics.log" && grep -q "success" "$WORK/diagnostics.log"; then
	pass "healthy Wi-Fi: diagnostics log written to the persistent LOGFILE path with start+success snapshots"
else
	fail "healthy Wi-Fi: diagnostics log missing expected start/success snapshots: $(cat "$WORK/diagnostics.log" 2>/dev/null)"
fi

# --- Test 3: sentinel present, Wi-Fi never comes up (no carrier at all) -
# --- times out and reverts to stock, marker correctly rewritten --------

sysnet3="$WORK/sysnet3"; make_sysnet "$sysnet3" "0"
run_start 1 "$sysnet3" 0 0 1 2 1
rc=$(cat "$WORK/rc")
marker_bytes=$(head -c 13 "$WORK/marker.bin")
if [ "$rc" -ne 0 ] && [ "$marker_bytes" = "$(printf 'ota:kernel\n\n')" ] && grep -q "reverting to stock" "$WORK/out.log"; then
	pass "Wi-Fi never associates: failsafe times out, reverts marker to stock, verified byte format"
else
	fail "Wi-Fi never associates: expected marker reverted to ota:kernel (rc=$rc, marker='$marker_bytes'): $(cat "$WORK/out.log")"
fi
if [ -f "$WORK/diagnostics.log" ] && grep -q "start (t=0s)" "$WORK/diagnostics.log" \
	&& grep -q "timeout reached" "$WORK/diagnostics.log" && grep -q "wifi_healthy() sub-checks" "$WORK/diagnostics.log"; then
	pass "Wi-Fi never associates: diagnostics log captured start+timeout snapshots on the persistent partition, survives the revert"
else
	fail "Wi-Fi never associates: diagnostics log missing expected content: $(cat "$WORK/diagnostics.log" 2>/dev/null)"
fi

# --- Test 4: carrier up but never gets an IP - still fails, still -------
# --- reverts (proves every stage of the check is actually required) -----

sysnet4="$WORK/sysnet4"; make_sysnet "$sysnet4" "1"
run_start 1 "$sysnet4" 0 0 1 2 1
rc=$(cat "$WORK/rc")
marker_bytes=$(head -c 13 "$WORK/marker.bin")
if [ "$rc" -ne 0 ] && [ "$marker_bytes" = "$(printf 'ota:kernel\n\n')" ]; then
	pass "associated but no DHCP lease: still correctly treated as unhealthy, reverts to stock"
else
	fail "associated-but-no-IP case did not revert as expected (rc=$rc, marker='$marker_bytes')"
fi

# --- Test 5: full local network stack up but gateway unreachable --------
# --- (ping fails) - still fails, still reverts --------------------------

sysnet5="$WORK/sysnet5"; make_sysnet "$sysnet5" "1"
run_start 1 "$sysnet5" 1 1 1 2 1
rc=$(cat "$WORK/rc")
marker_bytes=$(head -c 13 "$WORK/marker.bin")
if [ "$rc" -ne 0 ] && [ "$marker_bytes" = "$(printf 'ota:kernel\n\n')" ]; then
	pass "IP acquired but gateway unreachable: still correctly treated as unhealthy, reverts to stock"
else
	fail "gateway-unreachable case did not revert as expected (rc=$rc, marker='$marker_bytes')"
fi

# --- Test 6: marker readback mismatch - must NOT claim success, must ----
# --- print the manual-reboot safety line, must not loop -----------------

test_readback_mismatch() {
	sentinel="$WORK/sentinel-t6"; : > "$sentinel"
	marker="$WORK/marker-t6.bin"
	# A marker "device" that silently fails to actually store what's
	# written (simulated via a directory instead of a writable file -
	# writes into it will error, so readback can never match).
	mkdir -p "$marker"
	PATH="$FIXTURE_BIN:$PATH" \
		SENTINEL="$sentinel" MARKER_DEV="$marker" IFACE=wlan0 SYSNET="$WORK/sysnet-t6-empty" \
		WIFI_125_FAILSAFE_TIMEOUT=1 WIFI_125_FAILSAFE_INTERVAL=1 \
		FIXTURE_HAS_IP=0 FIXTURE_HAS_ROUTE=0 FIXTURE_PING_EXIT=1 \
		S98NEBULAOS_WIFI_125_FAILSAFE_NO_AUTORUN=1 \
		sh -c ". '$FAILSAFE_SCRIPT'; start" > "$WORK/t6.log" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ] && grep -q "SAFE_FOR_MANUAL_REBOOT_TO_STOCK=YES" "$WORK/t6.log" \
		&& grep -q "refusing to reboot blind" "$WORK/t6.log"; then
		pass "marker readback mismatch: refuses to claim success, reports SAFE_FOR_MANUAL_REBOOT_TO_STOCK=YES"
	else
		fail "marker readback mismatch: expected a safe stop with the manual-reboot report (rc=$rc): $(cat "$WORK/t6.log")"
	fi
}
test_readback_mismatch

# --- Test 7: periodic (~20s) diagnostic snapshots during a longer -------
# --- failing run, not just start/end -------------------------------------

sysnet7="$WORK/sysnet7"; make_sysnet "$sysnet7" "0"
run_start 1 "$sysnet7" 0 0 1 45 5
snapshot_count=$(grep -c "^=== S98nebulaos-wifi-125-failsafe diagnostics:" "$WORK/diagnostics.log" 2>/dev/null || echo 0)
if [ "$snapshot_count" -ge 3 ]; then
	pass "longer failing run: periodic diagnostic snapshots captured mid-wait, not just start/end ($snapshot_count total)"
else
	fail "longer failing run: expected at least 3 diagnostic snapshots (start, mid-wait, timeout), got $snapshot_count"
fi

echo
echo "wifi-125-failsafe-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
