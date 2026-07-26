# NebulaOS Memory Resilience

**Status:** In progress — Memory Resilience Gate sub-mission, required before Phase 7 (mutable application installs) resumes.

---

## 1. Checkpoint (recorded before any kernel change)

- **Firmware repo HEAD:** `58a0ba5cdab669138c5c76ffade84139ed146398` (branch `master`, clean except the pre-existing documented untracked `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md`).
- **NebulaOS Klipper fork:** `coreflake1/NebulaOS-klipper`, branch `nebulaos`, commit `b3d5ab2b9484f1558586c3a2ea43d46ff9a473a7` (ancestry: `pellcorp/klipper@386fde4` + one commit, the klippy_extras addition). Local `vendor/klipper` checkout clean except a compiled `.so` build byproduct (not tracked).
- **Running device (192.168.0.146):** kernel `6.6.18-rt23`, OTA marker `ota:kernel2` (custom slot active), `klippy_state: ready`, `klippy_connected: true`.
- **Namespace state:** `/usr/data/nebulaos/apps/{klipper,moonraker,mainsail}` all present and empty (the earlier stuck `.partial` directories were cleaned up); `activation-state.json` shows `klipper`/`moonraker`/`mainsail` = `immutable:incomplete_or_invalid`, `printer_data`/`shared_gcode` = `persistent`. This exact state is the baseline the memory-resilience work must not regress.
- **OOM evidence (from `dmesg`, captured before this sub-mission began):**
  ```
  oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),task=git,pid=3277,uid=0
  Out of memory: Killed process 3277 (git) total-vm:56472kB, anon-rss:37480kB, file-rss:0kB, shmem-rss:9728kB, UID:0 pgtables:76kB oom_score_adj:0
  oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),task=git,pid=3477,uid=0
  Out of memory: Killed process 3477 (git) total-vm:55516kB, anon-rss:36540kB, file-rss:128kB, shmem-rss:9728kB, UID:0 pgtables:68kB oom_score_adj:0
  ```
  First event (pid 3277) occurred during the real boot's own `S03nebulaos-factory-seed` run; second (pid 3477) during a manual reproduction of the same `git clone` command afterward, run interactively for diagnosis (not part of any production path).
- **Root cause confirmed:** `swapon /usr/data/swap` → `Function not implemented`; `/proc/swaps` does not exist at all — `CONFIG_SWAP` is not compiled into this kernel. Stock's own pre-existing 128MB swap file at `/usr/data/swap` (same shared partition) is present but inert for this reason.
- **Total RAM:** 208MB (`free -m`), no swap.

Frozen functionality reconfirmed intact at this checkpoint: webcam (real snapshot captured), USB (`sda` mounted under `/opt/printer_data/gcodes/USB`), printer safety (standby, unhomed), `S99confirm-good`/OTA marker behavior.

## 2. Kernel Kconfig investigation (confirmed against real kernel source, not guessed)

Checked directly against `vendor/x2000_kernel_6.6/kernel/kernel-6.6`:

| Symbol | Location | Type/dependencies | Prior state |
|---|---|---|---|
| `CONFIG_SWAP` | `mm/Kconfig:15` | `menuconfig SWAP ... depends on MMU && BLOCK && !ARCH_NO_SWAP` | `# CONFIG_SWAP is not set`. `CONFIG_MMU=y` and `CONFIG_BLOCK=y` already satisfied; `ARCH_NO_SWAP` not defined for this arch (so `!ARCH_NO_SWAP` is true) |
| `CONFIG_ZRAM` | `drivers/block/zram/Kconfig` | `tristate ... depends on BLOCK && SYSFS && MMU`, `depends on CRYPTO_LZO \|\| CRYPTO_ZSTD \|\| CRYPTO_LZ4 \|\| CRYPTO_LZ4HC \|\| CRYPTO_842`, `select ZSMALLOC` | `# CONFIG_ZRAM is not set` |
| `CONFIG_CRYPTO_LZ4` | `crypto/Kconfig:1197` | `tristate ... select CRYPTO_ALGAPI/CRYPTO_ACOMP2/LZ4_COMPRESS/LZ4_DECOMPRESS` (all pure C, no MIPS-specific assembly to verify) | `# CONFIG_CRYPTO_LZ4 is not set`. `CONFIG_CRYPTO_LZO=y` was already enabled (used elsewhere), confirming a working fallback compressor choice already exists if LZ4 is ever found unsuitable |
| `CONFIG_ZSMALLOC` | `mm/Kconfig:190` | `tristate ... depends on MMU` (auto-`select`ed by `ZRAM`) | not set, no extra dependency beyond already-satisfied `MMU` |
| `CONFIG_IKCONFIG`/`CONFIG_IKCONFIG_PROC` | standard kernel option | live `/proc/config.gz` inspection | not set |

