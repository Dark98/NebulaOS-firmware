#!/bin/sh
# Final rootfs build - bakes everything stage 4 assembled in the overlay
# (Klipper, Moonraker, ustreamer, Mainsail, the cross-compiled extras) into
# the actual rootfs.ext2/rootfs.squashfs. Assumes 02 and 03 already ran in
# this same session (02 for any overlay/config changes, 03 for any kernel
# source changes with its own forced dirclean) - this script does not
# re-sync the overlay or force a kernel rebuild itself, so a change to
# either that hasn't gone through 02/03 first will silently not appear here.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

# 2026-07-23: see 02-configure-buildroot.sh for why this lock exists.
exec 9>"$REPO_ROOT/.openke-build.lock"
flock -n 9 || { echo "another build stage already owns $REPO_ROOT/.openke-build.lock" >&2; exit 1; }

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
KERNEL_MOUNT="$REPO_ROOT/vendor/x2000_kernel_6.6/kernel/kernel-6.6"

# 2026-07-23: source-fingerprint check - refuse to package an image built
# from a source tree that changed mid-build (a real risk in this project:
# multiple sessions/processes have edited files in this same repo while a
# build was in flight before). Snapshot before the real make, compare after
# copying artifacts, abort rather than silently ship a mismatched build.
source_fingerprint() {
	(
		cd "$REPO_ROOT" && git rev-parse HEAD && git status --porcelain=v2
		cd "$REPO_ROOT/vendor/x2000_kernel_6.6" && git rev-parse HEAD && git status --porcelain=v2
	) | sha256sum | awk '{print $1}'
}
FINGERPRINT_BEFORE=$(source_fingerprint)

docker run --label "openke-build-pid=$$" --rm --user root \
	-v "$KERNEL_MOUNT:/kernel_6_6/kernel/kernel-6.6" \
	-v "$BUILDROOT_DIR:/src" -w /src pellcorp/k1-bash-build bash -c '
apt-get -qq update >/dev/null 2>&1
apt-get install -y -qq python3 bc cpio rsync unzip bison flex libncurses5-dev file \
	build-essential libssl-dev libelf-dev >/dev/null 2>&1
make
'

mkdir -p "$REPO_ROOT/artifacts/buildroot-halley5-v30-image"
# Copying via a root container, not the host user directly - output/images/*
# is root-owned from the docker --user root build above, and the chown back
# to the real host user/group below needs root too.
HOST_UID=$(id -u)
HOST_GID=$(id -g)
docker run --label "openke-build-pid=$$" --rm --user root -v "$REPO_ROOT:/repo" pellcorp/k1-bash-build bash -c "
set -e
cp '/repo/vendor/buildroot-x2000/output/images/xImage' '/repo/artifacts/buildroot-halley5-v30-image/xImage'
cp '/repo/vendor/buildroot-x2000/output/images/rootfs.ext2' '/repo/artifacts/buildroot-halley5-v30-image/rootfs.ext2'
cp '/repo/vendor/buildroot-x2000/output/images/rootfs.squashfs' '/repo/artifacts/buildroot-halley5-v30-image/rootfs.squashfs'
cp '/repo/vendor/buildroot-x2000/.config' '/repo/artifacts/buildroot-halley5-v30-image/buildroot.config'
cp '/repo/vendor/buildroot-x2000/output/build/linux-custom/.config' '/repo/artifacts/buildroot-halley5-v30-image/kernel.config'
chown $HOST_UID:$HOST_GID /repo/artifacts/buildroot-halley5-v30-image/*
"

FINGERPRINT_AFTER=$(source_fingerprint)
if [ "$FINGERPRINT_BEFORE" != "$FINGERPRINT_AFTER" ]; then
	echo "ABORT: source tree changed during the build (fingerprint $FINGERPRINT_BEFORE -> $FINGERPRINT_AFTER)" >&2
	echo "Refusing to trust these artifacts - re-run the build against a stable tree." >&2
	exit 1
fi

# Build manifest - the source of truth flash-spare-slot.sh verifies against
# before writing anything to real hardware (see its own --manifest handling).
# Git commits/dirty-state let a later "which build is this" question be
# answered without guessing from file timestamps.
ARTIFACT_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"
MANIFEST="$ARTIFACT_DIR/build-manifest.txt"
{
	echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "git_commit_main=$(cd "$REPO_ROOT" && git rev-parse HEAD)"
	echo "git_dirty_main=$(cd "$REPO_ROOT" && [ -z "$(git status --porcelain)" ] && echo no || echo yes)"
	echo "git_commit_kernel=$(cd "$REPO_ROOT/vendor/x2000_kernel_6.6" && git rev-parse HEAD)"
	echo "git_dirty_kernel=$(cd "$REPO_ROOT/vendor/x2000_kernel_6.6" && [ -z "$(git status --porcelain)" ] && echo no || echo yes)"
	echo "kernel_config_sha256=$(sha256sum "$ARTIFACT_DIR/kernel.config" | awk '{print $1}')"
	echo "buildroot_config_sha256=$(sha256sum "$ARTIFACT_DIR/buildroot.config" | awk '{print $1}')"
	echo "xImage_size=$(wc -c < "$ARTIFACT_DIR/xImage")"
	echo "xImage_sha256=$(sha256sum "$ARTIFACT_DIR/xImage" | awk '{print $1}')"
	echo "rootfs_squashfs_size=$(wc -c < "$ARTIFACT_DIR/rootfs.squashfs")"
	echo "rootfs_squashfs_sha256=$(sha256sum "$ARTIFACT_DIR/rootfs.squashfs" | awk '{print $1}')"
} > "$MANIFEST"

echo "== final build complete, artifacts copied to artifacts/buildroot-halley5-v30-image/ (xImage, rootfs.ext2, rootfs.squashfs) =="
echo "== build manifest: $MANIFEST =="
cat "$MANIFEST"
