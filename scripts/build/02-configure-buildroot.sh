#!/bin/sh
# Wire up Buildroot's configuration: the real, already-verified .config this
# project produced (artifacts/buildroot-halley5-v30-image/buildroot.config),
# the kernel config fragment (FIRMWARE.md sec 10-12's additions on top of
# the vendor x2000_halley5_v30_linux defconfig), the LINUX_OVERRIDE_SRCDIR
# pointer, and this repo's own hand-written overlay content.
#
# Reusing the exact verified .config here (rather than re-deriving every
# BR2_PACKAGE_* option from scratch) is deliberate: several of those options
# hit a real class of bug this session where a naive `echo "X=y" >> .config`
# landed on a duplicate line that a later `make olddefconfig` pass then lost
# to the file's *other*, unedited copy of the same symbol (see FIRMWARE.md
# sec 14) - copying the known-good, already-normalized file sidesteps that
# whole class of mistake rather than risking reintroducing it.
#
# IMPORTANT: always re-run this script after ANY change to scripts/build/overlay/
# or the kernel fragment/buildroot.config artifacts, and before 03/05 - a real
# bug this session (FIRMWARE.md sec 24): editing the git-tracked overlay
# template alone does nothing, since Buildroot only ever reads from
# vendor/buildroot-x2000/board/halley5-nebulaos-overlay/ (gitignored), which
# this script is what syncs the template into. A rebuild after only touching
# the template, without re-running this first, silently uses whatever this
# script last copied there.
#
# IMPORTANT: renaming or deleting a file from scripts/build/overlay/ does NOT
# remove it from a real build - a genuinely separate bug from the one above,
# found for real deleting S01tmpfs-datastore in favor of
# S01persistent-datastore (the GuppyScreen persistent-storage work): this
# script re-syncs the overlay TEMPLATE cleanly every time (the rm -rf above),
# but Buildroot's own output/target/ staging directory only ever gets files
# ADDED or OVERWRITTEN by the rootfs-overlay step, never removed, and
# accumulates across every build since the last full clean. Both
# S01tmpfs-datastore (deleted from the overlay days earlier) and
# S01persistent-datastore (its replacement) ended up in the same built image
# at once - actively dangerous here specifically, since the stale script
# re-mounted tmpfs right after the new one finished setting up real
# persistent storage, silently undoing it. Buildroot has no cheap way to
# selectively re-sync output/target/ (its package install stamps live
# elsewhere and do not get invalidated by removing target files directly, so
# deleting output/target/ alone leaves it mostly empty instead of clean) - a
# renamed or deleted overlay file must also be removed by hand from
# vendor/buildroot-x2000/output/target/ before the next 05-final-build.sh, or
# the build needs a full clean. 06-verify.sh also cannot catch this on its
# own: it only inspects rootfs.ext2, and both rootfs.ext2 and rootfs.squashfs
# are built from this same stale output/target/, so a leftover file is wrong
# in both images identically - checking the actual packaged rootfs.squashfs
# directly (e.g. via unsquashfs) is the only real way to confirm a removed
# file is genuinely gone.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

# Final Pre-Flash Audit mission (2026-08-08): DEPS_MANIFEST provides
# PELLCORP_K1_BASH_BUILD_IMAGE (the digest-pinned toolchain container ref)
# - see manifests/dependencies.conf's own comment on that entry.
DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
[ -f "$DEPS_MANIFEST" ] || { echo "FATAL: $DEPS_MANIFEST not found" >&2; exit 1; }
. "$DEPS_MANIFEST"

# 2026-07-23: this and the other numbered build stages all write into the
# same shared vendor/buildroot-x2000 tree - running two of these at once
# (e.g. from two terminals) would silently interleave writes. Cheap
# insurance: a single exclusive lock file, held for the whole script.
exec 9>"$REPO_ROOT/.nebulaos-build.lock"
flock -n 9 || { echo "another build stage already owns $REPO_ROOT/.nebulaos-build.lock" >&2; exit 1; }

