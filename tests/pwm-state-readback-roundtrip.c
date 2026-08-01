/*
 * Host-side (native, NOT mipsel) round-trip arithmetic test for the
 * NebulaOS PWM state readback patch
 * (scripts/build/patches/pwm-ingenic-v2-get-state.patch,
 * docs/NEBULAOS_PWM_STATE_READBACK_REPORT.md).
 *
 * HONESTY NOTE (read before trusting this test's "pass" result): this is
 * NOT the real kernel driver code, compiled and executed. It is a
 * hand-copied, by-hand-verified re-implementation of exactly the integer
 * arithmetic ingenic_pwm_config() (the .apply write path) and the new
 * ingenic_pwm_get_state() (the .get_state readback path) perform on
 * simulated PWM_EN/PWM_INITR/PWM_WCFG registers (plain local variables
 * here, not real hardware or even real kernel register-access macros).
 * It cannot exercise devicetree parsing, clk framework behavior, mutex
 * locking, or the actual MIPS-compiled object code - none of that is
 * host-executable. What it DOES genuinely prove, by actually running (not
 * just reading) this arithmetic on this host: that the tick<->ns
 * conversion and PWM_WCFG high_num/low_num encode/decode this patch uses
 * for .get_state reproduces exactly what the vendor driver's own .apply
 * path programs, for a representative range of (enabled, period_ns,
 * duty_ns, polarity, clk_in) combinations, including the tick-rounding
 * behavior inherent to any integer tick-based PWM. See the real
 * compile-test result (module_drivers/drivers/pwm/pwm-ingenic-v2.o built
 * via the project's docker cross-compile pattern) for proof the actual
 * kernel source compiles; this file only proves the arithmetic.
 *
 * Formulas mirrored from kernel/kernel-6.6/module_drivers/drivers/pwm/
 * pwm-ingenic-v2.c as patched:
 *   - ingenic_pwm_tick_ns(clk_in): tmp=1; loop PRESCALE(=2) times
 *     tmp*=2; pwm_freq = clk_in/tmp; clk_ns = 1e9/pwm_freq (integer
 *     division, matching do_div()'s quotient).
 *   - .apply (ingenic_pwm_config()): period = period_ns/clk_ns,
 *     duty = duty_ns/clk_ns (both truncating integer division);
 *     PWM_WCFG high_num = duty, low_num = period - duty.
 *   - .get_state (ingenic_pwm_get_state()): high_num/low_num read back
 *     from PWM_WCFG; period_ticks = high_num + low_num, duty_ticks =
 *     high_num; state.period = period_ticks * clk_ns, state.duty_cycle =
 *     duty_ticks * clk_ns.
 *   - polarity: PWM_INITR bit written 1 for PWM_POLARITY_NORMAL, 0 for
 *     PWM_POLARITY_INVERSED (pwm_set_init_level()/
 *     ingenic_pwm_set_polarity()); read back the same way.
 *   - enabled: PWM_EN bit, written/read directly.
 *
 * Build/run (host gcc, no cross-toolchain needed - pure integer C):
 *   cc -Wall -Wextra -O2 -o /tmp/pwm-roundtrip pwm-state-readback-roundtrip.c
 *   /tmp/pwm-roundtrip
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

#define PRESCALE 2

enum polarity { POLARITY_NORMAL, POLARITY_INVERSED };

static uint64_t tick_ns(uint32_t clk_in)
{
	uint32_t tmp = 1;
	uint32_t pwm_freq;
	int i;

	for (i = 0; i < PRESCALE; i++) {
		tmp = 2 * tmp;
	}
	pwm_freq = clk_in / tmp;
	return 1000000000ULL / pwm_freq;
}

struct state {
	int enabled;
	uint64_t period;
	uint64_t duty_cycle;
	enum polarity polarity;
};

/* Simulated hardware register state for one channel. */
struct hw_channel {
	int en_bit;
	int initr_bit;
	uint32_t high_num;	/* PWM_WCFG high 16 bits */
	uint32_t low_num;	/* PWM_WCFG low 16 bits */
};

/* Mirrors ingenic_pwm_apply()/ingenic_pwm_config()/
 * ingenic_pwm_set_polarity() exactly - see file header. */
