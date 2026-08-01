# NebulaOS PWM State Readback (`.get_state`) - Implementation Report

Status: compile-tested prototype, gated behind `CONFIG_PWM_INGENIC_V2_GET_STATE`
(default `n`), NOT deployed, NOT flashed, NOT enabled for any build. 100%
offline source/compile-test work. This closes the hard blocker recorded in
`docs/NEBULAOS_BACKLIGHT_DIAGNOSTIC_PLAN.md`: no live PWM mutation should be
permitted until restoration can be proven exact, and it could not be proven
exact while `pwm-ingenic-v2.c` implemented no `.get_state` callback at all.

Relevant files:
- `scripts/build/patches/pwm-ingenic-v2-get-state.patch` - the kernel patch
  (new `ingenic_pwm_get_state()`, `ingenic_pwm_tick_ns()` shared helper,
  exported `ingenic_pwm_channel_get_state_is_exact()`, a new `get_state_exact`
  sysfs attribute, and a new `CONFIG_PWM_INGENIC_V2_GET_STATE` Kconfig option).
- `scripts/build/pwm-state-readback-variant.sh <GETSTATE0|GETSTATE1>` - toggles
  the variant on/off against the vendor kernel checkout; the only script
  allowed to touch `module_drivers/drivers/pwm/{Kconfig,pwm-ingenic-v2.c}`
  from now on (same discipline `touch-qualification-variant.sh` established).
- `tests/pwm-state-readback-variant-tests.sh` - 22 offline structural/toggle
  assertions.
- `tests/pwm-state-readback-roundtrip.c` - a host-native re-implementation of
  the tick↔ns/`PWM_WCFG` encode-decode arithmetic, compiled and run natively
  (54 assertions) to prove the arithmetic itself, independent of the kernel
  cross-toolchain.
- `scripts/build/patches/display-backlight-probe-diag.patch` - unchanged
  functionally; two documentation-only TODO cross-references added pointing
  here (see "Cross-module wiring" below).

## What's implemented

`ingenic_pwm_get_state(struct pwm_chip *chip, struct pwm_device *pwm, struct
pwm_state *state)`, wired into `ingenic_pwm_ops.get_state`, both gated behind
`#ifdef CONFIG_PWM_INGENIC_V2_GET_STATE` so the driver is byte-for-byte
identical to today when the option is unselected (the default). It populates:

- **`state->enabled`** - read directly from `PWM_EN` (`pwm_enable_status()`),
  masked to the channel's bit. Mode-independent (the register is written the
  same way in `ingenic_pwm_enable()`/`ingenic_pwm_disable()` regardless of
  `mode_sel[]`), so this is accurate for every channel, `COMMON_MODE` or
  `DMA_MODE`.
