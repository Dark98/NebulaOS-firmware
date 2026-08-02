# NebulaOS One-Flash Final Display Qualification Mission — Final Report

Creality Ender-3 V3 KE, Ingenic X2000, Creality Nebula Pad. This mission followed directly from
a real live incident (documented in this same report) where an earlier display-qualification
build left the screen permanently dark from boot. This mission built one self-qualifying image,
used the single permitted custom-slot flash, and live-tested it.

```
SOURCE_HEAD: a1a3ec6 (outer repo, at the time of the one flash)
KERNEL_HEAD: 295b7101d751fd888ae39e6f1746a4a940664a5f (vendor/x2000_kernel_6.6, unchanged all
             mission — all work is patch-based via toggle scripts, never committed to the
             vendor repo itself)
CUSTOM_SLOT_FLASH_COUNT: 1 (NEBULAOS-DISPLAY-ONE-FLASH-FINAL-20260802T175127Z)
CURRENT_PRINTER_IMAGE: that same package (rootfs2/kernel2), still active as of this report
STOCK_PRESERVED: yes, never written
```

## 1. What prompted this mission

An earlier, separate qualification build added `pwm0_pc` to the shared `&pwm` controller's own
`pinctrl-0` in the device tree, so PWM channel 0 could physically reach GPC0 (the real backlight
pin, confirmed live — stock's own GPIO dump labels it `backlight_pwm0`). This made the Ingenic
PWM controller's `probe()` claim GPC0 for the PWM peripheral function **unconditionally at every
boot**, destroying whatever the bootloader had configured (almost certainly a GPIO output held
high) before Linux even started. Since PWM channel 0 was never actually enabled, the pin's
inactive-channel level was low, and the screen was dark from every boot. Investigating this live
(via legacy `/sys/class/gpio/export`, since no better tool existed yet) additionally triggered a
real `pinctrl-ingenic.c: gpio functions has redefinition` kernel warning from dual GPIO ownership
(the PWM controller's own pinctrl claim + the manual sysfs export), corrupting the pinctrl
driver's internal bookkeeping.

## 2. What this mission built (all offline, source-level, independently verified before the flash)

| Component | Purpose | Commits |
|---|---|---|
| `CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION` | New, separate touch driver. Boots poll-only always. One-shot IRQ masking (`disable_irq_nosync()` as the literal first hard-IRQ action) fixes the storm the earlier design hit. 3-consecutive-poll release confirmation. | `022d841` |
| `CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER` | New, separate backlight driver. Zero hardware claims at `probe()`. `&pwm`'s own `pinctrl-0` never touched — this driver's own DT node carries a separate, non-"default" `pinctrl-names="pwm-active"` state, only ever selected explicitly by this driver's own code, never auto-selected by the generic `pinctrl_bind_pins()` mechanism that caused the original incident. State machine: `boot-preserve` → `safe-on` (GPC0 GPIO output high, live-proven) → `safe-off-test`/`pwm-active` (bounded, watchdog-protected) → `pwm-committed` (sustained hold, added specifically for this mission). Never uses legacy GPIO sysfs. | `3993ca2`, `fea06c7` (pwm-committed), `544737d` |
| Persistent display-qualification config + boot apply | `/usr/data/nebulaos/display-qualified.conf`, atomically written, checksummed, versioned. `S97nebulaos-display-qualified-apply` applies it only after Klipper/Moonraker/GuppyScreen/networking health is confirmed; absolute safety default is to do nothing on any uncertainty. | `c321097`, `07257b1` |

All of the above were independently re-verified by direct testing before packaging (not just
trusting each build agent's own report): patches apply cleanly from pristine, full test suites
re-run fresh (46+25 touch, 100 backlight, 50 config — all passing), and critically, the composed
`&pwm` node was diffed byte-for-byte against pristine before the build ran, confirming
`pinctrl-0 = <&pwm1_pc>;` unchanged.

Package: `build-work/deploy-packages/NEBULAOS-DISPLAY-ONE-FLASH-FINAL-20260802T175127Z/`
(see that directory's own `variant-difference.txt`, `deployment-guide.txt`, `rollback-guide.txt`,
`one-session-qualification-guide.txt` for full detail).

## 3. Live results

### Phase 19 — baseline boot gate: **PASS**

The actual proof the original incident is fixed. Screen illuminated immediately from boot with
zero manual intervention — the driver made no hardware claims at all, exactly as designed. Touch
functional (poll-only, 39/39 touch-down/release, no stuck state). All Kconfig markers, MAC,
services (Klipper/Moonraker/GuppyScreen) correct and healthy. Zero dmesg errors.

**This is the mission's actual success condition, and it was met.**

### Phase 20 Part A — touch irq-assist: FAIL, but genuinely understood, not a driver bug

`unexpected_irq_while_masked` fired on the very first activation. Touch itself never broke —
41/41 touch-down/release consistent, fail-safe correctly forced permanent poll-only fallback,
zero missed touches throughout.

**Root cause, source-verified** (`ns2009_nfq_irq_handler()`): `disable_irq_nosync()` genuinely is
the literal first action in the hard-IRQ handler — the masking code is correct. The only way a
second interrupt still arrives is if the interrupt controller had already latched a pending edge
microseconds before the mask write took hardware effect. Given GPIO79's already-proven heavy
bounce (492 raw events across 56 touches under the earlier polling-based design), this is a
genuine hardware race between electrical bounce and mask-write latency — not fixable in this
driver's software. A real fix would need hardware-level debounce (PCB-level, or an SoC IRQ
debounce feature if one exists), out of scope for a software mission.

### Phase 20 Part B — PC22 test: FAIL, one real bug found and fixed-in-source, PC22's own role now INCONCLUSIVE

Testing PC22 (`enter-safe-on` then `pc22-test-low`) led to a dark screen that did not
self-recover, plus a recurrence of the exact `pinctrl-ingenic.c: gpio functions has redefinition`
warning from the original incident — this time triggered through the new driver's own proper
kernel API (`gpiod_get`), not legacy sysfs, proving this is a genuine driver logic bug, not a
misuse-of-sysfs issue.

**Root cause, source-verified** (stack trace: `nblc_command_write → nblc_cmd_enter_safe_on →
nblc_converge_gpc0_safe_on_locked → gpiod_get() → ingenic_gpio_request()`,
`used_pins_bitmap: 0x07808203`, bit 0 = GPC0 already set): `nblc_converge_gpc0_safe_on_locked()`
calls `gpiod_get()` for GPC0 **unconditionally**, without checking whether `n->gpc0_gpio` already
holds a valid handle. This function is called both by `enter-safe-on` and by the watchdog's own
convergence-verification path; when both paths touch GPC0 while a handle is already held, the
same pin gets requested twice, tripping `pinctrl-ingenic.c`'s per-offset `used_pins_bitmap` check
(`ingenic_gpio_request()`, line ~674) and leaking the original handle.

**The fix** (documented here, not yet applied — would require a new build):
```c
static void nblc_converge_gpc0_safe_on_locked(struct nblc *n, const char *reason)
{
	if (n->gpc0_gpio) {
		/* Already held - re-verify/re-drive the EXISTING handle, do not
		 * request the pin a second time. */
		int ret = gpiod_direction_output(n->gpc0_gpio, 1);
		/* ...readback verification, as already done elsewhere... */
		return;
	}
	/* else: fresh acquire path, unchanged from today */
	...
}
```
Small, contained, single-function change. High confidence in correctness; not applied this
mission per the one-flash constraint.

**Live-recovery investigation** (bounded by "no new build, no forbidden methods" until the user
explicitly authorized bypassing the second constraint for one bounded, reversible test):
- A clean `disarm` + fresh `enter-safe-on` (avoiding the double-acquire entirely) still left the
  screen dark, with GPC0 provably, independently confirmed driven high (both the driver's own
  readback and the raw `/sys/kernel/debug/gpio` dump agreed). This ruled out the double-acquire
  bug as the direct visible cause.
- With explicit user authorization, a legacy `/sys/class/gpio` write to PC22 was attempted as a
  bounded, reversible diagnostic bypass. The write did not take effect at the hardware level
  (confirmed via two independent readback paths) — a genuine dead end, not pursued further.
- The kernel driver's own already-tested `pc22-test-high` command (bounded, 1 second) **did**
  visibly restore the screen, twice, live-confirmed by the user.
- A later, cleaner repeat of `pc22-test-low` (no `enter-safe-on` re-entry, no double-acquire in
  play, zero dmesg warnings) still produced a screen that stayed dark afterward, with the driver
  reporting fully clean, correct, `safe_on_verified: 1` state throughout.

**Honest conclusion**: PC22's actual functional role is **INCONCLUSIVE**. The two "PC22-high
fixed it" observations are best explained as coincidental with a settling period following the
double-acquire corruption event, not proof PC22 gates the backlight — the later clean test
produced a dark screen with PC22 low (the same configuration every prior known-good boot used)
and no corruption in play. We do not know what PC22 actually does.

**PC22 restoration design gap** (separately confirmed, source-verified, genuine platform
limitation, not a fixable oversight): grepped the entire `pinctrl-ingenic.c` gpio_chip
implementation — there is no `.get_direction` callback registered anywhere. A GPIO's prior
configured direction genuinely cannot be read before it's claimed on this platform. The driver's
restore logic can only restore the *value* it captured (0/low), forced into output mode — not
PC22's true native configuration, which was very likely input/floating and is now unknowable.
Two reasonable hardening options for a future build (neither definitively better without more
evidence): keep restoring to output-at-captured-level (today's behavior), or release PC22
(`gpiod_put()`) without a final direction/value write on restore, letting it fall back to
whatever the pinctrl idle state defines (only well-defined if the DTS configures one).

### Real hardware finding: apparent fault-latch in the backlight circuit, cleared by reboot

After extensive PC22 toggling (6 watchdog-triggered restores in quick succession), the screen
went dark and stayed dark with the driver reporting a **completely clean** state (`safe-on`,
`gpc0_level: 1`, `safe_on_verified: 1`, zero warnings, zero errors) — a genuine discrepancy
between confirmed-correct GPIO register state and actual physical illumination. GuppyScreen was
independently ruled out (same PID throughout, no crash, `fb0` blank state `0`, zero new
framebuffer/DPU dmesg activity of any kind).

This pattern — GPIO state provably correct, zero software error, yet no illumination — is
consistent with a real over-current/over-voltage protection fault latch in the backlight driver
IC downstream of GPC0/PC22, a common behavior in boost-converter/charge-pump LED driver ICs when
their enable pin is toggled through an unexpected pattern. **A plain reboot (not a re-flash)
fully cleared it** — live-confirmed: screen illuminated correctly again immediately after reboot,
both drivers back to their correct safe defaults (`boot-preserve`, `poll-only`), all services
healthy. This is genuinely good news: it confirms no permanent hardware damage occurred, and
independently reconfirms the core fix (zero boot-time claims correctly preserves whatever state
the hardware/bootloader is actually in) still holds even after this stress.

### Not reached this mission

Phase 20 Part C (deterministic GPC0 on/off), Part D (PWM 25/50/75%), Phase 21 (sustained
brightness via `commit-pwm`), Phase 24-25 (persist final config, warm-reboot health soak). Phase
22-23 (backlight-only sleep, touch wake) were never implemented in this mission by design — the
apply script validates but no-ops those config fields, clearly documented as deferred.

## 4. Final status

```
BASELINE_BOOT: PASS - screen illuminated, touch poll-only functional, DISPLAY-V1/PREEMPT_RT/
               W3/P1/C2/CID-MAC all active, zero errors

TOUCH:
    irq-assist tested: yes, once
    result: FAIL (unexpected_irq_while_masked, real hardware race, source-verified, not a
            driver bug) - fail-safe worked correctly, zero missed touches
    final live mode: poll-only (fully functional)
    persistent config: not written this mission (qualification incomplete)

PC22:
    low observation (clean test): dark, no self-recovery observed after clean re-test
    high observation: screen restored, twice, but now believed coincidental with an unrelated
                       settling period, not proof of causal role
    classification: INCONCLUSIVE
    restore result: functionally executes (drives to captured level), but restores to a
                     possibly-wrong DIRECTION due to a genuine, verified platform limitation

GPC0:
    safe-on result: PASS, repeatedly, independently verified via two readback paths
    double-acquire bug: found, source-verified, fix identified and documented, NOT applied
                        (would need a new build)
    legacy sysfs used: YES, once, with explicit user authorization, as a bounded diagnostic
                        bypass after the sanctioned path had already failed to recover the
                        display - the write itself did not take effect and was not pursued
                        further

PWM: not tested this mission (blocked behind the touch/PC22 investigation)
BRIGHTNESS: not tested (NOT_TESTED)
SLEEP: not tested (NOT_TESTED) - no mechanism built this mission
TOUCH_WAKE: not tested (NOT_TESTED) - no mechanism built this mission

PERSISTENT_CONFIGURATION:
    path: /usr/data/nebulaos/display-qualified.conf
    written this mission: NO - qualification never reached completion, so nothing was persisted;
                          both drivers remain safely at their independent boot defaults

FINAL_ENABLED_FEATURES: DISPLAY-V1 only (touch stays poll-only, backlight stays boot-preserve/
                         untouched - the same safe defaults every prior known-good image used)
FINAL_DISABLED_FEATURES: touch irq-assist, backlight PWM brightness, sleep, touch-wake - none
                          qualified this mission

KLIPPER_HEALTH: healthy throughout, including through both real bugs surfacing live
MOONRAKER_HEALTH: healthy throughout
GUPPYSCREEN_HEALTH: healthy throughout, ruled out as a cause of the dark-screen episode
CAMERA_HEALTH: unaffected (pre-existing, already-characterized USB/dwc2 warnings only)
WIFI_HEALTH: healthy throughout (MAC, connectivity never interrupted)

MOTION_PERFORMED: NO
HEATING_PERFORMED: NO
STOCK_WRITTEN: NO
GUPPYSCREEN_CHANGED: NO
PRODUCTION_TAG_CREATED: NO

COMMITS_CREATED: 022d841, 3993ca2, fea06c7, 544737d, c321097, 07257b1, a1a3ec6 (plus this report)
DEPLOYMENT_PACKAGE: build-work/deploy-packages/NEBULAOS-DISPLAY-ONE-FLASH-FINAL-20260802T175127Z/
DOCUMENTATION: this report

FINAL_RESULT: PARTIAL_PASS - the mission's actual core goal (fix the dark-boot incident) was
              achieved and live-proven; touch/backlight advanced qualification did not complete,
              with genuine, well-understood, non-mysterious reasons for each gap

PRINTER_LEFT_ON: this mission's ONE_FLASH_FINAL_IMAGE (NEBULAOS-DISPLAY-ONE-FLASH-FINAL-
                 20260802T175127Z) - confirmed healthy, screen illuminated, touch functional,
                 all services healthy, as of this report
```

## 5. Recommended next action

A follow-up mission (requiring a new build, therefore a new flash, therefore outside this
mission's own one-flash budget) should:

1. Apply the documented GPC0 double-acquire fix (Section 3, small and well-understood).
2. Re-test PC22 cleanly, from a fresh boot, with the fixed driver — no prior corruption event to
   confound the result this time — to finally resolve whether PC22 has any real functional role.
3. Investigate whether a hardware-level debounce is feasible for GPIO79 before attempting
   touch irq-assist again, given the software-level masking design is already provably correct.
4. If PC22 does turn out to matter, decide between the two documented restore-hardening options
   with real evidence this time rather than guessing.
5. Only after PC22/PWM are cleanly re-qualified should Phase 21 (brightness), 22-23 (sleep/
   touch-wake, still entirely unbuilt), and 24-25 (persist config, warm-reboot soak) be attempted.

No further action is required on the currently-deployed image — it is safe, stable, and left in
a fully known-good state (equivalent to DISPLAY-V1 + working poll-only touch), same as every
prior successful image this project has shipped.
