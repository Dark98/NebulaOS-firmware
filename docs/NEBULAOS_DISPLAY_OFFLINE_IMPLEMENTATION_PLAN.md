# NebulaOS Display Offline Implementation Plan

Companion to [NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md](NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md).
Covers Phases D18 (compile-only prototypes) and D19 (offline tests/assertions) in detail: what
was built, how it's toggled, what was tested, and what a future real build/qualification pass
must do before any candidate could ever become a production default. Nothing in this document
authorizes a build, flash, or powered-on test - see
[NEBULAOS_DISPLAY_LIVE_QUALIFICATION_PLAN.md](NEBULAOS_DISPLAY_LIVE_QUALIFICATION_PLAN.md) for
that.

## DISPLAY-P1: kernel backlight-class prototype

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
established, verified function for that exact pin in this software stack, so DISPLAY-P1
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
not a defect introduced by DISPLAY-P1 - it is a limitation of stubbing the kernel config for a
lightweight syntax check, and it affected a node hundreds of lines away, in code this session
never touched.

**Net result**: DISPLAY-P1's own added DT syntax was never independently run through a
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

## Deferred prototypes (P2-P5) - why they were not built this session

Per `build-work/display-analysis/candidate-ranking.tsv`:
- **Auto vsync-gate before `FBIOPAN_DISPLAY`** and **IRQ-driven touch pen-down**: both are
  real, well-evidenced gaps, but committing engineering time to fix them before a live
  measurement confirms the gap is actually user-visible (tearing / perceptible touch latency)
  risks solving a theoretical problem at the cost of touching a currently-working code path.
  See `hardware-test-matrix.tsv` HT-04/HT-05.
- **Backlight-only blanking** and **deep display powerdown**: both have a hard prerequisite on
  DISPLAY-P1 actually landing and being electrically confirmed first (there is nothing to
  "blank-only" or "power down" independently until a real backlight exists).
- **DPU IRQ diagnostics**: a real, low-risk, low-effort candidate, but writing and testing a
  new sysfs/debugfs exposure was deprioritized this session in favor of DISPLAY-P1, the
  clearest and highest-priority gap. A reasonable next-session pickup if this analysis is
  resumed.

All other candidates in the ranking file (WIP-driver migration, DRM/KMS migration, refresh-rate
correction/overclock, RGB565 in-memory framebuffer, pressure-aware touch filtering,
touch-as-wake-source) are REJECT or DEFER_UNTIL_HARDWARE with no prototype planned at this
time - see the ranking file for the full rationale on each.