static void apply_state(struct hw_channel *hw, uint32_t clk_in,
			 int enabled, uint64_t period_ns, uint64_t duty_ns,
			 enum polarity pol)
{
	hw->initr_bit = (pol == POLARITY_NORMAL) ? 1 : 0;

	if (!enabled) {
		hw->en_bit = 0;
		return;
	}

	uint64_t clk_ns = tick_ns(clk_in);
	uint32_t period = (uint32_t)(period_ns / clk_ns);
	uint32_t duty = (uint32_t)(duty_ns / clk_ns);

	hw->high_num = duty;
	hw->low_num = period - duty;
	hw->en_bit = 1;
}

/* Mirrors ingenic_pwm_get_state() exactly - see file header. COMMON_MODE
 * only; DMA_MODE is tested separately below (get_state_dma_mode()). */
static void get_state(const struct hw_channel *hw, uint32_t clk_in,
		       struct state *out)
{
	out->enabled = hw->en_bit;
	out->polarity = hw->initr_bit ? POLARITY_NORMAL : POLARITY_INVERSED;

	uint64_t clk_ns = tick_ns(clk_in);
	uint32_t high_num = hw->high_num;
	uint32_t low_num = hw->low_num;

	out->duty_cycle = (uint64_t)high_num * clk_ns;
	out->period = (uint64_t)(high_num + low_num) * clk_ns;
}

/* Mirrors ingenic_pwm_get_state()'s DMA_MODE branch: period/duty_cycle
 * always 0, is_exact always false - never fabricated. */
static void get_state_dma_mode(const struct hw_channel *hw, struct state *out,
				int *is_exact)
{
	out->enabled = hw->en_bit;
	out->polarity = hw->initr_bit ? POLARITY_NORMAL : POLARITY_INVERSED;
	out->period = 0;
	out->duty_cycle = 0;
	*is_exact = 0;
}

static int PASS, FAIL;

#define CHECK(cond, msg, ...) do { \
	if (cond) { \
		PASS++; \
	} else { \
		FAIL++; \
		printf("FAIL: " msg "\n", ##__VA_ARGS__); \
	} \
} while (0)

/* Runs one COMMON_MODE apply->get_state round trip and checks it against
 * the tick-rounding-aware expected value (NOT the raw requested ns value -
 * see the file header: exact means "exact to what .apply() actually
 * programmed", not "exact to the ns value the caller asked for"). */
static void check_roundtrip(const char *label, uint32_t clk_in,
			    int enabled, uint64_t period_ns, uint64_t duty_ns,
			    enum polarity pol)
{
	struct hw_channel hw = {0};
	struct state st;

	apply_state(&hw, clk_in, enabled, period_ns, duty_ns, pol);
	get_state(&hw, clk_in, &st);

	CHECK(st.enabled == enabled, "%s: enabled mismatch: got %d want %d",
	      label, st.enabled, enabled);
	CHECK(st.polarity == pol, "%s: polarity mismatch: got %d want %d",
	      label, st.polarity, pol);

	if (!enabled) {
		/* Disabled channels don't program WCFG in this driver -
		 * period/duty_cycle readback is whatever WCFG last held
		 * (0 for a freshly-simulated channel here); only
		 * enabled/polarity are meaningful for a disabled state. */
		return;
	}

	uint64_t clk_ns = tick_ns(clk_in);
	uint64_t expect_period = (period_ns / clk_ns) * clk_ns;
	uint64_t expect_duty = (duty_ns / clk_ns) * clk_ns;

	CHECK(st.period == expect_period,
	      "%s: period mismatch: got %llu want %llu (requested %llu, clk_ns=%llu)",
	      label, (unsigned long long)st.period, (unsigned long long)expect_period,
	      (unsigned long long)period_ns, (unsigned long long)clk_ns);
	CHECK(st.duty_cycle == expect_duty,
	      "%s: duty_cycle mismatch: got %llu want %llu (requested %llu, clk_ns=%llu)",
	      label, (unsigned long long)st.duty_cycle, (unsigned long long)expect_duty,
	      (unsigned long long)duty_ns, (unsigned long long)clk_ns);
	CHECK(st.duty_cycle <= st.period,
	      "%s: duty_cycle (%llu) exceeds period (%llu)",
	      label, (unsigned long long)st.duty_cycle, (unsigned long long)st.period);
}

