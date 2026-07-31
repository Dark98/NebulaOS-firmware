#!/bin/sh
#
# Offline, repeatable tests for scripts/build/preempt-variant.sh (pre-
# qualification mission Phase A8, 2026-07-31). Operates against the real
# tracked Kconfig fragment (artifacts/buildroot-halley5-v30-image/
# halley5-nebulaos-fragment.config) - it's a small, git-tracked text file
# in the main repo, not a gitignored vendor checkout, so a trap
# guarantees `git checkout --` restores it to a clean, unmodified state
# on exit, pass or fail.
#
# Usage: sh tests/preempt-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/preempt-variant.sh"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"

PASS=0
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=$((FAIL + 1))
}

pass() {
	PASS=$((PASS + 1))
}

cleanup() {
	git -C "$REPO_ROOT" checkout -- "$FRAGMENT" 2>/dev/null
}
trap cleanup EXIT INT TERM

[ -f "$FRAGMENT" ] || {
	echo "SKIP: $FRAGMENT not present"
	exit 0
}

# --- Test 1: R0 leaves the tracked fragment file git-clean (today's
# real baseline needs no override at all). ---
sh "$VARIANT_SCRIPT" R0 >/dev/null
if [ -z "$(git -C "$REPO_ROOT" status --porcelain -- "$FRAGMENT")" ]; then
	pass
else
	fail "R0 did not produce a git-clean fragment file"
fi

# --- Test 2: R1 adds exactly one CONFIG_PREEMPT_RT=y line. ---
sh "$VARIANT_SCRIPT" R1 >/dev/null
count=$(grep -c '^CONFIG_PREEMPT_RT=y$' "$FRAGMENT")
if [ "$count" = "1" ]; then
	pass
else
	fail "R1 produced $count CONFIG_PREEMPT_RT=y lines, expected exactly 1"
fi

# --- Test 3: R1 never touches CONFIG_HZ (mission's own explicit
# instruction - HZ is never part of this A/B). ---
if grep -q 'CONFIG_HZ' "$FRAGMENT"; then
	fail "R1 introduced a CONFIG_HZ line into the fragment - HZ must never be touched by this variant"
else
	pass
fi

# --- Test 4: re-applying R1 twice in a row is idempotent (no duplicate
# blocks/lines). ---
sh "$VARIANT_SCRIPT" R1 >/dev/null
count=$(grep -c '^CONFIG_PREEMPT_RT=y$' "$FRAGMENT")
if [ "$count" = "1" ]; then
	pass
else
	fail "re-applying R1 produced $count CONFIG_PREEMPT_RT=y lines, expected exactly 1 (not idempotent)"
fi

# --- Test 5: switching from R1 back to R0 restores a byte-identical,
# git-clean baseline (no residual blank lines or partial blocks left
# behind). ---
sh "$VARIANT_SCRIPT" R0 >/dev/null
if [ -z "$(git -C "$REPO_ROOT" status --porcelain -- "$FRAGMENT")" ]; then
	pass
else
	fail "switching from R1 back to R0 left the fragment file modified: $(git -C "$REPO_ROOT" diff -- "$FRAGMENT")"
fi

# --- Test 6: an unknown variant name is rejected, not silently applied. ---
if sh "$VARIANT_SCRIPT" R9 >/dev/null 2>&1; then
	fail "an unknown variant name 'R9' was accepted instead of rejected"
else
	pass
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
