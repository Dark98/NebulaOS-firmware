# NebulaOS Display Offline Implementation Plan

Companion to [NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md](NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md).
Covers Phases D18 (compile-only prototypes) and D19 (offline tests/assertions) in detail: what
was built, how it's toggled, what was tested, and what a future real build/qualification pass
must do before any candidate could ever become a production default. Nothing in this document
authorizes a build, flash, or powered-on test - see
[NEBULAOS_DISPLAY_LIVE_QUALIFICATION_PLAN.md](NEBULAOS_DISPLAY_LIVE_QUALIFICATION_PLAN.md) for
that.

## DISPLAY-B1: kernel backlight-class prototype

**Files**:
- `scripts/build/display-backlight-variant.sh` - the S0/S1 toggle script, same idempotent
  marker-block pattern as the project's existing `preempt-variant.sh`/`wifi-sdio-variant.sh`.
- `tests/display-backlight-variant-tests.sh` - 8 offline tests.

**What S1 does** (never applied by default - `git status` on the tracked DTS is clean unless
this script has been explicitly run with `S1`):
1. Repoints the existing `&pwm { pinctrl-0 = <&pwm1_pc>; }` override in
   `halley5_v30.dts:763-767` to `pwm0_pc` (GPC-0/PWM channel 0) - the pin stock's own live GPIO
   dump labels `backlight_pwm0`, and the pin this project's own 2026-07-23 stock-parity audit
   already confirmed is free (the only other claimant, an `&msc2` `ingenic,sdr-gpio` property
   on the same pin, is itself overridden to `status="disabled"` later in the same file).
2. Adds a new root-level DT node:
   ```
   nebulaos_backlight: nebulaos_backlight {
       compatible = "pwm-backlight";
       pwms = <&pwm 0 20000>;
       brightness-levels = <0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15>;
       default-brightness-level = <8>;
   };
   ```
   Period `20000` (nanoseconds) = 50kHz, matching stock's own `pwm_backlight.sh` script
   (`pwm_freq=50000`). The brightness-level table is a **starting point only** - the real
   dimming curve for this specific panel/backlight circuit is UNKNOWN_UNTIL_HARDWARE (see
   HT-01/HT-09 in the live qualification plan).

**What S1 deliberately does NOT do**: it does not wire a power-enable GPIO. Stock's own
`pwm_backlight.sh` drives a separate `PC22` enable line alongside PWM; this project's DT has no
established, verified function for that exact pin in this software stack, so DISPLAY-B1
intentionally scopes itself to the PWM brightness path only, leaving the enable-line question
open rather than guessing at it.

**Why no separate Kconfig change was needed**: `CONFIG_BACKLIGHT_CLASS_DEVICE`,
`CONFIG_BACKLIGHT_PWM`, and `CONFIG_PWM`/`CONFIG_PWM_INGENIC_V2` are already all `=y` in the
production `kernel.config` - this is a pure DT-wiring gap, not a missing-driver gap (see
`build-work/display-analysis/kernel-config-display.txt`).

### Offline tests (8, all passing)

`tests/display-backlight-variant-tests.sh` verifies, against the real tracked vendor DTS
(snapshotting and restoring its exact pre-test state on exit, same discipline as the project's
other variant-test suites):
1. S0 leaves the DTS git-clean.
2. S1 adds exactly one `nebulaos_backlight` node.
3. S1 repoints `&pwm` to `pwm0_pc` and leaves no stale `pwm1_pc` reference.
4. S1's backlight node references channel 0 at the 20000ns/50kHz period.
5. Re-applying S1 twice is idempotent (no duplicate nodes).
6. Switching S1 back to S0 restores a byte-identical, git-clean baseline.
7. An unknown variant name is rejected.

