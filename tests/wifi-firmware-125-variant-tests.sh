#!/bin/sh
#
# CYW43430 Wi-Fi firmware engineering test (2026-08-09): offline regression
# coverage for scripts/build/wifi-firmware-125-variant.sh's clmload_status
# diagnostic patch (apply_diag_patch()/revert_diag_patch()) - the one part
# of that script risky enough (kernel source text patching) to warrant its
# own test, run against a real, throwaway fixture file, never the real
# vendor checkout.
#
# Does NOT exercise apply()/revert()'s firmware-staging path (that needs
# real pinned-hash-matching binary files and a real vendor kernel tree -
# out of scope for a fast offline test; verified manually against the
# real build instead, same as this project's other build-time-only
# scripts).
#
# Usage: sh tests/wifi-firmware-125-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/wifi-firmware-125-variant.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/wifi-firmware-125-variant-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# A real, throwaway stand-in for common.c: just enough context around the
# actual target line (copied verbatim from the real pinned kernel source)
# to prove the patch is scoped correctly and doesn't touch neighboring
# lines - including a fake ROAMOFF1-style line elsewhere in the file, to
# prove this patch never touches that region either.
make_fixture() {
	dest="$1"
	cat > "$dest" <<'EOF'
/* fixture: fake ROAMOFF1 region, must never be touched by this patch */
static int brcmf_roamoff = 1;

static int brcmf_c_download_blob(struct brcmf_if *ifp,
				 const void *data, size_t size,
				 const char *loadvar, const char *statvar)
{
	if (err) {
		bphy_err(drvr, "%s (%zu byte file) failed (%d)\n",
			 loadvar, size, err);
		/* Retrieve status and print */
		err = brcmf_fil_iovar_int_get(ifp, statvar, &status);
		if (err)
			bphy_err(drvr, "get %s failed (%d)\n", statvar, err);
		else
			brcmf_dbg(INFO, "%s=%d\n", statvar, status);
		err = -EIO;
	}

	kfree(chunk_buf);
	return err;
}
EOF
}

# --- Test 1: apply_diag_patch() swaps the exact line, nothing else ------

fixture1="$WORK/common1.c"
make_fixture "$fixture1"
COMMON_C="$fixture1" WIFI_125_VARIANT_NO_AUTORUN=1 \
	sh -c ". '$VARIANT_SCRIPT'; apply_diag_patch" > "$WORK/t1.log" 2>&1
if grep -qF 'bphy_err(drvr, "ENGINEERING DIAG clmload_status %s=%d\n", statvar, status);' "$fixture1" \
	&& ! grep -qF 'brcmf_dbg(INFO, "%s=%d\n", statvar, status);' "$fixture1"; then
	pass "apply_diag_patch: swaps brcmf_dbg for bphy_err on the target line"
else
	fail "apply_diag_patch: target line not correctly swapped: $(cat "$WORK/t1.log")"
fi
if grep -qF 'static int brcmf_roamoff = 1;' "$fixture1" \
	&& grep -qF 'bphy_err(drvr, "get %s failed (%d)\n", statvar, err);' "$fixture1"; then
	pass "apply_diag_patch: ROAMOFF1 fixture region and neighboring lines untouched"
else
	fail "apply_diag_patch: touched something outside its own scope"
fi

# --- Test 2: apply_diag_patch() is idempotent ----------------------------

COMMON_C="$fixture1" WIFI_125_VARIANT_NO_AUTORUN=1 \
	sh -c ". '$VARIANT_SCRIPT'; apply_diag_patch" > "$WORK/t2.log" 2>&1
occurrences=$(grep -cF 'ENGINEERING DIAG clmload_status' "$fixture1")
if [ "$occurrences" -eq 1 ] && grep -q "already applied" "$WORK/t2.log"; then
	pass "apply_diag_patch: idempotent - re-running does not duplicate the patch"
else
	fail "apply_diag_patch: not idempotent (occurrences=$occurrences): $(cat "$WORK/t2.log")"
fi

# --- Test 3: revert_diag_patch() restores the exact original line -------

fixture3="$WORK/common3.c"
make_fixture "$fixture3"
original_content=$(cat "$fixture3")
COMMON_C="$fixture3" WIFI_125_VARIANT_NO_AUTORUN=1 \
	sh -c ". '$VARIANT_SCRIPT'; apply_diag_patch; revert_diag_patch" > "$WORK/t3.log" 2>&1
reverted_content=$(cat "$fixture3")
if [ "$original_content" = "$reverted_content" ]; then
	pass "revert_diag_patch: apply then revert restores byte-identical original content"
else
	fail "revert_diag_patch: content differs after apply+revert round-trip"
fi

# --- Test 4: revert_diag_patch() on an already-clean file is a safe no-op

fixture4="$WORK/common4.c"
make_fixture "$fixture4"
before=$(cat "$fixture4")
COMMON_C="$fixture4" WIFI_125_VARIANT_NO_AUTORUN=1 \
	sh -c ". '$VARIANT_SCRIPT'; revert_diag_patch" > "$WORK/t4.log" 2>&1
after=$(cat "$fixture4")
if [ "$before" = "$after" ]; then
	pass "revert_diag_patch: no-op when the diagnostic was never applied"
else
	fail "revert_diag_patch: unexpectedly modified a file with no patch applied"
fi

# --- Test 5: apply_diag_patch() refuses to guess against divergent source

fixture5="$WORK/common5.c"
echo "totally unrelated content, no matching line at all" > "$fixture5"
COMMON_C="$fixture5" WIFI_125_VARIANT_NO_AUTORUN=1 \
	sh -c ". '$VARIANT_SCRIPT'; apply_diag_patch" > "$WORK/t5.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q "kernel source has diverged" "$WORK/t5.log"; then
	pass "apply_diag_patch: refuses to guess when the expected line is absent"
else
	fail "apply_diag_patch: should have failed loudly on divergent source (rc=$rc): $(cat "$WORK/t5.log")"
fi

echo
echo "wifi-firmware-125-variant-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
