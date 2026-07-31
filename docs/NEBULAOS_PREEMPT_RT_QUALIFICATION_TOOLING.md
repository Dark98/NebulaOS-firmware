# PREEMPT_RT Qualification: Variants and Diagnostic Tooling

Pre-qualification mission Phase A8 (2026-07-31). See
`docs/NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md` sec 12/13/18.15/18.20 for
the full source-grounded PREEMPT_RT analysis this builds on.

## Variants

Applied via `scripts/build/preempt-variant.sh <R0|R1>` to the tracked
Kconfig fragment (`artifacts/buildroot-halley5-v30-image/
halley5-nebulaos-fragment.config`):

| Variant | `CONFIG_PREEMPT` | `CONFIG_PREEMPT_RT` | `CONFIG_HZ` |
|---|---|---|---|
| R0 (baseline) | `y` (base defconfig default, no fragment override needed) | not set | `100` (unchanged) |
| R1 | cleared automatically by the Kconfig `choice` block | `y` | `100` (unchanged) |

Neither variant touches SDIO, camera, power-save, compression, or any
other userspace configuration - exactly one variable changes between R0
and R1, per the mission's own governing principle. HZ is never touched by
either variant.

## Kernel configuration validation checklist (for Phase A11's real build)

Not yet performed - requires the real docker/Buildroot toolchain, deferred
to Phase A11 per this mission's own phase separation (this phase prepares
variant *infrastructure*; A11 does the actual builds). When A11 builds R1,
confirm:

- [ ] `CONFIG_PREEMPT_RT=y` in the resulting `.config`
- [ ] `CONFIG_ARCH_SUPPORTS_RT=y` (already confirmed present in the base
      defconfig by source reading - `NEBULAOS_CAMERA_USB_RT_SOURCE_
      ANALYSIS.md` sec 12)
- [ ] `CONFIG_EXPERT=y`, `CONFIG_HAVE_POSIX_CPU_TIMERS_TASK_WORK=y` (same,
      already confirmed present)
- [ ] Kernel builds cleanly end to end (`03-build-kernel-and-rootfs.sh`)
- [ ] `brcmfmac` rebuilt in-tree as part of the same kernel build (it is
      real, unmodified in-tree source - confirmed no separate vermagic
      concern exists, sec 18.15)
- [ ] No external/out-of-tree kernel module in this image at all (already
      established elsewhere: this build currently ships zero loadable
      modules - `lsmod` empty - so there is no vermagic mismatch class of
      risk to check for any module)
- [ ] DWC2, UVC, MMC/SDIO, UART, display, and touch drivers all still
      present/functional in the resulting `.config` (a straightforward
      diff against R0's own `.config` should show the preemption-model
      choice as the only default-derived difference, plus whatever new
      RT-only symbols the choice pulls in - no unrelated driver should
      disappear)

## Diagnostic tooling plan

Per the mission's own instruction, diagnostic tools are **not** part of
the normal production image - they belong in a separate qualification
artifact, or get removed from the production rootfs after Phase B8's
testing is done. None of the packages below are added to
`artifacts/buildroot-halley5-v30-image/buildroot.config` (the real
production package list) by this phase - they are documented here as what
Phase A11's separate diagnostic-image build would need to add.

| Tool | Source | Purpose | Production package? |
|---|---|---|---|
| `cyclictest` | `BR2_PACKAGE_RT_TESTS` (rt-tests) | Worst-case scheduling latency measurement - the actual target metric for the whole R0 vs R1 comparison | No - diagnostic-image only |
| `chrt` | Already provided by `util-linux` (`BR2_PACKAGE_UTIL_LINUX_CHRT`, if not already enabled - confirm at A11 build time) | Set/query a test process's scheduling policy/priority for controlled latency tests | No - diagnostic-image only, unless already present for another reason |
| `taskset` | Already provided by `util-linux` (`BR2_PACKAGE_UTIL_LINUX_SCHED`, if not already enabled - confirm at A11 build time) | Pin a test process to a specific CPU core for repeatable measurements | No - diagnostic-image only |
| `pidstat` | `BR2_PACKAGE_SYSSTAT` | Per-process CPU/context-switch statistics during a controlled test | No - diagnostic-image only |
| Interrupt-rate sampler | Custom - properly belongs to Phase A9's benchmark tooling extension (`scripts/qa/production-benchmark.sh` already samples USB OTG interrupt rate; extending it to a general per-IRQ-line sampler, including DWC2's threaded-IRQ specifically under R1, is Phase A9's own scope, not duplicated here) | Confirm DWC2's IRQ thread behavior/rate under R1 | N/A - shell/awk against `/proc/interrupts`, no new package |
| Context-switch sampler | Same as above - Phase A9 | Confirm the context-switch-rate cost DWC2 IRQ threading is expected to add under R1 | N/A - Phase A9 |
| Klipper MCU statistics collector | Same as above - Phase A9 | UART/MCU comms health under both variants | N/A - Phase A9 |
| Wi-Fi latency collector | Same as above - Phase A9 | Confirm Wi-Fi (already rated Low RT risk) is genuinely unaffected | N/A - Phase A9 |
| Camera frame-continuity collector | Same as above - Phase A9 | Confirm DWC2 IRQ threading doesn't cause camera frame drops under R1 | N/A - Phase A9 |

Only `cyclictest`, `chrt`, `taskset`, and `pidstat` require an actual new
Buildroot package selection (`rt-tests`, confirming `util-linux`/`sysstat`
sub-option coverage) - everything else is achievable with shell/awk
against existing `/proc` interfaces already used elsewhere in this
project's own benchmark tooling, and is scoped to Phase A9 instead of
duplicated here.

## Image matrix restraint

Per the mission's own explicit instruction, this phase does not build the
full Cartesian product of every variant combination. Only R0 and R1's own
Kconfig-fragment-level toggle is prepared and tested here
(`tests/preempt-variant-tests.sh`, 6 tests, confirming clean R0 baseline,
correct single-line R1 addition, HZ never touched, idempotent
re-application, and clean reset back to R0). Proving both actually
*build* (not just resolve at the Kconfig-fragment level) is Phase A11's
own scope - the final RT A/B will use only the frozen, selected Wi-Fi and
camera configuration, not every experimental combination prepared in
Phases A3-A7.