**Where the fix actually lives**: `artifacts/buildroot-halley5-v30-image/halley5-openke-fragment.config` — confirmed via `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES` in `buildroot.config` that this fragment file (not the `kernel.config` snapshot in the same artifacts directory, which `05-final-build.sh` only ever *copies from* the real built `.config` as a post-build record) is the actual input Buildroot merges onto the kernel's base defconfig. Added: `CONFIG_SWAP=y`, `CONFIG_ZRAM=y` (built directly into the kernel, not `=m` — no dependency on module-loading infrastructure at the very early boot point `S00zram-swap` needs to run), `CONFIG_CRYPTO_LZ4=y`, `CONFIG_ZRAM_DEF_COMP_LZ4=y`, `CONFIG_IKCONFIG=y`, `CONFIG_IKCONFIG_PROC=y`.

**BusyBox userspace tools already present, confirmed live — not assumed**: `swapon: unrecognized option '--show'` (from the earlier live diagnosis) already proved the `swapon` applet itself works and is compiled in; a direct check of `vendor/buildroot-x2000/package/busybox/busybox.config` confirms `CONFIG_MKSWAP=y`, `CONFIG_SWAPON=y`, `CONFIG_SWAPOFF=y`, `CONFIG_FREE=y` were already all enabled by default in this project's Buildroot BusyBox config — the original failure (`Function not implemented`) was conclusively the kernel's missing `CONFIG_SWAP`, not a missing userspace tool. Confirmed exact installed paths live: `/sbin/mkswap`, `/sbin/swapon`, `/sbin/swapoff` (all BusyBox multi-call symlinks), `/usr/bin/free`.

## 3. Implementation

### 3.1 Primary layer: zram (`S00zram-swap`)

