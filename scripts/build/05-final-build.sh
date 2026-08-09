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

# Final Pre-Flash Audit mission (2026-08-08): DEPS_MANIFEST provides
# PELLCORP_K1_BASH_BUILD_IMAGE (the digest-pinned toolchain container ref)
# - see manifests/dependencies.conf's own comment on that entry. Named
# DEPS_MANIFEST, not MANIFEST, to not collide with this script's own,
# unrelated later use of $MANIFEST for the build's own output manifest.
DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
[ -f "$DEPS_MANIFEST" ] || { echo "FATAL: $DEPS_MANIFEST not found" >&2; exit 1; }
. "$DEPS_MANIFEST"

# 2026-07-23: see 02-configure-buildroot.sh for why this lock exists.
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
KERNEL_MOUNT="$REPO_ROOT/vendor/x2000_kernel_6.6/kernel/kernel-6.6"

# 2026-07-23: source-fingerprint check - refuse to package an image built
# from a source tree that changed mid-build (a real risk in this project:
# multiple sessions/processes have edited files in this same repo while a
# build was in flight before). Snapshot before the real make, compare after
# copying artifacts, abort rather than silently ship a mismatched build.
#
# 2026-07-26: excludes artifacts/buildroot-halley5-v30-image/ from the main
# repo's status - this script itself overwrites xImage/rootfs.*/*.config
# under that exact path a few lines below (see the docker cp step), which
# was previously included in both the BEFORE and AFTER snapshots and so
# self-tripped this check on every build that changes the kernel/buildroot
# config in a way that produces a different kernel.config/buildroot.config
# than what's currently committed - a false positive, not a real "something
# else touched the tree mid-build" case (which is what this check is
# actually meant to catch).
source_fingerprint() {
	(
		cd "$REPO_ROOT" && git rev-parse HEAD && \
			git status --porcelain=v2 -- . ":(exclude)artifacts/buildroot-halley5-v30-image/"
		cd "$REPO_ROOT/vendor/x2000_kernel_6.6" && git rev-parse HEAD && git status --porcelain=v2
	) | sha256sum | awk '{print $1}'
}
FINGERPRINT_BEFORE=$(source_fingerprint)

