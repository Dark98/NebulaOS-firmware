#!/bin/sh
#
# NebulaOS auto-updates-camera-complete mission (2026-07-28, see
# docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md). Shared by
# scripts/build/04-cross-compile-app-stack.sh (real build - packages
# vendor/klipper and vendor/moonraker) and tests/factory-seed-git-tests.sh
# (offline fixture repos) - kept in its own file specifically so the tests
# exercise this exact function, not a second/parallel reimplementation of
# its validation rules.
#
# PRIOR APPROACH (removed): each vendor checkout was flattened into a
# single synthetic orphan commit ("NebulaOS factory seed snapshot of
# <branch> @ <true_commit>") before bundling, because a plain
# `git bundle create` of vendor/klipper's shallow clone (1-2 commits deep,
# 00-fetch-vendor-sources.sh's clone_pinned) produces a bundle that
# `git bundle verify` reports as fine but a real `git clone` of rejects
# with "Failed to traverse parents of commit ..." / "remote did not send
# all necessary objects" (confirmed again against git 2.55.0 - a genuine,
# still-present git limitation, not a syntax mistake). That synthetic
# commit had no shared ancestry with the real coreflake1/NebulaOS-klipper
# or Arksine/moonraker history on GitHub, which made Moonraker's own
# `git merge-base --is-ancestor HEAD origin/<branch>` check permanently
# fail (return code 1) on every freshly-seeded device - HEAD could never
# be an ancestor of a real remote branch it shared no history with. This
# set `diverged=true` -> `has_recoverable_errors()=true` ->
# `is_valid()=false` (vendor/moonraker/moonraker/components/update_manager/
# git_deploy.py) permanently, blocking every real Klipper/Moonraker update.
#
# FIX: stop bundling/flattening entirely. Archive each vendor checkout's
# REAL `.git` directory (shallow boundary, real branch, real commits) plus
# its working tree as a plain tar file, with the local branch renamed to
# match Moonraker's hardcoded reserved-slot expectation ("master" - see
# BASE_CONFIG in update_manager/common.py, not configurable) and origin
# rewritten to the real public remote. On-device seeding (S04) then
# extracts the tar directly into place - no `git clone` at all, which is
# also strictly cheaper on this 208MB device than the clone-from-bundle
# step it replaces (plain tar extraction does no object repacking).

