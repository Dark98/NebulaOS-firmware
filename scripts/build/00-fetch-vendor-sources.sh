#!/bin/sh
# Clone/download every third-party source this build needs, pinned to the
# exact refs this project used. See FIRMWARE.md for why each one was chosen.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
VENDOR="$REPO_ROOT/vendor"
mkdir -p "$VENDOR"
cd "$VENDOR"

clone_pinned() {
	name="$1"; url="$2"; ref="$3"; extra="$4"
	if [ -d "$name/.git" ]; then
		echo "== $name already present, skipping clone =="
		return
	fi
	echo "== cloning $name @ $ref =="
	git clone $extra "$url" "$name"
	git -C "$name" fetch origin "$ref" 2>/dev/null || true
	git -C "$name" checkout "$ref"
}

# X2000 kernel SDK (Phase 2's rebase target, FIRMWARE.md sec 7's "Update").
# Sparse-checked-out to kernel/kernel-6.6 only (the full repo is ~684MB).
if [ ! -d "x2000_kernel_6.6/.git" ]; then
	echo "== cloning x2000_kernel_6.6 (sparse: kernel/kernel-6.6 only) =="
	git clone --filter=blob:none --sparse \
		https://github.com/Llixuma/ingenic-linux-kernel6.6-x2000-v1.0-20250221.git \
		x2000_kernel_6.6
	git -C x2000_kernel_6.6 sparse-checkout set kernel/kernel-6.6
	git -C x2000_kernel_6.6 checkout a98c2e1f22e4263ddd4153a4eca4db4dcfd2777b
else
	echo "== x2000_kernel_6.6 already present, skipping =="
fi

# Buildroot config for this board family (Phase 0's find).
clone_pinned buildroot-x2000 https://github.com/lone0/buildroot-x2000.git \
	74d020081096972857acdb9e76c6c5335455d430

# SimpleAF's Klipper fork - Track 1's "SimpleAF + the probe" decision applies
# here too: this is the environment this whole app stack targets.
clone_pinned klipper https://github.com/pellcorp/klipper.git \
	386fde4fd38e8eda6999e58bf260eceb00051188

# Official Moonraker - not a fork, no reason to deviate.
clone_pinned moonraker https://github.com/Arksine/moonraker.git \
	d5ee17128bb88434aacdab90c2e9e990e2b64e4a

# Camera pipeline - real MIT-licensed uStreamer port for this board family.
clone_pinned k1-ustreamer https://github.com/pellcorp/k1-ustreamer.git \
	18e30bb313d54b1b01dd995bd31ce5a3d5adffd6 "--recurse-submodules"
git -C k1-ustreamer submodule update --init --recursive

# Mainsail - a built Vue app, fetched as a real release archive, not built
# from source here (no Node.js toolchain needed for this build at all).
mkdir -p mainsail-dist
if [ ! -f mainsail-dist/mainsail.zip ]; then
	echo "== downloading Mainsail's latest release =="
	curl -sL https://github.com/mainsail-crew/mainsail/releases/latest/download/mainsail.zip \
		-o mainsail-dist/mainsail.zip
fi
rm -rf mainsail-dist/dist
mkdir -p mainsail-dist/dist
unzip -q mainsail-dist/mainsail.zip -d mainsail-dist/dist

# mainsail-crew's own installer repo - only used for its real, canonical
# nginx reverse-proxy config template (already baked into scripts/build/
# overlay/etc/nginx/nginx.conf), not needed again unless you're re-deriving
# that config. Left commented out - uncomment if you want to re-check it.
# clone_pinned kiauh https://github.com/dw-0/kiauh.git HEAD

echo "== all vendor sources fetched =="
