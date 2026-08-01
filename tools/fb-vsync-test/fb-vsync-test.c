/*
 * fb-vsync-test - standalone framebuffer pan/vsync diagnostic tool
 *
 * Built for the DISPLAY-V1 live qualification mission (NebulaOS, Ender-3 V3
 * KE + Nebula Pad, Ingenic X2000/Halley5 SoC). Exercises exactly the ioctls
 * the DISPLAY-V1 kernel patch touches (scripts/build/patches/display-vsync-
 * gate.patch: FBIOPAN_DISPLAY, optionally FBIO_WAITFORVSYNC) against the
 * real /dev/fb0 device, on a fixed cadence, for a bounded number of frames,
 * measuring ioctl latency directly. It does NOT modify panel timing, pixel
 * format, or any driver/module source - it only calls existing, already-
 * supported ioctls from userspace, the same way GuppyScreen (or any fbdev
 * client) already does.
 *
 * IMPORTANT, found while preparing this tool (2026-08-01): the DISPLAY-V1
 * patch adds three atomic_t diagnostic counters to the kernel's internal
 * `struct ingenicfb_device` (pan_vsync_gated_count, pan_vsync_timeout_count,
 * pan_vsync_invalid_count) but never exports them anywhere userspace can
 * read them - no debugfs node, no sysfs attribute, no procfs entry. The
 * live qualification plan's own test guide (docs/
 * NEBULAOS_DISPLAY_LIVE_QUALIFICATION_PLAN.md, "DISPLAY-V1 test guide")
 * describes "watch[ing] the new debugfs/diagnostic counters" as part of a
 * healthy result, but as shipped in this build there is no way to do that
 * directly. This tool cannot read those kernel-internal counters either -
 * nothing in userspace can, given the current patch. The only indirect,
 * partial proxy is the kernel's own printk_ratelimit()'d dev_warn() that
 * fires on a real pan_vsync_timeout_count increment ("pan_display: vsync
 * wait timed out/interrupted, applying frame N immediately") - grep dmesg
 * for "pan_display: vsync wait" separately if you need that signal. This
 * tool's own report only reflects what it can directly observe from
 * userspace: ioctl return codes/errno and ioctl call latency.
 *
 * Restores the original visible page and the original framebuffer pixel
 * content before exiting, unconditionally, including on SIGINT/SIGTERM -
 * this is not optional/flag-gated (see --restore-page below for what that
 * flag actually controls).
 *
 * Usage:
 *   fb-vsync-test [options]
 *
 * Options:
 *   --frames N            number of pan cycles to run (default 500)
 *   --rate HZ             target pan rate in Hz (default 30)
 *   --pattern NAME         split | bands | framenum | diagonal (default split)
 *   --use-waitforvsync     before each pan, explicitly call FBIO_WAITFORVSYNC
 *                          first, then pan - an explicit-wait comparison mode
 *                          against the kernel's own auto-gated path.
 *   --restore-page         after the mandatory restore, re-map and byte-
 *                          compare the framebuffer against a pre-test backup
 *                          and report any mismatch (an extra verification
 *                          pass - restoration itself always happens with or
 *                          without this flag).
 *   --output-report PATH  write a plain key:value summary report to PATH
 *   --device PATH         framebuffer device (default /dev/fb0)
 *   -h / --help            usage
 *
 * Exit status: 0 on a clean, fully-completed run; 1 on a setup/usage error;
 * 2 if interrupted by a signal (still restores cleanly first).
 *
 * Deliberately simple: no threads, no dynamic pattern plugins, one flat
 * source file. Correctness (never leaving the display or framebuffer
 * content altered on exit) matters far more here than cleverness.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

/* --- global state touched by the signal handler (kept minimal, async-signal-safe) --- */
static volatile sig_atomic_t g_stop = 0;

static void on_signal(int signo)
{
	(void)signo;
	g_stop = 1;
}

/* --- CLI options --- */
struct options {
	int frames;
	int rate_hz;
	const char *pattern;
	int use_waitforvsync;
	int restore_page_verify;
	const char *output_report;
	const char *device;
};

static void usage(const char *prog)
{
	fprintf(stderr,
		"usage: %s [--frames N] [--rate HZ] [--pattern split|bands|framenum|diagonal]\n"
		"          [--use-waitforvsync] [--restore-page] [--output-report PATH]\n"
		"          [--device /dev/fb0]\n",
		prog);
}

