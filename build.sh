#!/bin/sh
# The one documented command to reproduce the current qualified NebulaOS
# baseline from a fresh clone:
#
#   git clone https://github.com/coreflake1/NebulaOS-firmware.git
#   cd NebulaOS-firmware
#   ./build.sh
#
# Fetches every pinned dependency (kernel, Klipper, GuppyScreen, Moonraker,
# Buildroot, ustreamer, Mainsail, wireless-regdb, WiFi firmware - see
# manifests/dependencies.conf), composes all 8 accepted baseline variants,
# builds the kernel/rootfs/app-stack, and verifies the result against the
# accepted-baseline assertions - scripts/build/build-qualified-baseline.sh
# does the actual sequencing; this is a thin, host-dependency-aware wrapper
# around it, not a reimplementation.
#
# Phase 11 (2026-08-15, unified-build-environment migration): this used to
# have two modes - run directly on a host with git/curl/etc already
# installed, or `--containerized` to get those from a thin wrapper image
# that then launched TWO MORE nested containers (pellcorp/k1-bash-build,
# ghcr.io/coreflake1/guppydev) via the host's own Docker socket for the
# actual work. That nested-container design is gone. There is now exactly
# ONE container, pinned by digest in manifests/dependencies.conf
# (BUILD_IMAGE_REPO/BUILD_IMAGE_DIGEST) - it already contains every host
# build tool the 00-06 pipeline needs (see build-env/Dockerfile), so
# nothing here or inside those stages ever calls `docker`/`apt-get` again.
#
# Requires on the host: Docker or Podman, and nothing else - not even git,
# since the container itself is what clones/builds everything once it's
# running with this checkout mounted in.
#
# Does NOT reuse any existing vendor/, build-work/, or artifacts/ state by
# itself - run this against a genuinely fresh clone for a real clean-room
# result (an already-populated vendor/ is convenient for iteration but
# defeats the point of using this script to prove reproducibility).
#
# Exits non-zero if any pin fails to resolve, any variant fails to apply,
# either baseline assertion fails, or any build stage fails - this script
# propagates the container's real exit status, it does not swallow it.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MANIFEST="$SCRIPT_DIR/manifests/dependencies.conf"
[ -f "$MANIFEST" ] || { echo "FATAL: $MANIFEST not found" >&2; exit 1; }
. "$MANIFEST"

: "${BUILD_IMAGE_REPO:?FATAL: BUILD_IMAGE_REPO not set in $MANIFEST}"
: "${BUILD_IMAGE_DIGEST:?FATAL: BUILD_IMAGE_DIGEST not set in $MANIFEST}"
IMAGE_REF="${BUILD_IMAGE_REPO}@${BUILD_IMAGE_DIGEST}"

ENGINE=""
for candidate in docker podman; do
	command -v "$candidate" >/dev/null 2>&1 && { ENGINE="$candidate"; break; }
done
[ -n "$ENGINE" ] || {
	echo "FATAL: neither docker nor podman found on this host - one of them is required to run the pinned build environment ($IMAGE_REF)." >&2
	exit 1
}

echo "== build.sh: pulling pinned build environment $IMAGE_REF (engine: $ENGINE) =="
"$ENGINE" pull "$IMAGE_REF"

# -v mounts this checkout at the same absolute path inside the container as
# outside it, and runs as the invoking host UID (not root) - see
# build-env/Dockerfile's own header for why: several Buildroot host tools
# bake the absolute build path into their own RUNPATH, and the whole point
# of removing the old nested-container design was to stop crossing a path
# boundary that made two different builds of the identical source disagree
# on that path for no product-relevant reason.
# -e HOME=/tmp: an arbitrary host UID has no /etc/passwd entry inside the
# container, so HOME defaults to "/" (not writable by this UID) - confirmed
# live this would break any tool that wants to write a cache/config file
# (pip's download cache, git's config lookup). /tmp is writable by anyone
# and doesn't need to persist across runs.
exec "$ENGINE" run --rm -it \
	--user "$(id -u):$(id -g)" \
	-e HOME=/tmp \
	-v "$SCRIPT_DIR:$SCRIPT_DIR" \
	-w "$SCRIPT_DIR" \
	"$IMAGE_REF" \
	"sh scripts/build/build-qualified-baseline.sh"