# Orphaned-container cleanup (2026-07-23) - a real incident this session: a
# killed build wrapper left its `docker run` process running independently
# (SIGKILL can't be trapped, so no shell-level cleanup in the wrapper itself
# could ever have caught this), needing a manual `docker stop` once noticed.
# Every docker container this project's scripts spawn carries
# --label openke-build-pid=<owning PID> - check each one found against a
# live PID and stop anything left over from a run that's no longer alive,
# regardless of whether the lock itself was contended just now.
for cid_pid in $(docker ps --filter "label=openke-build-pid" --format '{{.ID}}={{.Label "openke-build-pid"}}' 2>/dev/null); do
	cid=${cid_pid%%=*}
	opid=${cid_pid##*=}
	if ! kill -0 "$opid" 2>/dev/null; then
		echo "stopping orphaned container $cid (from dead pid $opid)" >&2
		docker stop "$cid" >/dev/null 2>&1 || true
	fi
done
BUILDROOT_DIR="$REPO_ROOT/vendor/buildroot-x2000"
ARTIFACTS="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"

if [ ! -d "$BUILDROOT_DIR/.git" ]; then
	echo "vendor/buildroot-x2000 not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
fi

# Everything below runs inside a root container, not as the host user - a
# real bug this session: once any docker --user root build has run (every
# build does), vendor/buildroot-x2000/ becomes root-owned, and plain host
# `cp`/`rm` calls here start failing with "Permission denied" on every
# subsequent run. Doing the file operations here too, not just the make
# steps, makes this script actually idempotent/re-runnable.
docker run --label "openke-build-pid=$$" --rm --user root \
	-v "$REPO_ROOT:/repo" \
	"$PELLCORP_K1_BASH_BUILD_IMAGE" bash -c '
set -e
cp "/repo/artifacts/buildroot-halley5-v30-image/buildroot.config" "/repo/vendor/buildroot-x2000/.config"
mkdir -p "/repo/vendor/buildroot-x2000/board"
cp "/repo/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config" "/repo/vendor/buildroot-x2000/board/halley5-nebulaos-fragment.config"
cp "/repo/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-busybox-fragment.config" "/repo/vendor/buildroot-x2000/board/halley5-nebulaos-busybox-fragment.config"
cat > "/repo/vendor/buildroot-x2000/local.mk" <<EOF
LINUX_OVERRIDE_SRCDIR = /kernel_6_6/kernel/kernel-6.6
EOF
rm -rf "/repo/vendor/buildroot-x2000/board/halley5-nebulaos-overlay"
mkdir -p "/repo/vendor/buildroot-x2000/board/halley5-nebulaos-overlay"
cp -r "/repo/scripts/build/overlay/." "/repo/vendor/buildroot-x2000/board/halley5-nebulaos-overlay/"
mkdir -p "/repo/vendor/buildroot-x2000/board/halley5-nebulaos-overlay/opt/printer_data/comms" \
         "/repo/vendor/buildroot-x2000/board/halley5-nebulaos-overlay/opt/printer_data/logs" \
         "/repo/vendor/buildroot-x2000/board/halley5-nebulaos-overlay/opt/printer_data/gcodes"
# Real bug found live on 2026-07-28: this rm -rf/cp only cleans the BOARD
# overlay staging dir (above), not output/target/ or
# output/build/buildroot-fs/ext2/target/ - per the IMPORTANT comment near
# the top of this file, those two are additive-only and keep every
# renamed-away overlay file forever unless a full clean is done. This has
# now bitten three separate renames (S01tmpfs-datastore ->
# S01persistent-datastore; S39wifi -> S01wifi; S03nebulaos-factory-seed/
# S04nebulaos-activate -> S04nebulaos-factory-seed/S05nebulaos-activate),
# and the last two shipped together on a real flashed device: BOTH old and
# new init.d scripts were present in the same booted squashfs, and because
# the new activate scripts bind_if_not_already() no-ops when its target
# is already mounted, the OLD (pre-fix, less-validated) activation script -
# which sorts earlier and ran first - was the one actually deciding every
# real bind-mount, silently shadowing the fix. (Note for future edits to
# this comment block: it lives inside a single-quoted docker bash -c
# string below - no literal apostrophes allowed in it, or the outer shell
# parse breaks exactly like this one did the first time.) Clean every historically
# renamed/removed overlay-relative path from both real output copies here;
# add to this list whenever an overlay file is renamed or deleted, the same
# way dcf7060 does for the seed archives in 04-cross-compile-app-stack.sh.
for obsolete_rel in \
	"etc/init.d/S01tmpfs-datastore" \
	"etc/init.d/S39wifi" \
	"etc/init.d/S03nebulaos-factory-seed" \
	"etc/init.d/S04nebulaos-activate"; do
	rm -f "/repo/vendor/buildroot-x2000/output/target/$obsolete_rel" \
	      "/repo/vendor/buildroot-x2000/output/build/buildroot-fs/ext2/target/$obsolete_rel" 2>/dev/null || true
done
rm -rf "/repo/vendor/buildroot-x2000/board/halley5-nebulaos-wheels"
mkdir -p "/repo/vendor/buildroot-x2000/board/halley5-nebulaos-wheels"
cp "/repo/scripts/build/vendor-wheels/"*.whl "/repo/vendor/buildroot-x2000/board/halley5-nebulaos-wheels/"
cp "/repo/scripts/build/vendor-patches/python-matplotlib/python-matplotlib.mk" "/repo/vendor/buildroot-x2000/package/python-matplotlib/python-matplotlib.mk"
'

# Hand the overlay tree back to the host user - real bug found 2026-07-23:
# 04-cross-compile-app-stack.sh writes into this same tree (opt/klipper,
# opt/moonraker) as the host user, not root, and a root-owned overlay from
# the cp above makes that fail with "Permission denied" on the very next
# stage. The rest of vendor/buildroot-x2000/ deliberately stays root-owned
# (this scripts own docker run above already re-roots itself every time to
# cope with that) - only the overlay tree actually needs to be writable by
# the host user.
docker run --label "openke-build-pid=$$" --rm --user root \
	-v "$REPO_ROOT:/repo" \
	"$PELLCORP_K1_BASH_BUILD_IMAGE" \
	chown -R "$(id -u):$(id -g)" "/repo/vendor/buildroot-x2000/board/halley5-nebulaos-overlay"

echo "== normalizing .config (resolves any derived Kconfig selects) =="
docker run --label "openke-build-pid=$$" --rm --user root \
	-v "$REPO_ROOT/vendor/x2000_kernel_6.6/kernel/kernel-6.6:/kernel_6_6/kernel/kernel-6.6" \
	-v "$BUILDROOT_DIR:/src" -w /src "$PELLCORP_K1_BASH_BUILD_IMAGE" bash -c '
apt-get -qq update >/dev/null 2>&1
apt-get install -y -qq python3 bc cpio rsync unzip bison flex libncurses5-dev file build-essential libssl-dev libelf-dev >/dev/null 2>&1
make olddefconfig
'

# Reproducibility fix (2026-07-26, NebulaOS mutable-runtime mission): a real
# bug found by directly inspecting the built rootfs.squashfs with unsquashfs
# instead of trusting 05-final-build.sh's exit code - enabling
# BR2_PACKAGE_LIBOPENSSL_BIN=y (the openssl CLI) above did NOT get the
# openssl binary into the image, because libopenssl had already been built
# once before (as a transitive dependency of git/python3-ssl/curl) with that
# suboption off, and Buildroot's own per-package build stamps
# (output/build/<pkg>/.stamp_*) are not invalidated by a suboption-only
# .config change - only by the package's own source/patch/version changing.
# This is a general Buildroot limitation, not specific to openssl: ANY
# suboption added to an already-built package needs an explicit dirclean, or
# it silently keeps the old build. Forcing it here (rather than relying on
# whoever runs this script next to remember to do it by hand, which is
# exactly how this was first missed) makes the fix part of the tracked
# pipeline instead of a one-off manual step - dirclean is a safe no-op if
# the package was never built yet (e.g. on a genuinely fresh output/ tree).
docker run --label "openke-build-pid=$$" --rm --user root \
	-v "$REPO_ROOT/vendor/x2000_kernel_6.6/kernel/kernel-6.6:/kernel_6_6/kernel/kernel-6.6" \
	-v "$BUILDROOT_DIR:/src" -w /src "$PELLCORP_K1_BASH_BUILD_IMAGE" bash -c '
apt-get -qq update >/dev/null 2>&1
apt-get install -y -qq python3 bc cpio rsync unzip bison flex libncurses5-dev file build-essential libssl-dev libelf-dev >/dev/null 2>&1
make libopenssl-dirclean 2>/dev/null || true
# Same class of bug, found again (Memory Resilience Gate, 2026-07-26):
# adding CONFIG_FEATURE_SWAPON_PRI via the busybox config fragment had no
# effect on an already-built busybox (confirmed live on a flashed image:
# swapon rejected the priority option outright) - same stale-stamp
# mechanism as the libopenssl case above.
make busybox-dirclean 2>/dev/null || true
'

echo "== buildroot configured =="