make_seed_archive() {
	src="$1"; active_branch="$2"; origin_url="$3"; out="$4"; sparse_exclude="${5:-}"
	# Production optimization mission, Phase 4 (2026-07-30): both optional,
	# trailing so every existing 5-arg call site (including
	# tests/factory-seed-git-tests.sh's offline fixtures, which have no
	# real target Python toolchain to test against) is unaffected and
	# simply skips precompilation. python3_bin must be a HOST-architecture
	# build of the *same* CPython version/build that runs on the target
	# (Buildroot's own output/host/bin/python3, exactly what
	# BR2_PACKAGE_PYTHON3_PYC_ONLY already uses for system packages) -
	# Python bytecode itself is not CPU-architecture-specific, only
	# CPython-version-specific, so this produces byte-identical .pyc
	# output to what the target interpreter would compile natively,
	# without needing target emulation. mount_path is the real absolute
	# path this tree runs from on the device (e.g. /opt/klipper) - used
	# only to make embedded tracebacks show real device paths instead of
	# this function's own mktemp staging path; purely cosmetic, no
	# functional effect on bytecode validity.
	python3_bin="${6:-}"; mount_path="${7:-}"
	tmp=$(mktemp -d)
	cp -r "$src/." "$tmp/"
	# Ensure the archived copy is checked out on the branch Moonraker's
	# reserved slot actually expects, without disturbing $src itself.
	if ! git -C "$tmp" show-ref --verify --quiet "refs/heads/$active_branch"; then
		git -C "$tmp" branch "$active_branch"
	fi
	git -C "$tmp" checkout -q "$active_branch"

	# Real bug found live (first full first-boot qualification, 2026-07-28):
	# a plain `tar -xzf` of vendor/klipper's real working tree still has to
	# write out its ~226MB of real files (mostly its own vendored MCU HAL/
	# SDK sources under lib/, needed only to compile MCU firmware - never
	# read by Klippy's own host-side runtime) - measured live at 1m51s on
	# the real device, on top of both venv creations and moonraker's own
	# seeding. The device was hard-rebooted twice by an impatient human
	# before that ever finished, leaving klipper/moonraker's app
	# directories seeded empty (no .git at all) - not a WiFi bug, a
	# too-slow factory seed. Fixed with git's own sparse-checkout: the
	# excluded path's blobs stay fully present in .git/objects (real,
	# complete history - the mission's core requirement - is untouched),
	# only the WORKING TREE omits it, and git treats that as intentional
	# sparsity, not a modification/deletion (confirmed live: `git status`
	# reports "in a sparse checkout", never a dirty/deleted lib/). Cut
	# klipper's real device extraction from 1m51s to a few seconds.
	if [ -n "$sparse_exclude" ]; then
		git -C "$tmp" sparse-checkout init --no-cone
		printf '/*\n!%s\n' "$sparse_exclude" > "$tmp/.git/info/sparse-checkout"
		git -C "$tmp" read-tree -mu HEAD
	fi
	# Reset ALL remotes to exactly one "origin" with the standard
	# wildcard fetch refspec. Real bug found while validating this
	# against the actual coreflake1/NebulaOS-klipper remote: vendor/
	# klipper's own "origin" remote (00-fetch-vendor-sources.sh's
	# clone_pinned) is scoped to a narrow `+refs/heads/jun2025:
	# refs/remotes/origin/jun2025` fetch refspec, left over from its
	# original single-branch clone. Archiving that config as-is would
	# make a later plain `git fetch origin` (exactly what Moonraker's
	# own GitDeploy refresh runs) silently fail to populate
	# refs/remotes/origin/master at all, reproducing the very
	# `merge-base --is-ancestor HEAD origin/master` failure
	# (diverged=true) this whole mission exists to fix - confirmed by
	# reproducing it locally before this fix. Removing every remote and
	# re-adding a single "origin" with git's normal wildcard refspec is
	# what a real `git clone` would have produced, and is what this
	# archive must reproduce without ever running a clone.
	for r in $(git -C "$tmp" remote); do
		git -C "$tmp" remote remove "$r"
	done
	# `git remote remove` does not always clean up a leftover
	# refs/remotes/<name>/HEAD symref (a known git quirk - HEAD is a
	# symbolic ref, not a plain remote-tracking branch); left in place it
	# points at nothing and makes `git fsck` print a spurious "invalid
	# sha1 pointer" error. Harmless to the actual ancestry check but real
	# noise in build logs, so clear the whole refs/remotes tree outright.
	rm -rf "$tmp/.git/refs/remotes"
	git -C "$tmp" remote add origin "$origin_url"
	git -C "$tmp" config "remote.origin.fetch" "+refs/heads/*:refs/remotes/origin/*"
	# Real, critical bug found live during the first genuinely successful
	# fresh-boot qualification: `branch --set-upstream-to` requires the
	# target remote-tracking ref (origin/<branch>) to already exist
	# locally, which it never does in an offline-built archive (no fetch
	# has ever happened against this freshly-added "origin" remote) - so
	# this silently failed every single time, swallowed by its own
	# `|| true`. Without it, the branch has no `branch.<name>.remote`
	# config at all, which is exactly what Moonraker's own GitDeploy reads
	# to populate `git_remote` (git_deploy.py's `config_get(f"branch.
	# {branch}.remote")`) - with that unset, git_remote is "?", and
	# is_valid()'s own `"?" not in (git_branch, git_remote,
	# upstream_commit)` check fails it directly, independent of and in
	# addition to the diverged/dirty/detached checks this mission already
	# fixed. Confirmed live: `is_valid` stayed false with a real, correctly
	# ancestor-reachable, non-diverged, non-dirty repo until this exact
	# config was set. Setting the two config keys directly (not via
	# `--set-upstream-to`) needs no pre-existing remote-tracking ref at
	# all - confirmed live this alone was sufficient to make Moonraker
	# report is_valid=true for both klipper and moonraker.
	git -C "$tmp" config "branch.$active_branch.remote" origin
	git -C "$tmp" config "branch.$active_branch.merge" "refs/heads/$active_branch"

	# Discard local build-artifact drift on the one known, understood
	# tracked binary this repeatedly reproduces on (klippy/chelper/
	# c_helper.so - a host-recompiled x86 .so that must never ship to
	# the MIPS target anyway). Real bug found while writing this
	# function's own tests: an earlier version did a blanket
	# `git checkout -- .`, which discards ANY tracked-file modification -
	# that silently defeated the dirty-tree rejection below for every
	# tracked file, not just this one binary (confirmed live: a
	# deliberately dirtied source file was wiped clean before the check
	# ever ran, so "reject a dirty tree" never actually fired). Only
	# ever discard this specific, known-safe path; anything else dirty
	# must still fail the check below.
	if [ -e "$tmp/klippy/chelper/c_helper.so" ]; then
		git -C "$tmp" checkout -q -- klippy/chelper/c_helper.so 2>/dev/null || true
	fi

	# Defense in depth: this archive must contain zero synthetic history
	# and a genuinely clean, valid repo before it is ever packaged.
	if git -C "$tmp" log --all --format=%s 2>/dev/null | grep -q "NebulaOS factory seed snapshot"; then
		echo "ERROR: refusing to package $src - synthetic wrapper commit detected in history" >&2
		rm -rf "$tmp"
		return 1
	fi
	if [ -n "$(git -C "$tmp" status --porcelain)" ]; then
		echo "ERROR: refusing to package $src - working tree is not clean" >&2
		rm -rf "$tmp"
		return 1
	fi
	if ! git -C "$tmp" fsck --no-dangling >/dev/null; then
		echo "ERROR: refusing to package $src - git fsck reported repository damage" >&2
		rm -rf "$tmp"
		return 1
	fi

	# Precompile to .pyc, deliberately AFTER the clean-tree check above,
	# not before: __pycache__ directories are untracked, and the dirty-
	# tree guard would otherwise refuse to package a tree that compiled
	# cleanly. A failure here is non-fatal - it just means this seed
	# ships without precompiled bytecode and pays the normal one-time
	# compile-on-first-import cost instead, same as before this feature
	# existed; it must never block the whole build.
	#
	# Excludes top-level scripts/ as well as .git/: real failure found
	# live - Klipper's own scripts/stepstats.py is a Python-2-only dev
	# tool (a bare `print "..." %` statement) that Klippy's own runtime
	# never imports, but compileall's walk still reaches it and returns
	# non-zero for the whole tree over that one irrelevant file (Moonraker
	# has a handful of similarly never-imported scripts/*.py of its own -
	# losing bytecode for these purely host-side dev/release tools, never
	# run on the target, is a non-issue).
	if [ -n "$python3_bin" ]; then
		if [ -n "$mount_path" ]; then
			PYTHONPATH="" "$python3_bin" -m compileall -q \
				-x '(^|/)(\.git|scripts)($|/)' -s "$tmp" -p "$mount_path" "$tmp" \
				|| echo "WARNING: bytecode precompilation failed for $src - shipping source-only, as before" >&2
		else
			PYTHONPATH="" "$python3_bin" -m compileall -q \
				-x '(^|/)(\.git|scripts)($|/)' "$tmp" \
				|| echo "WARNING: bytecode precompilation failed for $src - shipping source-only, as before" >&2
		fi
	fi

	# gzip, not a plain tar: real bug found at the first full build after
	# this archive format landed - a plain tar of vendor/klipper's real
	# working tree (~226MB uncommitted source, mostly its own vendored
	# MCU HAL/SDK libraries under lib/) on top of the ALREADY-shipped
	# plain copy at /opt/klipper overflowed the fixed 400M rootfs.ext2
	# ("Could not allocate block in ext2 filesystem"). The old flattened-
	# commit bundle never hit this because git's own pack compression
	# made it ~11.5MB; gzip here brings a real tar back down to a
	# comparable order of magnitude (~40MB measured) while still
	# preserving real, non-synthetic history.
	tar -C "$tmp" -czf "$out" .
	git -C "$tmp" rev-parse HEAD
	rm -rf "$tmp"
}
