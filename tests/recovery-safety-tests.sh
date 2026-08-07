#!/bin/sh
#
# Clean-Update + Virgin Baseline mission, Phase 5 (2026-08-08): offline
# assertions that Moonraker's built-in Recovery (soft: fetch + reset to
# the tracked remote ref; hard: full re-clone - see
# docs/NEBULAOS_UPDATER_AUDIT.md) cannot revert any accepted feature.
#
# This is deliberately NOT a fixture-based test like the others under
# tests/ - "recovery target == canonical branch" is a claim about the
# REAL remote repository Recovery actually resets to, not about local
# fixtures, so this does a real, read-only, shallow clone of
# coreflake1/NebulaOS-klipper's master branch (network required, no
# device involved) and checks it directly. This is the same class of
# real-remote verification Phase 1's own branch-unification fix used to
# confirm its fast-forward was safe before pushing it.
#
# Usage: sh tests/recovery-safety-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/recovery-safety-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

. "$DEPS_MANIFEST"

# The exact set of NebulaOS-accepted klippy/extras files this project's
# own klippy_extras/ tracks as reviewable source of truth (see
# 04-cross-compile-app-stack.sh's own comment on this). Losing any of
# these to a Recovery reset would silently regress an accepted feature.
ACCEPTED_FILES="z_compensate.py prtouch_v2.py prtouch_probe.py prtouch_mcu.py prtouch_nozzle.py prtouch_calibration.py"

# --- Test 1: manifest, factory-seed, and migrate all agree on one branch ---
# The exact class of bug Phase 1 found: two branches existed, only one was
# actually tracked/pinned, and they silently diverged. This asserts the
# three places that hardcode "which branch is canonical" can never drift
# apart again without this test catching it.

test_branch_consistency() {
	manifest_branch="$KLIPPER_BRANCH"
	factory_seed_branch=$(grep -o 'seed_git_app klipper [a-zA-Z0-9_-]*' \
		"$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-factory-seed" | awk '{print $3}')
	migrate_branch=$(grep -o 'reseed_git_app klipper [a-zA-Z0-9_-]*' \
		"$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate" | awk '{print $3}')

	if [ "$manifest_branch" = "master" ] && [ "$manifest_branch" = "$factory_seed_branch" ] \
		&& [ "$manifest_branch" = "$migrate_branch" ]; then
		pass "manifest ($manifest_branch), factory-seed ($factory_seed_branch), and migrate ($migrate_branch) all track the same canonical klipper branch"
	else
		fail "klipper branch drift detected: manifest=$manifest_branch factory-seed=$factory_seed_branch migrate=$migrate_branch - this is exactly the class of bug Phase 1 fixed"
	fi
}

# --- Test 2: real remote clone - recovery target has every accepted file ---

test_recovery_target_has_accepted_features() {
	clone_dir="$WORK/klipper-recovery-target"
	if ! git clone -q --depth 1 --branch "$KLIPPER_BRANCH" "$KLIPPER_REPO" "$clone_dir" 2>"$WORK/clone-error.log"; then
		fail "could not clone $KLIPPER_REPO branch $KLIPPER_BRANCH (recovery target) for verification: $(cat "$WORK/clone-error.log")"
		return
	fi

	head_commit=$(git -C "$clone_dir" rev-parse HEAD)
	if [ "$head_commit" = "$KLIPPER_PIN" ]; then
		pass "recovery target (origin/$KLIPPER_BRANCH tip) matches the pinned build commit exactly - no undocumented drift"
	else
		fail "recovery target tip ($head_commit) does not match manifest's KLIPPER_PIN ($KLIPPER_PIN) - manifest is stale or branch has moved since it was last pinned"
	fi

	missing=""
	empty=""
	for f in $ACCEPTED_FILES; do
		path="$clone_dir/klippy/extras/$f"
		if [ ! -f "$path" ]; then
			missing="$missing $f"
		elif [ ! -s "$path" ]; then
			empty="$empty $f"
		fi
	done
	if [ -z "$missing" ] && [ -z "$empty" ]; then
		pass "every accepted klippy/extras file is present and non-empty on the real recovery-target branch"
	else
		fail "recovery target is missing or has empty accepted files - missing:[$missing] empty:[$empty] - a Recovery reset would silently regress these features"
	fi

	# "No baseline-required local patching": nothing here ever depends on
	# a post-clone patch step targeting klipper specifically (the build
	# pipeline does patch other components - GuppyScreen's spdlog/lvgl
	# submodules, Moonraker's sqlite-nolock fix - so this must be scoped
	# to klipper, not a blanket "no patch anywhere" check) - so a plain
	# `git clone`/`git reset --hard` of this exact branch, which is
	# precisely what Moonraker's Recovery does, reproduces this content
	# byte-for-byte with no separate step required.
	if ! grep -B3 -A3 "git apply\|patch -" "$REPO_ROOT/scripts/build/00-fetch-vendor-sources.sh" "$REPO_ROOT/scripts/build/04-cross-compile-app-stack.sh" 2>/dev/null \
		| grep -qi "klipper"; then
		pass "no post-clone patch step targets klipper - accepted features are fully self-contained in the git history Recovery resets to"
	else
		fail "a git apply/patch step was found targeting klipper in the build pipeline - accepted features may depend on something Recovery would not reapply"
	fi
}

# --- Test 3: recovery target content matches this repo's own reviewable ---
# --- source of truth (klippy_extras/) - not just present, but correct ---

test_accepted_files_match_source_of_truth() {
	clone_dir="$WORK/klipper-recovery-target"
	[ -d "$clone_dir" ] || { fail "no clone available from test 2 to compare against"; return; }

	mismatched=""
	for f in $ACCEPTED_FILES; do
		src="$REPO_ROOT/klippy_extras/$f"
		target="$clone_dir/klippy/extras/$f"
		[ -f "$src" ] || continue
		[ -f "$target" ] || continue
		if ! diff -q "$src" "$target" >/dev/null 2>&1; then
			mismatched="$mismatched $f"
		fi
	done
	if [ -z "$mismatched" ]; then
		pass "accepted files on the recovery-target branch match this repo's own klippy_extras/ source of truth exactly"
	else
		fail "recovery-target content diverges from klippy_extras/ source of truth for:$mismatched - either the fork was updated without syncing this repo's copy, or vice versa"
	fi
}

test_branch_consistency
test_recovery_target_has_accepted_features
test_accepted_files_match_source_of_truth

echo
echo "recovery-safety-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