- **`state->polarity`** - read from `PWM_INITR` bit `[channel]` ("init
  level"), matching exactly what `ingenic_pwm_set_polarity()`/
  `pwm_set_init_level()` write (`1` → `PWM_POLARITY_NORMAL`, `0` →
  `PWM_POLARITY_INVERSED`). Also mode-independent, also accurate for every
  channel.
- **`state->period` / `state->duty_cycle`** (`COMMON_MODE` only) - read from
  `PWM_WCFG + channel*4`: `high_num` (bits `[31:16]`) is the duty-tick count,
  `low_num` (bits `[15:0]`) is the remaining-tick count. `duty_ticks =
  high_num`, `period_ticks = high_num + low_num` - this is exactly the
  inverse of what `ingenic_pwm_config()`'s `pwm_waveform_high()`/
  `pwm_waveform_low()` calls write (`high_num = duty`, `low_num = period -
  duty`), so the decode is provably the exact inverse of the encode, not an
  independently-derived guess.
- The finish-level bit (`PWM_INITR` bit `[channel+16]`) is deliberately left
  unmodeled, per the mission brief: it has no equivalent in `struct
  pwm_state`, `ingenic_pwm_config()` always forces it to `0` unconditionally,
  and nothing in the driver ever reads it back for any other purpose. Test 9
  in the variant test suite asserts `ingenic_pwm_get_state()` never calls
  `pwm_set_finish_level()`.

A new helper, `ingenic_pwm_tick_ns(unsigned int clk_in)`, was extracted from
`ingenic_pwm_config()`'s inline tick-math and is now called by **both**
`ingenic_pwm_config()` (the `.apply` write path) and `ingenic_pwm_get_state()`
(the new `.get_state` read path). This is the load-bearing design choice that
guarantees the two paths cannot independently drift: they are, literally, the
same code, not two formulas someone verified were equivalent once. This
refactor is unconditional (not gated behind the new Kconfig option) because it
is a pure, behavior-preserving reorganization of already-always-compiled code
(`PWM_INGENIC_V2=y` in the real board defconfig, unconditionally) - see
"Compile-test results" below for proof this leaves the `GETSTATE0` (option
unselected) object unaffected in every way that matters.

## The PRESCALE finding, and how it was resolved

`ingenic_pwm_config()` (the pristine, unmodified `.apply` path) does this,
in order:

```c
pwm_clk_config(ingenic_pwm, channel, PRESCALE);      /* writes PRESCALE into PWM_CCFG0/1 */
clk_in = clk_get_rate(ingenic_pwm->clk_pwm);
prescale = pwm_get_prescale(ingenic_pwm, channel);   /* reads PWM_CCFG0/1 back */

for (i = 0; i < PRESCALE; i++) { tmp = 2 * tmp; }     /* tmp = 2^PRESCALE, using the MACRO */
pwm_freq = clk_in / tmp;
do_div(clk_ns, pwm_freq);
```

**`prescale` (the hardware readback) is never used again after that
assignment.** The divisor (`tmp`, hence `pwm_freq`, hence `clk_ns`) is derived
purely from the compile-time `PRESCALE` macro (currently `2`), not from
`prescale`. This is genuinely dead code in the pristine vendor driver - not
something this patch introduced. It was traced by direct read of the function
body (`kernel/kernel-6.6/module_drivers/drivers/pwm/pwm-ingenic-v2.c`), not
assumed.

Two ways to resolve this for `.get_state`:
1. "Correct" it: have `.get_state` read the live `PWM_CCFG0/1` prescale field
   and use *that* as the divisor.
2. Reproduce the existing (arguably buggy) behavior exactly: always assume
   divisor `= 2^PRESCALE` (the compile-time constant), regardless of what the
   live register holds.

**Option 2 was chosen**, per the mission brief's explicit acceptance bar:
*"this must agree with the driver's own apply path"*, not with what a more
"correct" driver would do. Since `ingenic_pwm_config()` itself unconditionally
assumes divisor `= 2^PRESCALE` when it *writes* `PWM_WCFG`, `.get_state` must
assume the identical divisor when it *reads* `PWM_WCFG` back, or an
apply→get_state round trip would silently disagree - which would be a new,
patch-introduced bug, and a much worse outcome than reproducing an existing
one. The `pwm_get_prescale()` readback call itself was left untouched in
`ingenic_pwm_config()` (only the tick-math after it was extracted into the
shared helper) specifically so the pristine driver's register-write behavior
(`PWM_CCFG0/1` is still written and still read back) is unchanged byte-for-
byte - only the *consumption* of that dead readback moved, not its existence.

Practical consequence for testing: because `ingenic_pwm_config()` never
varies `PRESCALE` at runtime (it is always the same compile-time constant on
every call, for every channel), there is no way to exercise "two different
prescale register values" through the driver's own real code path. The
"two different prescale/clock-divider configurations" required by the
mission brief were achieved instead by varying `clk_in` (`clk_get_rate()`'s
return value) - which *does* vary the effective tick period, is a real input
to the same formula, and is the only variable that actually changes
`ingenic_pwm_config()`'s frequency math in practice. See
`tests/pwm-state-readback-roundtrip.c`'s two `clk_in` values (`50000000` -
the real `DEFAULT_PWM_CLK_RATE`, and an arbitrary second rate,
`24000000`).

## DMA_MODE handling - the decision, and why