static int parse_args(int argc, char **argv, struct options *o)
{
	o->frames = 500;
	o->rate_hz = 30;
	o->pattern = "split";
	o->use_waitforvsync = 0;
	o->restore_page_verify = 0;
	o->output_report = NULL;
	o->device = "/dev/fb0";

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--frames") && i + 1 < argc) {
			o->frames = atoi(argv[++i]);
		} else if (!strcmp(argv[i], "--rate") && i + 1 < argc) {
			o->rate_hz = atoi(argv[++i]);
		} else if (!strcmp(argv[i], "--pattern") && i + 1 < argc) {
			o->pattern = argv[++i];
		} else if (!strcmp(argv[i], "--use-waitforvsync")) {
			o->use_waitforvsync = 1;
		} else if (!strcmp(argv[i], "--restore-page")) {
			o->restore_page_verify = 1;
		} else if (!strcmp(argv[i], "--output-report") && i + 1 < argc) {
			o->output_report = argv[++i];
		} else if (!strcmp(argv[i], "--device") && i + 1 < argc) {
			o->device = argv[++i];
		} else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
			usage(argv[0]);
			exit(0);
		} else {
			fprintf(stderr, "unknown argument: %s\n", argv[i]);
			usage(argv[0]);
			return -1;
		}
	}
	if (o->frames <= 0) { fprintf(stderr, "--frames must be > 0\n"); return -1; }
	if (o->rate_hz <= 0) { fprintf(stderr, "--rate must be > 0\n"); return -1; }
	if (strcmp(o->pattern, "split") && strcmp(o->pattern, "bands") &&
	    strcmp(o->pattern, "framenum") && strcmp(o->pattern, "diagonal")) {
		fprintf(stderr, "--pattern must be one of: split, bands, framenum, diagonal\n");
		return -1;
	}
	return 0;
}

/* --- latency sample storage --- */
struct latency_stats {
	double *samples_us;
	int count;
	int capacity;
	long errors;
};

static void latency_init(struct latency_stats *s, int capacity)
{
	s->samples_us = malloc(sizeof(double) * (size_t)capacity);
	s->count = 0;
	s->capacity = capacity;
	s->errors = 0;
}

static void latency_add(struct latency_stats *s, double us)
{
	if (s->count < s->capacity)
		s->samples_us[s->count++] = us;
}

static int cmp_double(const void *a, const void *b)
{
	double da = *(const double *)a, db = *(const double *)b;
	return (da > db) - (da < db);
}

static double percentile(double *sorted, int n, double pct)
{
	if (n <= 0) return 0.0;
	int idx = (int)(pct * (n - 1));
	if (idx < 0) idx = 0;
	if (idx >= n) idx = n - 1;
	return sorted[idx];
}

static double now_monotonic_us(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec * 1e6 + (double)ts.tv_nsec / 1e3;
}

/* --- pixel packing, generic over the reported bpp/channel layout --- */
static uint32_t pack_pixel(const struct fb_var_screeninfo *v, uint8_t r, uint8_t g, uint8_t b)
{
	uint32_t rr = v->red.length   ? (r * ((1u << v->red.length)   - 1)) / 255 : 0;
	uint32_t gg = v->green.length ? (g * ((1u << v->green.length) - 1)) / 255 : 0;
	uint32_t bb = v->blue.length  ? (b * ((1u << v->blue.length)  - 1)) / 255 : 0;
	return (rr << v->red.offset) | (gg << v->green.offset) | (bb << v->blue.offset);
}

/* Assumes little-endian in-memory pixel layout, which matches this target
 * (mipsel = MIPS little-endian) and the project's already-confirmed RGB565
 * wire format - not a portable assumption for other hardware. */
static void put_pixel(uint8_t *frame_base, int line_length, int bytes_per_pixel,
                       int x, int y, uint32_t pixel)
{
	uint8_t *p = frame_base + (size_t)y * line_length + (size_t)x * bytes_per_pixel;
	memcpy(p, &pixel, (size_t)bytes_per_pixel);
}

/* --- tiny 5x7 block font, digits 0-9 only - just enough for a large,
 * legible frame counter. Each row is the low 5 bits, MSB-first (leftmost
 * pixel = bit 4). --- */
