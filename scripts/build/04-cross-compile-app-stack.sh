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
VENDOR="$REPO_ROOT/vendor"
BUILDROOT_DIR="$VENDOR/buildroot-x2000"
OVERLAY="$BUILDROOT_DIR/board/halley5-nebulaos-overlay"
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

# NebulaOS mutable-runtime closure mission (2026-07-27): empty mount-point
# baked into the squashfs so S05nebulaos-activate can bind-mount the real,
# persistent Klipper venv ($NEBULAOS_ROOT/envs/klipper) onto it at boot.
# Required specifically because Moonraker's update_manager hardcodes
# "~/klippy-env/bin/python" as its bootstrap default for the klipper slot
# (klippy_connection.py's own __init__, used synchronously at Moonraker
# startup, before Klippy's real identify handshake has a chance to report
# its actual executable) - with no config override available for this
# slot (confirmed live: path/env/virtualenv aren't in update_manager's own
# OPTION_OVERRIDES), the only way to make update_manager succeed on the
# very first Moonraker start (not just self-heal after a lucky second
# restart once Klippy's real path gets persisted to Moonraker's own db)
# is to make that exact hardcoded default path real. /root is part of the
# read-only squashfs, so this directory must exist here at build time -
# mkdir at runtime would fail (read-only filesystem).
mkdir -p "$OVERLAY/root/klippy-env"
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
# guppy_module_loader.py, etc.) used to be a real gap - written and
# referenced by printer.cfg's own comments, but never actually copied
# anywhere by this pipeline, since only vendor Klipper's own klippy/extras/
# ever made it into the overlay above. Fixed at the source instead of here:
# vendor/klipper now tracks coreflake1/NebulaOS-klipper's `nebulaos` branch
# (00-fetch-vendor-sources.sh), which has every one of these files committed
# directly into its own klippy/extras/ - the wholesale `cp -r klippy` above
# already carries them into the overlay, so no separate copy step is needed
# here any more. This repo's own klippy_extras/ directory remains the
# reviewable source of truth for these files' content (edit there, then
# re-commit into the fork - see docs/NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md
# sec 1.3), it is just no longer injected at build time as untracked files.

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
	zipp==3.20.2 wheel==0.42.0
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
#
# OpenKE fix (USB/webcam stock-parity mission, FIRMWARE.md sec 60): this
# used to build via pellcorp's own `pellcorp/k1-camera-build` docker image,
# which bundles Ingenic's stock vendor toolchain
# (/opt/toolchains/mips-gcc720-glibc229, glibc 2.29). That toolchain's
# glibc uses a DIFFERENT MIPS ABI than this project's own Buildroot-built
# target glibc (2.38, confirmed via /lib/libc.so.6's own banner:
# "libc ABIs: MIPS_PLT UNIQUE MIPS_O32_FP64 ABSOLUTE MIPS_XHASH") - the
# resulting ustreamer.bin's own dynamic-linker request
# (`readelf -l` -> "Requesting program interpreter:
# /lib/ld-linux-mipsn8.so.1") never matched this rootfs's real interpreter
# (plain /lib/ld.so.1), so the binary could never actually execute here -
# busybox ash reports this as a confusing "not found" (it's really the
# missing interpreter, not the file itself; confirmed real files/libs were
# all present and correctly staged). This was never caught before because
# no prior session had a real UVC webcam physically attached to test with.
#
# Fix: build the *exact same*, untouched pellcorp/k1-ustreamer source
# (still vendor/k1-ustreamer at its pinned commit, submodules unchanged)
# with this project's own internal Buildroot toolchain instead - the same
# one already used for Klipper's chelper and Moonraker's streaming-form-
# data above, guaranteeing ABI consistency with the rest of the rootfs.
# Mirrors docker.sh's own real, proven build steps (jpeg-9d, libevent,
# libmd, libbsd, then ustreamer itself) with the toolchain swapped.
echo "== cross-compiling ustreamer (this project's own Buildroot toolchain, not pellcorp/k1-camera-build's incompatible one) =="
rm -rf "$VENDOR/k1-ustreamer/build"
docker run --label "openke-build-pid=$$" --rm \
	-v "$VENDOR/k1-ustreamer:/src" \
	-v "$TOOLCHAIN_HOST:/buildroot-host" \
	-w /src pellcorp/k1-bash-build bash -c '
	set -e
	# Append, not prepend: the Buildroot host/bin dir also carries its own
	# internal automake-1.16/autoconf wrappers (built for its own package
	# builds), which are broken when found ahead of the container real
	# system automake/autoconf - they hardcode paths only valid inside the
	# Buildroot build tree itself. Appending still finds the uniquely-named
	# mipsel-buildroot-linux-gnu-* cross tools (no name collision with
	# anything already in the container PATH) without shadowing them.
	export PATH=$PATH:/buildroot-host/bin
	export BUILD_PREFIX=/src/build/ustreamer-deps
	export CC=mipsel-buildroot-linux-gnu-gcc
	export AR=mipsel-buildroot-linux-gnu-gcc-ar
	export LD=mipsel-buildroot-linux-gnu-ld
	export STRIP=mipsel-buildroot-linux-gnu-strip
	export CFLAGS="-I$BUILD_PREFIX/include/"
	export LDFLAGS="-L$BUILD_PREFIX/lib/"
	mkdir -p /src/build

	cd /src/jpeg-9d && git clean -xdf
	cd /src/ustreamer && make clean PKG_CONFIG=true

	cd /src/build
	tar xf ../libevent-2.1.12-stable.tar.gz && cd libevent-2.1.12-stable
	./configure --host=mipsel-buildroot-linux-gnu --prefix=$BUILD_PREFIX \
		--disable-openssl --disable-samples --disable-libevent-regress
	make && make install

	cd /src/build
	tar xf ../libmd-1.1.0.tar.xz && cd libmd-1.1.0
	./configure --host=mipsel-buildroot-linux-gnu --prefix=$BUILD_PREFIX
	make && make install

	cd /src/build
	tar xf ../libbsd-0.11.7.tar.xz && cd libbsd-0.11.7
	./configure --host=mipsel-buildroot-linux-gnu --prefix=$BUILD_PREFIX
	make && make install

	cd /src/jpeg-9d
	./configure --host=mipsel-buildroot-linux-gnu --build=x86_64-pc-linux-gnu --prefix=$BUILD_PREFIX
	make && make install

	cd /src/ustreamer
	export CFLAGS="$CFLAGS -Os -march=mips32r2 -ffunction-sections -fdata-sections"
	export LDFLAGS="$LDFLAGS -Wl,--gc-sections -s"
	make PKG_CONFIG=true WITH_PTHREAD_NP=0 WITH_SETPROCTITLE=0
	mipsel-buildroot-linux-gnu-strip --strip-unneeded src/ustreamer.bin