`mode_sel[channel]` defaults to `COMMON_MODE` (zero-initialized) and is only
ever changed to `DMA_MODE` via a debug-only sysfs store handler
(`pwm_store_config()`, intended for manual test use, not expected live on a
real backlight channel - confirmed by source read, not assumed). `DMA_MODE`
uses a completely separate DMA-fed waveform mechanism (the `PWM_DES`/
`PWM_DMADDR`/`PWM_DTLR`/... register block) with no simple duty/period
register at all - there is nothing to decode.

Two options were considered for `ingenic_pwm_get_state()`'s `DMA_MODE`
branch:
1. **Return an error** (e.g. `-EOPNOTSUPP`).
2. **Return `0` (success)** with `period`/`duty_cycle` left at `0`, plus an
   out-of-band "not exact" signal.

**Option 2 was chosen**, and this is a real, load-bearing finding, not a
stylistic preference: `drivers/pwm/core.c:pwm_device_request()` (the *only*
call site that ever invokes `.get_state`, exactly once per PWM device, at
request time) does this:

```c
err = pwm->chip->ops->get_state(pwm->chip, pwm, &state);
if (!err)
        pwm->state = state;
```

If `.get_state` returns an error, `pwm->state` is **not** updated at all - it
stays at its zero-initialized default. That is *exactly* the same outcome as
not implementing `.get_state` in the first place, for **every** field,
including `enabled`/`polarity` - which, for a `DMA_MODE` channel, this driver
*can* read accurately (both registers are mode-independent). Returning an
error would therefore silently discard two genuinely accurate fields to avoid
reporting a `0` for two fields that cannot be decoded - a strictly worse
outcome for any real caller. Returning `0` (success) with `period =
duty_cycle = 0` for `DMA_MODE`, plus the new
`ingenic_pwm_channel_get_state_is_exact()` (exported) /`get_state_exact`
(sysfs, for the `request`-selected debug channel) out-of-band flag, gives a
well-behaved caller strictly more information than either alternative -
provided it checks that flag before trusting `period`/`duty_cycle`, which is
exactly the documented contract (see the function's own header comment in
`pwm-ingenic-v2.c`).

The `0`/`0` values reported are never claimed as real duty/period - the
function's own comment and the exactness flag exist precisely so no caller
can mistake them for a genuine reading. **BLOCKED**: exact `DMA_MODE`
duty/period decode is BLOCKED, permanently, not just "not yet done" - there is
no register that holds this information in a form comparable to
`COMMON_MODE`'s `PWM_WCFG`, so this is a hardware/architecture limit, not an
implementation gap.

## Naming convention reused

`ingenic_pwm_channel_get_state_is_exact()` / `get_state_exact` deliberately
reuses the `pwm_restore_is_exact`/`gpio_restore_is_exact` naming convention
already established in `nebulaos_backlight_probe_diag.c`'s debugfs `status`
file, so a later diagnostic reading both surfaces sees a consistent
"is exact" vocabulary rather than two different ad hoc names for the same
concept.

## Cross-module wiring into `nebulaos_backlight_probe_diag.c` - left as a TODO

The mission brief allowed updating `nebulaos_backlight_probe_diag.c`'s own
hardcoded `pwm_restore_is_exact: 0` field to query the new capability, but
only if it was a small, obviously-correct edit, with an explicit TODO
otherwise. This was judged **not** small enough to do here:

- `nebulaos_backlight_probe_diag.c` only ever holds a generic `struct
  pwm_device *` (acquired via `devm_pwm_get(dev, NULL)`), with no header
  declaring `pwm-ingenic-v2.c`'s new exported
  `ingenic_pwm_channel_get_state_is_exact(struct pwm_chip *chip, unsigned int
  channel)` - there is currently no shared header for either driver's
  internal symbols at all.
- A correct integration would need: (1) a new small header (of a kind neither
  driver currently has), (2) a runtime check that `diag->pwm`'s `chip` is
  actually the ingenic v2 chip before calling an ingenic-v2-specific function
  on it (a generic PWM consumer must never assume which concrete driver
  backs its `pwm_device`), and (3) re-verifying
  `nebulaos_backlight_probe_diag.c`'s own already-hardened, already-tested
  32-test suite afterward, since this would be a genuine behavior change to
  that file, not a comment.