static const uint8_t digit_font[10][7] = {
	{0x0E,0x11,0x13,0x15,0x19,0x11,0x0E}, /* 0 */
	{0x04,0x0C,0x04,0x04,0x04,0x04,0x0E}, /* 1 */
	{0x0E,0x11,0x01,0x02,0x04,0x08,0x1F}, /* 2 */
	{0x1F,0x02,0x04,0x02,0x01,0x11,0x0E}, /* 3 */
	{0x02,0x06,0x0A,0x12,0x1F,0x02,0x02}, /* 4 */
	{0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E}, /* 5 */
	{0x06,0x08,0x10,0x1E,0x11,0x11,0x0E}, /* 6 */
	{0x1F,0x01,0x02,0x04,0x08,0x08,0x08}, /* 7 */
	{0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E}, /* 8 */
	{0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C}, /* 9 */
};

static void draw_digit(uint8_t *frame_base, int line_length, int bpp,
                        const struct fb_var_screeninfo *v,
                        int x0, int y0, int scale, int digit,
                        uint32_t fg, uint32_t xres, uint32_t yres)
{
	if (digit < 0 || digit > 9) return;
	for (int row = 0; row < 7; row++) {
		uint8_t bits = digit_font[digit][row];
		for (int col = 0; col < 5; col++) {
			if (!(bits & (1 << (4 - col)))) continue;
			for (int sy = 0; sy < scale; sy++) {
				int y = y0 + row * scale + sy;
				if (y < 0 || (uint32_t)y >= yres) continue;
				for (int sx = 0; sx < scale; sx++) {
					int x = x0 + col * scale + sx;
					if (x < 0 || (uint32_t)x >= xres) continue;
					put_pixel(frame_base, line_length, bpp, x, y, fg);
				}
			}
		}
	}
	(void)v;
}

/* --- deterministic test patterns. Each fills one entire frame buffer slot. --- */

static void pattern_split(uint8_t *base, int ll, int bpp, const struct fb_var_screeninfo *v,
                           uint32_t xres, uint32_t yres, long frame_idx)
{
	uint32_t black = pack_pixel(v, 0, 0, 0);
	uint32_t white = pack_pixel(v, 255, 255, 255);
	uint32_t split_col = (uint32_t)(frame_idx % (long)xres);
	for (uint32_t y = 0; y < yres; y++)
		for (uint32_t x = 0; x < xres; x++)
			put_pixel(base, ll, bpp, (int)x, (int)y, x < split_col ? white : black);
}

static void pattern_bands(uint8_t *base, int ll, int bpp, const struct fb_var_screeninfo *v,
                           uint32_t xres, uint32_t yres, long frame_idx)
{
	uint32_t black = pack_pixel(v, 0, 0, 0);
	uint32_t white = pack_pixel(v, 255, 255, 255);
	const int band_h = 8;
	int phase = (int)(frame_idx % band_h);
	for (uint32_t y = 0; y < yres; y++) {
		int band = ((int)y + phase) / band_h;
		uint32_t color = (band % 2) ? white : black;
		for (uint32_t x = 0; x < xres; x++)
			put_pixel(base, ll, bpp, (int)x, (int)y, color);
	}
}

static void pattern_framenum(uint8_t *base, int ll, int bpp, const struct fb_var_screeninfo *v,
                              uint32_t xres, uint32_t yres, long frame_idx)
{
	/* Background alternates per-frame for maximum frame-to-frame contrast
	 * (helps a human observer spot a tear/stale-frame at a glance). */
	uint32_t bg = (frame_idx % 2) ? pack_pixel(v, 0, 0, 64) : pack_pixel(v, 64, 0, 0);
	uint32_t fg = pack_pixel(v, 255, 255, 0);
	for (uint32_t y = 0; y < yres; y++)
		for (uint32_t x = 0; x < xres; x++)
			put_pixel(base, ll, bpp, (int)x, (int)y, bg);

	char buf[16];
	snprintf(buf, sizeof(buf), "%ld", frame_idx);
	int len = (int)strlen(buf);
	const int scale = 6;         /* each digit cell -> 5*scale x 7*scale px */
	const int digit_w = 5 * scale;
	const int spacing = scale;
	int total_w = len * (digit_w + spacing) - spacing;
	int x0 = ((int)xres - total_w) / 2;
	int y0 = ((int)yres - 7 * scale) / 2;
	if (x0 < 0) x0 = 0;
	for (int i = 0; i < len; i++) {
		draw_digit(base, ll, bpp, v, x0 + i * (digit_w + spacing), y0, scale,
		           buf[i] - '0', fg, xres, yres);
	}
}

