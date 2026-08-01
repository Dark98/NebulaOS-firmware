# NebulaOS Backlight Probe Diagnostic (DISPLAY-B0-DIAG) - Safety-Hardening Pass

Status: compile-tested prototype, NOT deployed, NOT flashed. This document
covers the safety-design hardening pass performed on top of the original
DISPLAY-B0-DIAG prototype (kernel: add bounded backlight probe diagnostic
variant / test: verify isolated display diagnostic variants). It does not
change, and does not attempt to change, the underlying hardware unknown:
whether PWM channel 0 (pwm0_pc / GPC-0) and enable-GPIO PC22 actually
control a real backlight circuit on this board remains UNKNOWN_UNTIL_HARDWARE
(see `build-work/display-analysis/backlight-path-analysis.txt`). This
mission is scoped entirely to hardening the SAFETY DESIGN of the diagnostic
itself, offline, by source inspection and compile test.

Relevant files:
- `scripts/build/patches/display-backlight-probe-diag.patch` - the kernel
  patch (new driver `nebulaos_backlight_probe_diag.c`, Kconfig/Makefile
  wiring).
- `scripts/build/display-backlight-diag-variant.sh <DIAG0|DIAG1>` - toggles
  the variant on/off against the vendor kernel checkout.
- `tests/display-backlight-diag-variant-tests.sh` - 32 offline tests (22
  pre-existing + 10 added by this hardening pass).

## What changed in this hardening pass

Two REAL BUGS were found by source inspection and fixed - not just
documented:

1. **Apply-before-arm ordering bug (fixed).** The prior revision of
   `nebulaos_bl_diag_cmd_probe()` applied the candidate hardware state
   (`pwm_apply_state()` / `gpiod_set_raw_value_cansleep()`) and only
   afterward armed the watchdog (`schedule_delayed_work()`). This left a
   real window: a crash/oops/kill between "apply" and "arm" would leave
   hardware in the probed state with no watchdog covering it - exactly the
   failure mode the mission's safety-design requirement warns against. Fixed
   by reordering to capture-prior-state -> arm-watchdog -> apply-hardware,
   so any crash between "arm" and "apply" only ever races against a
   watchdog that fires and restores the (harmless, nothing-was-applied-yet)
   saved state.

   A residual race was then found and fixed in the failure-unwind path for
   this same reordering: when `pwm_apply_state()` itself fails (having
   already armed the watchdog), the original fix unlocked `diag->lock`
   before calling `cancel_delayed_work_sync()`, which is a genuine
   TOCTOU race - a second thread could schedule a brand-new probe on the
   same `delayed_work` object between the unlock and the cancel, and the
   cancel would then wipe out THEIR timer instead of the failed one. Fixed
   by using the non-blocking `cancel_delayed_work()` (not `_sync()`) while
   still holding `diag->lock` - safe here specifically because this branch
   never itself calls the restore function (nothing was ever applied), so
   correctness never depended on blocking until an in-flight watchdog
   finished. See the driver's own comment at that call site for the full
   reasoning about why the non-blocking variant is correct there and the
   blocking variant is correct everywhere else in the file (explicit
   "restore" command, `remove()`).

2. **Wrong timeout bounds (fixed).** The prior revision enforced
   default=3000ms / max=10000ms. The mission's exact requirement is
   default=2000ms, hard maximum=3000ms (reject anything longer). Fixed the
   `#define`s and added an explicit test proving a >3000ms request is
   rejected before anything is armed or touched (Test 11).

3. **Overclaimed "exact restoration" (found and corrected - documentation +
   status field, not a code-behavior change).** See "Restoration exactness"
   below - this was a real, previously undocumented gap between what the
   driver's own comments claimed and what the underlying hardware/kernel
   stack can actually support.