'
mkdir -p "$OVERLAY/usr/bin" "$OVERLAY/usr/lib"
cp "$VENDOR/k1-ustreamer/ustreamer/src/ustreamer.bin" "$OVERLAY/usr/bin/ustreamer"
chmod 755 "$OVERLAY/usr/bin/ustreamer"
cp "$VENDOR"/k1-ustreamer/build/ustreamer-deps/lib/*.so* "$OVERLAY/usr/lib/"
# re-create the SONAME symlinks the binary actually needs - verified fresh
# against this rebuilt binary via `readelf -d ustreamer | grep NEEDED`,
# not assumed from the old pellcorp-toolchain build.
( cd "$OVERLAY/usr/lib" && \
  ln -sf libjpeg.so.9.4.0 libjpeg.so.9 && \
  ln -sf libevent-2.1.so.7.0.1 libevent-2.1.so.7 && \
  ln -sf libevent_core-2.1.so.7.0.1 libevent_core-2.1.so.7 && \
  ln -sf libevent_extra-2.1.so.7.0.1 libevent_extra-2.1.so.7 && \
  ln -sf libevent_pthreads-2.1.so.7.0.1 libevent_pthreads-2.1.so.7 && \
  ln -sf libmd.so.0.1.0 libmd.so.0 && \
  ln -sf libbsd.so.0.11.7 libbsd.so.0 )

### 4. v4l2-ctl (USB/webcam stock-parity mission, FIRMWARE.md sec 60)
#
# The camera-macro warning found in an earlier (Mainsail-warnings) mission
# ("v4l2-ctl: command not found") was a genuinely unresolved gap: this
# project's vendored Buildroot tree (a trimmed BSP subset) has no
# package/v4l-utils at all. S50webcam's own dynamic UVC-node discovery (see
# its own header comment) also depends on a real v4l2-ctl being present, not
# just the camera macro. Built from the real upstream source pinned in
# 00-fetch-vendor-sources.sh (v4l-utils-1.20.0, the last autotools release
# before the 1.22 meson migration - this build container has no python3/
# meson/ninja). Only utils/v4l2-ctl is built, not the whole suite; static
# libv4l2 is skipped entirely (--disable-v4l2-ctl-libv4l means v4l2-ctl uses
# raw ioctls directly, so it doesn't need libv4l2's own broken .la ordering
# fixed) - same minimal-footprint approach as ustreamer above, same
# toolchain, same reasoning for appending (not prepending) buildroot-host/
# bin to PATH.
echo "== cross-compiling v4l2-ctl (this project's own Buildroot toolchain) =="
docker run --label "openke-build-pid=$$" --rm --user root \
	-v "$VENDOR/v4l-utils:/src" \
	-v "$TOOLCHAIN_HOST:/buildroot-host" \
	-w /src pellcorp/k1-bash-build bash -c '
	set -e
	apt-get update >/dev/null 2>&1
	apt-get install -y autoconf automake libtool gettext autopoint pkg-config >/dev/null 2>&1
	export PATH=$PATH:/buildroot-host/bin
	export CC=mipsel-buildroot-linux-gnu-gcc
	export AR=mipsel-buildroot-linux-gnu-gcc-ar
	export LD=mipsel-buildroot-linux-gnu-ld
	export STRIP=mipsel-buildroot-linux-gnu-strip

	autoreconf -fiv
	./configure --host=mipsel-buildroot-linux-gnu \
		--disable-libdvbv5 --disable-qv4l2 --disable-qvidcap \
		--disable-gconv --disable-bpf --disable-v4l2-ctl-libv4l \
		--disable-shared --enable-static --without-jpeg

	make -C lib/libv4lconvert
	make -C utils/v4l2-ctl
	mipsel-buildroot-linux-gnu-strip --strip-unneeded utils/v4l2-ctl/v4l2-ctl
'
cp "$VENDOR/v4l-utils/utils/v4l2-ctl/v4l2-ctl" "$OVERLAY/usr/bin/v4l2-ctl"
chmod 755 "$OVERLAY/usr/bin/v4l2-ctl"

### 5. Mainsail static build (already unpacked by 00-fetch-vendor-sources.sh)
echo "== copying Mainsail static build =="
mkdir -p "$OVERLAY/usr/share/mainsail"
cp -r "$VENDOR"/mainsail-dist/dist/* "$OVERLAY/usr/share/mainsail/"

### 6. NebulaOS mutable-runtime mission, Phase 4 (revised - real-history
# repair mission, see docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md
# and the auto-updates-camera-complete mission): immutable offline factory
# seeds for Klipper and Moonraker, baked into the read-only squashfs so
# first-boot namespace seeding (S04nebulaos-factory-seed) never depends on
# GitHub, PyPI, or DNS being reachable. Mainsail needs no seed archive - it
# is already a plain static release tree, not a git repo, so the existing
# /usr/share/mainsail copy above IS its own offline seed; first-boot
# seeding just cp -a's it.
#
# PRIOR APPROACH (removed): each vendor checkout was flattened into a
# single synthetic orphan commit ("NebulaOS factory seed snapshot of
# <branch> @ <true_commit>") before bundling, because a plain
# `git bundle create` of vendor/klipper's shallow clone (1-2 commits deep,
# 00-fetch-vendor-sources.sh's clone_pinned) produces a bundle that
# `git bundle verify` reports as fine but a real `git clone` of rejects
# with "Failed to traverse parents of commit ..." / "remote did not send all
# necessary objects" (confirmed again against git 2.55.0 - a genuine,
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
# vendor/klipper's real "nebulaos" branch commit
# (b3d5ab2b9484f1558586c3a2ea43d46ff9a473a7) is confirmed genuinely
# present on GitHub (`git ls-remote nebulaos`) and was additionally pushed
# as a real "master" branch on the same coreflake1/NebulaOS-klipper fork
# (see the mission's Phase C) - so after this seed's origin fetch,
# origin/master is a real ref whose tip HEAD is trivially an ancestor of
# (currently: identical to). "nebulaos" remains a real branch too, kept as
# the development/source branch this project keeps building from.
# vendor/moonraker is already a full (non-shallow) clone of the official
# Arksine/moonraker repo with HEAD == origin/master, so it needs no branch
# surgery at all - only the same archive-instead-of-bundle treatment.
#
# make_seed_archive() itself lives in scripts/build/lib/make-seed-archive.sh,
# shared verbatim with tests/factory-seed-git-tests.sh so the tests exercise
# this exact function rather than a parallel reimplementation of its rules.
. "$SCRIPT_DIR/lib/make-seed-archive.sh"

echo "== creating offline factory-seed archives (Klipper, Moonraker) =="
mkdir -p "$OVERLAY/opt/nebulaos-seeds"
klipper_origin="https://github.com/coreflake1/NebulaOS-klipper.git"
klipper_seed_commit=$(make_seed_archive "$VENDOR/klipper" master \
	"$klipper_origin" "$OVERLAY/opt/nebulaos-seeds/klipper.tar")
klipper_is_shallow=$(git -C "$VENDOR/klipper" rev-parse --is-shallow-repository)

moonraker_origin="https://github.com/Arksine/moonraker.git"
moonraker_seed_commit=$(make_seed_archive "$VENDOR/moonraker" master \
	"$moonraker_origin" "$OVERLAY/opt/nebulaos-seeds/moonraker.tar")
moonraker_is_shallow=$(git -C "$VENDOR/moonraker" rev-parse --is-shallow-repository)
mainsail_version=$(cat "$VENDOR/mainsail-dist/dist/.version" 2>/dev/null || echo "unknown")
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > "$OVERLAY/opt/nebulaos-seeds/seed-manifest.json" <<EOF
{
  "schema_version": 2,
  "build_date": "$build_date",
  "seeds": {
    "klipper": {
      "format": "git_repo_archive_real_history",
      "file": "klipper.tar",
      "repository": "$klipper_origin",
      "branch": "master",
      "seed_commit": "$klipper_seed_commit",
      "is_shallow": $klipper_is_shallow,
      "sha256": "$(sha256sum "$OVERLAY/opt/nebulaos-seeds/klipper.tar" | cut -d' ' -f1)",
      "compatibility_level": 2,
      "upstream_base": "pellcorp/klipper @ 386fde4fd38e8eda6999e58bf260eceb00051188",
      "note": "real, genuinely-rooted shallow history - no synthetic wrapper commit; HEAD is confirmed present on the real coreflake1/NebulaOS-klipper remote as both 'master' and 'nebulaos'"
    },
    "moonraker": {
      "format": "git_repo_archive_real_history",
      "file": "moonraker.tar",
      "repository": "$moonraker_origin",
      "branch": "master",
      "seed_commit": "$moonraker_seed_commit",
      "is_shallow": $moonraker_is_shallow,
      "sha256": "$(sha256sum "$OVERLAY/opt/nebulaos-seeds/moonraker.tar" | cut -d' ' -f1)",
      "compatibility_level": 2,
      "note": "full, non-shallow real history; HEAD equals official Arksine/moonraker origin/master at build time"
    },
    "mainsail": {
      "format": "directory_copy",
      "source_path": "/usr/share/mainsail",
      "version": "$mainsail_version",
      "compatibility_level": 2
    }
  }
}
EOF
echo "== factory seeds created: $(ls -la "$OVERLAY/opt/nebulaos-seeds/") =="

echo "== app-stack overlay assembled at $OVERLAY =="
