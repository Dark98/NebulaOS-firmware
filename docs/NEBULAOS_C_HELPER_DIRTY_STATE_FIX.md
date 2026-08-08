# c_helper.so dirty-state fix (Final Baseline Closure mission, 2026-08-08)

## Symptom

Every real device's Moonraker reported the persistent Klipper checkout
(`/usr/data/nebulaos/apps/klipper`) as dirty/invalid in
`/machine/update/status` (`is_dirty: true`, `is_valid: false`,
`pristine: false`), even immediately after a genuinely clean first-boot
seed with no source modifications of any kind.

## Root cause

`klippy/chelper/c_helper.so` is a cross-compiled MIPS binary. This
project's own build pipeline (`scripts/build/04-cross-compile-app-
stack.sh`) unconditionally rebuilds it from `klippy/chelper/*.c`/`*.h`
via `make CC=mipsel-buildroot-linux-gnu-gcc` on every single build,
overwriting whatever bytes are on disk at that path - independent of
what git tracks there.

Prior to this fix, `NebulaOS-klipper` (the pinned fork) tracked a
committed copy of this binary in git (having deliberately disabled
upstream Klipper's own `*.so` `.gitignore` entry). That committed copy
was never actually used as shipped - it existed only to be immediately
overwritten by the cross-compile step above - but its mere presence in
the git index meant the freshly-compiled bytes on disk always differed
from git's tracked blob for that path, making the checkout permanently
"dirty" by git's own definition.

This project's own tooling (`scripts/build/lib/make-seed-archive.sh`,
`scripts/build/overlay/etc/init.d/S04nebulaos-migrate`,
`klippy_extras/nebulaos_version.py`'s `_klipper_git_state()`) already
special-cased this exact path out of their own dirty-tree checks, for
exactly this reason. Moonraker's own pinned, unforked update_manager
(`moonraker/components/update_manager/git_deploy.py`, verified directly
against the pinned commit in `manifests/dependencies.conf`'s
`MOONRAKER_PIN`) has no such allowlist mechanism, and no config option
exists to add one for its reserved `klipper`/`moonraker` update_manager
slots (`OPTION_OVERRIDES` in `update_manager/common.py` only accepts
`channel`, `pinned_commit`, `refresh_interval`, `report_anomalies`) - so
Moonraker always saw this one always-different file as a real,
uncorrectable source modification.

## Fix

`KLIPPER_PIN` bumped to `845396f0e84324103a5a0c518f4a0a031e4d410d`, which:

- `git rm --cached klippy/chelper/c_helper.so` - untracks the binary. The
  real `.c`/`.h` sources it compiles from remain fully tracked; only the
  generated output is excluded, so a genuine future source modification
  remains fully visible to any dirty-tree check, git's or Moonraker's.
- Restores upstream Klipper's own original `*.so` in `.gitignore` (this
  fork had it commented out).

A fresh clone of this pin has no `c_helper.so` on disk at all until the
build pipeline's cross-compile step creates it - `git status --porcelain`
(what Moonraker's own `is_dirty()` is ultimately built on) never lists it,
tracked or not, once it's gitignored, so the checkout now reads as clean
and valid with zero special-casing required on Moonraker's side. This is
the least-invasive fix available: it does not touch pinned, unforked
Moonraker source, does not weaken any dirty-detection globally (every
other path is still fully checked, by git and by Moonraker), and does not
hide any genuine source modification.

`scripts/build/lib/make-seed-archive.sh`'s wrong-architecture safety net
(discarding a stray host-arch `c_helper.so` before packaging) previously
did this by `git checkout --`-ing back to the committed version; with
nothing left to check out to, it now does a plain `rm -f` instead - same
practical safety property (never ship a wrong-architecture binary), fails
loudly downstream (Klippy's own `get_ffi()` has no on-device build
fallback) rather than silently.

## Verification

- `tests/factory-seed-git-tests.sh`: wrong-architecture discard behavior
  regression-tested directly.
- Existing `dirty_exclude`-based tests in the same file (both `seed_git_app`
  and the on-device init scripts) are unaffected: they build fixtures with
  an *untracked* `c_helper.so`, which was always correctly excluded via
  git's pathspec syntax regardless of tracked state.
- `06-verify.sh`'s seed-archive-vs-immutable-baseline `c_helper.so` SHA256
  comparison is unaffected: it compares packaged file bytes directly (via
  `tar`/`debugfs cat`), never git tracking state.