Everything else in the original driver (kernel-owned `delayed_work`
watchdog independent of any userspace process; exactly-one-active-probe
enforcement; 0%/100% duty rejection; synchronous restore on `remove()`;
no channel/GPIO number ever exposed through the debugfs interface) was
already correctly designed and is unchanged in behavior, only strengthened
with additional tests proving it.

## Restoration exactness - the honest finding (mission item 5)

This was investigated by reading the actual bound drivers on this board,
not assumed:

- **GPIO side: EXACT.** This board's `pinctrl-ingenic.c` gpio_chip
  implements `.get = ingenic_gpio_get()`, which reads the live `PxPIN`
  hardware register on every single call
  (`ingenic_gpio_readl(chip, PxPIN) & BIT(pin)`, confirmed by direct source
  read). Both the initial capture at driver-bind time and the per-probe
  capture immediately before arming/applying are genuine hardware
  readbacks. Restoring to that captured value is a real, exact
  reconstruction of the pin's actual prior electrical level.

- **PWM side: NOT EXACT - a documented limitation, not a claimed fact.**
  This board's bound PWM driver, `module_drivers/drivers/pwm/pwm-ingenic-v2.c`,
  defines `struct pwm_ops` with only `.apply` populated - **no
  `.get_state` callback**. The generic PWM core
  (`drivers/pwm/core.c:pwm_device_request()`) only populates a consumer's
  cached `pwm_device.state` from real hardware `if (pwm->chip->ops->get_state)`;
  when that callback is NULL, as it is here, the state simply stays at
  whatever it was already zero-initialized to. Because this diagnostic is
  the first-ever consumer of PWM channel 0 in this software stack (no
  other DT node references it - see `backlight-path-analysis.txt`),
  `pwm_get_state()` in this driver does **not** return "whatever the
  bootloader/earlier boot stage established" - it returns a synthetic
  all-zero (`period=0, duty_cycle=0, enabled=false`) state. "Restoring" to
  that captured state means driving the candidate PWM to disabled/
  zero-period - a reasonable, deliberately-chosen **safe default**, but
  categorically not a reconstruction of whatever electrical waveform (if
  any) the bootloader/SPL actually left running on that pin, which this
  kernel has no way to read.

  The prior revision's own comments claimed pwm_get_state() "reads the
  descriptor's cached/hardware state" - phrasing that reads as an exact
  hardware readback claim and is not accurate for this board's driver
  stack. This has been corrected throughout the driver's file header, its
  probe()/restore comments, the Kconfig help text, and
  `scripts/build/display-backlight-diag-variant.sh`'s own comment block.

  This is now also surfaced at **runtime**, not just in source comments:
  the debugfs `.../status` file (and the `status` command's `dev_info()`
  log line) always report `pwm_restore_is_exact: 0` and
  `gpio_restore_is_exact: 1` (or `-1` if no candidate GPIO is present on
  the DT node), so a human operator never has to take the claim on faith
  from a comment alone.

## Bounds enforced (mission item 3)

- Default probe timeout: 2000ms (`NEBULAOS_BL_DIAG_DEFAULT_TIMEOUT_MS`).
- Maximum allowed timeout: 3000ms (`NEBULAOS_BL_DIAG_MAX_TIMEOUT_MS`) -
  anything longer is rejected with `-EINVAL` before any hardware is
  touched or any state is armed (Test 10, Test 11).
- Minimum allowed timeout: 250ms (`NEBULAOS_BL_DIAG_MIN_TIMEOUT_MS`,
  unchanged) - a sane floor so a pathologically tiny timeout can't be used
  to race the arm/apply/cancel logic in practice.
- Duty cycle: only 25/50/75% accepted; 0% and 100% explicitly rejected
  (unchanged from the original revision, re-verified here).

## No arbitrary channel/GPIO (mission item 4)

