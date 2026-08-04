#!/bin/sh
#
# Offline, repeatable test for scripts/build/overlay/etc/init.d/S50webcam's
# ustreamer invocation (NebulaOS WiFi/camera IRQ contention mission,
# 2026-08-03/04). Source-inspection only - proves the --tcp-nodelay flag is
# present in the actual command line ustreamer gets started with, which is
# what live frame-timing measurement showed reduces WiFi-path stream
# jitter. Does not and cannot prove the live network behavior itself -
# that was verified separately, live, against real hardware (see
# docs/NEBULAOS_WIFI_CAMERA_IRQ_CONTENTION_REPORT.md).
#
# Usage: sh tests/webcam-tcp-nodelay-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
TARGET="$REPO_ROOT/scripts/build/overlay/etc/init.d/S50webcam"

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$TARGET" ] || { echo "SKIP: $TARGET not present"; exit 0; }

# --- Test 1: syntax is valid POSIX sh. ---
if sh -n "$TARGET" 2>/dev/null; then
	pass
else
	fail "$TARGET has a shell syntax error"
fi

# --- Test 2: the ustreamer invocation inside start_ustreamer() includes
# --tcp-nodelay on the same logical command as --port=8080 (i.e. it's
# actually part of the real ustreamer command line, not just present
# somewhere else in the file, e.g. a comment). ---
INVOCATION=$(awk '/^start_ustreamer\(\) \{/,/^}/' "$TARGET" | grep -v '^\s*#')
if echo "$INVOCATION" | tr -d '\t\n\\' | grep -q -- '--port=8080--tcp-nodelay\|--tcp-nodelay.*--port=8080\|--port=8080.*--tcp-nodelay'; then
	pass
else
	fail "start_ustreamer() does not include --tcp-nodelay in the real ustreamer command line: $INVOCATION"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