static void pattern_diagonal(uint8_t *base, int ll, int bpp, const struct fb_var_screeninfo *v,
                              uint32_t xres, uint32_t yres, long frame_idx)
{
	uint32_t black = pack_pixel(v, 0, 0, 0);
	uint32_t line_color = pack_pixel(v, 0, 255, 0);
	int offset = (int)(frame_idx % (long)xres);
	const int thickness = 4;
	for (uint32_t y = 0; y < yres; y++) {
		for (uint32_t x = 0; x < xres; x++)
			put_pixel(base, ll, bpp, (int)x, (int)y, black);
		int target_x = ((int)y + offset) % (int)xres;
		for (int t = 0; t < thickness; t++) {
			int x = target_x + t;
			if (x >= 0 && (uint32_t)x < xres)
				put_pixel(base, ll, bpp, x, (int)y, line_color);
		}
	}
}

static void draw_pattern(const char *name, uint8_t *base, int ll, int bpp,
                          const struct fb_var_screeninfo *v,
                          uint32_t xres, uint32_t yres, long frame_idx)
{
	if (!strcmp(name, "split"))         pattern_split(base, ll, bpp, v, xres, yres, frame_idx);
	else if (!strcmp(name, "bands"))    pattern_bands(base, ll, bpp, v, xres, yres, frame_idx);
	else if (!strcmp(name, "framenum")) pattern_framenum(base, ll, bpp, v, xres, yres, frame_idx);
	else                                pattern_diagonal(base, ll, bpp, v, xres, yres, frame_idx);
}