Verified by source inspection (Test 14): `devm_pwm_get(dev, NULL)` and
`devm_gpiod_get_optional(dev, "enable", GPIOD_ASIS)` are each called
**exactly once** in the entire file, both inside `nebulaos_bl_diag_probe()`
(module bind time only). The debugfs command parser
(`nebulaos_bl_diag_command_write()` / `nebulaos_bl_diag_cmd_probe()`) never
acquires a PWM/GPIO handle itself and never parses a channel or GPIO
number from user input - the only numeric argument it ever parses is the
timeout. There is no code path, even in principle, through which an
arbitrary channel or GPIO could be requested through this interface.

## Kernel-owned restoration, independent of any process (mission item 1)

Re-verified, not just re-asserted: the watchdog is a `delayed_work`
(`INIT_DELAYED_WORK`/`schedule_delayed_work`) running on the kernel's
system workqueue. It is scheduled against the kernel's own timer wheel and
holds no reference to any file descriptor, process, or task struct
belonging to whatever process issued the probe command. A dropped SSH
session, a killed shell, or a signal delivered to the calling process
cannot prevent it from firing - there is no code path in this driver that
ties the watchdog's lifetime to any userspace process's lifetime. This is
now additionally protected by the arm-before-apply ordering fix above, so
even a kernel-side crash/oops in the narrow window between arming and
applying cannot produce an "applied but uncovered" state.

## Test results

