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
docker run --label "openke-build-pid=$$" --rm \
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

# Stock-parity fix (FIRMWARE.md sec 13): only klippy/ was ever staged here,
# so Moonraker's file_manager always registered "config_examples" ->
# /opt/klipper/config and "docs" -> /opt/klipper/docs (its own unconditional
# behavior, not custom-specific), and both warned "invalid path" every boot
# since neither existed. Stock's real Klipper install (/usr/share/klipper)
# ships the full upstream checkout, config/ and docs/ included, which is
# why stock never showed this warning - not a different Moonraker behavior,
# just real content actually being present. Our own vendor/klipper is a
# full checkout too; it was just never copied. Packaging the exact same
# revision's reference content here, not fabricated placeholder content.
rm -rf "$OVERLAY/opt/klipper/config" "$OVERLAY/opt/klipper/docs"
cp -r "$VENDOR/klipper/config" "$OVERLAY/opt/klipper/"
cp -r "$VENDOR/klipper/docs" "$OVERLAY/opt/klipper/"

# This repo's own klippy_extras/ (prtouch_v2.py, z_compensate.py,
# guppy_module_loader.py, etc.) was a real, pre-existing gap - written and
# referenced by printer.cfg's own comments, but never actually copied
# anywhere by this pipeline, since only vendor Klipper's own klippy/extras/
# ever made it into the overlay above. Layered on top (never replacing
# vendor Klipper's own extras), same as everything else in this stage.
cp "$REPO_ROOT/klippy_extras/"*.py "$OVERLAY/opt/klipper/klippy/extras/"
rm -rf "$OVERLAY/opt/klipper/klippy/extras/__pycache__"

### 2. Moonraker: source + its Python dependency chain
echo "== copying Moonraker source =="
mkdir -p "$OVERLAY/opt/moonraker"
rm -rf "$OVERLAY/opt/moonraker/moonraker"
cp -r "$VENDOR/moonraker/moonraker" "$OVERLAY/opt/moonraker/"
find "$OVERLAY/opt/moonraker" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# OpenKE (2026-07-23): vendor/moonraker is a plain upstream clone re-fetched
# fresh by 00-fetch-vendor-sources.sh every time (unlike the kernel, which
# is a real fork we commit to) - so this patch is applied to the copy that
# just landed in the overlay, not to vendor/moonraker itself, which would
# silently lose it on the next fetch. Fixes a real, reproducible hang/
# "database is locked" error found on real hardware: strace showed
# fcntl64(fd, F_SETLK64, F_RDLCK, PENDING_BYTE) = -1 EACCES on this
# kernel's tmpfs, with zero real lock contention (single connection, first
# ever access) - SQLite's own documented nolock=1 URI workaround for
# filesystems with broken POSIX locking fixes it, confirmed reliably
# reproducible/fixed multiple times in a row (see FIRMWARE.md sec 23).
#
# -N: the copy above is a fresh rm -rf + cp -r from vendor/moonraker every
# run, so this should always be pristine and apply cleanly - but patch's own
# "already applied" detection has, in practice, still triggered here and
# (without -N) aborted the whole script via set -e despite the file already
# being in the correct end state. -N makes patch skip hunks it detects as
# already-applied instead of erroring, so this stays idempotent either way.
patch -N -p1 -d "$OVERLAY/opt/moonraker" < "$SCRIPT_DIR/patches/moonraker-sqlite-nolock.patch" || true

# OpenKE (2026-07-23): zipp added after a real, previously-silent bug found
# on real hardware - importlib_metadata (below) imports zipp at runtime, but
# --no-deps meant it was never actually downloaded, so Moonraker died
# instantly with ModuleNotFoundError: No module named zipp, before opening
# its own log file at all.
echo "== downloading Moonraker's pure-Python deps with no Buildroot package =="
mkdir -p "$WORK/pywheels"
docker run --label "openke-build-pid=$$" --rm --user root -v "$WORK/pywheels:/wheels" pellcorp/k1-bash-build bash -c '
apt-get update >/dev/null 2>&1
apt-get install -y python3-pip >/dev/null 2>&1
pip3 download -d /wheels --no-deps \
	inotify-simple==2.0.1 libnacl==2.1.0 apprise==1.9.3 ldap3==2.9.1 \
	importlib_metadata==8.4.0 preprocess-cancellation==0.2.1 pyasn1 \
	zipp==3.20.2
'
SITEPKG="$OVERLAY/usr/lib/python3.11/site-packages"
mkdir -p "$SITEPKG"
for whl in "$WORK"/pywheels/*.whl; do
	python3 -m zipfile -e "$whl" "$SITEPKG/" 2>&1 || unzip -o -q "$whl" -d "$SITEPKG"
done

echo "== cross-compiling Moonraker's one real C extension: streaming-form-data =="
docker run --label "openke-build-pid=$$" --rm --user root -v "$WORK/pywheels:/wheels" pellcorp/k1-bash-build bash -c '
apt-get update >/dev/null 2>&1
apt-get install -y python3-pip >/dev/null 2>&1
pip3 download -d /wheels --no-deps --no-binary :all: streaming-form-data==1.11.0
'
tar xzf "$WORK/pywheels/streaming-form-data-1.11.0.tar.gz" -C "$WORK"
docker run --label "openke-build-pid=$$" --rm \
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
docker run --label "openke-build-pid=$$" --rm -v "$VENDOR/k1-ustreamer:/home/tim/k1-ustreamer" \
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