docker run --label "openke-build-pid=$$" --rm --user root \
	-v "$KERNEL_MOUNT:/kernel_6_6/kernel/kernel-6.6" \
	-v "$BUILDROOT_DIR:/src" -w /src "$PELLCORP_K1_BASH_BUILD_IMAGE" bash -c '
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
docker run --label "openke-build-pid=$$" --rm --user root -v "$REPO_ROOT:/repo" "$PELLCORP_K1_BASH_BUILD_IMAGE" bash -c "
set -e
cp '/repo/vendor/buildroot-x2000/output/images/xImage' '/repo/artifacts/buildroot-halley5-v30-image/xImage'
cp '/repo/vendor/buildroot-x2000/output/images/rootfs.ext2' '/repo/artifacts/buildroot-halley5-v30-image/rootfs.ext2'
cp '/repo/vendor/buildroot-x2000/output/images/rootfs.squashfs' '/repo/artifacts/buildroot-halley5-v30-image/rootfs.squashfs'
cp '/repo/vendor/buildroot-x2000/.config' '/repo/artifacts/buildroot-halley5-v30-image/buildroot.config'
cp '/repo/vendor/buildroot-x2000/output/build/linux-custom/.config' '/repo/artifacts/buildroot-halley5-v30-image/kernel.config'
cp '/repo/vendor/x2000_kernel_6.6/kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts' '/repo/artifacts/buildroot-halley5-v30-image/halley5_v30.dts'
chown $HOST_UID:$HOST_GID /repo/artifacts/buildroot-halley5-v30-image/*
"

FINGERPRINT_AFTER=$(source_fingerprint)
if [ "$FINGERPRINT_BEFORE" != "$FINGERPRINT_AFTER" ]; then
	echo "ABORT: source tree changed during the build (fingerprint $FINGERPRINT_BEFORE -> $FINGERPRINT_AFTER)" >&2
	echo "Refusing to trust these artifacts - re-run the build against a stable tree." >&2
	exit 1
fi

# Optional hard gate for a real release build (2026-07-31,
# NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md's vendor-pin audit / pre-
# qualification mission Phase A2): "reject release builds from a dirty main
# repository" is the right rule for a FINAL production build, but this same
# script also produces every intermediate experimental/A-B variant build,
# which this project routinely does against a dirty, in-progress tree - a
# blanket rejection here would break that normal workflow. Opt-in via
# NEBULAOS_REQUIRE_CLEAN_TREE=1 (set only for the final Phase 13 production
# build), default off so today's iterative builds are unaffected.
if [ "${NEBULAOS_REQUIRE_CLEAN_TREE:-0}" = "1" ]; then
	if [ -n "$(cd "$REPO_ROOT" && git status --porcelain)" ]; then
		echo "FATAL: NEBULAOS_REQUIRE_CLEAN_TREE=1 but the main repository has uncommitted changes - a release build must come from a clean, committed tree" >&2
		exit 1
	fi
fi

# Build manifest - the source of truth flash-spare-slot.sh verifies against
# before writing anything to real hardware (see its own --manifest handling).
# Git commits/dirty-state let a later "which build is this" question be
# answered without guessing from file timestamps.
#
# Expanded 2026-07-31 (same audit) to cover every vendored git tree, not just
# main + kernel - a future investigator holding only this manifest can now
# reconstruct exactly which commit of every dependency produced a given
# shipped image, without needing the live vendor/ checkouts to still exist.
ARTIFACT_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"
MANIFEST="$ARTIFACT_DIR/build-manifest.txt"
git_field() {
	# name, vendor-relative-path (empty = repo root)
	fname="$1"; fdir="$REPO_ROOT${2:+/$2}"
	if [ -d "$fdir/.git" ]; then
		echo "${fname}=$(cd "$fdir" && git rev-parse HEAD)"
		echo "${fname}_dirty=$(cd "$fdir" && [ -z "$(git status --porcelain)" ] && echo no || echo yes)"
	else
		echo "${fname}=absent"
		echo "${fname}_dirty=unknown"
	fi
}
artifact_sha256() {
	# name, path
	if [ -f "$2" ]; then
		echo "$1=$(sha256sum "$2" | awk '{print $1}')"
	else
		echo "$1=absent"
	fi
}
{
	echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	git_field git_commit_main ""
	git_field git_commit_kernel vendor/x2000_kernel_6.6
	git_field git_commit_buildroot vendor/buildroot-x2000
	git_field git_commit_klipper vendor/klipper
	git_field git_commit_moonraker vendor/moonraker
	git_field git_commit_guppyscreen vendor/nebulaos-guppyscreen
	git_field git_commit_pellcorp_creality vendor/pellcorp-creality
	git_field git_commit_k1_ustreamer vendor/k1-ustreamer
	git_field git_commit_v4l_utils vendor/v4l-utils
	if [ -d "$REPO_ROOT/vendor/k1-ustreamer/.git" ]; then
		echo "git_submodules_k1_ustreamer=$(cd "$REPO_ROOT/vendor/k1-ustreamer" && git submodule status | awk '{printf "%s@%s;", $2, $1}')"
	else
		echo "git_submodules_k1_ustreamer=absent"
	fi
	artifact_sha256 mainsail_zip_sha256 "$REPO_ROOT/vendor/mainsail-dist/mainsail.zip"
	artifact_sha256 guppyscreen_sha256 "$REPO_ROOT/artifacts/guppyscreen-mips/guppyscreen"
	artifact_sha256 guppybeep_sha256 "$REPO_ROOT/artifacts/guppyscreen-mips/guppybeep"
	artifact_sha256 wifi_firmware_sha256 "$REPO_ROOT/scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.bin"
	artifact_sha256 wifi_clm_sha256 "$REPO_ROOT/scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.clm_blob"
	artifact_sha256 wifi_nvram_sha256 "$REPO_ROOT/scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.txt"
	artifact_sha256 regulatory_db_sha256 "$REPO_ROOT/scripts/build/overlay/lib/firmware/regulatory.db"
	artifact_sha256 kernel_config_sha256 "$ARTIFACT_DIR/kernel.config"
	artifact_sha256 buildroot_config_sha256 "$ARTIFACT_DIR/buildroot.config"
	artifact_sha256 device_tree_sha256 "$ARTIFACT_DIR/halley5_v30.dts"
	artifact_sha256 xImage_sha256 "$ARTIFACT_DIR/xImage"
	echo "xImage_size=$(wc -c < "$ARTIFACT_DIR/xImage")"
	artifact_sha256 rootfs_squashfs_sha256 "$ARTIFACT_DIR/rootfs.squashfs"
	echo "rootfs_squashfs_size=$(wc -c < "$ARTIFACT_DIR/rootfs.squashfs")"
} > "$MANIFEST"

echo "== final build complete, artifacts copied to artifacts/buildroot-halley5-v30-image/ (xImage, rootfs.ext2, rootfs.squashfs) =="
echo "== build manifest: $MANIFEST =="
cat "$MANIFEST"
