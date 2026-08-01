# fb-vsync-test

Standalone framebuffer pan/vsync diagnostic tool for the DISPLAY-V1 live
qualification mission (NebulaOS, Ender-3 V3 KE + Nebula Pad, Ingenic
X2000/Halley5 SoC). Exercises `FBIOPAN_DISPLAY` (and, optionally,
`FBIO_WAITFORVSYNC`) against the real `/dev/fb0` device on a fixed cadence,
for a bounded number of frames, measuring ioctl latency directly. It does
**not** modify panel timing, pixel format, or any kernel/driver source - it
only calls existing, already-supported fbdev ioctls from userspace, exactly
the way any fbdev client (including GuppyScreen) already does.

See `fb-vsync-test.c`'s own top-of-file comment for the full design
rationale, including an important caveat found while writing this tool: the
DISPLAY-V1 kernel patch (`scripts/build/patches/display-vsync-gate.patch`)
adds three atomic diagnostic counters (`pan_vsync_gated_count`,
`pan_vsync_timeout_count`, `pan_vsync_invalid_count`) to the kernel's
internal `struct ingenicfb_device`, but never exports them anywhere
userspace can read - no debugfs node, no sysfs attribute, no procfs entry
exists for them in this kernel build (confirmed both by reading the patch
and live, via `find /sys/kernel/debug -iname '*ingenicfb*' -o -iname
'*dpu*'` returning nothing on the deployed DISPLAY-V1 image). This tool
cannot read those counters either - nothing in userspace can with this
kernel as built. The only indirect, partial proxy is the kernel's own
`printk_ratelimit()`'d `dev_warn()` that fires when a real
`pan_vsync_timeout_count` increment happens ("`pan_display: vsync wait
timed out/interrupted, applying frame N immediately`") - grep dmesg for
`"pan_display: vsync wait"` separately if that signal is needed. This
tool's own `--output-report` reflects that limitation directly.

## Build (cross-compile for the printer's MIPS target)

```sh
vendor/buildroot-x2000/output/host/bin/mipsel-buildroot-linux-gnu-gcc \
    -O2 -Wall -Wextra -o tools/fb-vsync-test/fb-vsync-test \
    tools/fb-vsync-test/fb-vsync-test.c
```

Requires the project's own Buildroot toolchain to already be built (i.e.
after running the normal `scripts/build/*.sh` pipeline at least once, or
having `vendor/buildroot-x2000/output/host/bin/` populated some other way).
Produces a small (~a few hundred KB, dynamically linked) MIPS32 executable.
Not committed to the repo - only the source and this README are tracked;
rebuild it locally whenever it's needed.

## Deploy and run (on the device)

The binary is small - `/tmp` on-device is fine for it (unlike a
~100MB rootfs transfer, which needs `/usr/data/<staging-dir>/` instead per
this project's own SSH/device-access conventions).

```sh
scp -O tools/fb-vsync-test/fb-vsync-test root@<printer-ip>:/tmp/
ssh root@<printer-ip> '/tmp/fb-vsync-test --frames 500 --rate 30 --pattern split \
    --output-report /tmp/fb-vsync-test-report.txt'
```

## Options

| Flag | Meaning |
|---|---|
| `--frames N` | number of pan cycles to run (default 500) |
| `--rate HZ` | target pan rate in Hz (default 30) |
| `--pattern NAME` | `split` \| `bands` \| `framenum` \| `diagonal` (default `split`) |
| `--use-waitforvsync` | explicitly call `FBIO_WAITFORVSYNC` before each pan, for an explicit-wait vs. auto-gated comparison |
| `--restore-page` | after the tool's own *mandatory* restore (see below), re-read the framebuffer and byte-compare it against a pre-test backup, reporting any mismatch - an extra verification pass, not what makes restoration happen |
| `--output-report PATH` | write a plain `key: value` summary report to `PATH` (also always printed to stdout) |
| `--device PATH` | framebuffer device (default `/dev/fb0`) |

Exit status: `0` on a clean, fully-completed run; `1` on a setup/usage
error; `2` if interrupted by a signal (restore still happens first).

## Safety behavior (always on, not flag-gated)

Before touching anything, the tool backs up the *entire* mapped
framebuffer (all buffer slots, not just the currently-visible one) and
records the original `fb_var_screeninfo` (including `xoffset`/`yoffset`).
On any exit path - normal completion, or `SIGINT`/`SIGTERM` - it restores
the original visible page via `FBIOPAN_DISPLAY` and copies the original
pixel content back into every buffer slot, unconditionally. `SIGINT`/
`SIGTERM` handlers only set a flag (async-signal-safe); the actual restore
logic always runs in normal (non-handler) context after the main loop
breaks.

## Test patterns

- `split` - a vertical high-contrast black/white split whose column
  position advances one pixel per frame.
- `bands` - alternating black/white horizontal bands whose phase shifts
  by one row per frame.
- `framenum` - the current frame number rendered large (tiny embedded 5x7
  block font, scaled up) against a background that alternates color every
  frame for maximum frame-to-frame contrast.
- `diagonal` - a moving diagonal high-contrast line.

All patterns are intentionally simple and deterministic - a human watching
the live screen (or comparing before/after captures) should be able to
immediately recognize a stale/torn/repeated frame.