**A real bug was found and fixed while writing this test suite**: the toggle script's own
marker-strip `sed` command used the literal `/* --- ..._BEGIN --- */` string, unescaped, as a
regex address. Its embedded `*` characters are BRE metacharacters ("zero or more of the
preceding atom"), not literal stars, so the strip step silently matched nothing and every
re-application of S1 appended a second, duplicate backlight node (caught by test 5, the
idempotency check, which failed on the first run). Fixed by escaping every BRE-special
character (`.[\*^$/`) before using either marker string as a sed address; `grep -qF`
(fixed-string presence detection only) was unaffected either way. This is the exact same class
of footgun the project has hit before with shell quoting in docker heredocs
([[feedback_shell_quoting_in_docker_heredocs]]) - special characters embedded in a marker/
delimiter string need explicit escaping wherever they're reused as a pattern, not just as
literal text.

### Compile-test attempt and its honest outcome

A genuine `make dtbs`-based compile test was attempted against the real vendor kernel build
tree (`vendor/buildroot-x2000/output/build/linux-custom`, a fully-configured tree left over
from a prior real build, including a working `include/generated/autoconf.h`). This tree turned
out to be root-tainted (files left behind by a prior `docker --user root` build run) - the
`make` invocation failed rebuilding its own `fixdep` host tool with a permission error, and as a
side effect of that failed recipe, `make` deleted `include/generated/autoconf.h` in that
gitignored cache directory (confirmed via `git status` that no *tracked* file was affected -
this entire tree is covered by `.gitignore:4: /vendor/`). This file will be regenerated
automatically the next time the project's real `03-build-kernel-and-rootfs.sh` pipeline runs
(it invokes `make` inside Docker as intended, which handles this permission class correctly per
[[feedback_nebulaos_stale_build_artifacts]]-adjacent project convention) - no action is required
before that, but it is disclosed here in the interest of transparency about every real
side-effect this session caused, however minor and self-healing.

A second, lighter attempt used `cpp` directly with a stubbed, empty `generated/autoconf.h` in
an isolated scratch directory (touching no vendor or build-cache files at all). This got much
further - it correctly preprocessed the whole DTS include chain including the newly-added
`nebulaos_backlight` node - but `dtc` itself then failed on a **pre-existing, unrelated** line
in the base `x2000.dtsi` (`spi@10043000`'s `dmas = <&pdma INGENIC_DMA_TYPE(...)>` property,
`x2000.dtsi:422`), because the `INGENIC_DMA_TYPE` macro's expansion depends on real
`CONFIG_SOC_X2000`-conditional definitions the empty autoconf.h stub does not provide. This is
not a defect introduced by DISPLAY-B1 - it is a limitation of stubbing the kernel config for a
lightweight syntax check, and it affected a node hundreds of lines away, in code this session
never touched.

**Net result**: DISPLAY-B1's own added DT syntax was never independently run through a
completed `dtc` binary compile in this session. It is validated instead by exact structural
pattern-matching against the two already-compiled MIPI-reference `pwm-backlight` nodes
elsewhere in this exact file (`HALLEY5_MIPI_LCD_FW050.dtsi`/`HALLEY5_MIPI_LCD_ZC50289HSHD02.dtsi`
- identical `compatible`/`pwms`/`brightness-levels`/`default-brightness-level` shape, already
proven to parse correctly when their own gating Kconfig option is enabled) and by the 8 passing
tests above. **Classify the DT syntax as SUPPORTED_INFERENCE, not PROVEN_BY_COMPILE_TEST** -
honest about the gap rather than asserting a compile success that did not actually complete.

### Acceptance criteria for a future real build (before HT-09 in the live qualification plan)

1. Apply `sh scripts/build/display-backlight-variant.sh S1` to a clean tree.
2. Run the project's real `02-configure-buildroot.sh` + `03-build-kernel-and-rootfs.sh` pipeline
   (inside Docker, as the project always does) and confirm `make dtbs`/the full kernel build
   completes with zero new warnings/errors attributable to this change.
3. Confirm the built `.dtb` contains the `nebulaos_backlight` node and the repointed `&pwm`
   pinctrl group (`fdtdump`/`dtc -I dtb -O dts` the output and grep for both).
4. Package to a **spare slot only** (`package-variant-artifacts.sh`, never the active
   production slot) per the live qualification plan's HT-09.
5. Revert to S0 (`sh scripts/build/display-backlight-variant.sh S0`) before any production
   build - this prototype must never be the shipped default until HT-01/HT-09 confirm it
   actually functions on real hardware.

## DISPLAY-V1: vsync-gated pan_display prototype

Prepared in the follow-on powered-on investigation mission (2026-08-01), after live evidence
(`NEBULAOS_DISPLAY_LIVE_READ_ONLY_REPORT.md`) re-confirmed the DPU vsync IRQ fires at the
expected ~60Hz rate and re-confirmed the underlying tearing race is real and still present.

**Files**:
- `scripts/build/patches/display-vsync-gate.patch` - a real unified diff against the pinned
  vendor kernel commit, touching `fb_stage/Kconfig`, `fb_stage/ingenicfb.c`,
  `include/ingenicfb.h`.
- `scripts/build/display-vsync-variant.sh` - the V0/V1 toggle script. Unlike the DTS-only
  DISPLAY-B1 toggle, this applies/reverts a real C-source patch via `git apply`/
  `git checkout --` inside the vendor kernel checkout, and separately selects
  `CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y` in the tracked Kconfig fragment (same marker-block
  pattern as `preempt-variant.sh` - this fragment's marker text has no BRE-special characters,
  so the escaping bug found in DISPLAY-B1's original script does not apply here).
- `tests/display-vsync-variant-tests.sh` - 6 offline tests.

**What V1 does**:
1. A new Kconfig option `FB_INGENIC_PAN_VSYNC_GATE` (default `n`), guarding everything below at
   compile time - with it unset, the compiled driver is byte-for-byte identical to today's
   baseline.
2. Four new fields on `struct ingenicfb_device` (`pan_vsync_seq`, `pan_vsync_gated_count`,
   `pan_vsync_timeout_count`, `pan_vsync_invalid_count`), a monotonic atomic counter bumped in
   `ingenicfb_set_vsync_value()` on every real vsync IRQ event.
3. `ingenicfb_pan_display()` gains two changes:
   - **An always-on, independent correctness fix** (not gated behind the Kconfig option -
     applies to the baseline too): `next_frm` (derived from userspace-supplied
     `var->yoffset`/`var->yres` and used to index `fbdev->vidmem[]`/`dctrl->sreadesc_phys[]`)
     was never bounds-checked before use. Now validated against `CONFIG_FB_INGENIC_NR_FRAMES`
     and against `yres == 0` before any array access.
   - **The vsync gate itself** (Kconfig-guarded): before calling `dpu_ctrl_rdma_change()`,
     capture the current vsync sequence number, drop `info->lock` (`unlock_fb_info()`, the exact
     same pattern this driver's own `FBIO_WAITFORVSYNC` ioctl handler already uses for the
     identical `wait_event_interruptible_timeout()` primitive - not a new synchronization
     pattern in this driver), wait up to 34ms (~2 frame periods at this panel's ~59.98Hz) for
     the counter to advance, re-acquire the lock, then apply the frame switch regardless of
     whether the wait succeeded or timed out. Skips the wait entirely if `dctrl->blank` is set
     (no vsync IRQs will arrive while the DPU is suspended, so waiting would just burn the full
     timeout for nothing).

**Real correction to a prior offline finding, found while designing this**: re-reading
`ingenicfb_set_vsync_value()` directly (rather than trusting the earlier offline agent's
characterization) shows `wake_up_interruptible(&fbdev->vsync_wq)` is called unconditionally in
*both* branches of its skip-map decision - the skip-map only throttles which vsync events get a
precise timestamp recorded for userspace's `FBIO_WAITFORVSYNC`, not which ones wake waiters. The
original offline pass's "roughly 1-in-10 vsync events delivered to the waitqueue" characterization
was **incorrect** - every real vsync wakes waiters. This actually makes DISPLAY-V1's design
simpler and safer than initially planned: reusing the same waitqueue carries no added latency
risk from the skip-map.

### Offline tests (6, all passing)

Mirrors DISPLAY-B1's test discipline against the vendor kernel checkout and the Kconfig
fragment: V0 clean baseline, V1 adds the Kconfig option to source and selects it in the fragment
exactly once, V1's patch includes the new struct field and the bounds check, idempotent
re-application, clean reversion to V0, rejection of an unknown variant name.

### A real process mistake made (and fixed) while preparing this and TOUCH-I1

While writing DISPLAY-V1's and TOUCH-I1's source patches, the vendor kernel checkout was edited
directly **while a full alpha-baseline build was running in the background against that same
checkout**. `05-final-build.sh`'s own source-tree fingerprint check (`git status --porcelain`
before vs. after the build) correctly detected the tree had changed mid-build and refused to
trust the resulting artifacts, twice, on two separate build attempts. Both times the tracked
`artifacts/buildroot-halley5-v30-image/{kernel.config,halley5_v30.dts,halley5-nebulaos-fragment.config}`
had already been copied from the (untrustworthy) build output before the abort check ran - both
times reverted via `git checkout` immediately upon discovery. This was a real, disclosed
mistake, not a hidden one: **never edit anything under `vendor/x2000_kernel_6.6` while any
build against that checkout is in flight**, even briefly - a revert immediately afterward does
not retroactively fix a fingerprint comparison already computed mid-build. Both prototype
patches were preserved by capturing them as tracked `.patch` files before each revert, and the
build was re-run a third time, untouched, to completion.

## TOUCH-I1: IRQ-assisted touch-down prototype

Prepared in the same follow-on mission, after live evidence confirmed touch has no dedicated
GPIO IRQ registered anywhere in the system today (`/proc/interrupts` has zero touch/GPIO79
lines), matching the offline finding exactly.

**Files**:
- `scripts/build/patches/touch-irq-gate.patch` - real unified diff against
  `drivers/input/touchscreen/{Kconfig,ns2009.c}`.
- `scripts/build/touch-irq-variant.sh` - the I0/I1 toggle script, same pattern as
  `display-vsync-variant.sh`.
- `tests/touch-irq-variant-tests.sh` - 6 offline tests.

**Design principle: the existing 30ms poll is never modified, disabled, or made conditional.**
The IRQ path is purely an additive latency accelerant layered on top of it - if the IRQ can
never be requested, storms, or simply never fires, input availability is completely unaffected;
the poll alone continues to work exactly as it does today. This was a deliberate simplification
over a more complex "switch modes between polling and IRQ" design: since correctness never
depends on the IRQ path succeeding, there is no state machine to get wrong.

**What I1 does**:
1. A new Kconfig option `TOUCHSCREEN_NS2009_PENDOWN_IRQ` (default `n`).
2. In `ns2009_ts_probe()`, after the existing polled input device is already registered: a
   best-effort `ns2009_setup_pendown_irq()` call. If `pendown-gpios` is absent, or
   `gpiod_to_irq()` fails, or `devm_request_threaded_irq()` fails, it logs an informational
   message and returns - probe() itself never fails because of this.
3. **The exact trigger polarity was never established from source/disassembly alone** (this
   driver's own prior history already warns against guessing GPIO active-high/low) - so this
   deliberately requests **both edges** (`IRQF_TRIGGER_RISING | IRQF_TRIGGER_FALLING`,
   `IRQF_ONESHOT`, NULL hard-IRQ handler, all logic in the threaded bottom half). Any transition
   on the pin, in either direction, just triggers an immediate call to the same
   `ns2009_ts_report()` the ordinary poll already calls - the actual down/up state still comes
   from a fresh `gpiod_get_value_cansleep()` read inside that function, never from which edge
   fired. Getting the "wrong" edge direction only costs one harmless extra report call; it can
   never produce a wrong touch state.
4. **Storm protection**: a rolling 1-second window tracks edge count; if more than 50 edges land
   within one window (electrical noise/bounce, not real touch activity), the IRQ is permanently
   disabled (`disable_irq_nosync()`) for the remaining lifetime of the device instance, falling
   back to poll-only. This is a deliberate one-way trip, not a retry loop - simple and safe.
5. Diagnostics exposed via `debugfs_create_dir("ns2009_ts", NULL)`: `irq_count`,
   `irq_storm_triggered`, `irq_active`.

**Why edge-triggering (not level-triggering) makes "remains asserted" safe by construction**: a
GPIO stuck at one level generates at most one edge (the transition into the stuck state), never
a storm, since edge-triggered IRQs only fire on transitions. The mission's own "remains
asserted" fallback requirement is therefore inherently satisfied by this design choice, not by
extra logic.

### Offline tests (6, all passing)

Same structure as DISPLAY-V1's suite: I0 clean baseline, I1 adds the Kconfig option and selects
it in the fragment exactly once, I1's patch includes the threaded handler/both-edges
flags/storm-protection constant and leaves the existing `input_setup_polling()` registration
call structurally untouched, idempotent re-application, clean reversion, rejection of an unknown
variant name.

### Compile-test status for DISPLAY-V1 and TOUCH-I1

Both patches were verified to apply cleanly (`git apply --check`) against the pinned kernel
commit. Neither has yet been run through a completed `make dtbs`/full kernel build in isolation
this session - the background alpha-baseline build (needed first, to restore a stable, known-
good tree per the process-mistake note above) was still in progress when this document was
last updated. **Classification: SUPPORTED_INFERENCE for compilability** (both patches are small,
guarded by `#ifdef`, use only standard, already-`#include`d kernel APIs (`wait_event_
interruptible_timeout`, `devm_request_threaded_irq`, `debugfs_create_*`, all already used
elsewhere in this exact kernel tree) - not yet PROVEN_BY_COMPILE_TEST. See the final mission
report for whether a completed build validated this before the mission concluded.

## Deferred prototypes - not built this session

Per `build-work/display-analysis/candidate-ranking.tsv`, and unchanged by the live findings
above:
- **Backlight-only blanking** and **deep display powerdown**: both have a hard prerequisite on
  DISPLAY-B1 actually landing and being electrically confirmed first (there is nothing to
  "blank-only" or "power down" independently until a real backlight exists).
- **DPU IRQ diagnostics**: a real, low-risk, low-effort candidate, but still deprioritized this
  session in favor of the three named candidates. A reasonable next-session pickup.

All other candidates in the ranking file (WIP-driver migration, DRM/KMS migration, refresh-rate
correction/overclock, RGB565 in-memory framebuffer, pressure-aware touch filtering,
touch-as-wake-source) remain REJECT or DEFER_UNTIL_HARDWARE with no prototype planned - see the
ranking file for the full rationale on each.