New init script, numbered to run immediately after `S00revert-safety` and before `S01persistent-datastore` (no dependency on `/usr/data` being mounted at all — zram is pure RAM). Idempotent (checks `/proc/swaps` and `disksize` before acting), never blocks boot on failure (falls through with a logged warning if `/dev/zram0`/sysfs isn't present, or if any step fails). Starting qualification parameters: **128MiB logical size, LZ4 compressor, priority 100**. Also applies conservative sysctl policy here (`vm.swappiness=10`, `vm.page-cluster=0`) — reasoned, not copied from a desktop/server guide: this is a PREEMPT_RT motion-control system, so favor keeping pages resident and avoid page-cluster's disk-seek-oriented multi-page I/O bursts (wrong model for both zram and eMMC-backed swap).

### 3.2 Fallback layer: NebulaOS-owned disk swap (`S03nebulaos-diskswap`)

New init script, runs after `S02nebulaos-namespace` (needs `/usr/data/nebulaos` to exist) and before `S04nebulaos-factory-seed` (the memory-heavy step being protected). Owns `/usr/data/nebulaos/system/swapfile` — **not** the stock swap file at `/usr/data/swap` (present but deliberately unused, per this mission's own direction not to depend on a stock-owned resource; its location/128MB size is recorded here for comparison only, not reuse). Starting qualification parameters: **128MiB, priority 10** (lower than zram's 100, so zram is always preferred first). Allocated via a bounded `dd if=/dev/zero ... conv=fsync` (never sparse, never `truncate`/`fallocate`, per this mission's explicit preference for deterministic, verifiable allocation on this exact ext4/eMMC setup), `chmod 600`, validated (exact size + `0:0` ownership + `-rw-------` permissions) before ever being trusted as already-valid on a later boot, recreated from scratch if invalid, never truncated once genuinely active (guarded by the `/proc/swaps` idempotency check). Tolerates `/usr/data` being unmounted/read-only by skipping cleanly rather than failing boot.

Both init scripts' logic (ownership checks, ordering, idempotency) follow the same patterns already established and live-tested in `S04nebulaos-namespace`/`S05nebulaos-activate` (BusyBox `ls -ldn`+`awk` for numeric ownership, not `stat`, per that earlier live finding).

### 3.3 OOM priority table (applied via `oom_score_adj` after each daemon starts)

| Tier | Process | `oom_score_adj` | Reasoning |
|---|---|---|---|
| Most protected | Klipper (`S55klipper`) | **-700** | MCU/motion-control communication; deliberately not -1000 per this mission's own instruction — the kernel must retain a sensible victim if memory is truly exhausted, not be forced to pick the one process that must never die |
| Strongly protected | *(rollback/activation supervisor — not yet a persistent daemon; applies once Phase 8's rollback orchestration runs as one)* | not yet applicable | recorded here as a placeholder for Phase 8 |
| Moderately protected | Moonraker (`S56moonraker`) | **-400** | coordinates updates/rollback, must outlive GuppyScreen/webcam/update-helpers under pressure, but is less critical than Klipper itself |
| Normal/expendable | GuppyScreen (`S58guppyscreen`) | **0** | explicit kernel-default value, written anyway so the full table is auditable in one place rather than "whatever the kernel happened to default to" |
| More expendable | webcam/ustreamer (`S50webcam`) | **300** | optional media, never printer-critical |
| Most expendable | Factory-seed/update helpers (`S04nebulaos-factory-seed`, applied to the script's own shell so git/cp children inherit it) | **500** | exactly the tier that should be picked first — real git processes were the ones OOM-killed in the original incident; this makes that outcome intentional/designed rather than accidental |

Applied directly after `start-stop-daemon` returns, reading the daemon's own PID back from its pidfile (`echo <value> > /proc/$PID/oom_score_adj`) — survives normal service restarts since each restart re-applies it in the same `start()` function.

### 3.4 Maintenance safety gate

`S04nebulaos-factory-seed`'s `maintenance_gate_ok()` (read-only checks only) blocks heavy seeding when: a print is active or paused (`/printer/objects/query?print_stats`, matching this project's own established live-JSON-format discipline — Moonraker's real output has no space after `:`); an update-transaction lock directory (`updates/locks`) is non-empty; or — the gate directly closing the original incident — **no memory-resilience swap is active at all** (neither `/dev/zram0` nor the NebulaOS disk swap file appear in `/proc/swaps`). A blocked run simply skips and logs, retrying on the next boot; it never partially proceeds.

### 3.5 Expendable-service pausing

`S04nebulaos-factory-seed` stops `S58guppyscreen`/`S50webcam` before seeding and restarts them after (success or failure path both reach `resume_expendable_services`). On a normal first boot this is a genuine no-op (`S04` runs at init position 4, well before `S50`/`S58` have ever started) — kept anyway for a later re-invocation (namespace-recovery-after-normal-boot, or Phase 7 reusing this same seeding pattern), per this mission's own explicit instruction not to treat "stopping services alone" as sufficient, but still wanting the extra margin when it *is* meaningful.

### 3.6 Serialization

`start()` seeds Klipper, then Moonraker, then Mainsail strictly in sequence (never concurrently), with `sync` after each git operation and once more at the end — matching this mission's own required "prepare → verify → release → next component" shape given this project's synchronous (non-backgrounded) init-script execution model.

### 3.7 Low-memory git behavior

`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_N`/`GIT_CONFIG_VALUE_N` (a documented git ≥2.31 mechanism, confirmed available — device git is 2.42.1) set for every `git clone` in `S04nebulaos-factory-seed`: `pack.threads=1` (single-threaded delta/pack work — directly reduces index-pack's peak RSS, the exact operation that was OOM-killed), `core.packedGitWindowSize=1m`, `core.deltaBaseCacheLimit=8m` (both bound how much of the pack this process maps/caches at once), `gc.auto=0` (no incidental background gc competing for memory immediately after a clone). Not yet measured against the alternative the mission also raises (a prepared archive with `.git` metadata instead of invoking `git clone` at all) — deferred pending the live re-test in Section 5, since the combination of swap + these settings may already resolve the original failure without needing a different seed format.

## 4. Static verification (`06-verify.sh` extended)

Added `check_builtin CONFIG_SWAP`/`CONFIG_ZRAM`/`CONFIG_CRYPTO_LZ4` (checked against the real built kernel `.config`, the same mechanism already used for other built-in-driver assertions — catches this exact class of regression, which a rootfs-file-only check could never see) and `check` calls for `/sbin/{mkswap,swapon,swapoff}`, `/usr/bin/free`, both new init scripts, and the seed bundles/manifest.

## 5. Live qualification

(Recorded after the next build+flash+test cycle.)
