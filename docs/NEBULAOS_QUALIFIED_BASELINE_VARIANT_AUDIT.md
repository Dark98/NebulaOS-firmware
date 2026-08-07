# Qualified baseline variant audit

Started as Phase 1 of the baseline-canonicalization-and-z_compensate-
deployment mission (2026-08-06/07); extended by Phase 6 of the follow-up
Repository + Canonical Baseline Repair mission (2026-08-07) once it became
clear the original scope (tag
`nebulaos-display-baseline-vsync-pwm-sleep-2026-08-03`) was no longer the
actual currently-accepted baseline - `nebulaos-wifi-camera-irq-fix-2026-08-04`
superseded it three days later. Full inventory of every
`scripts/build/*-variant.sh` script, what each one actually touches, whether
they can interfere with each other, and which argument value is the
*accepted* one for the current baseline (tag
`nebulaos-wifi-camera-irq-fix-2026-08-04`, kernel commit
`295b7101d751fd888ae39e6f1746a4a940664a5f`, unchanged from the 08-03 tag).

## Category legend

Every accepted-or-not source of change this project has produced falls into
exactly one of these buckets. Used throughout this document and worth
naming explicitly, since "accepted" alone doesn't distinguish *how* a change
reaches a build:

- **ACCEPTED BASELINE** - real, live-qualified, and either (a) a plain
  tracked file with no toggle at all, so every build already includes it, or
  (b) gated behind a `*-variant.sh` script that `apply-qualified-baseline.sh`
  now calls automatically. Nothing in this category depends on a human
  remembering to run anything by hand.
- **ACCEPTED LATER FIX** - same bar as ACCEPTED BASELINE (live-qualified,
  real), called out separately here only because it landed after the
  original 08-03 baseline and is the reason this document's scope widened.
  Once folded into `apply-qualified-baseline.sh` (as `wifi-roamoff-disable-
  variant.sh` ROAMOFF1 now is) there is no build-time distinction from
  ACCEPTED BASELINE - the split is purely historical/documentation.
- **EXPERIMENTAL** - a real prototype, never live-qualified as a production
  candidate, kept for possible future work. Off by default, requires an
  explicit script invocation to turn on.
