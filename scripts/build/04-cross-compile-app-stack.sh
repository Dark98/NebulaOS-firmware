#!/bin/sh
# Cross-compile the handful of things that need the Buildroot-built
# toolchain directly (Klipper's chelper C extension, Moonraker's
# streaming-form-data C extension, ustreamer itself), download the
# pure-Python wheels with no Buildroot package, and assemble the full
# app-stack overlay - Klipper/Moonraker source, Mainsail's static build,
# and everything above - on top of the hand-written files stage 2 already
# put in place.
#
# Must run after 03-build-kernel-and-rootfs.sh - needs the Buildroot
# toolchain and target Python headers to already be built.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
VENDOR="$REPO_ROOT/vendor"
BUILDROOT_DIR="$VENDOR/buildroot-x2000"
OVERLAY="$BUILDROOT_DIR/board/halley5-openke-overlay"
TOOLCHAIN_HOST="$BUILDROOT_DIR/output/host"
SYSROOT="$TOOLCHAIN_HOST/mipsel-buildroot-linux-gnu/sysroot"
WORK="$REPO_ROOT/build-work/app-stack-extras"

if [ ! -x "$TOOLCHAIN_HOST/bin/mipsel-buildroot-linux-gnu-gcc" ]; then
	echo "Buildroot toolchain not built - run 03-build-kernel-and-rootfs.sh first" >&2
	exit 1
fi

mkdir -p "$WORK"

### 1. Klipper: klippy/ source + a freshly cross-compiled chelper.so
###    (this fork's own checked-in c_helper.so is a prebuilt MIPS binary of
###    unknown toolchain/ABI provenance - don't trust it, rebuild it here).
echo "== cross-compiling Klipper's chelper C extension =="
docker run --rm \
	-v "$VENDOR/klipper:/klipper" \
	-v "$BUILDROOT_DIR/output:/buildroot-output" \
	-w /klipper/klippy/chelper pellcorp/k1-bash-build bash -c '
	export PATH=/buildroot-output/host/bin:$PATH
	make clean
	make CC=mipsel-buildroot-linux-gnu-gcc
'
mkdir -p "$OVERLAY/opt/klipper"
rm -rf "$OVERLAY/opt/klipper/klippy"
cp -r "$VENDOR/klipper/klippy" "$OVERLAY/opt/klipper/"
find "$OVERLAY/opt/klipper" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
rm -f "$OVERLAY/opt/klipper/klippy/chelper"/*.o "$OVERLAY/opt/klipper/klippy/chelper"/*.a

### 2. Moonraker: source + its Python dependency chain
echo "== copying Moonraker source =="
mkdir -p "$OVERLAY/opt/moonraker"
rm -rf "$OVERLAY/opt/moonraker/moonraker"
cp -r "$VENDOR/moonraker/moonraker" "$OVERLAY/opt/moonraker/"
find "$OVERLAY/opt/moonraker" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

echo "== downloading Moonraker's pure-Python deps with no Buildroot package =="
mkdir -p "$WORK/pywheels"
docker run --rm --user root -v "$WORK/pywheels:/wheels" pellcorp/k1-bash-build bash -c '
apt-get update >/dev/null 2>&1
apt-get install -y python3-pip >/dev/null 2>&1
pip3 download -d /wheels --no-deps \
	inotify-simple==2.0.1 libnacl==2.1.0 apprise==1.9.3 ldap3==2.9.1 \
	importlib_metadata==8.4.0 preprocess-cancellation==0.2.1 pyasn1
'
SITEPKG="$OVERLAY/usr/lib/python3.11/site-packages"
mkdir -p "$SITEPKG"
for whl in "$WORK"/pywheels/*.whl; do
	python3 -m zipfile -e "$whl" "$SITEPKG/" 2>&1 || unzip -o -q "$whl" -d "$SITEPKG"
done

echo "== cross-compiling Moonraker's one real C extension: streaming-form-data =="
docker run --rm --user root -v "$WORK/pywheels:/wheels" pellcorp/k1-bash-build bash -c '
apt-get update >/dev/null 2>&1
apt-get install -y python3-pip >/dev/null 2>&1
pip3 download -d /wheels --no-deps --no-binary :all: streaming-form-data==1.11.0
'
tar xzf "$WORK/pywheels/streaming-form-data-1.11.0.tar.gz" -C "$WORK"
docker run --rm \
	-v "$SYSROOT:/sysroot" \
	-v "$TOOLCHAIN_HOST:/buildroot-host" \
	-v "$WORK/streaming-form-data-1.11.0:/src" \
	-w /src pellcorp/k1-bash-build bash -c '
	export PATH=/buildroot-host/bin:$PATH
	mipsel-buildroot-linux-gnu-gcc -shared -fPIC -O2 \
		-I/sysroot/usr/include/python3.11 \
		-o streaming_form_data/_parser.cpython-311-mipsel-linux-gnu.so \
		streaming_form_data/_parser.c
'
mkdir -p "$SITEPKG/streaming_form_data"
cp "$WORK"/streaming-form-data-1.11.0/streaming_form_data/*.py \
   "$WORK"/streaming-form-data-1.11.0/streaming_form_data/*.so \
   "$SITEPKG/streaming_form_data/"

### 3. ustreamer (camera pipeline)
echo "== cross-compiling ustreamer =="
docker run --rm -v "$VENDOR/k1-ustreamer:/home/tim/k1-ustreamer" \
	-w /home/tim/k1-ustreamer pellcorp/k1-camera-build \
	/home/tim/k1-ustreamer/docker.sh all
mkdir -p "$OVERLAY/usr/bin" "$OVERLAY/usr/lib"
cp "$VENDOR/k1-ustreamer/ustreamer/src/ustreamer.bin" "$OVERLAY/usr/bin/ustreamer"
chmod 755 "$OVERLAY/usr/bin/ustreamer"
cp "$VENDOR"/k1-ustreamer/build/ustreamer-deps/lib/*.so* "$OVERLAY/usr/lib/"
# re-create the SONAME symlinks the binary actually needs (readelf -d
# ustreamer | grep NEEDED confirms these exact names)
( cd "$OVERLAY/usr/lib" && \
  ln -sf libjpeg.so.9.4.0 libjpeg.so.9 && \
  ln -sf libevent-2.1.so.7.0.1 libevent-2.1.so.7 && \
  ln -sf libevent_core-2.1.so.7.0.1 libevent_core-2.1.so.7 && \
  ln -sf libevent_extra-2.1.so.7.0.1 libevent_extra-2.1.so.7 && \
  ln -sf libevent_pthreads-2.1.so.7.0.1 libevent_pthreads-2.1.so.7 && \
  ln -sf libmd.so.0.1.0 libmd.so.0 && \
  ln -sf libbsd.so.0.11.7 libbsd.so.0 )

### 4. Mainsail static build (already unpacked by 00-fetch-vendor-sources.sh)
echo "== copying Mainsail static build =="
mkdir -p "$OVERLAY/usr/share/mainsail"
cp -r "$VENDOR"/mainsail-dist/dist/* "$OVERLAY/usr/share/mainsail/"

echo "== app-stack overlay assembled at $OVERLAY =="