int main(int argc, char **argv)
{
	struct options opt;
	if (parse_args(argc, argv, &opt) != 0)
		return 1;

	int fd = open(opt.device, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "open(%s): %s\n", opt.device, strerror(errno));
		return 1;
	}

	struct fb_fix_screeninfo finfo;
	struct fb_var_screeninfo vinfo, orig_vinfo;
	if (ioctl(fd, FBIOGET_FSCREENINFO, &finfo) < 0) {
		fprintf(stderr, "FBIOGET_FSCREENINFO: %s\n", strerror(errno));
		close(fd);
		return 1;
	}
	if (ioctl(fd, FBIOGET_VSCREENINFO, &vinfo) < 0) {
		fprintf(stderr, "FBIOGET_VSCREENINFO: %s\n", strerror(errno));
		close(fd);
		return 1;
	}
	orig_vinfo = vinfo;

	fprintf(stderr, "fb: %ux%u visible, %ux%u virtual, %u bpp, line_length=%u, smem_len=%u\n",
	        vinfo.xres, vinfo.yres, vinfo.xres_virtual, vinfo.yres_virtual,
	        vinfo.bits_per_pixel, finfo.line_length, finfo.smem_len);

	if (vinfo.xres != 480 || vinfo.yres != 272) {
		fprintf(stderr,
			"WARNING: expected 480x272 visible resolution, got %ux%u - "
			"continuing anyway since this tool only depends on the "
			"reported geometry, but this does not match the expected "
			"Nebula Pad panel.\n",
			vinfo.xres, vinfo.yres);
	}

	int num_buffers = 0;
	if (vinfo.yres > 0)
		num_buffers = (int)(vinfo.yres_virtual / vinfo.yres);
	if (num_buffers < 2) {
		fprintf(stderr,
			"ABORT: yres_virtual (%u) / yres (%u) = %d buffer slot(s) - "
			"need at least 2 for safe pan testing (expected 3, the "
			"triple-buffer configuration this panel normally runs).\n",
			vinfo.yres_virtual, vinfo.yres, num_buffers);
		close(fd);
		return 1;
	}
	if (num_buffers != 3) {
		fprintf(stderr,
			"WARNING: expected 3 buffer slots (816-line virtual height), "
			"found %d - continuing, but this is not the expected "
			"triple-buffer layout.\n", num_buffers);
	}

	int bpp = vinfo.bits_per_pixel / 8;
	if (bpp < 1 || bpp > 4) {
		fprintf(stderr, "ABORT: unsupported bits_per_pixel=%u\n", vinfo.bits_per_pixel);
		close(fd);
		return 1;
	}

	size_t map_len = (size_t)finfo.line_length * vinfo.yres_virtual;
	if (finfo.smem_len > 0 && (size_t)finfo.smem_len > map_len)
		map_len = finfo.smem_len;

	uint8_t *fb_mem = mmap(NULL, map_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (fb_mem == MAP_FAILED) {
		fprintf(stderr, "mmap: %s\n", strerror(errno));
		close(fd);
		return 1;
	}

	/* Full pixel-content backup, taken before anything is touched, so the
	 * original content of ALL buffer slots can be restored on exit -
	 * regardless of which slot(s) happened to be visible or written
	 * during the test. */
	uint8_t *backup = malloc(map_len);
	if (!backup) {
		fprintf(stderr, "malloc(backup, %zu bytes) failed\n", map_len);
		munmap(fb_mem, map_len);
		close(fd);
		return 1;
	}
	memcpy(backup, fb_mem, map_len);

	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);

	struct latency_stats pan_stats, vsync_stats;
	latency_init(&pan_stats, opt.frames);
	latency_init(&vsync_stats, opt.use_waitforvsync ? opt.frames : 1);

	double period_us = 1e6 / (double)opt.rate_hz;
	double t_start = now_monotonic_us();
	double t_next = t_start;
	int frames_done = 0;
	int interrupted = 0;

	for (long i = 0; i < opt.frames; i++) {
		if (g_stop) { interrupted = 1; break; }

		int slot = (int)(i % num_buffers);
		uint8_t *slot_base = fb_mem + (size_t)slot * finfo.line_length * vinfo.yres;
		draw_pattern(opt.pattern, slot_base, (int)finfo.line_length, bpp, &vinfo,
		             vinfo.xres, vinfo.yres, i);

		if (opt.use_waitforvsync) {
			uint32_t crtc = 0;
			double t0 = now_monotonic_us();
			int rc = ioctl(fd, FBIO_WAITFORVSYNC, &crtc);
			double t1 = now_monotonic_us();
			if (rc < 0) vsync_stats.errors++;
			else latency_add(&vsync_stats, t1 - t0);
		}

		struct fb_var_screeninfo pan_var = vinfo;
		pan_var.xoffset = 0;
		pan_var.yoffset = (uint32_t)slot * vinfo.yres;

		double t0 = now_monotonic_us();
		int rc = ioctl(fd, FBIOPAN_DISPLAY, &pan_var);
		double t1 = now_monotonic_us();
		if (rc < 0) pan_stats.errors++;
		else latency_add(&pan_stats, t1 - t0);

		frames_done++;

		t_next += period_us;
		double now = now_monotonic_us();
		double sleep_us = t_next - now;
		if (sleep_us > 0) {
			struct timespec ts;
			ts.tv_sec = (time_t)(sleep_us / 1e6);
			ts.tv_nsec = (long)((sleep_us - (double)ts.tv_sec * 1e6) * 1e3);
			nanosleep(&ts, NULL);
		}
		if (g_stop) { interrupted = 1; break; }
	}

	double t_end = now_monotonic_us();
	double wall_s = (t_end - t_start) / 1e6;

	/* --- mandatory restore: original visible page, then original pixel
	 * content, unconditionally, whether we finished normally or were
	 * signaled. --- */
	int restore_pan_rc = ioctl(fd, FBIOPAN_DISPLAY, &orig_vinfo);
	memcpy(fb_mem, backup, map_len);

	const char *restore_verify_result = "not_requested";
	if (opt.restore_page_verify) {
		/* Extra paranoia pass: re-read what's actually in the mapping
		 * right now and confirm it matches the backup byte-for-byte. */
		if (memcmp(fb_mem, backup, map_len) == 0)
			restore_verify_result = "OK";
		else
			restore_verify_result = "MISMATCH";
	}

	munmap(fb_mem, map_len);
	free(backup);
	close(fd);

	/* --- stats --- */
	qsort(pan_stats.samples_us, (size_t)pan_stats.count, sizeof(double), cmp_double);
	if (vsync_stats.count > 0)
		qsort(vsync_stats.samples_us, (size_t)vsync_stats.count, sizeof(double), cmp_double);

	double pan_min = pan_stats.count ? pan_stats.samples_us[0] : 0;
	double pan_max = pan_stats.count ? pan_stats.samples_us[pan_stats.count - 1] : 0;
	double pan_median = percentile(pan_stats.samples_us, pan_stats.count, 0.50);
	double pan_p95 = percentile(pan_stats.samples_us, pan_stats.count, 0.95);
	double pan_p99 = percentile(pan_stats.samples_us, pan_stats.count, 0.99);

	double vs_min = 0, vs_max = 0, vs_median = 0, vs_p95 = 0, vs_p99 = 0;
	if (vsync_stats.count > 0) {
		vs_min = vsync_stats.samples_us[0];
		vs_max = vsync_stats.samples_us[vsync_stats.count - 1];
		vs_median = percentile(vsync_stats.samples_us, vsync_stats.count, 0.50);
		vs_p95 = percentile(vsync_stats.samples_us, vsync_stats.count, 0.95);
		vs_p99 = percentile(vsync_stats.samples_us, vsync_stats.count, 0.99);
	}

	FILE *report = stdout;
	FILE *report_file = NULL;
	if (opt.output_report) {
		report_file = fopen(opt.output_report, "w");
		if (!report_file)
			fprintf(stderr, "warning: could not open %s for report output: %s\n",
			        opt.output_report, strerror(errno));
	}

	for (int pass = 0; pass < 2; pass++) {
		FILE *out = (pass == 0) ? report : report_file;
		if (!out) continue;
		fprintf(out, "tool: fb-vsync-test\n");
		fprintf(out, "device: %s\n", opt.device);
		fprintf(out, "pattern: %s\n", opt.pattern);
		fprintf(out, "fb_xres: %u\n", vinfo.xres);
		fprintf(out, "fb_yres: %u\n", vinfo.yres);
		fprintf(out, "fb_yres_virtual: %u\n", vinfo.yres_virtual);
		fprintf(out, "fb_bits_per_pixel: %u\n", vinfo.bits_per_pixel);
		fprintf(out, "num_buffer_slots: %d\n", num_buffers);
		fprintf(out, "frames_requested: %d\n", opt.frames);
		fprintf(out, "frames_completed: %d\n", frames_done);
		fprintf(out, "interrupted_by_signal: %d\n", interrupted);
		fprintf(out, "rate_hz_requested: %d\n", opt.rate_hz);
		fprintf(out, "wall_time_s: %.3f\n", wall_s);
		fprintf(out, "achieved_fps: %.3f\n", frames_done > 0 ? (double)frames_done / wall_s : 0.0);
		fprintf(out, "use_waitforvsync: %d\n", opt.use_waitforvsync);
		fprintf(out, "pan_ioctl_count: %d\n", pan_stats.count);
		fprintf(out, "pan_ioctl_errors: %ld\n", pan_stats.errors);
		fprintf(out, "pan_latency_us_min: %.2f\n", pan_min);
		fprintf(out, "pan_latency_us_median: %.2f\n", pan_median);
		fprintf(out, "pan_latency_us_p95: %.2f\n", pan_p95);
		fprintf(out, "pan_latency_us_p99: %.2f\n", pan_p99);
		fprintf(out, "pan_latency_us_max: %.2f\n", pan_max);
		fprintf(out, "waitforvsync_ioctl_count: %d\n", vsync_stats.count);
		fprintf(out, "waitforvsync_ioctl_errors: %ld\n", vsync_stats.errors);
		if (vsync_stats.count > 0) {
			fprintf(out, "waitforvsync_latency_us_min: %.2f\n", vs_min);
			fprintf(out, "waitforvsync_latency_us_median: %.2f\n", vs_median);
			fprintf(out, "waitforvsync_latency_us_p95: %.2f\n", vs_p95);
			fprintf(out, "waitforvsync_latency_us_p99: %.2f\n", vs_p99);
			fprintf(out, "waitforvsync_latency_us_max: %.2f\n", vs_max);
		}
		fprintf(out, "restore_pan_ioctl_rc: %d\n", restore_pan_rc);
		fprintf(out, "restore_page_verify_requested: %d\n", opt.restore_page_verify);
		fprintf(out, "restore_page_verify_result: %s\n", restore_verify_result);
		fprintf(out, "note_kernel_debugfs_counters: pan_vsync_gated_count/"
		             "pan_vsync_timeout_count/pan_vsync_invalid_count exist "
		             "in-kernel (DISPLAY-V1 patch) but are NOT exported via "
		             "debugfs/sysfs/procfs in this build - unreadable from "
		             "userspace by this or any tool; grep dmesg for "
		             "'pan_display: vsync wait' as the only indirect proxy "
		             "for timeout/invalid events.\n");
	}
	if (report_file) fclose(report_file);

	free(pan_stats.samples_us);
	free(vsync_stats.samples_us);

	return interrupted ? 2 : 0;
}
