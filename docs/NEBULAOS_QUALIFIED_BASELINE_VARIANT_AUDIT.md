# Qualified baseline variant audit

Phase 1 of the baseline-canonicalization-and-z_compensate-deployment mission
(2026-08-06/07). Full inventory of every `scripts/build/*-variant.sh` script,
what each one actually touches, whether they can interfere with each other,
and which argument value is the *accepted* one for the pinned baseline
(tag `nebulaos-display-baseline-vsync-pwm-sleep-2026-08-03`, commit
`f9dc10f594cd7591e1146317cda877f75165934b`, kernel commit
`295b7101d751fd888ae39e6f1746a4a940664a5f`).

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

## Explicitly excluded (audited, not merely forgotten)

- **`touch-qualification-variant.sh` (`QUAL0`/`QUAL1`)** - `QUAL0` (off) is
  the accepted state: `CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION` does not
  appear anywhere in the tracked `kernel.config`. Not invoked by
  `apply-qualified-baseline.sh` at all, on purpose - a pristine fresh
  checkout is already `QUAL0`, and invoking this script (even with `QUAL0`)
  after `touch-final-qualification-variant.sh` has already run would risk
  the exact silent-discard interaction its own header documents.
- **`touch-irq-variant.sh`, `touch-d0-diag-variant.sh`,
  `touch-i0-diag-variant.sh`, `display-backlight-variant.sh`,
  `display-backlight-diag-variant.sh`** - diagnostic/prototype-only tools.
  None of their Kconfig symbols (or, for `display-backlight-variant.sh`,
  DT node) appear in the tracked `kernel.config`/`halley5_v30.dts`,
  confirming their accepted state is plain "off" (default/pristine, no
  script invocation needed).
- **`wifi-roamoff-disable-variant.sh` (`ROAMOFF1`)** - real and accepted,
  but for the *later* `nebulaos-wifi-camera-irq-fix-2026-08-04` baseline
  (commit `8d445a9`), which postdates this mission's pinned baseline source
  (`f9dc10f`, 2026-08-03). Out of scope for this profile by the mission's
  own explicit baseline pin, not an oversight - `git show 8d445a9` confirms
  it is a plain `static int brcmf_roamoff = 1;` compile-time default change,
  unrelated to the separately-existing "Wi-Fi power save off" baseline item
  (a userspace/`wpa_supplicant`-side setting already present in the tracked
  `scripts/build/overlay/` tree, unaffected by any kernel variant work).

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

## Verification

After running `apply-qualified-baseline.sh` and the numbered pipeline
(`02` through `05`), the resulting `artifacts/buildroot-halley5-v30-image/
kernel.config` and `halley5_v30.dts` must diff empty against the versions
tracked at `HEAD` (== the pinned baseline tag) - see Phase 2's assertions
and Phase 5's baseline-difference gate for where this is actually enforced
as a hard build-blocking check, not just a manual spot check.