- **FAILED-SUPERSEDED** - a real, once-live prototype that a later, better
  fix replaced (e.g. `display-backlight-variant.sh`'s DISPLAY-B1 -> `backlight-
  final-controller-variant.sh`'s FINAL1). Kept for history, not for reuse.
- **DIAGNOSTIC ONLY** - read-only instrumentation/observation tooling with
  no intended production use at all.

## How "accepted" was determined

Not by trusting any variant script's own marker file under `build-work/` -
those record whichever argument was *last* passed to that script, and by
design get reset to the "off" value after a real qualification build (so an
unreviewed experiment can never silently become the new default - see each
script's own header). The real, durable source of truth is the fully
*resolved* output the qualified build actually produced and that this repo
already tracks in git:

- `artifacts/buildroot-halley5-v30-image/kernel.config`
- `artifacts/buildroot-halley5-v30-image/halley5_v30.dts`

Both are confirmed byte-identical between the pinned baseline tag and the
current `HEAD` (`git diff f9dc10f... HEAD -- <path>` is empty for both,
plus `buildroot.config` and `halley5-nebulaos-fragment.config`) - the
tracked fragment/DTS templates have not drifted since the baseline was cut.
Every Kconfig symbol below was independently confirmed present (or absent)
in the real `kernel.config` via direct `grep`, not inferred from a script's
own comments or a stale marker file.

## Root cause of the regression this audit exists to prevent

Each variant script's Kconfig contribution lives in the *tracked* fragment
file (`artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config`),
but every script also strips its own marker block back out as its first
action - so by the time a qualified build gets tagged, the tracked fragment
no longer contains the lines that produced it. The kernel *source* changes
(new driver files, Kconfig entries, DTS nodes) live only as `.patch` files
under `scripts/build/patches/`, applied directly to the gitignored
`vendor/x2000_kernel_6.6` checkout - never committed to that inner kernel
repo either. Running the plain `00-06` pipeline against a fresh checkout
therefore reproduces the *pre-variant* kernel, silently dropping every
accepted fix. `scripts/build/apply-qualified-baseline.sh` closes this gap:
one command, applies every accepted variant, from a clean checkout, every
time.

## Per-script audit

| Script | Accepted arg | Files touched | Kconfig symbol(s) | Shares files with | Order constraint |
|---|---|---|---|---|---|
| `preempt-variant.sh` | **R1** | tracked fragment (own marker block only) | `CONFIG_PREEMPT_RT=y` | none | none |
| `wifi-sdio-variant.sh` | **W3** | vendor DTS, scoped to the `&msc1 { ... }` block only | (DTS boolean properties, not Kconfig) | DTS file only, with `backlight-final-controller-variant.sh` (disjoint region - see below) | none |
| `display-vsync-variant.sh` | **V1** | vendor `fb_stage` driver files (exclusive) + tracked fragment (own marker) | `CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y` | none | none |
| `pinctrl-ownership-fix-variant.sh` | **FIX1** | vendor `pinctrl-ingenic.c`/`.h` (exclusive, unconditional C fix, no Kconfig gate) | none | none | none |
| `backlight-final-controller-variant.sh` | **FINAL1** | vendor `drivers/misc/{Kconfig,Makefile}` + new driver file (exclusive) + vendor DTS (own marker-wrapped top-level node, append-only) + tracked fragment (own marker) | `CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER=y` | DTS file only, with `wifi-sdio-variant.sh` (disjoint region) | none - explicitly designed to never touch `&pwm`'s own `pinctrl-0` line, the exact edit that caused the real prior screen-goes-dark incident this driver replaces |
| `pwm-state-readback-variant.sh` | **GETSTATE1** | vendor `drivers/pwm/{Kconfig,pwm-ingenic-v2.c}` (exclusive) + tracked fragment (own marker) | `CONFIG_PWM_INGENIC_V2_GET_STATE=y` | none | none. Note: this script's own header warns "NEVER enable for a production/active-slot build until live-hardware qualification" - the tracked, currently-deployed `kernel.config` has it enabled anyway, so it clearly *was* qualified since that comment was written; treated as accepted on the strength of the real deployed config, not the (apparently stale) comment. |
| `touch-final-qualification-variant.sh` | **FINALQUAL1** | vendor `drivers/input/touchscreen/{Kconfig,ns2009.c,Makefile}` (shared with `touch-qualification-variant.sh`) + new driver file (exclusive) + tracked fragment (own marker) | `CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION=y` | `Kconfig`/`ns2009.c`/`Makefile`, with `touch-qualification-variant.sh` | **Must run after `touch-qualification-variant.sh` if that script is used at all** - its own "off" step does an unconditional blanket `git checkout --` of those three files, silently discarding this script's content if run afterward (documented and self-tested in this script's own header). Moot for this baseline: see below. |
| `wifi-roamoff-disable-variant.sh` (**ACCEPTED LATER FIX**, added 2026-08-07) | **ROAMOFF1** | vendor `drivers/net/wireless/broadcom/brcm80211/brcmfmac/common.c` (exclusive) via `scripts/build/patches/wifi-roamoff-disable.patch` | none (source-level `module_param` default, not a Kconfig symbol - verified live instead: `/sys/module/brcmfmac/parameters/roamoff` reads `1` on the deployed device, see commit `8d445a98`) | none | none |

## Explicitly excluded (audited, not merely forgotten)

Every script below is **EXPERIMENTAL**, **FAILED-SUPERSEDED**, or
**DIAGNOSTIC ONLY** - real work, kept for history/future reference, but
never part of a production build. `apply-qualified-baseline.sh` never
invokes any of them. As of 2026-08-07, the five whose blanket `git checkout
--` can actually destroy an ACCEPTED variant's state (as opposed to merely
being irrelevant to it) also refuse to run at all once that accepted state
is present - see "Guarded against accidental clobber" below.

- **`touch-qualification-variant.sh` (`QUAL0`/`QUAL1`)** - FAILED-SUPERSEDED
  by `touch-final-qualification-variant.sh`. `QUAL0` (off) is the accepted
  state: `CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION` does not appear anywhere
  in the tracked `kernel.config`. Not invoked by `apply-qualified-
  baseline.sh` at all - a pristine fresh checkout is already `QUAL0`.
- **`touch-irq-variant.sh`, `touch-d0-diag-variant.sh`,
  `touch-i0-diag-variant.sh`** - FAILED-SUPERSEDED, same lineage as
  `touch-qualification-variant.sh` above (see that script's own header:
  these three are its direct predecessors, explicitly marked deprecated
  there). None of their Kconfig symbols appear in the tracked
  `kernel.config`, confirming their accepted state is plain "off".
- **`display-backlight-variant.sh` (`S0`/`S1`)** - FAILED-SUPERSEDED by
  `backlight-final-controller-variant.sh`'s FINAL1 (its own header already
  said "NEVER apply this to a build destined for the active/production
  slot" - the enable-line electrical behavior it needed was still
  `UNKNOWN_UNTIL_HARDWARE` when it was written). No DT node from it appears
  in the tracked `halley5_v30.dts`.
- **`display-backlight-diag-variant.sh`** - DIAGNOSTIC ONLY, a probe-timing
  instrumentation variant for the same investigation. Never reached
  production; already uses the safe scoped-edit pattern (see its own header
  on the 2026-08-02 incident that motivated that), so it composes safely
  with `wifi-sdio-variant.sh` and needed no new guard here.

### Guarded against accidental clobber (2026-08-07)

Five scripts still do (or, until this mission, did) an unconditional
`git checkout --` of a file another, now-accepted variant also owns. One of
these already caused a real incident (2026-08-02, documented in `wifi-sdio-
variant.sh`'s own header: a composed qualification build silently lost its
backlight DT node because a sibling script's blanket checkout ran after it
and wiped it, no build error anywhere). That incident led to `wifi-sdio-
variant.sh` and `display-backlight-diag-variant.sh` being rewritten to
scoped, composable edits - but `display-backlight-variant.sh` and the four
`touch-qualification-variant.sh`-family scripts kept the original blanket-
checkout pattern, since at the time nothing accepted still lived in their
target files. That stopped being true once `backlight-final-controller-
variant.sh` (FINAL1) and `touch-final-qualification-variant.sh`
(FINALQUAL1) became part of the accepted baseline. Each of the five now
checks for the accepted variant's marker before its blanket checkout and
refuses to run (clear `FATAL:` message, exit 1) if found, rather than
relying on a header comment and operator discipline alone:

- `display-backlight-variant.sh` (S0 and S1) - refuses if
  `NEBULAOS_BACKLIGHT_FINAL_CONTROLLER_VARIANT_DTS_BEGIN` is present in the
  DTS.
- `touch-qualification-variant.sh`, `touch-d0-diag-variant.sh`,
  `touch-i0-diag-variant.sh`, `touch-irq-variant.sh` (all variant values) -
  refuse if `config TOUCHSCREEN_NS2009_FINAL_QUALIFICATION` is present in
  the touchscreen `Kconfig`.

All five verified live against a real vendor checkout with the accepted
baseline composed: each refuses correctly for both its "on" and "off"
argument (the checkout itself is the destructive step, regardless of what
gets applied afterward), and each still works normally against a pristine,
un-composed checkout (confirmed by resetting and re-running QUAL0/S0).

## Userspace/overlay "preserve" items - not part of this audit

`supervisorctl long-name fix`, `S99confirm-good behavior`, `c03757e seed
fix`, and the userspace half of `touch-wake debugfs-path fix` all live in
`scripts/build/overlay/` - a plain git-tracked directory (unlike the
gitignored `vendor/` tree), re-synced verbatim into the Buildroot overlay
by `02-configure-buildroot.sh` on every run regardless of which kernel
variants are applied. These were never at risk from the regression this
audit investigates (confirmed: the earlier bad rebuild's diff against the
tracked baseline was scoped entirely to `kernel.config` and
`halley5_v30.dts`, zero overlay-file differences).

## ACCEPTED BASELINE items added since 08-03 with no variant script at all

Not every post-08-03 accepted fix needed a toggle script. These are plain
tracked files, picked up by every build automatically - listed here only so
this document is a complete inventory of "everything accepted since the
original baseline," not just the kernel-variant subset:

- **WiFi SDIO IRQ thread priority** (commit `a233317`) -
  `scripts/build/overlay/etc/init.d/S02nebulaos-wifi-irq-priority`, a plain
  tracked init.d script. No Kconfig/DTS involvement at all.
- **ustreamer `--tcp-nodelay`** (commit `c29e41e`) - a flag added directly
  to `scripts/build/overlay/etc/init.d/S50webcam`'s own ustreamer invocation.
- **Camera LOW/MED/HIGH quality presets** (commit `5479e0e`) - plain tracked
  macro/config files under `scripts/build/overlay/opt/`, with their own
  `06-verify.sh` build-time presence checks (same pattern as the existing
  `frontend-controls.cfg`/`guppy_cmd.cfg` checks) - a future build already
  fails loudly if either goes missing, no separate audit needed here.
- **z_compensate structured Klipper status contract** (commit `60e7ce5`,
  Klipper-side; consumed by `nebulaos-guppyscreen` commit `531bc75`) -
  `klippy_extras/z_compensate.py`'s `get_status()` plus GuppyScreen's
  `recalibration_wizard_panel`/`z_compensate_status.cpp`. Previously only
  live-deployed by hand to both `/opt/klipper` and a manually-copied
  GuppyScreen binary with no source-pin proof either matched what was
  running; now the sole source of truth is the pinned `KLIPPER_PIN`/
  `GUPPYSCREEN_PIN` in `manifests/dependencies.conf`, fetched and built by
  `00-fetch-vendor-sources.sh`/`04-cross-compile-app-stack.sh` - see those
  files' own 2026-08-07 comments. `nebulaos-guppyscreen` commit `be5d372`
  (config/theme parse-safety fix, a real fixed startup crash - see
  `tests/test_config_theme_parse_safety.cpp`'s own header) is the same pin
  and is included automatically, not a separate step.

## Verification

After running `apply-qualified-baseline.sh` and the numbered pipeline
(`02` through `05`), the resulting `artifacts/buildroot-halley5-v30-image/
kernel.config` and `halley5_v30.dts` must diff empty against the versions
tracked at `HEAD` (== the pinned baseline tag) - see Phase 2's assertions
and Phase 5's baseline-difference gate for where this is actually enforced
as a hard build-blocking check, not just a manual spot check. This check
does not, by construction, cover `wifi-roamoff-disable-variant.sh`'s
source-level patch (not a `kernel.config`/DTS change) or the plain-tracked
overlay items above (already covered by `06-verify.sh`'s own file-presence
checks and, for `z_compensate`/GuppyScreen, by the dependency-manifest pin
gate) - each has its own, separately-adequate verification path instead.