`sh tests/display-backlight-diag-variant-tests.sh`: **32 passed, 0
failed** (22 pre-existing tests unchanged and still passing + 10 new tests
added by this hardening pass: exact 2000/3000ms bounds, timeout>3s
rejection, arm-before-apply ordering, non-blocking-cancel-under-lock in
the failure-unwind path with no TOCTOU-reintroducing `_sync()` call,
exactly-once PWM/GPIO acquisition at bind time only, no channel/GPIO
number ever exposed, honest `pwm_restore_is_exact`/`gpio_restore_is_exact`
status fields, and removal of the prior overclaiming "cached/hardware
state" phrasing).

## Classification of claims

- **PROVEN_BY_COMPILE_TEST:** the patched driver compiles cleanly (`.o`
  target) against the real vendor kernel tree via the project's Docker
  cross-compile methodology, with `CONFIG_NEBULAOS_BACKLIGHT_PROBE_DIAG=y`.
  The DT node compiles into the `.dtb` and decompiles back to the expected
  `pwms = <&pwm 0 20000>; enable-gpios = <&gpc 22 ...>;` content. All 32
  offline tests pass.
- **PROVEN_BY_SOURCE_INSPECTION:** the arm-before-apply ordering; the
  exactly-once PWM/GPIO acquisition; the absence of any channel/GPIO
  number in the command interface; the GPIO-restore-is-exact /
  PWM-restore-is-not-exact asymmetry (traced through
  `pinctrl-ingenic.c`'s `.get` callback and `pwm-ingenic-v2.c`'s missing
  `.get_state`, and the generic `drivers/pwm/core.c:pwm_device_request()`
  logic that gates hardware readback on that callback's presence); the
  kernel-workqueue-based, process-independent watchdog.
- **SUPPORTED_INFERENCE:** that `cancel_delayed_work()` (non-blocking)
  is safe under `diag->lock` specifically in the failure-unwind branch,
  because that branch never calls the restore function itself - this
  follows from the code structure but was not exercised on live hardware
  under real scheduling pressure.
- **UNKNOWN_UNTIL_HARDWARE (unchanged from the original prototype, out of
  this hardening pass's scope):** whether PWM channel 0/enable-GPIO PC22
  actually drive a real backlight circuit at all; whether the watchdog
  timer genuinely fires under real hardware/scheduling conditions; whether
  a real PWM/GPIO write takes the expected electrical effect; whether a
  killed shell/process genuinely cannot block the restore in practice
  (only proven true by source inspection of the kernel API contract, not
  by a live test).

## Addendum: command-interface hardening + real PWM-exactness gate (2026-08-xx)

This addendum covers a second hardening pass performed after the PWM state
readback mission landed (see `docs/NEBULAOS_PWM_STATE_READBACK_REPORT.md`
and `scripts/build/patches/pwm-ingenic-v2-get-state.patch`), which added a
real `.get_state` implementation to `pwm-ingenic-v2.c` behind
`CONFIG_PWM_INGENIC_V2_GET_STATE` plus an exported capability query,
`ingenic_pwm_channel_get_state_is_exact(chip, channel)`, but deliberately
left two things as documented follow-ups rather than in-scope for that
change: wiring this diagnostic's `pwm_restore_is_exact` status field up to
the real answer, and constraining the debugfs command interface to the
mission's exact whitelist. Both are done now.

### Constrained command whitelist

The debugfs `.../command` interface previously accepted a free-form
`probe <kind> <value> [timeout_ms]` grammar (`kind` = `enable`/`pwm`,
`value` = `low`/`high`/`25`/`50`/`75`, plus an optional caller-supplied
timeout). It now accepts EXACTLY these 9 literal strings and nothing
else, each taking zero arguments:

```
status
arm
disarm
probe-enable-low
probe-enable-high
probe-pwm-25
probe-pwm-50
probe-pwm-75
restore
```

Any trailing token after the command word - a GPIO/channel number, a
duty cycle, a period, an MMIO address, a timeout, anything at all - is
rejected outright with `-EINVAL` by a single check in
`nebulaos_bl_diag_command_write()` (`if (rest && *rest) return -EINVAL;`)
that runs *before* the command-dispatch chain, so it structurally cannot
reach any command handler. This single check is what makes an arbitrary
GPIO number, PWM channel, duty cycle, period, or timeout impossible to
construct through this interface at all, not merely bounds-checked at
the handler. The old free-form `kind`/`value`/`timeout_arg` parsing
(`!strcmp(kind, ...)`, `!strcmp(value, ...)`, `kstrtouint()`) no longer
exists anywhere in the file.

- `probe-enable-low` / `probe-enable-high` drive the same candidate
  enable-GPIO the driver already bound at `probe()` time
  (`diag->enable_gpio`, acquired once via `devm_gpiod_get_optional(dev,
  "enable", ...)`) to logical low/high, with the existing
  snapshot-and-restore behavior unchanged.
- `probe-pwm-25` / `probe-pwm-50` / `probe-pwm-75` drive the same
  candidate PWM channel (`diag->pwm`) to exactly 25%/50%/75% duty -
  never 0% or 100%, which cannot even be represented as a command
  literal now (there is no `probe-pwm-0` or `probe-pwm-100`).
- `arm` / `disarm` gate the whole diagnostic at a level above individual
  probes: `diag->diag_armed` defaults to `false` at every boot/bind (see
  `nebulaos_bl_diag_probe()`), and every `probe-*` command is rejected
  with `-EPERM` while disarmed - re-verified in this pass, this remains
  true after every change. `disarm` is fail-safe: it forces an
  immediate, synchronous restore of any still-active probe (same
  cancel-before-lock ordering as the existing `restore`/`remove()`
  paths) before clearing the armed flag, so "disarm" genuinely
  de-activates the diagnostic rather than merely blocking new probes.
  `restore` itself is never gated behind `arm`/`disarm` - it is always
  the safety escape hatch.

### Fixed 2-second probe duration (interpretation decision)

The mission spec's "default 2s, max 3s, no arbitrary timeout" was
interpreted as: remove the free-form timeout argument entirely rather
than keep accepting one and merely bounds-checking it. Reasoning: a
bounds-checked-but-still-caller-supplied argument is a strictly weaker
guarantee than an argument that cannot be constructed in the first
place, and the whitelist's `probe-*` commands (unlike the old `probe
<kind> <value>` two/three-token form) have no natural place left to put
a timeout argument without reintroducing exactly the free-form grammar
the whitelist is meant to close off. Every probe now always uses
`NEBULAOS_BL_DIAG_DEFAULT_TIMEOUT_MS` (2000ms). The
`[NEBULAOS_BL_DIAG_MIN_TIMEOUT_MS, NEBULAOS_BL_DIAG_MAX_TIMEOUT_MS]`
constants (`[250ms, 3000ms]`, unchanged) remain as a compile-time
invariant a `static_assert()` in `nebulaos_bl_diag_cmd_probe()` checks
`DEFAULT` against, so a future edit can never silently push the fixed
duration outside the mission's envelope - enforced by the compiler
instead of a runtime branch no caller can ever reach.

### Real PWM-exactness gate (closes the two TODOs)

`nebulaos_bl_diag_pwm_restore_is_exact()` is the new single source of
truth for whether the candidate PWM channel's restoration is currently
exact:

```c
#ifdef CONFIG_PWM_INGENIC_V2_GET_STATE
	/* ... chip/driver-name identity check ... */
	return ingenic_pwm_channel_get_state_is_exact(chip, diag->pwm->hwpwm);
#else
	return false;   /* conservative: refuse to arm, never assume exact */
#endif
```

Both the debugfs `.../status` file's `pwm_restore_is_exact` field and
`nebulaos_bl_diag_cmd_probe()`'s arm/probe-refusal gate call this same
function - neither has its own separate hardcoded answer anymore. The
gate runs before `nebulaos_bl_diag_cmd_probe()` captures or touches any
hardware (same "reject before touching anything" position as the
existing `-EBUSY`/`-ENODEV` checks) and applies uniformly to both probe
types via `nebulaos_bl_diag_probe_type_restore_is_exact()` - GPIO probes
route to `nebulaos_bl_diag_gpio_restore_is_exact()` (`diag->enable_gpio
!= NULL`, unconditionally true when present, per the existing GPIO
readback proof), PWM probes route to the function above. A probe whose
resource is not currently exact is rejected with `-EOPNOTSUPP`, before
anything is armed or applied.

Two defensive details worth calling out:

- **Chip identity check.** A generic PWM consumer has no framework-level
  way to prove a `struct pwm_chip *` really is a `pwm-ingenic-v2.c`
  chip (the `to_ingenic_chip()` `container_of()` cast inside that driver
  is only safe for a chip that genuinely is one). Rather than trust the
  bound chip blindly, `nebulaos_bl_diag_pwm_restore_is_exact()` checks
  `chip->dev->driver->name` equals `"ingenic-pwm"` (the platform driver
  name `pwm-ingenic-v2.c` registers itself under) before calling the
  exported query at all, and returns `false` if that doesn't hold.
- **Kconfig/Makefile coupling stays soft, deliberately.** No `select` or
  `depends on CONFIG_PWM_INGENIC_V2_GET_STATE` was added to
  `NEBULAOS_BACKLIGHT_PROBE_DIAG` - the two options remain fully
  independent Kconfig symbols in different subsystems, each still owned
  exclusively by its own variant script
  (`display-backlight-diag-variant.sh` / `pwm-state-readback-variant.sh`
  - see those scripts' own header comments for why that ownership
  boundary exists). The consumer-side reference to
  `ingenic_pwm_channel_get_state_is_exact()` is wrapped in the matching
  `#ifdef CONFIG_PWM_INGENIC_V2_GET_STATE`, so the symbol reference is
  compiled out entirely (not just dead-code-eliminated) whenever that
  option is unselected - the mandatory safe fallback for "PWM readback
  not compiled in" is "treat as not exact, refuse every PWM probe",
  never "assume exact". No shared header was added under
  `module_drivers/include/` for a single one-line declaration; instead a
  direct `extern bool ingenic_pwm_channel_get_state_is_exact(struct
  pwm_chip *chip, unsigned int channel);` mirrors the exact
  forward-declaration convention `pwm-ingenic-v2.c` itself already
  established immediately above its own
  `EXPORT_SYMBOL_GPL(ingenic_pwm_channel_get_state_is_exact)` line.

### Boot-time behavior, re-confirmed

`nebulaos_bl_diag_probe()` (module bind) still never calls
`pwm_apply_state()`/`gpiod_direction_output()`/
`gpiod_set_raw_value_cansleep()` - zero hardware-state change at bind
time, unchanged from the original prototype. It now additionally
initializes `diag->diag_armed = false` explicitly, so the diagnostic is
fully inert (disarmed, no probe possible) until a human writes `arm`.

### Compile testing

Compile-tested via this project's docker cross-compile pattern
(`docker run --rm --user root -v "$BUILDROOT_DIR:/src" -w
/src/output/build/linux-custom pellcorp/k1-bash-build bash -c '...'`,
`make ARCH=mips CROSS_COMPILE=mipsel-buildroot-linux-gnu- W=1
module_drivers/drivers/misc/nebulaos_backlight_probe_diag.o`), in both
configurations:

- **`CONFIG_PWM_INGENIC_V2_GET_STATE` unselected (the real board
  default):** compiled clean, zero errors, zero warnings. `nm` on the
  resulting object confirms no `get_state_is_exact`-related symbol
  reference at all - the `#ifdef` genuinely compiles the call out, not
  merely hides it behind a runtime `false`.
- **`CONFIG_PWM_INGENIC_V2_GET_STATE` selected:** compiled clean, zero
  errors, zero warnings, alongside `pwm-ingenic-v2.o` (also rebuilt
  clean under this option). `nm` confirms the expected pairing: the PWM
  object exports `T ingenic_pwm_channel_get_state_is_exact`, and the
  backlight-diag object references `U ingenic_pwm_channel_get_state_is_exact`
  (undefined, correctly resolved at final link time) - proving the
  cross-module wiring is real and would link.

Unrelated finding, noted for the record and NOT fixed here (out of
scope - `pwm-ingenic-v2.c` may only be touched to confirm the exported
symbol per this pass's own constraints): the pristine, unpatched
`pwm-ingenic-v2.c` baseline (i.e. with
`CONFIG_PWM_INGENIC_V2_GET_STATE` unselected AND the get-state patch not
applied at all) fails a combined `W=1` build with
`-Werror=unused-but-set-variable` on `ingenic_pwm_config()`'s `prescale`
local. This is pre-existing vendor baseline behavior, not a regression -
`git diff` against vendor HEAD confirms `pwm-ingenic-v2.c` is untouched
in that configuration - and happens not to matter for the mainline build
today because module_drivers is compiled without `W=1`. The PWM state
readback patch's own restructuring of that code path (adding `(void)prescale;`)
incidentally fixes it under `CONFIG_PWM_INGENIC_V2_GET_STATE`, which is
why it only surfaces in the "unselected AND unpatched" combination
specifically, not in either configuration this project's own build
actually ships.

### Test results

`sh tests/display-backlight-diag-variant-tests.sh`: **50 passed, 0
failed** (of the original 32: 27 unchanged, 5 rewritten because they
tested implementation details of the now-removed free-form grammar or
the now-live-instead-of-hardcoded exactness field - not deleted, see the
test file's own "UPDATED" comments at each rewritten block for the
justification; plus 8 new test blocks covering the 9-command whitelist,
removal of the old free-form grammar, the fixed-duration invariant, the
diagnostic-level arm/disarm gate and its fail-safe disarm behavior, and
that the PWM-exactness gate genuinely branches on the real exported
function rather than a hardcoded constant in either direction).

## Packaging decision

See the mission's final report for the packaging decision and the
resulting `build-work/deploy-packages/` artifact (if produced). This
document's role is only to record the safety-design hardening itself;
packaging a full DISPLAY-V1 + W3 + R1 + DIAG1 build is a separate,
downstream step that never flashes or deploys anything.