int main(void)
{
	/* Two different clk_in ("clock-divider configuration") values -
	 * see the report's PRESCALE finding: PRESCALE itself is a fixed
	 * compile-time constant in every .apply() call in this driver
	 * (there is no live code path that varies it), so the only way
	 * .apply() ever produces a different tick period is a different
	 * clk_pwm rate. DEFAULT_PWM_CLK_RATE (50000000) is what probe()
	 * actually configures; a second, different rate is included here
	 * purely to prove the arithmetic isn't hardcoded to one clock. */
	uint32_t clk_a = 50000000;	/* DEFAULT_PWM_CLK_RATE */
	uint32_t clk_b = 24000000;	/* an alternate, arbitrary rate */

	printf("tick_ns(%u) = %llu ns/tick\n", clk_a, (unsigned long long)tick_ns(clk_a));
	printf("tick_ns(%u) = %llu ns/tick\n", clk_b, (unsigned long long)tick_ns(clk_b));

	/* Disabled state. */
	check_roundtrip("disabled/normal/clk_a", clk_a, 0, 20000, 10000, POLARITY_NORMAL);
	check_roundtrip("disabled/inversed/clk_b", clk_b, 0, 20000, 10000, POLARITY_INVERSED);

	/* Enabled, known period/duty (50% - the candidate backlight
	 * period from the diagnostic driver, 20000ns/20kHz-class). */
	check_roundtrip("enabled/50pct/normal/clk_a", clk_a, 1, 20000, 10000, POLARITY_NORMAL);
	check_roundtrip("enabled/50pct/inversed/clk_a", clk_a, 1, 20000, 10000, POLARITY_INVERSED);

	/* Zero duty. */
	check_roundtrip("enabled/zero_duty/clk_a", clk_a, 1, 20000, 0, POLARITY_NORMAL);

	/* Full duty (period == duty). */
	check_roundtrip("enabled/full_duty/clk_a", clk_a, 1, 20000, 20000, POLARITY_NORMAL);

	/* 25%/75% (the diagnostic driver's other candidate duty values). */
	check_roundtrip("enabled/25pct/clk_a", clk_a, 1, 20000, 5000, POLARITY_NORMAL);
	check_roundtrip("enabled/75pct/clk_a", clk_a, 1, 20000, 15000, POLARITY_NORMAL);

	/* Second clk_in ("prescale/clock-divider configuration"). */
	check_roundtrip("enabled/50pct/normal/clk_b", clk_b, 1, 20000, 10000, POLARITY_NORMAL);
	check_roundtrip("enabled/75pct/inversed/clk_b", clk_b, 1, 20000, 15000, POLARITY_INVERSED);

	/* A period well outside the candidate backlight value, to prove
	 * the arithmetic isn't special-cased to 20000ns. */
	check_roundtrip("enabled/1ms_period/clk_a", clk_a, 1, 1000000, 250000, POLARITY_NORMAL);

	/* DMA_MODE: must never fabricate period/duty_cycle, must always
	 * flag not-exact, but enabled/polarity must still be accurate
	 * (mode-independent registers). */
	{
		struct hw_channel hw = {0};
		struct state st;
		int is_exact = 1;

		hw.en_bit = 1;
		hw.initr_bit = 1;
		hw.high_num = 0x1234;	/* would-be garbage if misread as COMMON_MODE */
		hw.low_num = 0x5678;

		get_state_dma_mode(&hw, &st, &is_exact);
		CHECK(st.enabled == 1, "DMA_MODE: enabled not read accurately");
		CHECK(st.polarity == POLARITY_NORMAL, "DMA_MODE: polarity not read accurately");
		CHECK(st.period == 0, "DMA_MODE: period was fabricated instead of left at 0 (got %llu)",
		      (unsigned long long)st.period);
		CHECK(st.duty_cycle == 0, "DMA_MODE: duty_cycle was fabricated instead of left at 0 (got %llu)",
		      (unsigned long long)st.duty_cycle);
		CHECK(is_exact == 0, "DMA_MODE: is_exact was not flagged false");
	}

	printf("\n%d passed, %d failed\n", PASS, FAIL);
	return FAIL == 0 ? 0 : 1;
}
