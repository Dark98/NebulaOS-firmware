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
# Two modes:
#
#   ./build.sh
#     Runs directly on this host. Requires: git, docker, curl, tar, gzip,
#     unzip, coreutils (sha256sum) - see build-env/Dockerfile for the exact
#     list this was verified against. All of these are already implicit
#     requirements of the existing 00-06 pipeline; nothing new here.
#
#   ./build.sh --containerized
#     Builds (or reuses) build-env/Dockerfile and runs the same sequence
#     inside it, with the current directory and the host's Docker socket
#     mounted in - for a host that doesn't have git/curl/etc. already
#     installed, or a CI runner that shouldn't need to. The nested
#     pellcorp/k1-bash-build and guppydev cross-compile containers are
#     still started against the HOST daemon either way (via the mounted
#     socket) - this never runs Docker-in-Docker.
#
# Does NOT reuse any existing vendor/, build-work/, or artifacts/ state by
# itself - run this against a genuinely fresh clone for a real clean-room
# result (an already-populated vendor/ is convenient for iteration but
# defeats the point of using this script to prove reproducibility).
#
# Exits non-zero if any pin fails to resolve, any variant fails to apply,
# either baseline assertion fails, or any build stage fails.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

if [ "$1" = "--containerized" ]; then
	echo "== build.sh: building/using build-env container =="
	docker build -t nebulaos-build-env "$SCRIPT_DIR/build-env"
	exec docker run --rm -it \
		-v "$SCRIPT_DIR:/work" \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-w /work \
		nebulaos-build-env "cd /work && sh build.sh"
fi

for tool in git docker curl tar gzip unzip sha256sum; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "FATAL: '$tool' not found on this host." >&2
		echo "Either install it, or run './build.sh --containerized' instead (see build-env/Dockerfile)." >&2
		exit 1
	}
done

exec sh "$SCRIPT_DIR/scripts/build/build-qualified-baseline.sh"