- That is real, multi-file, cross-driver design work - explicitly out of
  scope for this patch per the mission's own bound ("if it's a larger change
  ... leave a clear TODO comment instead").

**What was done instead**: two documentation-only TODO comments were added to
`nebulaos_backlight_probe_diag.c` (its file header's "RESTORATION EXACTNESS"
section, and `nebulaos_bl_diag_status_show()`'s own comment immediately above
the hardcoded `seq_puts(s, "pwm_restore_is_exact: 0\n")` line), cross-
referencing this report and explaining exactly what remains to be wired up
and why. No functional line changed. Verified this introduced zero
regression: all 32 pre-existing `tests/display-backlight-diag-variant-tests.sh`
assertions still pass, the patch still applies cleanly to a pristine
checkout, and `nebulaos_backlight_probe_diag.o` still compiles cleanly
(`W=1`, zero warnings) via the project's docker cross-compile pattern.

The hardcoded `pwm_restore_is_exact: 0` remains **conservative, not wrong**:
it is still literally true whenever `CONFIG_PWM_INGENIC_V2_GET_STATE` is
unselected (the default, and the only state either build has ever shipped),
and if it is ever selected without this follow-up being done, the field
understates exactness rather than overstating it - never the reverse.

## Test results

### Structural/toggle tests - `sh tests/pwm-state-readback-variant-tests.sh`

**22 passed, 0 failed.** Covers: `GETSTATE0`/`GETSTATE1` toggle cleanliness
and idempotency; `.get_state` wired behind the new Kconfig option; the three
expected registers (`PWM_EN`/`PWM_INITR`/`PWM_WCFG`) are genuinely read (not
fabricated); the shared `ingenic_pwm_tick_ns()` helper is defined exactly
once and called from both `.apply` and `.get_state`; the `pwm_get_prescale()`
dead-code readback is preserved unchanged (proving the PRESCALE finding's
resolution didn't silently remove the vendor's original register access);
the `DMA_MODE` branch zeroes `period`/`duty_cycle` and returns `0` (not an
error); the exactness query is exported and correctly keyed off `mode_sel[]
!= DMA_MODE`; the finish-level bit is never touched by `get_state`; an
unknown variant name is rejected; the patch applies cleanly to a pristine
checkout; and the host-native round-trip harness (below) compiles and
passes.

### Host-native arithmetic round-trip - `tests/pwm-state-readback-roundtrip.c`

**54 passed, 0 failed**, compiled and run natively (`cc -Wall -Wextra -O2`,
zero warnings) - **NOT** cross-compiled, **NOT** the real kernel object code.
This is a hand-copied re-implementation of exactly the tick↔ns and
`PWM_WCFG` high/low-num encode/decode arithmetic (mirrored line-by-line from
the patched driver, with the source cross-referenced in the file's own
header), run against simulated register state (plain local variables, not
real hardware or even real kernel register-access macros). It genuinely
executes and checks real numeric results for: disabled state, enabled state,
a known period, a known duty (25/50/75%, matching the diagnostic driver's own
candidate values), zero duty, full duty (`period == duty`), both polarities,
and two different `clk_in` values (`50000000` = `DEFAULT_PWM_CLK_RATE`, and an
arbitrary `24000000`) - plus the `DMA_MODE` "never fabricate, always flag"
contract. It proves the arithmetic; it does not prove the compiled kernel
object, which is covered separately below.

### Real kernel object compile test (docker cross-compile)

Performed via this project's established pattern
(`docker run --rm --user root -v "$BUILDROOT_DIR:/src" -w
/src/output/build/linux-custom pellcorp/k1-bash-build bash -c '...'`, reusing
the already-configured `vendor/buildroot-x2000/output/build/linux-custom`
tree and its pre-built `mipsel-buildroot-linux-gnu-` host toolchain from a
prior full build - `make ARCH=mips CROSS_COMPILE=mipsel-buildroot-linux-gnu-
W=1 module_drivers/drivers/pwm/pwm-ingenic-v2.o`), in **both**
configurations:

- **`GETSTATE0`** (`CONFIG_PWM_INGENIC_V2_GET_STATE` unselected, the real
  board default): compiled clean, zero errors, zero warnings. `nm` on the
  resulting object confirms no `get_state`/`is_exact` symbols are present -
  the option genuinely compiles out.
- **`GETSTATE1`** (selected): compiled clean, zero errors, zero warnings.
  `nm` confirms the expected new symbols: `ingenic_pwm_get_state` (static),
  the exported `ingenic_pwm_channel_get_state_is_exact` (global `T`), and
  `pwm_show_get_state_exact` (static).

One real bug was caught and fixed during this compile test: an early draft
comment contained the literal substring `PWM_DE*/PWM_D*`, whose embedded
`*/` prematurely closed the enclosing `/* ... */` block comment, causing the
next real apostrophe in the following prose ("...whether it's safe...") to be
parsed as an unterminated character literal (`error: missing terminating '
character`). Fixed by rewording to avoid the `*/` substring
(`PWM_DES/PWM_DMADDR/PWM_DTLR`) rather than escaping it, since C comments
have no escape mechanism for `*/`.

`nebulaos_backlight_probe_diag.o` (the documentation-only TODO-comment
change) was also separately compile-tested via the same pattern, `W=1`, zero
warnings - see "Cross-module wiring" above.

## What's PROVEN vs. ASSUMED

- **PROVEN_BY_SOURCE_INSPECTION**: the `PWM_WCFG` high/low-num encode
  (`pwm_waveform_high()`/`pwm_waveform_low()`) and the fact `.get_state`'s
  decode is its exact algebraic inverse; the `PRESCALE` dead-code finding
  (`pwm_get_prescale()`'s return value is never consumed); `PWM_EN`/
  `PWM_INITR` being mode-independent registers (written identically by
  `ingenic_pwm_enable()`/`disable()`/`ingenic_pwm_config()` regardless of
  `mode_sel[]`); `mode_sel[]` defaulting to `COMMON_MODE` and only reachable
  as `DMA_MODE` via a debug sysfs handler; `pwm_device_request()`'s
  success-only state-copy behavior in `drivers/pwm/core.c`; `pwm_get_state()`
  being a cheap cached-copy inline (confirmed in `include/linux/pwm.h`) that
  never re-reads hardware, meaning `.get_state` only ever matters at the
  one-shot PWM-request-time call.
- **PROVEN_BY_COMPILE_TEST**: both `GETSTATE0` and `GETSTATE1` compile
  cleanly (`W=1`, zero warnings) against the real vendor kernel tree via the
  project's docker methodology, with the expected symbols present/absent as
  designed.
- **PROVEN_BY_HOST_EXECUTION** (not the same as compiled-kernel-code
  execution - see caveat above): the tick↔ns and `PWM_WCFG` arithmetic
  round-trips correctly for the tested value matrix, run natively.
- **SUPPORTED_INFERENCE**: that reproducing (rather than "fixing") the
  PRESCALE dead-code behavior is the correct choice - this follows directly
  from the mission's own stated acceptance bar ("agree with `.apply`"), not
  from live hardware measurement.
- **UNKNOWN_UNTIL_HARDWARE** (out of this patch's scope, same category as the
  original backlight diagnostic plan): whether the real hardware's `PWM_WCFG`
  register genuinely behaves exactly as `pwm_waveform_high()`/
  `pwm_waveform_low()`'s comments describe under real electrical load; this
  patch only proves the driver's own read/write code is internally
  consistent, not that the silicon matches the vendor's register-map
  documentation. No live device access was performed or attempted for this
  task.
- **BLOCKED** (permanent, not "not yet done"): exact `DMA_MODE` duty/period
  readback - no register exists to decode it (see "DMA_MODE handling"
  above).

## Vendor tree discipline

`vendor/x2000_kernel_6.6` was left `git status --porcelain`-clean after every
apply/build/test/revert cycle in this mission, verified explicitly each time.
Only the outer repo's new/modified files (the patch, the toggle script, the
tests, this report, and the two TODO-comment lines in
`display-backlight-probe-diag.patch`) were committed.
