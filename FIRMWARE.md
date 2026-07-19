# Building our own firmware package (OS included) - full analysis + gameplan

Supersedes `NETWORKING.md` §6's shorter answer to the same question, after the user pointed at two
things that materially change the picture: (1) the real OS running here (corrected below), and
(2) official Ingenic vendor documentation for this exact chip/kernel generation already sitting in
`~/Documents/guppyscreen/docs hw/` - unreviewed until this pass. Everything below is read-only
findings (device queried live, idle, no writes) plus documentation review - **nothing has been
flashed, built, or changed on the device.**

## 1. Correcting the OS assumption - it's Buildroot, not Ubuntu

Checked directly on the live device: `/etc/os-release` reads:

```
NAME=Buildroot
VERSION=2020.02.1-g1ad352d2bd-dirty
ID=buildroot
VERSION_ID=2020.02.1
PRETTY_NAME="Buildroot 2020.02.1"
```

This is [Buildroot](https://buildroot.org/), not Ubuntu - a lightweight, source-based embedded
Linux build system, not a general-purpose distro. This is actually *better* news for "more
lightweight, more up to date" than Ubuntu would have been: Buildroot is already about as minimal as
it gets, extremely well-documented, and - critically - it's confirmed to be the *exact* system
already in use here (see §3), so building our own updated image means using the same, familiar
tool the vendor already used, not introducing a new one.

## 2. Exact hardware + reference platform, now fully mapped

- **SoC**: Ingenic X2000 (XBurst II, MIPS32R2) - confirmed multiple ways: `/proc/cpuinfo`
  (`system type: xburst2-based`), and now also directly from the live device tree:
  `/proc/device-tree/compatible` = `ingenic,x2000_module_base` + `ingenic,x2000`.
- **Reference board family**: Ingenic's own "Halley5" X2000 evaluation board (see §3) - Creality's
  Nebula Pad is a customized board built on this reference design, standard practice for these
  vendor SoCs.
- **Storage layout, fully mapped this session** (`/proc/partitions` + `mount`, all read-only):
  ```
  mmcblk0p1  1 MiB    (likely xboot/bootloader - small, matches ref. table's "xboot" role)
  mmcblk0p2  1 MiB    (likely a paired/backup slot for p1)
  mmcblk0p3  4 MiB    (likely kernel/boot - paired with p4)
  mmcblk0p4  4 MiB    (likely kernel/boot backup, or dtb)
  mmcblk0p5  8 MiB    (likely dtb or another paired slot)
  mmcblk0p6  8 MiB    (paired with p5)
  mmcblk0p7  500 MiB  (candidate: squashfs rootfs image, "/rom")
  mmcblk0p8  500 MiB  (candidate: paired/backup rootfs slot - real A/B redundancy)
  mmcblk0p9  300 MiB  ext4, mounted at /overlay - the writable overlay layer (see below)
  mmcblk0p10 ~6 GiB   ext4, mounted at /usr/data - the actual persistent user-data partition
                       (printer_data, Klipper config, our own OpenKE install all live here)
  ```
  Exact p1-p8 role assignment is inferred from size/position matching the Halley5 reference
  `partitions.tab` layout (§3), not yet confirmed byte-for-byte - a real next step, not a risk in
  itself (read-only to confirm).
- **Root filesystem architecture - genuinely reassuring for experimentation risk**: `mount` shows
  `/dev/root` mounted read-only as squashfs at `/rom`, with `mmcblk0p9` (ext4) providing a writable
  `overlayfs` upper layer mounted as `/` itself. This is a standard, safe embedded-Linux pattern:
  **the base OS image never gets written to directly during normal operation** - all runtime
  changes land in the overlay, and `/usr/data` (the big partition) is separate again. This means
  many kinds of experimentation are recoverable by design, not just by luck.

## 3. The official Ingenic documentation already in `docs hw/` - previously unreviewed

Two key resources sitting in `~/Documents/guppyscreen/docs hw/`, not looked at until this pass:

- **`02-Halley5_Linux4.4内核开发手册.pdf`** ("Halley5 Linux 4.4 Kernel Development Manual", Ingenic
  Semiconductor, v2.0, 2021) - 189 pages, **real, detailed, engineering-grade vendor documentation**
  for the exact kernel generation this device runs (`vermagic=4.4.94`) on the exact reference board
  family (Halley5, X2000). Confirmed by reading it directly (not just skimming):
  - Real kernel defconfig list including `halley5_v20_linux_msc_defconfig` (eMMC/SD boot - matches
    this device exactly) and, importantly, **`halley5_v20_linux_sfc_nand_recovery_defconfig`
    ("used for OTA-upgrade recovery config")** - recovery is a standard, designed-in part of this
    platform, not something uniquely locked down by Creality. A reference partition table example
    in the same manual includes an explicit `recovery` partition alongside `xboot`/`boot`/
    `pretest`/`reserved`.
  - Concrete, actionable instructions for modifying and reflashing the device tree (`make
    kernel-dtbs`, exact output paths, exact Kconfig symbol `INGENIC_BUILTIN_DTB`, exact flash
    offsets for eMMC: dtb at `0xb00000`).
  - A full chapter (28) on the SoC's built-in Gigabit Ethernet MAC (GMAC/RGMII) - not directly
    usable without hardware (the Nebula Pad doesn't appear to have a populated ethernet PHY), but
    confirms the SoC itself has real wired-ethernet silicon.
  - Kconfig-level detail for the USB host/device stack (exact symbol names, e.g. `VFAT_FS`,
    default USB host support = mass storage/camera/HID only - **matches exactly what we found live
    on the device this session**, strong evidence this manual really does describe this device's
    actual configuration, not just a generic relative).
  - Confirms the rootfs build system is **Buildroot** (`buildroot/dl/...`,
    `buildroot/package/ingenic/...` paths throughout) - matches §1's live confirmation exactly.
- **`X2000_PM_20220909.pdf`** - the X2000 chip Programming Manual (43MB, official chip-level
  reference) - not yet reviewed in depth this session, real next step (register-level detail,
  likely including boot-mode/strap-pin selection, useful for understanding recovery-mode entry).
- **`ingenic-linux-docs-ingenic-master/`** - a full clone of Ingenic's public docs repo, mostly
  covering their *newer* kernel-5.10-based SDKs (X2000/X1600/X2500/X26XX). One concrete, valuable
  find inside it: a kernel-5.10 X2000 SDK release note documents a **public FTP server with public
  credentials** for their official flashing tool:
  ```
  ftp://ftp.ingenic.com.cn/DevSupport/Tools/USBBurner/cloner-2.5.54-{ubuntu,windows}_alpha.tar.gz
  account: ingenic_public   password: BFdg2f9B12
  ```
  Real, vendor-published, explicitly public credentials (not a leak) - genuine evidence the tooling
  ecosystem for this chip family is realistically obtainable, not something to reverse-engineer
  blind. Also documents the exact cross-compiler used (`gcc 7.2.0, Ingenic MIPS LINUX Tools
  R5.2.2`) for the newer SDK generation - useful reference even though our device is on the older
  Linux-4.4-based Halley5 SDK, not this one.

**Update - this question is now answered, see §5a below.** The kernel source itself (not just the
manual) turned out to be publicly obtainable, exact-version-matching, and is now cloned locally.

## 4a. Phase 0 results (2026-07-18) - the kernel source match, found and cloned

GitHub code search for the exact strings found live on this device (`x2000_module_base`,
`halley5_v20`) turned up two public repos carrying a full Ingenic X2000/Halley5 kernel tree:
[`Jubian540/x2000_kernel`](https://github.com/Jubian540/x2000_kernel) and
[`bakueikozo/atomkernel4`](https://github.com/bakueikozo/atomkernel4), plus a matching Buildroot
config: [`lone0/buildroot-x2000`](https://github.com/lone0/buildroot-x2000) ("Buildroot for
Halley5, the evaluation board for Ingenic X2000 SoC"). All shallow-cloned into this workspace's new
`vendor/` directory (`vendor/x2000_kernel`, `vendor/buildroot-x2000` - gitignored-worthy, large,
not meant to be committed wholesale; see note at the end of this section).

Confirmed, not assumed:

- **Exact kernel version match**: `vendor/x2000_kernel/Makefile` -> `VERSION = 4, PATCHLEVEL = 4,
  SUBLEVEL = 94` - this is genuinely `4.4.94`, byte-identical to this device's own
  `vermagic=4.4.94` extracted back in `NETWORKING.md` §2. Not "close enough" - exact.
  Codename: "Blurry Fish Butt" (the real, if silly, upstream 4.4 release codename).
  - **This is a real find - but likely not, or not purely, a redistributable one.** No provenance
    is documented in either repo (no README noting how it was obtained); given the file layout
    (full stock Linux tree plus vendor board files, no visible license/attribution changes) this
    reads as a reupload of an internal Ingenic SDK drop, the kind that circulates through Chinese
    hardware-hacking channels (a pattern one of these accounts explicitly names elsewhere: "reupload
    from gittea/baidu cloud" on a related repo). The kernel itself is GPLv2 (inherently
    redistributable, and Ingenic's own patches on top inherit that), but treat this as an unofficial
    community mirror, not an Ingenic-sanctioned release - keep it local/reference-only for now,
    don't publish or redistribute further without thinking about it properly first.
- **Board files match exactly**: `arch/mips/boot/dts/ingenic/x2000_module_base.dts`,
  `x2000_module_base_mmc0.dts`, `x2000_module_base_mmc2.dts` (matching this device's live
  `/proc/device-tree/compatible` = `ingenic,x2000_module_base` exactly) and
  `arch/mips/configs/halley5_v20_linux_msc_defconfig` /
  `halley5_v20_linux_sfc_nand_recovery_defconfig` (matching the kernel manual's defconfig table
  exactly, §3 above) both exist in this tree.
- **The AX88179 driver (the whole point of track 2) is already in this exact source tree**:
  `drivers/net/usb/ax88179_178a.c`, `usbnet.c`, `asix_common.c`, `asix_devices.c` all present.
  Confirmed **not enabled** in the closest-matching defconfig
  (`x2000_module_base_linux_mmc2_defconfig`: `# CONFIG_USB_USBNET is not set`). Exact Kconfig
  symbol confirmed from `drivers/net/usb/Kconfig`: **`CONFIG_USB_NET_AX88179_178A`** ("ASIX
  AX88179/178A USB 3.0/2.0 to Gigabit Ethernet" - literally names our exact adapter). This turns
  track 2 from "build a driver against a hoped-for-compatible source" into "flip a defconfig option
  and rebuild" - about as tractable as this kind of problem gets.
- **`lone0/buildroot-x2000` has a real `board/halley5/` directory and `configs/halley5_x2000_defconfig`**
  - a genuine, matching Buildroot config for this exact reference board (though it targets a plain
  rootfs, not squashfs+overlay - `BR2_TARGET_ROOTFS_SQUASHFS` is unset there, so Creality's
  read-only-squashfs-plus-overlay scheme, §2, is their own customization on top of the vendor
  reference, not something this base config already does).
- **Live device tree spot-check**: `/proc/device-tree/` on the real printer lists real, plausible
  Ingenic X2000 nodes (`ahb0`/`ahb1`/`ahb2`, `apb`, `cpufreq-dt`, `interrupt-controller`,
  `reserved-memory`, `rtcclk`, `spi_gpio`) - consistent with a real X2000 device tree, not yet
  diffed node-by-node against the reference `.dts` (real remaining task, not done this pass).

**What this changes**: Phase 0's single biggest open question (matching kernel source) is answered.
Phase 1 (build the AX88179 module, test via `insmod`) is now realistic to actually attempt, not
just plan - the source, the exact symbol, and the exact vermagic target are all in hand.

## 4b. Phase 0 results, continued - real GPT partition table + silicon-level recovery mode

Two more Phase 0 items done properly rather than inferred from sizes.

**GPT partition table, parsed byte-for-byte (read-only `dd` of the first 68 sectors of
`/dev/mmcblk0`, decoded locally with a small Python script against the real GPT spec - not
guessed from partition sizes alone as in §2):**

```
p1  ota           1 MiB     (OTA update state/metadata)
p2  sn_mac        1 MiB     (serial number / MAC provisioning data)
p3  rtos          4 MiB   \  real A/B pair - firmware for the X2000's auxiliary
p4  rtos2         4 MiB   /  XBurst0 real-time core (separate from the main Linux cores)
p5  kernel        8 MiB   \  real A/B pair - the Linux kernel image (uImage)
p6  kernel2       8 MiB   /
p7  rootfs        500 MiB \  real A/B pair - the squashfs root filesystem image
p8  rootfs2       500 MiB /
p9  rootfs_data   300 MiB    writable ext4 overlay (confirmed via mount, §2)
p10 userdata      6130 MiB   /usr/data (confirmed via mount, §2)
```

This is a **real, genuine A/B update-safety design** - not inferred, confirmed by name. Better
still, `/proc/cmdline` on the live device reads `root=/dev/mmcblk0p7` - **`p7`/`rootfs` is the
currently active slot, meaning `p8`/`rootfs2` (and very likely `p6`/`kernel2`) are spare, currently
unused partitions.** This is about as safe a concrete experimentation target as this device could
offer: a custom kernel/rootfs could go on the *B* slot entirely, with the *A* slot (currently
booting, working) completely untouched throughout Phase 1/2 testing.

**Silicon-level recovery mode - resolves the one risk flagged as unconfirmed in §2/§4:**
`X2000_PM_20220909.pdf` chapter 42 ("XBurst Boot ROM Specification") documents this precisely.
The X2000 has an internal 16KB mask ROM that always runs first after reset, before anything on
the eMMC is even read, and its behavior is selected by three physical strap pins:

```
BOOT_SEL0 = pin PE25, BOOT_SEL1 = pin PE26, BOOT_SEL2 = pin PE27

boot_sel[2:0]   Boot source
000             SPI flash @ 3.3V
001             eMMC/SD (MSC2 @ 3.3V)
010 or 110      USB (recovery/download mode)
011             NOR flash
100             SPI flash @ 1.8V
101             eMMC/SD (MSC0)
111             eMMC/SD (MSC2 @ 1.8V)
```

With `boot_sel[2:0]` strapped to `010`/`110`, **the mask ROM itself switches to USB download mode
and waits for a host PC** - a documented, complete protocol (USB VID:PID `0xa108:0xEAEF` - `0xa108`
is Ingenic's own vendor ID, which not coincidentally also shows up elsewhere on this exact board's
`lsusb` output already, `NETWORKING.md` §1 context), 6 vendor control requests
(`VR_GET_CPU_INFO`/`VR_SET_DATA_ADDRESS`/`VR_SET_DATA_LENGTH`/`VR_FLUSH_CACHES`/
`VR_PROGRAM_START1`/`VR_PROGRAM_START2`), used to load a small SPL program into internal SRAM and
run it. **This recovery path lives entirely in mask ROM - it cannot be bricked by any software
mistake, corrupted bootloader, or bad flash write, because it runs before any of that is ever
read.** This is the best possible category of recovery mechanism, and it's exactly what the
"cloner" flashing tool (`NETWORKING.md`/`FIRMWARE.md` §3) talks to.

**One real unknown left, and it's a hardware question, not a software one**: whether `PE25`/`PE26`/
`PE27` are actually broken out to an accessible pad/test-point/jumper on the Nebula Pad's specific
PCB, or whether reaching them would need probing the chip package directly. Not answerable via SSH
- would need physical inspection of the board (or Creality/community teardown photos) whenever a
real flash is actually attempted. Everything else about the recovery path is now fully documented
and doesn't need further investigation.

## 4. Revised difficulty assessment

This materially changes the earlier (`NETWORKING.md` §6) assessment - not because the work
shrinks to zero, but because several previously-unknown risk factors are now resolved in our
favor:

- Recovery is a real, standard, vendor-designed feature of this exact platform (§3), not an
  unknown - meaningfully reduces "irrecoverable brick" risk for kernel/rootfs-level work.
- The rootfs build system is the one we'd have chosen anyway (Buildroot) and is already confirmed
  in use, not something to introduce fresh.
- We have genuine, detailed, engineering-grade vendor documentation for the exact kernel
  generation and reference board family this device is built from - not a generic "some MIPS SoC"
  situation, a specific, well-documented one.
- The base OS image is read-only with an overlay (§2) - normal experimentation is naturally
  contained.

What's still genuinely hard: doing real board-level kernel *work* (not just adding a module) means
working carefully through 189 pages of real, detailed vendor documentation plus whatever
Creality-specific customization exists on top of the Halley5 reference (touch controller specifics,
the exact WiFi/BT combo chip integration, camera driver specifics) - real work, just no longer
*blind* work, and no longer blocked on "do we even have matching source" (§4a - resolved).

## 5. Gameplan (Phase 0 essentially complete - rest pending explicit go-ahead)

**Phase 0 - research/acquisition, zero device risk (all local/network, not touching the printer)**
1. ~~Try to obtain the actual Halley5 Linux-4.4 kernel source tree~~ **DONE (§4a)** - found and
   cloned locally (`vendor/x2000_kernel`, `vendor/buildroot-x2000`), exact version match confirmed.
2. ~~Review `X2000_PM_20220909.pdf` for boot-mode/recovery-entry procedure~~ **DONE (§4b)** - full
   silicon-level USB recovery mode documented and understood. One remaining sub-item is a hardware
   question (are the strap pins physically accessible on this board), not answerable remotely.
3. ~~Map the exact partition table byte-for-byte~~ **DONE (§4b)** - real GPT parse, not inferred:
   confirmed genuine A/B redundancy (`kernel`/`kernel2`, `rootfs`/`rootfs2`) and confirmed via
   `/proc/cmdline` which slot is active (`p7`) vs. spare (`p8`). Live device tree top-level nodes
   spot-checked (§4a) and look plausible; a full node-by-node diff against the reference `.dts` is
   the one remaining minor Phase 0 item, low priority given everything else now confirmed.

**Phase 1 - smallest possible real test, still low risk (the ethernet driver, track 2)**
4. Build the `ax88179_178a` kernel *module* (not a full kernel) against `vendor/x2000_kernel`,
   using the `x2000_module_base_linux_mmc2_defconfig` as a base with
   `CONFIG_USB_NET_AX88179_178A=m` enabled, matching the exact vermagic already extracted
   (`NETWORKING.md` §2 - `4.4.94 SMP preempt mod_unload MIPS32_R2 32BIT`). Needs a matching MIPS
   cross-compiler (OpenKE already has MIPS cross-compilation experience/tooling from other work -
   reuse rather than rebuild). Test via `insmod` on the real, idle printer - session-only, worst
   case is a hang + power cycle, no image changes (see `NETWORKING.md` §2 for why this specific
   test is low-risk). Real, concrete proof our source/toolchain match is correct before attempting
   anything bigger.

   **Build + vermagic verification DONE (2026-07-19). `insmod` test NOT done yet - resume here.**

   Toolchain: reused the same Docker image already proven for OpenKE's own MIPS builds
   (`pellcorp/k1-bash-build@sha256:0b96d1d65175c5a2e3a83a64c3212d08dd774fef0900f991e0ebc570ba896c85`,
   see `~/Documents/guppyscreen/scripts/build-nginx-mipsel.sh`). It bundles Ingenic's own
   `mips-gcc720-glibc229` toolchain at `/opt/toolchains/mips-gcc720-glibc229/bin/` - confirmed via
   the compiler's version banner ("Ingenic Linux-Release5.0.2-Default(xburst2(fp64)+glibc2.29)") to
   be Ingenic's actual vendor toolchain for this exact chip family, not just "a MIPS toolchain that
   happens to work." Default container user (`developer`) can't `apt-get install`; use
   `docker run --user root`. `bc` isn't in the image by default and is required by
   `include/generated/timeconst.h` - install it inline (`apt-get install -y bc`) before building; a
   pre-existing, unrelated, non-fatal Kconfig bug in this vendor tree
   (`drivers/net/wireless/bcmdhd/Kconfig:29: error: recursive dependency detected!`) fires on every
   config step but `.config` is still written correctly regardless - ignore the noise.

   Exact commands, run inside the container with `vendor/x2000_kernel` mounted at `/src` and `cwd`
   there:
   ```sh
   export ARCH=mips
   export CROSS_COMPILE=mips-linux-gnu-
   export PATH=/opt/toolchains/mips-gcc720-glibc229/bin:$PATH
   apt-get install -y bc   # once per container invocation, needs --user root
   make x2000_module_base_linux_mmc2_defconfig
   ./scripts/config --module CONFIG_USB_USBNET
   ./scripts/config --module CONFIG_USB_NET_AX88179_178A
   ./scripts/config --module CONFIG_MII
   make olddefconfig
   make -j$(nproc) modules_prepare
   make -j$(nproc) M=drivers/net modules
   make -j$(nproc) M=drivers/net/usb modules
   ```
   Produces (among incidental siblings in the same directories, harmless/unused):
   `drivers/net/mii.ko`, `drivers/net/usb/ax88179_178a.ko`, `drivers/net/usb/usbnet.ko`,
   `drivers/net/usb/asix.ko`. Confirmed present in the generated `.config` before building: `SMP=y`,
   `PREEMPT=y`, `MODULE_UNLOAD=y`, `MODULES=y`, `LOCALVERSION=""`, no `MODVERSIONS` line - the exact
   components of the real device's vermagic. **Verified after build**: `strings <file>.ko | grep
   ^vermagic=` on all four `.ko` files each reads exactly
   `vermagic=4.4.94 SMP preempt mod_unload MIPS32_R2 32BIT` - byte-identical to the string extracted
   from the real device's own existing modules (`NETWORKING.md` §2). Since `CONFIG_MODVERSIONS` is
   off on the real device (confirmed same place), this coarse vermagic match is the only
   compatibility gate that matters - no per-symbol CRC check needed.

   Built `.ko` files copied to a stable, durable location (not just left inside the gitignored
   `vendor/` clone, which could be deleted/re-cloned):
   `~/Documents/ke-mainline-klipper/artifacts/ax88179-modules/` (`ax88179_178a.ko`, `usbnet.ko`,
   `mii.ko`, `asix.ko`).

   **Remaining step, next concrete action**: `scp` these four `.ko` files to the real printer,
   confirm it's idle via a *fresh* `print_stats` check (it was mid-print - `BUTTRESS BASE M10 (L)`,
   PETG - when last checked 2026-07-19; that check is now stale, re-check don't trust it), then
   `insmod mii.ko && insmod usbnet.ko && insmod asix.ko && insmod ax88179_178a.ko` (load order
   matters - dependencies first), and check `dmesg`/`ip link` for a new interface. If it works. add
   an init script matching Creality's own `/module_driver/*.sh` pattern for persistence (§5 step 4
   below covers this already). If `insmod` reports a version mismatch despite the matching
   vermagic string, the next thing to check would be per-symbol CRCs after all (re-verify the
   `CONFIG_MODVERSIONS`-off assumption against the built `.ko`'s own `Module.symvers` output - the
   `usb` subdirectory's build emitted a "Symbol version dump ./Module.symvers is missing" warning
   not seen on the first (`drivers/net`) build; not yet investigated, likely benign since modversions
   is off on the target too, but worth a first look if `insmod` unexpectedly fails).

**Phase 2 - real custom builds, moderate risk, only after Phase 1 succeeds**

5. ~~Build a custom Buildroot-based rootfs image~~ **BUILD DONE 2026-07-19, zero device writes,
   minimal-proof-of-pipeline scope by explicit user pre-approval (they were away and asked what
   was needed to finish this unattended).** Full account below - read this before redoing any of
   this work.
6. ~~Consider kernel changes beyond adding modules (e.g. a newer Ingenic-community kernel fork)~~ -
   turned out to be exactly what step 5 above used, not a separate later step - see below.

**Phase 3 - only if everything above is solid and validated, NOT started, real hardware**
7. A real flash of kernel+rootfs to the live printer, using the platform's own confirmed recovery
   path as a safety net, only after dry-running the process as many times as reasonably possible
   against non-production copies (e.g. test on the paired/backup partition slot if p3/p4 or
   p7/p8 really are A/B pairs, confirmed in Phase 0). **Deliberately not attempted, and should not
   be attempted without the user present** - real hardware, no safety net if something goes wrong
   mid-flash, same standing rule as everywhere else in this workspace.

**Explicitly not recommended, no real reason to do it here**: replacing the bootloader (`xboot`) -
no concrete benefit identified for this project, and it's the single highest-risk component to get
wrong regardless of how well-documented the recovery path turns out to be.

### Phase 2 results (2026-07-19) - real cross-compiled kernel + rootfs, zero device writes

**Scope, agreed with the user before they left for the afternoon** (they were unreachable
mid-session, same pattern as track 1's `klippy_extras/` work): a minimal proof-of-pipeline build -
confirm the Buildroot cross-compilation pipeline actually produces a working image at all, not
attempt full production parity (that's real, substantial future work - the exact package set to
match Klipper/Moonraker/nginx/camera/WiFi, and converting to squashfs+overlay to match the real
device's A/B partition format - neither started, see "What's still needed for parity" below).

**What was built**, using `vendor/buildroot-x2000`'s own `halley5_x2000_defconfig` as-is (the real
vendor-community config for this exact board, found in Phase 0) inside the same
`pellcorp/k1-bash-build` Docker container already proven for other MIPS builds in this workspace -
entirely local compute, the real printer was never touched:

- **A full Buildroot-internal cross-toolchain**, built from scratch (not reusing Ingenic's
  pre-built `mips-gcc720-glibc229` toolchain from Phase 1 - this defconfig is set up to build its
  own, `BR2_TOOLCHAIN_BUILDROOT=y`).
- **A real, working Linux kernel, version 6.1.28** - genuinely newer than the device's current
  4.4.94, which is actually the point ("more lightweight, more up to date" was the original ask).
  Source: [`Ingenic-community/linux`](https://github.com/Ingenic-community/linux) (real, active,
  33-star GitHub org "dedicated to unleashing the full potential of Ingenic processors", pushed as
  recently as 2025-03-27) at commit `39aefb83ed4422c63fa56e0d87b3e1317b6f60dc`, using its own
  `halley5` defconfig (confirmed `CONFIG_X2000_HALLEY5=y` - genuine, real X2000/Halley5 board
  support on a modern kernel, not a coincidence). **This is a different, separate kernel source
  from `vendor/x2000_kernel`** (the 4.4.94 tree Phase 1 used to vermagic-match the device's
  *current, running* kernel for a loadable module) - Buildroot fetched this one itself, fresh,
  during this build; don't confuse the two or assume they're interchangeable. Built output:
  `uImage` (U-Boot-wrapped, 3.9 MB).
- **A real, working root filesystem**, Buildroot 2023.11.1, `busybox`-based, ext2 format, 60 MB.
  Sanity-checked directly (via `debugfs`, no mount/root needed) - correct top-level layout
  (`/bin`, `/etc`, `/lib`, `/sbin`, `/usr`, `/var`, `linuxrc`), `/usr/lib/os-release` reads
  `NAME=Buildroot VERSION=2023.11.1` as expected, `/bin/busybox` present and correctly sized.
- **Zero build errors.** Both the kernel and rootfs stages completed cleanly on the first attempt
  that actually had its build dependencies installed (`python3`/`bc`/`cpio`/`rsync`/`unzip`/
  `bison`/`flex`/`libncurses5-dev`/`file`/`build-essential`/`libssl-dev` - none of these are in the
  base `k1-bash-build` image, install them with `apt-get` as `--user root` same as Phase 1 before
  running `make`; the very first attempt failed fast because a separate `--rm` container had
  installed them and then discarded them - packages don't persist across separate container runs
  even with the same image, only the bind-mounted source tree does).
- **Saved durably** (not just left in the gitignored `vendor/` clone) at
  `artifacts/buildroot-halley5-image/`: `uImage`, `rootfs.ext2`, and `buildroot.config` (the exact
  `.config` used, for reproducibility) - committed to this repo (no remote, so "committed" means
  durable-on-this-machine, same caveat as Phase 1's artifacts).

**QEMU boot-test attempted, as agreed bonus verification - expected negative result, not a bug.**
Checked prior art first (`pellcorp/k1-qemu`'s own readme: even the SimpleAF author only got "mixed
success" trying to boot a MIPS Ingenic-family kernel under QEMU, and built a separate x86_64
stand-in for fast userspace-only testing instead - real, documented precedent this wasn't
expected to just work). Ran `qemu-system-mipsel -M malta` (QEMU's generic MIPS reference board,
the only MIPS machine model QEMU actually implements - there is no X2000/Halley5 machine model
upstream, confirmed by checking) against the built `vmlinux`+`rootfs.ext2`, 30s timeout. **Zero
console output at all** - not even early boot messages - confirming the kernel's Ingenic X2000
board-init code doesn't do anything meaningful against the Malta board's completely different
memory-mapped peripheral layout (no GT-64120 north bridge, different UART/interrupt-controller
addresses). This is the expected outcome given no X2000 QEMU support exists, not a build defect -
the build itself (cross-compile + basic rootfs structure) is independently confirmed correct via
the `debugfs` inspection above. **Real-hardware boot-testing remains the only way to actually
verify this image runs** - not attempted, needs the user present (see Phase 3 above).

**What's still needed for parity with the real device** (none of this started, all real, scoped
future work, not urgent):
1. **Package selection** - this build only has Buildroot's own default minimal package set
   (`busybox`, `dbus`, base system). Getting anywhere near replacing the real device's software
   stack needs Klipper, Moonraker, nginx, the camera pipeline, and WiFi driver/firmware support
   added as real Buildroot package selections - a substantial, multi-session undertaking, not
   attempted here on purpose (out of scope for "minimal proof-of-pipeline").
2. **Filesystem format** - this build uses plain ext2, not squashfs+overlay. The real device's
   spare `rootfs2`/`kernel2` partitions (Phase 0, `/proc/cmdline` confirms `p7` active, `p8`
   spare) are sized/formatted to match the *current* squashfs image - a converted or reconfigured
   Buildroot output would be needed before this could even attempt to occupy that slot format-
   correctly. `BR2_TARGET_ROOTFS_SQUASHFS` is a real, available Buildroot option, just not enabled
   in the vendor community's own reference config (which targets a plain rootfs use case, not
   Creality's specific A/B+overlay scheme) - flipping it on is straightforward when this is picked
   back up, not a research question.
3. **Device-tree/driver fit** - this kernel's `halley5` defconfig is for the *reference* Halley5
   evaluation board, not Creality's own customized Nebula Pad variant. Whether it needs any
   device-tree changes for this board's specific touch controller, WiFi/BT combo chip, or camera
   wiring is unconfirmed - likely some, unknown how much, not investigated this pass.
4. **Real hardware boot test** - the actual, only real verification that any of this works, per
   above. Needs the user present.

Nothing above has touched, flashed, or written to the real printer. This is a plan and a real,
verified-as-far-as-possible-without-hardware build artifact to pick up in a later session, one
step at a time, with the user's explicit go-ahead before any step that touches the real device
beyond read-only queries - fully consistent with how every other risky-adjacent step in this
workspace has been handled so far.

## 6. Live comparison against the real printer (2026-07-19) - what parity actually needs, reframed around "as open as possible"

**New framing from the user, stated explicitly this session**: the goal of this whole workspace is
"a complete 'open' printer, as much as possible" - not just a working replacement, a *more open*
one where feasible. This matters concretely: several places below where the real device uses
Creality's own closed/out-of-tree driver, this kernel's fork already has a real, fully open
mainline equivalent - meaning the honest goal isn't just "match parity" but "match or improve on
openness," and this section reflects that framing throughout.

User turned the printer on specifically so this comparison could be done for real instead of from
memory/assumption. All of the following is read-only (`ssh`, `lsmod`, `dmesg`, `i2cdetect`, no
writes) against the live device, cross-checked directly against the actual kernel source tree this
workspace already has (`vendor/buildroot-x2000/output/build/linux-<sha>/`, the same 6.1.28
Ingenic-community tree Phase 2 built).

**The real device's 14 custom kernel modules, confirmed exactly** (`lsmod` + `/module_driver/`
listing, matches the "14 modules" figure already in this file from earlier forensics):
`soc_watchdog`, `soc_efuse`, `ns2009_touch`, `lcd_general_480x272`, `hci_uart_h5_kernel_4_4_94`,
`cywdhd`, `soc_dtrng`, `soc_msc`, `soc_fb`, `soc_fb_layer_mixer`, `soc_rotator`, `pwm_backlight`,
`soc_pwm`, `soc_gpio`, `soc_i2c`, `soc_utils`, `rmem_manager`, `utils` (18 module names in `lsmod`
- some inter-depend, `utils`/`soc_utils` are shared low-level helpers most others link against).

### Per-peripheral assessment

**Camera - LOW risk, and can end up *more* open than stock, not just at parity.** The real device's
camera path is UVC webcam (`CCX2F3298`, `/dev/video4`) into Creality's own closed `cam_app`, which
drives Ingenic's proprietary "Helix"/"Felix" V4L2 M2M hardware H.264/JPEG encoder
(`vpu-helix`/`vpu-felix`, built into the kernel, not a loadable module, no public source). **The
user pointed at the actual fix**: `pellcorp/k1-ustreamer` (a real MIT-licensed port of the
open-source µStreamer project) + `pellcorp/creality`'s `k1/services/S50webcam` init script - which
runs `ustreamer -c HW -m MJPEG -d $V4L_DEVICE` directly against the UVC webcam device node. `-c HW`
means the *webcam's own onboard ISP* does the MJPEG compression (standard behavior for basically
any USB UVC webcam) - this **never touches Ingenic's Helix encoder at all**, the exact same
approach every generic Voron/Klipper printer with a USB webcam already uses. This is a strictly
better position than "match Creality's closed pipeline": skip it entirely, use a fully open
component instead. What's actually needed: `CONFIG_USB_VIDEO_CLASS` (`uvcvideo`, stock mainline USB
video driver, confirmed present in this kernel's `Kconfig` - just currently disabled,
`CONFIG_MEDIA_SUPPORT` is off in the current build) enabled and the kernel rebuilt, plus
cross-compiling `k1-ustreamer` for this target and adding the `S50webcam`-equivalent init script.
No device-tree work, no proprietary driver needed at all.

**WiFi - LOW-MEDIUM risk, and a real openness upgrade over stock.** Live device: `dmesg` confirms
the actual chip is a **Cypress CYW43438** (SDIO, vendor:device `02D0:A9A6`), loaded via Creality's
own closed `cywdhd.ko` (927 KB blob) plus a real firmware file already on the device,
`/lib/firmware/wifi_bcm/cyw43438-7.46.58.13.bin`. **CYW43438 is the exact same combo chip used on
the Raspberry Pi 3B and Pi Zero W** - one of the most mainline-supported WiFi chips that exists,
specifically *because* of Pi ubiquity. Confirmed directly: this exact kernel tree's `halley5`
defconfig **already has `CONFIG_BRCMFMAC=m` with SDIO support enabled** (the fully open, in-tree
mainline driver) - almost certainly because the reference Halley5 eval board itself also pairs
with a Broadcom/Cypress SDIO chip. Not yet confirmed byte-exact chip-ID match in
`brcmfmac`'s own `chip.c` tables (found `BRCM_CC_43430_CHIP_ID`/`CY_CC_43439_CHIP_ID` nearby but
not an exact `43438` literal in a quick grep - needs a closer check, not a blocker, very likely
fine given how well-trodden this exact chip is). The firmware blob itself would still be needed
(same as every Pi does) - the *driver* would be fully open, a real upgrade over Creality's closed
`cywdhd`.

**Bluetooth - LOW-MEDIUM risk, similarly upgradeable.** Live device: `BCM4343A1` combo silicon (same
package as the WiFi side), loaded via Creality's own `hci_uart_h5_kernel_4_4_94.ko` - literally
named for this exact kernel build, i.e. certainly won't load as-is on a 6.1 kernel regardless.
Real Broadcom patch-RAM firmware files already exist on the device in standard `.hcd` format
(`/lib/firmware/bt_bcm/BCM4343A1_*.hcd`) - this is the *same* file format mainline Linux's own
`hci_uart` H5 (three-wire UART) protocol support plus `btbcm`/`hci_bcm` firmware loading already
knows how to consume. Confirmed the H5 protocol option exists in this kernel's `Kconfig`
(`Bluetooth: Three-wire UART (H5) protocol support`); not yet enabled in the current build
(`CONFIG_BT_HCIUART` unset) - a real but straightforward config-and-rebuild task, not a research
gap, and the existing `.hcd` firmware files can likely be reused as-is.

**Touch panel - the one genuinely uncertain, real-work peripheral.** Live device: `ns2009_touch.ko`
against an I2C-attached NS2009 resistive touch controller (confirmed via `i2cdetect`/
`/sys/bus/i2c/devices/*/name` showing `ns2009` on the live device). Checked this kernel's
`drivers/input/touchscreen/` directory directly - **no `ns2009`-named driver exists**, mainline or
otherwise, in this source tree. The closest generic candidates (`ads7846.c`,
`resistive-adc-touch.c`) are for different chip protocols, not drop-in compatible. This is the one
piece that most likely needs either a real new driver written against the NS2009's own register
protocol, or porting/adapting Creality's existing `ns2009_touch.ko` source (only 8.5 KB - small,
plausibly tractable) to the newer kernel's driver model. Flagged clearly as real, unstarted work,
not a config flip.

**Display/LCD - genuinely uncertain, but the *available* option is architecturally better.** Live
device: Creality's own out-of-tree fbdev-style stack (`soc_fb` + `soc_fb_layer_mixer` +
`soc_rotator` + `lcd_general_480x272` + `pwm_backlight`/`soc_pwm` for backlight). This kernel tree
instead has a real, modern **DRM driver for Ingenic display hardware**
(`drivers/gpu/drm/ingenic/ingenic-drm-drv.c` + `ingenic-ipu.c`) - the architecturally-preferred,
actively-maintained-upstream approach vs. legacy fbdev, and genuinely more "open" in the sense of
being a real upstream-style driver rather than a vendor out-of-tree module. Currently disabled in
our build (`CONFIG_DRM` unset). **Unconfirmed**: whether this DRM driver's LCDC support covers the
exact small (480x272) panel/timing this specific board uses - that's real device-tree work, not
yet started, genuinely uncertain until tried.

**Core SoC infrastructure - likely LOW risk, probably mostly already solved by this newer kernel.**
The remaining custom modules (`soc_watchdog`, `soc_efuse`, `soc_dtrng`, `soc_msc`, `soc_gpio`,
`soc_i2c`, `soc_utils`/`utils`, `rmem_manager`) are Creality's own out-of-tree wrappers around core
SoC functions (RNG, MMC/SD host controller, pin control, I2C, reserved-memory/DMA management).
This kernel tree already has real, properly-in-tree equivalents for the X2000 specifically:
`drivers/char/hw_random/ingenic-rng.c`/`ingenic-trng.c`, `drivers/mmc/host/ingenic_mmc.c` +
`sdhci-ingenic.c`, `drivers/pinctrl/pinctrl-ingenic.c`, `drivers/tty/serial/8250/8250_ingenic.c`,
and more (`drivers/clk/ingenic`, `drivers/phy/ingenic`, `drivers/net/ethernet/stmicro/stmmac/
dwmac-ingenic.c`). Not individually build/boot-tested this pass, but the presence of a real,
apparently-complete driver set for this SoC family (rather than needing to port any of Creality's
14 custom modules directly) is a strong, concrete reason to expect this layer mostly "just works"
once the kernel config enables the right options - the actual open question is device-tree
correctness for this board's exact pin mapping, not driver existence.

**App stack and filesystem format - unchanged from Phase 2's own list, real substantial work,
untouched this pass**: Klipper/Moonraker/nginx/`k1-ustreamer`/GuppyScreen packaging, and converting
from plain ext2 to squashfs+overlay to match the real device's A/B partition format. Both still
completely unstarted.

### Net effect on the difficulty assessment

This live comparison is materially more encouraging than a generic "port 14 modules" framing would
suggest. Several pieces that looked like they'd need porting Creality's own closed drivers instead
have real, existing, fully-open mainline equivalents already sitting in the kernel source this
workspace is already using - WiFi (`brcmfmac`) and Bluetooth (`hci_uart` H5) most concretely, with
the existing firmware files on the device directly reusable in both cases; camera bypasses the
proprietary encoder entirely via the user's own `k1-ustreamer` suggestion. **Touch and display were
both looked at in much more depth in §7 below - the touch assessment above turned out too
pessimistic (a real open driver exists) and the display assessment above turned out based on a
wrong assumption (the DRM driver found here doesn't actually cover X2000 at all) - §7 supersedes
both bullet points for these two peripherals specifically, read that section, not this paragraph,
for the current state of either.** None of this has been attempted yet - this section (and §7) is
reconnaissance that makes the next real step (enabling configs, doing real backport/integration
work, and testing on real hardware with the user present) concrete rather than speculative.

## 7. Touch panel + display, looked at in depth (2026-07-19) - is either Creality-specific, or does an open equivalent exist?

User asked specifically, before starting work on either: is the touch driver and the display
driver genuinely Creality-specific, or is there an open-source equivalent already available? Real
answer for both, found by checking actual driver source (not just guessing from module names) -
**neither is a Creality-invented, un-reusable black box, but the two are in meaningfully different
states.**

### Touch panel (NS2009) - LOW risk, corrects §6's earlier "highest risk" call

§6 above concluded no NS2009 driver existed anywhere and this would likely need real new-driver
work. That was checked only against this workspace's own two kernel trees
(`vendor/x2000_kernel`, `vendor/buildroot-x2000`'s `Ingenic-community/linux`) - a broader GitHub
search turns up a different picture entirely:

- **NS2009 is a real, known chip** (vendor: Nsiway Technology, a genuine resistive touch
  controller IC), and **a complete, real, GPLv2 Linux driver for it already exists** - written by
  [Icenowy Zheng](https://github.com/icenowy) (a credible, real upstream Linux kernel contributor,
  well known for Allwinner SoC work), used across multiple independent embedded-Linux projects for
  the Allwinner V3S / Lichee Pi Zero / Lichee Pi Nano boards and derivatives (`suda-morris/SUDA_V3S`,
  `Dean-Chu/linux-v3s`, `EchoHeim/Allwinner-H616`, an OpenWrt sunxi patch series, and others - real,
  independent, working copies, not one-off toy code).
- **The driver (212 lines, `drivers/input/touchscreen/ns2009.c`) uses entirely generic Linux APIs**
  - `i2c_smbus_read_i2c_block_data`, the standard `input_dev`/`touchscreen_properties` framework,
  `input-polldev` for polling. Nothing Allwinner-specific in it at all - it only needs I2C + the
  input subsystem, both of which are architecture-agnostic. This means it's genuinely,
  straightforwardly portable to our Ingenic X2000 6.1 kernel: drop the file into
  `drivers/input/touchscreen/`, add a `Kconfig`/`Makefile` entry, add an I2C device-tree node
  matching what's already confirmed live on this printer (`i2cdetect`/`/sys/bus/i2c/devices/*/name`
  showing `ns2009` present, §6). Not yet merged into real upstream `torvalds/linux` (checked -
  zero hits), but real, working, and already proven across several other real SoCs.
- **Verdict: reuse this existing open driver.** This is integration work (get the file in, wire up
  Kconfig/Makefile/device-tree), not driver authorship. Corrects §6's "highest risk, real driver
  work" call to **LOW risk**.

**Update - actually done and build-verified (2026-07-19, same day), not just identified.** Ported
Icenowy Zheng's driver into `vendor/buildroot-x2000`'s 6.1.28 kernel tree and got a real,
correctly cross-compiled `.ko` out of it - zero device writes, pure local Docker cross-compile,
same toolchain Phase 2 already proved. Concretely, on top of the base patch:

1. Applied the driver + `Kconfig`/`Makefile` wiring cleanly (`patch -p1`, minor line-offset fuzz
   from the 5.4-to-6.1 version gap, no conflicts).
2. **Added a real `of_match_table`** (`compatible = "nsiway,ns2009"`) - the original patch only
   registered a legacy `i2c_device_id`, relying on i2c-core's older name-matching fallback; an
   explicit DT compatible string is the modern, more robust way to bind this on a real device-tree
   system.
3. **Ported the polling mechanism off `input_polldev`** - that whole framework (`devm_input_allocate_polled_device`/`input_register_polled_device`) was removed from mainline
   Linux between 5.4 (when this driver was written) and our 6.1 target; discovered this the honest
   way, via a real compile error (`fatal error: linux/input-polldev.h: No such file or directory`),
   not by inspection alone. Rewrote to the real modern replacement API
   (`input_setup_polling()`/`input_set_poll_interval()` on a plain `devm_input_allocate_device()`
   device), following the exact pattern this kernel's own `tps6507x-ts.c` driver already uses for
   the same kind of simple periodic-poll touchscreen.
4. **Added the missing `MODULE_LICENSE("GPL")`/`MODULE_AUTHOR`/`MODULE_DESCRIPTION`** - the original
   patch never had one at all (confirmed by grep - genuinely absent, not just unfamiliar
   convention), which `modpost` correctly refused to link without.
5. Hit and fixed two purely environmental build issues along the way, neither specific to this
   driver: `objtool` needing `libelf-dev`/`libelf1` (a host build dependency, not previously needed
   because the earlier Phase 1/2 builds happened to not exercise that code path), and one
   incremental-build invocation accidentally compiling for the host x86_64 instead of MIPS because
   `ARCH`/`CROSS_COMPILE` weren't re-exported in that particular `docker run` (container env vars
   don't persist between separate invocations, same class of gotcha as the missing-apt-packages
   issue Phase 1 already documented) - fixed by driving the rebuild through Buildroot's own
   `make linux-rebuild` (which supplies the correct, exact flags itself) rather than hand-invoking
   `make M=drivers/... modules` directly.

**Verified output**: `strings ns2009.ko` reads `vermagic=6.1.28 SMP preempt MIPS32_R1 32BIT`,
`license=GPL`, `name=ns2009`; `readelf -h` confirms a real MIPS object (`Machine: MIPS R3000`, the
standard ELF machine type for all MIPS variants). A separate, unrelated incremental-rebuild issue
(stale `vmlinux`-level SMP symbols - `ingenic_smp_init`/`jz4780_smp_wait_irqoff` - from mixing
build state across container instances) blocked linking a *complete* kernel image in the same
pass, but does not affect this module's own build correctness, confirmed independently via the
module's own successful `CC [M]`/`LD [M]` build steps and the vermagic/license/machine-type checks
above. A future clean one-shot rebuild (like Phase 2's original) would very likely not hit this.

**Independently double-checked one detail in this (2026-07-19, separate pass)**: the reported
vermagic says `MIPS32_R1`, worth verifying since this SoC is documented everywhere else as XBurst
II/MIPS32**R2**. Traced this to the actual kernel `.config` (not just the module) -
**`CONFIG_CPU_MIPS32_R1=y`** is genuinely what Phase 2's kernel build used, inherited as-is from
the `halley5_x2000_defconfig` community config. Compared directly against the real device: both
the vendor SDK's own matching defconfig (`vendor/x2000_kernel`'s `halley5_v20_linux_msc_defconfig`)
and the live printer's own currently-loaded modules (`strings /module_driver/*.ko`) confirm
`CONFIG_CPU_MIPS32_R2` is what this exact chip actually ships with. **Not a functional blocker** -
R1-compiled code runs correctly on R2-capable silicon (R2 is a superset), so this won't stop
anything from working - but it means this build isn't using the full instruction set the chip
actually supports. Worth flipping to `CONFIG_CPU_MIPS32_R2=y` in a future clean rebuild; flagged
now rather than left silently in.

**Saved durably** at `artifacts/ns2009-driver/`: `ns2009.c` (the final ported driver, all changes
above applied), `ns2009.ko` (the built module), `upstream-base-patch-lmahmutov-SGW-Openwrt.patch`
(the original 2017 patch this was based on, for provenance).

**Still needed before this is real on the actual printer** (none of this attempted - real hardware,
needs the user present): a device-tree node binding `compatible = "nsiway,ns2009"` at the confirmed
live I2C address (`i2c bus 4, address 0x48` - read via `/sys/bus/i2c/devices/4-0048/name` on the
live device, §6) with appropriate `touchscreen-*` properties (swapped-axes/inverted-axes/min-max,
following `Documentation/devicetree/bindings/input/touchscreen/touchscreen.yaml`'s standard
properties - this board's exact orientation/calibration not yet determined), and then a real
`insmod`+touch-event test on real hardware.

### Display/LCD - MEDIUM risk, corrects §6's overly-optimistic framing (the DRM driver found there doesn't actually cover this chip)

§6 above pointed at `drivers/gpu/drm/ingenic/` in the 6.1 `Ingenic-community/linux` tree as "a real,
modern DRM driver for Ingenic display hardware" and called this "architecturally better, just
unconfirmed for this exact panel." **That undersold a real gap, found on closer inspection**:
checking `ingenic-drm-drv.c`'s actual supported-SoC table shows it only covers the **older JZ47xx
generation** - `jz4740`, `jz4725b`, `jz4760`/`jz4760b`, `jz4770`, `jz4780`. **X2000 (XBurst II) is
not in this driver's supported chip list at all.** Confirmed further: the X2000 SoC-level device
tree in this same 6.1 kernel tree (`arch/mips/boot/dts/ingenic/x2000.dtsi`) has **zero**
LCD/panel/display-controller node of any kind, and the `halley5` defconfig this workspace has been
building against has no `CONFIG_FB`/`CONFIG_DRM` lines at all. **This specific community kernel
fork genuinely has no X2000 display support whatsoever** - not disabled, not "needs a device-tree
tweak," absent.

**User pushed back on this ("sounds implausible, did you search online?") - fair, and correct: the
check above was GitHub code search + two local kernel trees only, not a live web search. Redone
properly**: web search plus, most importantly, fetching the **actual current mainline
`torvalds/linux`** device-tree binding directly (not a fork, not a search-engine summary) -
`Documentation/devicetree/bindings/display/ingenic,lcd.yaml`'s `compatible` enum lists exactly the
same 6 chips (`jz4740`/`jz4725b`/`jz4760`/`jz4760b`/`jz4770`/`jz4780`) and no X2000 entry, confirmed
by reading the real file content, not a summary of it. One search engine's AI-generated summary
claimed "X2000 LCD bindings exist in kernel.org documentation" - checked directly and that claim
was **not supported by the actual file** (a real example of why synthesized search summaries need
verifying against source, not trusting at face value). Web search separately confirmed X2000 itself
(core SoC bits - pinctrl, clocks) landed in mainline starting around Linux 5.10 (Phoronix), but
nothing turned up for X2000 *display* support anywhere, mainline or community. **Conclusion
unchanged, now confirmed from three independent sources** (this workspace's kernel tree, live
upstream kernel.org fetch, web search) rather than two local trees alone.

**The real, better path forward, found in the vendor SDK this workspace already has**
(`vendor/x2000_kernel`, the exact-kernel-version-matching 4.4.94 tree from Phase 0): real, complete,
**genuinely open-source (GPLv2, "Copyright (c) 2012 Ingenic Semiconductor Co., Ltd.", confirmed by
reading the actual file header) X2000 display driver source exists** -
`drivers/video/fbdev/ingenic/fb_v12/ingenicfb.c` (whose own top-of-file path comment literally
reads `drivers/video/fbdev/ingenic/x2000_v12/ingenicfb.c` - confirming this is specifically the
X2000-generation version of Ingenic's fbdev driver, not a generic/unrelated one), enabled via
`CONFIG_FB_INGENIC=y`. **Confirmed this is exactly the config already proven to match this real
device**: `halley5_v20_linux_msc_defconfig` (the same defconfig Phase 0 already confirmed matches
this printer's kernel manual/build) has `CONFIG_FB_INGENIC=y` and a full display config block (11
lines: `CONFIG_FB`, `CONFIG_FB_CFB_*`, `CONFIG_BACKLIGHT_*`, `CONFIG_LCD_CLASS_DEVICE`, etc.) - this
driver is real, working, vendor-shipped, on this exact hardware family, not experimental. The
`fb_v12/displays/` directory (checked in §6) holds real example panel definitions
(`panel-kd035hvfbd037.c` and others) following a small, consistent pattern - strong evidence
Creality's own `lcd_general_480x272.ko` is nothing more than one more panel definition in this same
family, built on Ingenic's real open framework, not a from-scratch closed thing of their own.
`x2000_fullcolor_24inch_linux_sfc_nand_defconfig` and `x2000_fullcolor_7inch_linux_sfc_nand_defconfig`
(other real defconfigs in this same vendor tree) confirm this driver family is used with multiple
real panel sizes in production Ingenic reference designs, not a one-off.

**Verdict at the time: real work, but a well-understood category of it** - backport Ingenic's real
GPLv2 `CONFIG_FB_INGENIC` driver from the 4.4.94 vendor tree forward to the 6.1 kernel, a real but
well-trodden "port across a version gap" task. **Superseded below - a much better base exists.**

### Update (2026-07-19, same day): user found a complete, newer (6.6) X2000 SDK with native display support - verified directly, real, changes the plan

User found and verified (not just described - actually read the source) a public mirror of a much
newer, more complete Ingenic X2000 SDK:
[`Llixuma/ingenic-linux-kernel6.6-x2000-v1.0-20250221`](https://github.com/Llixuma/ingenic-linux-kernel6.6-x2000-v1.0-20250221).
Independently re-verified every claim directly against the actual repo (not taking the write-up on
faith) - all confirmed real:

- **Real repo** (`reupload from gittea/baidu cloud` - same honest provenance pattern already
  documented for `Jubian540/x2000_kernel` and friends, not a red flag, just how these vendor SDK
  drops circulate), 684 MB, pushed 2025-12-21.
- **A genuinely complete SDK in one place** - top level has `kernel/`, `buildroot/`, `u-boot/`,
  `device/`, `packages/`, `tools/`, `docs/`, `external/`, `frameworks/`, `prebuilts/` - unlike our
  current setup (`vendor/x2000_kernel` + `vendor/buildroot-x2000` as two separately-sourced,
  separately-matched repos), this is one coherent vendor drop.
- **Real, complete, GPLv2 X2000 display driver, confirmed by reading the actual file**:
  `kernel/kernel-6.6/module_drivers/drivers/video/fbdev/ingenic/fb_stage/ingenicfb.c` -
  `Copyright (c) 2020 Ingenic Semiconductor Co., Ltd.`, `MODULE_LICENSE("GPL")`, registers via
  `of_device_id ingenicfb_of_match[] = { { .compatible = "ingenic,dpu" } }` - **not**
  `ingenic,x2000-lcd` as might be guessed (this is exactly why earlier compatible-string-based
  searches for this driver came up empty - the real string is generic across the whole "DPU"
  display-controller family, not X2000-specific naming). Kconfig symbol `FB_INGENIC_STAGE`
  ("Version 12 DPU SoC" - same "v12" driver lineage already found in the 4.4.94 tree, now carried
  forward to a modern kernel).
- **Real X2000 device-tree node, confirmed by reading `kernel/kernel-6.6/module_drivers/dts/x2000/x2000.dtsi`**:
  `dpu: dpu@13050000 { compatible = "ingenic,dpu"; reg = <0x13050000 0x10000>; interrupts =
  <IRQ_LCD>, <IRQ_MIPI_DSI>; dsi-host-reg = <0x10075000>; dsi-phy-reg = <0x10077000>; ... }` - real
  hardware addresses for this exact SoC's display controller and MIPI-DSI host/PHY blocks.
- **Real panel driver library** at `.../ingenic/displays/` - dozens of real `panel-*.c` files.
  Most (`panel-jd9365*.c`, `panel-st7701s*.c`, etc.) are MIPI-DSI panel-controller-chip drivers,
  but several (`panel-kd035hvfbd037.c`, `panel-kd050hdfia019.c`/`020.c`, etc.) are the same simple
  parallel-RGB-style panel entries already seen in the older 4.4.94 tree - `panel-kd035hvfbd037.c`
  specifically appears in **both** trees, confirming real continuity/lineage, not a different
  unrelated driver family. This board's actual 480x272 panel is almost certainly this simpler
  parallel/RGB style (cheap small printer displays essentially never use MIPI-DSI), not one of the
  MIPI examples - so the relevant reference pattern is the simple panel files, not the MIPI-DSI
  subsystem (`jz_mipi_dsi/`) also present in this tree.
- **Real Halley5-specific panel device-tree examples exist**: `HALLEY5_MIPI_LCD_FW050.dtsi`,
  `HALLEY5_MIPI_LCD_ZC50289HSHD02.dtsi` (both MIPI panels, not this board's exact 480x272 panel,
  but real proof this exact SDK has been used with real Halley5-family hardware).
- **Also has real `brcmfmac` (WiFi) driver source present** at the same path structure already
  used successfully in Phase 2 - this SDK isn't just "the display piece," it looks like a complete,
  internally-consistent replacement for the display-less 6.1 base Phase 2 built against.

**Why this wasn't found earlier**: the compatible string (`ingenic,dpu`) is generic across the
whole Ingenic DPU-family display controller line, not X2000-specific - none of the earlier
searches (which reasonably guessed at `ingenic,x2000-lcd`-style naming) would have surfaced it.
The directory is also named `fb_stage` now, not `x2000_v12` as in the older tree, another reason
straightforward name-based searching missed it initially.

**This changes the plan materially.** Instead of backporting a driver across a ~7-year kernel gap
(4.4.94 to 6.1, real, error-prone work spanning many API generations), the real options now are:
1. **Port just the display driver from this 6.6 tree into the existing 6.1 tree** Phase 2 already
   built against - a 5-minor-version gap instead of a ~20-version one, far more tractable.
2. **Rebase Phase 2 onto this newer, more complete 6.6 SDK entirely** - since it already has native
   X2000 display support plus WiFi, and is a single coherent SDK rather than two separately-sourced
   repos, this may be the better foundation going forward, not just for display. Real cost: some of
   Phase 2's already-completed build work (the `artifacts/buildroot-halley5-image/` kernel+rootfs)
   would need redoing against this new base, and the ported NS2009 touch driver (§7 above) would
   need re-verifying/re-building against it too.

**Decided: option 2 (rebase Phase 2 entirely onto the 6.6 SDK), by explicit user instruction.**
Done same day. Full account below.

## 8. Phase 2 rebase onto the 6.6 SDK - DONE (2026-07-19), zero device writes

Rebuilt Phase 2's kernel+rootfs from scratch against `Llixuma/ingenic-linux-kernel6.6-x2000-v1.0-20250221`
instead of `Ingenic-community/linux`, using `vendor/buildroot-x2000`'s existing, already-proven
Buildroot pipeline (same Docker toolchain as before) - **not** the vendor's own elaborate
Android-style "lunch"/`envsetup.sh` build harness found alongside the kernel in that SDK (real,
complete, but a much larger, riskier surface to adopt whole-cloth than reusing our own
already-debugged pipeline just pointed at a different kernel source).

**Setup**:
- Sparse-cloned just `kernel/kernel-6.6` from the SDK (684 MB full repo; sparse checkout keeps
  this to ~1.8 GB working copy) into `vendor/x2000_kernel_6.6` (gitignored, same as other `vendor/`
  clones).
- Pointed Buildroot at this local source via its standard `<pkg>_OVERRIDE_SRCDIR` mechanism
  (`local.mk` in `vendor/buildroot-x2000`, referenced by the already-present
  `BR2_PACKAGE_OVERRIDE_FILE="$(CONFIG_DIR)/local.mk"`) - bypasses Buildroot's own download/git-
  clone step entirely via an rsync copy, the standard Buildroot way to build against a local
  source tree without wrapping it in a tarball or a nested git remote.
- Switched `BR2_LINUX_KERNEL_DEFCONFIG` from the community fork's `"halley5"` to the real vendor
  SDK's own `"x2000_halley5_v30_linux"` (matching the real defconfig file,
  `arch/mips/configs/x2000_halley5_v30_linux_defconfig`, confirmed present in the cloned tree) -
  **already has `CONFIG_FB_INGENIC_STAGE=y` and `CONFIG_USB_VIDEO_CLASS=y`/`CONFIG_MEDIA_SUPPORT=y`
  enabled by default**, i.e. display and camera support both come for free from this one defconfig
  switch, no manual config flipping needed for either.

**Three real, distinct build errors hit and fixed** (each genuinely new, not a repeat of Phase 2's
original gotchas):
1. **`linux-headers-custom` failed on a `binder.h` "leak" check** -
   `error: include/uapi/linux/android/binder.h: leak CONFIG_ANDROID_BINDER_IPC_64BIT to user-space`.
   This is a known, real quirk of this *exact* upstream Linux header (present in real
   `torvalds/linux` too, not something Ingenic introduced) when run through `make headers_install`
   outside a full kernel build context. Fixed by removing the 3-line
   `#ifndef CONFIG_ANDROID_BINDER_IPC_64BIT ... #endif` block from the local clone's copy of that
   header - we have no use for Android binder IPC on this device. Noted at
   `artifacts/buildroot-halley5-v30-image/binder-h-fix-note.txt` for provenance.
2. **Kernel-headers version mismatch**: `Incorrect selection of kernel headers: expected 6.1.x, got
   6.6.x`. Root cause, found by tracing through Buildroot's own `linux-headers` package logic (not
   guessed): with `BR2_KERNEL_HEADERS_AS_KERNEL=y` selected, the *expected* headers version is
   derived from `BR2_LINUX_KERNEL_VERSION` - which still held the old Ingenic-community git commit
   SHA from before the rebase (irrelevant to fetching once `OVERRIDE_SRCDIR` bypasses the download
   step, but still consulted for *this* label/consistency-check purpose). Two earlier attempts to
   fix this by hand-patching derived choice-group symbols
   (`BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_6_1` → `_6_6`) didn't work, because that whole choice
   group is unused in `AS_KERNEL` mode - a good reminder that hand-editing Kconfig-derived symbols
   in a raw `.config` is fragile; the robust fix was updating the one real source value
   (`BR2_LINUX_KERNEL_VERSION="6.6.18"`) and letting `make olddefconfig` recompute everything
   dependent on it correctly.
3. **`bc: not found`** during an incremental (non-full-`make`) module build - same class of gotcha
   Phase 1 already documented (fresh `docker run` invocations start a package-less container; only
   the bind-mounted source tree persists across separate invocations, not `apt-get`-installed
   packages) - fixed by re-running the `apt-get install` step before the incremental build command.

**Build succeeded cleanly after these fixes.** Verified output:
- `uImage` (5.9 MB) and `rootfs.ext2` (60 MB), kernel release string `6.6.18-rt23` (a **PREEMPT_RT**
  real-time kernel variant - a genuinely good property for a 3D-printer motion controller, not
  something specifically sought out but a welcome side effect of using this SDK's own default
  config).
- Kernel `.config` confirmed: `CONFIG_FB_INGENIC=y`, `CONFIG_FB_INGENIC_STAGE=y`,
  `CONFIG_USB_VIDEO_CLASS=y`, `CONFIG_MEDIA_SUPPORT=y`, `CONFIG_CPU_MIPS32_R5=y` (this SDK's own
  choice, real and internally consistent - unlike the earlier 6.1 rebase's stray `MIPS32_R1` note,
  no mismatch flagged here; not independently cross-checked against real device precedent since
  this is a different, newer reference design (`v30`) than the device's own shipped `v20`/4.4.94
  kernel, so some real config differences between hardware revisions are expected and not
  necessarily a red flag).
- Rootfs sanity-checked via `debugfs` exactly as Phase 2's original build was: correct top-level
  layout, `os-release` reads `Buildroot 2023.11.1`, `/bin/busybox` present and correctly sized.
- Saved to `artifacts/buildroot-halley5-v30-image/`: `uImage`, `rootfs.ext2`, `buildroot.config`,
  `kernel.config` (the actual kernel `.config` used, for reference), `local.mk` (the override
  mechanism, for reproducibility), `binder-h-fix-note.txt`. The original 6.1-based
  `artifacts/buildroot-halley5-image/` is **superseded but left in place**, not deleted - no reason
  to discard it, and it remains a real, valid build of a different (older) kernel lineage if ever
  useful for comparison.

### NS2009 touch driver re-ported against the new 6.6.18-rt23 kernel, same day

Reused the already-ported driver from the 6.1 rebase (§7's "Update - actually done" subsection)
rather than starting over - the driver itself (generic I2C + input-subsystem APIs) is
kernel-version-agnostic by design, but the *kernel's own API surface* had moved again in ways worth
finding and fixing properly rather than assuming compatibility:

1. **`i2c_driver.probe` signature changed** between 6.1 and 6.6: the old
   `int (*probe)(struct i2c_client *, const struct i2c_device_id *)` two-argument form (what the
   driver still used) is gone in this kernel's `include/linux/i2c.h` - only the newer
   `int (*probe)(struct i2c_client *client)` single-argument form remains. Found this by reading
   the actual header directly (not assuming it'd still compile), fixed by dropping the now-unused
   `const struct i2c_device_id *id` parameter from `ns2009_ts_probe()`'s signature - the function
   body never used `id` anyway.
2. **`CONFIG_INPUT_TOUCHSCREEN`'s own `menuconfig` gate wasn't enabled at all** in the
   `x2000_halley5_v30_linux_defconfig` - the entire touchscreen-driver subsystem is off by default
   in this reference config (plausibly because Ingenic's own reference board doesn't necessarily
   ship a resistive touch panel the way this printer does). Without this enabled first, the new
   `TOUCHSCREEN_NS2009` Kconfig entry has no menu to attach to and `make olddefconfig` silently
   drops it - not a bug, correct Kconfig dependency behavior, but a real thing to find and fix
   (`./scripts/config --enable CONFIG_INPUT_TOUCHSCREEN` before setting `TOUCHSCREEN_NS2009`).
3. Wired up `Kconfig`/`Makefile` entries in `drivers/input/touchscreen/` (new `config
   TOUCHSCREEN_NS2009` entry modeled on the neighboring `TOUCHSCREEN_TSC2007` entry;
   `obj-$(CONFIG_TOUCHSCREEN_NS2009) += ns2009.o` in the `Makefile`) in the local
   `vendor/x2000_kernel_6.6` clone - real, durable changes to that local tree (not committed to the
   upstream repo, just how it's built here), same treatment as the `binder.h` fix above.

**Verified output**: `strings ns2009.ko` reads `vermagic=6.6.18-rt23 SMP preempt mod_unload
MIPS32_R5 32BIT`, `license=GPL`, `name=ns2009` - **vermagic's `MIPS32_R5` matches the kernel's own
`.config` exactly this time**, no repeat of the earlier 6.1 rebase's `R1`-vs-`R2` mismatch. Real
device-tree alias confirmed present: `alias=of:N*T*Cnsiway,ns2009` - ready to bind against a real
`compatible = "nsiway,ns2009"` device-tree node. Saved (overwriting the 6.1-era copies, which are
superseded) at `artifacts/ns2009-driver/`: `ns2009.c` (final ported source, both this session's and
the earlier 6.1 rebase's fixes applied), `ns2009.ko` (built against 6.6.18-rt23 now).

**Still needed before any of this is real on hardware** (none attempted, real device, needs the
user present, same standing rule as everywhere else in this workspace):
1. A device-tree node (`compatible = "nsiway,ns2009"`) at the confirmed live I2C address (bus 4,
   address 0x48, §6/§7) with appropriate `touchscreen-*` properties - orientation/calibration for
   this specific board not yet determined.
2. WiFi (`brcmfmac`)/Bluetooth (`hci_uart` H5) config enabling - not done this pass, deferred (this
   session's scope was the display/touch rebase specifically); the `x2000_halley5_v30_linux_defconfig`
   didn't have these on by default the way the old 6.1 community fork's `halley5_x2000_defconfig`
   did, confirmed not yet re-checked against this new tree.
3. A real device-tree panel entry for this board's actual 480x272 parallel-RGB panel (§7's
   "displays" findings) - not started; the `HALLEY5_MIPI_LCD_*` examples in this SDK are for MIPI
   panels, not this board's likely simpler panel type.
4. Converting from plain ext2 to squashfs+overlay to match the real device's A/B partition format -
   not started, same gap Phase 2's original build had.
5. **The actual real-hardware boot test** - the only real verification any of this works. Not
   attempted, needs the user present.

## 9. Recovery/brick-risk investigation (2026-07-19) - the real safety net, confirmed from primary sources

User asked directly, before going any further: "shouldn't we build everything first? will we not
brick the pad?" - a fair question given how much build work had already happened without any real
device testing. Investigated properly rather than reassuring from memory: checked the *actual*
official Creality recovery documentation for this exact printer (not just the Phase 0 chip-level
research), and the real U-Boot source in the SDK already in hand.

### The real answer: yes, there's a documented, official, physical recovery path - confirmed by reading the actual PDF, not a search-engine summary

User pointed at two pages. The Creality-Helper-Script wiki's K1 recovery page fetched cleanly; the
official Creality KE-specific wiki page didn't render via `WebFetch` (JS-rendered page, only a
title came through) - but a web search surfaced the real, primary source: a PDF directly in
`CrealityOfficial/Ender-3_V3_KE_Annex` (`firmware recovery tool/Brick Rescue and Wire Brushing.pdf`).
**Downloaded and read that PDF directly** (not the search engine's synthesized text, which turned
out to blend details from the K1 page in a way worth not trusting at face value - the same
"verify the primary source" lesson from the `ingenic,lcd.yaml` incident earlier this session).

**Confirmed, from the actual official document**:
- **"Screen" = the Nebula Pad itself is what gets recovered** - the PDF's own photos show the
  literal "Creality Nebula Pad" (model `N-Pad01`) enclosure being opened via a "Base Shell Screw",
  confirming this recovery process targets exactly the X2000 SBC this whole track has been about,
  not a separate motion-control board.
- **Real physical "boot button" and "reset button" exist directly on the Nebula Pad's own PCB** -
  labeled in the PDF's own board photo, next to the MicroUSB port, 3D-printer port, Gsensor port,
  and WiFi antenna connector. **No soldering, no multimeter continuity tracing, no probing raw
  chip pins required** - this fully resolves Phase 0's one flagged unknown ("are the BOOT_SEL strap
  pins physically accessible on this board") in the best possible way: yes, via a documented button
  combo (hold both 3 seconds, release reset first then boot), not by chance-finding a test pad.
- **This is genuinely the same USB-download/mask-ROM recovery mode already researched in Phase 0** -
  confirmed by the PDF's own Device Manager screenshot showing "Ingenic USB BOOT DEVICE" (the exact
  driver name X2000's Boot ROM chapter already predicted), and the same "cloner" tool family already
  found (`cloner-2.5.18-windows_alpha` here vs. `2.5.54`/`2.5.36.1` found elsewhere - same lineage,
  different snapshots).
- **Official, ready-made recovery images exist and are Creality-published**: the PDF links
  `CrealityOfficial/Ender-3_V3_KE_Klipper` as the "Wire Brush Pack" download - real `.ingenic`
  firmware bundles, not something we'd have to construct ourselves. The recovery tool's own GUI
  (screenshotted in the PDF) shows five flashable components - `boot`/`uboot`/`rtos`/`kernel`/
  `rootfs` - reflashed together as one bundle, confirming a full known-good factory image can always
  be restored this way, independent of whatever state the spare partition experiments leave things
  in.

**Net effect on the actual risk picture**: this is a *materially* better answer than Phase 0's
original "recovery exists in theory, physical access unconfirmed." The escape hatch is real,
documented by Creality themselves for this exact product, requires no special tools beyond a
screwdriver/USB cable, and has ready-made factory images to restore from. This should be treated as
a real prerequisite to *confirm hands-on* (open the case, verify the buttons are exactly where the
photo shows, ideally have the `.ingenic` recovery package downloaded and the cloner tool ready
*before* ever attempting a custom boot test) rather than something to assume works from documentation
alone - but the documentation itself is about as strong as this kind of thing gets.

### The other half of the question - how does normal (non-recovery) A/B slot selection actually work - only partially resolved

Checked the U-Boot source in the same 6.6 SDK (`u-boot/board/ingenic/x2000_halley5/`) for the real
slot-selection logic. Found real board files (`board.c`, `partitions.tab`,
`partitions_mmc_ota.tab`), but **the reference `partitions_mmc_ota.tab` doesn't even show an A/B
pair** (`uboot`/`kernel`/`recovery`/`nv`/`resource`/`userdata`/`system`/`storage` - one `kernel`,
one `system`, no `kernel2`/`system2`) - confirming Creality's actual A/B scheme on the real device
is their own customization on top of this generic reference, not something directly visible in the
vendor U-Boot source as shipped.

**Checked the live device directly instead** (read-only, printer was mid-print throughout -
confirmed via a fresh `print_stats` check first, single small read, no interference): the real
`ota` partition (`mmcblk0p1`, 1 MiB) contains exactly 11 meaningful bytes - the plaintext string
`ota:kernel\n`, followed by all zeros. This is a real, minimal flag - but it doesn't look like a
full "which slot is active" pointer (no slot number/letter encoded), more likely a progress marker
for an in-flight OTA update process. The kernel's actual boot slot
(`root=/dev/mmcblk0p7 rootfstype=squashfs ro`, confirmed via `/proc/cmdline`) must be decided
*earlier*, most likely via U-Boot's own environment variables - not directly read this pass (no
`fw_printenv` on the device, and no separate U-Boot-env partition identified/read yet).

**Honest status**: the *recovery* half of the safety question is now very well-answered. The
*normal-operation A/B slot-selection* mechanism is still not fully pinned down - real, remaining,
low-priority research (not urgent, since the recovery path above is a strong enough safety net on
its own that not fully understanding the *normal* slot-switch mechanism doesn't block moving
forward carefully). If it matters later (e.g. to understand whether a failed boot on the spare slot
would automatically fall back to the working one, or would need the recovery process above), it's
worth reading U-Boot's actual boot script/environment more directly - via a real device
(`fw_printenv`-style env partition, if one exists) rather than guessing further from source alone.

## 10. "Build everything first" pass (2026-07-19) - real hardware wiring for touch, display, WiFi, Bluetooth, camera; all zero device writes

By explicit user instruction ("build first, it will minimize testing time"), given how solid the
recovery path in §9 turned out to be. This is the single densest build session in this track -
full account below, organized by subsystem, with every real bug hit along the way (there were
several genuinely new ones, distinct from earlier sessions' gotchas).

### Touch (NS2009) - device-tree wired in

Added a real I2C device-tree node in `module_drivers/dts/x2000/halley5_v30.dts` (the exact board
DTS this build compiles, confirmed via `DTC module_drivers/dts/x2000/halley5_v30.dtb` in the build
log and `CONFIG_DT_HALLEY5_V30=y`): `&i2c4 { status = "okay"; ns2009@48 { compatible =
"nsiway,ns2009"; reg = <0x48>; }; };`. The reference v30 board disables `i2c4` by default (only
`i2c3` is on) - the real printer's touch controller is confirmed live on bus 4
(`/sys/bus/i2c/devices/4-0048/name`), so this is a real, necessary board-specific override, not
optional.

### Display - a real, working (if best-effort) panel driver, not just an enabled Kconfig option

Wrote a genuinely new panel driver, `displays/panel-openke-general-480x272.c`, registered via a new
`CONFIG_STAGE_OPENKE_GENERAL_480X272` Kconfig entry (modeled on this SDK's own
`STAGE_ST7701S_RGB666` entry) and wired into the board DTS (`&dpu { status = "okay"; }` plus a
standalone `openke_panel` platform-device node using `compatible = "openke,general-480x272"`).

**Modeled on this SDK's own `panel-st7701s-rgb666.c`** (a real, complete `LCD_TYPE_TFT` example),
simplified down to just the three required `lcd_panel_ops` callbacks (`init`/`enable`/`disable`) -
a plain "general" RGB panel needs no command-interface init sequence the way that example's smart
controller chip does.

**Hit and fixed two real compile errors along the way, both API-version mismatches between the
reference example (evidently written against an older kernel) and this actual 6.6 tree**:
1. Copied `struct lcd_ops` (the generic Linux LCD-class `set_power`/`get_power` framework) where
   `struct lcd_panel.ops` actually expects `struct lcd_panel_ops` (`init`/`enable`/`disable`) -
   two genuinely different structs with similar names. Fixed by dropping the generic
   `lcd_device_register()` path entirely (not required for `ingenicfb_register_panel()` to work)
   and implementing the three real callbacks directly.
2. `of_get_named_gpio_flags()`/`enum of_gpio_flags`/`OF_GPIO_ACTIVE_LOW` - all removed from this
   kernel's `include/linux/of_gpio.h` (only the flag-less 3-argument `of_get_named_gpio()`
   remains). Fixed by switching to the flag-less call and hardcoding active-high polarity in C
   (documented as a real, flagged assumption - easy to invert in this one file if wrong).

**Confirmed real, from the live device** (read-only SSH, printer mid-print throughout,
`/sys/module/lcd_general_480x272/parameters/`): `gpio_lcd_power_en=PC21`, `gpio_lcd_rst=PB16`,
mode `480x272p-60`. **Not confirmed, best-effort defaults, clearly flagged in the driver's own
header comment**: exact sync timing (no datasheet found for this specific panel - used a
widely-documented standard timing for this exact resolution class instead), GPIO active-high/low
polarity, and color depth/mode (RGB888 assumed). Wrong values here would show as a garbled/
miscolored/shifted picture, not a hardware risk - genuinely tunable after a real boot, not
something that needs to be perfect before ever trying.

### WiFi (brcmfmac) and Bluetooth (H5) - both real, both hit real Kconfig gates that needed fixing

Added real hardware wiring in the board DTS: a `wlan_pwrseq` (`compatible = "mmc-pwrseq-simple"`)
node referencing the same WL_REG_ON GPIO (`gpd 1`) the vendor's own inert `bcmdhd_wlan` node
already named, referenced from `&msc1` via `mmc-pwrseq = <&wlan_pwrseq>;`. The vendor's own
`bcmdhd_wlan` node is left in place, unused, in case that out-of-tree driver is ever reconsidered
instead of mainline `brcmfmac`.

**Real Kconfig fights, each with a genuine root cause found, not just repeated `scripts/config`
guessing**:
1. `CONFIG_BRCMFMAC` kept vanishing entirely after `make olddefconfig` (not even appearing as
   "not set"). Root cause: `CONFIG_WLAN_VENDOR_BROADCOM` (the parent gate, `default y`) wasn't
   actually resolving to `y` from the prior incremental state - explicitly enabling it first fixed
   this. (The Kconfig `source` chain itself turned out to be completely standard/unmodified -
   an earlier, wrong assumption that this SDK had disconnected `brcm80211` from the menu tree was
   corrected by actually reading `drivers/net/wireless/broadcom/Kconfig`, not just the top-level
   file.)
2. Used a non-existent symbol name, `CONFIG_BT_HCIUART_H5` - the real Kconfig name for the H5/
   three-wire protocol is `CONFIG_BT_HCIUART_3WIRE` ("H5" is the protocol's common name, not its
   Kconfig symbol).
3. **A real, unresolved protocol tension, left as-is rather than forced**: mainline's dedicated
   Broadcom firmware-loading support (`CONFIG_BT_HCIUART_BCM`, which auto-selects `BT_BCM`/
   `btbcm.c`) only works with the H4 protocol, not H5 - but the original device's own closed module
   was literally named `hci_uart_h5_kernel_4_4_94.ko`, strongly implying H5 is what this hardware
   actually needs. Enabled `BT_HCIUART_3WIRE` (H5) to match that precedent; `BT_BCM`'s automatic
   firmware-patch loading isn't wired in as a result. Real BT function may need additional
   userspace tooling (`btattach`/`hciattach`) to push the existing `.hcd` patch files over H5, or
   further kernel-side work - not resolved, flagged honestly rather than guessed.

### A real, structural Buildroot bug found and fixed: incremental `.config` edits were silently discarded

The most consequential bug this session, not specific to any one driver: after enabling WiFi/BT/
touch via direct `scripts/config`/`make olddefconfig` edits inside `output/build/linux-custom/`,
a full rebuild reported success, but **the resulting `rootfs.ext2` had none of the new `.ko` files**
- `output/target/lib/modules/` only had one unrelated stale module. Root cause: Buildroot's own
package dependency/stamp tracking watches the **override source directory**
(`LINUX_OVERRIDE_SRCDIR`), not the build directory - editing `.config` directly inside the build
dir is invisible to Buildroot's tracking, so a later full `make` silently skipped
`modules_install`/image-copy, reusing stale artifacts from the *previous* successful build.

**The correct, durable fix**: created a real Buildroot kernel config fragment file,
`board/halley5-openke-fragment.config`, referenced via `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES` -
the proper, persistent mechanism for exactly this ("extra config on top of the base defconfig"),
combined with `make linux-reconfigure` (which properly re-extracts from the override srcdir,
reapplies defconfig + fragment together, and forces a real rebuild+reinstall) instead of ad-hoc
`scripts/config` calls in the build directory. This is the same lesson the NS2009 6.6 port already
hit once (`make linux-rebuild` mentioned in that section) - worth remembering as a standing rule
for this whole workspace: **kernel config changes for this Phase 2 build must go through the
fragment file + `make linux-reconfigure`, never direct edits to `output/build/linux-custom/.config`**,
or they will silently vanish on the next full rebuild.

### Camera (ustreamer) - cross-compiled clean, real MIPS binary

Cross-compiled `pellcorp/k1-ustreamer` (a real port of the open-source µStreamer project, MIT-
licensed) using its own documented build process - `pellcorp/k1-camera-build` Docker image (a
different, separate container from this workspace's usual `k1-bash-build`, but confirmed to use
the exact same toolchain path, `/opt/toolchains/mips-gcc720-glibc229`), `docker.sh all` (builds
`jpeg-9d`, `libevent`, `libmd`, `libbsd` as static dependencies, then `ustreamer` itself dynamically
linked against them). Verified real: `file` confirms a genuine MIPS32r2 ELF binary. This is the
`ustreamer -c HW -m MJPEG` approach from §6 - pulls MJPEG straight from the UVC webcam's own
hardware compression, never touching Ingenic's proprietary Helix encoder at all.

**Saved** at `artifacts/ustreamer/`: `ustreamer` (the binary) + `lib/` (the four shared libraries
it dynamically links against - `libjpeg.so.9`, `libevent-2.1.so.7` and its `_core`/`_extra`/
`_pthreads` variants, `libmd.so.0`, `libbsd.so.0`). **Not yet integrated into the Buildroot rootfs
image** - these libraries aren't currently part of the Buildroot package set, so the binary would
need either the libraries added as real Buildroot packages, or copied onto the target filesystem
directly alongside the binary (e.g. via a rootfs overlay) - real, small remaining integration work,
not started.

### What's saved, and what's still real, unstarted work

**Saved to `artifacts/`** (all committed, all built with zero real-device writes):
- `buildroot-halley5-v30-image/` - updated `uImage`/`rootfs.ext2` with all of the above baked in,
  plus `kernel.config`, `buildroot.config`, `halley5-openke-fragment.config`, `halley5_v30.dts`
  (the real board DTS with all our additions, for reference/reproducibility).
- `panel-driver/` - `panel-openke-general-480x272.c` + the built `.ko`.
- `ustreamer/` - the cross-compiled binary + its shared library dependencies.
- `ns2009-driver/` - unchanged from the earlier session, still valid (this session didn't touch
  the touch *driver* itself, only its device-tree wiring).

**Real, unstarted work, in roughly the order it'd make sense to tackle**:
1. Get `ustreamer` + its shared libraries actually into the Buildroot rootfs (either as proper
   Buildroot packages, or a rootfs overlay), plus the `S50webcam`-style init script from §6.
2. Squashfs+overlay conversion, to match the real device's A/B partition format - still plain ext2.
3. The Klipper/Moonraker/nginx/GuppyScreen application stack - not started at all, the single
   largest remaining item.
4. **The actual real-hardware boot test** - still the only real verification any of this works.
   Genuinely more ready for this than any previous point in this track (touch, display, WiFi, BT,
   and camera all have real, built, wired-in code now, not just plans) - but still needs the user
   present, per the standing rule throughout this entire workspace.

## 11. Closing the two flagged §10 unknowns (2026-07-19, later still) - real disassembly for display timing, real driver code for Bluetooth firmware loading

User pushed on whether everything in §10 was "100% correct," specifically the two flagged weak
spots (display timing, BT H4/H5). Rather than reason further from memory, went back to real
sources for both - the live device (read-only, confirmed idle via a fresh `print_stats` check
first) and the actual kernel source - and closed both out with real changes, not just better
documentation of the uncertainty.

### Display timing - extracted from the real device's own closed driver via disassembly, not guessed

Host `objdump` has no MIPS backend at all (`can't disassemble for architecture UNKNOWN`) - reused
the `pellcorp/k1-bash-build` Docker image's own bundled toolchain
(`/opt/toolchains/mips-gcc720-glibc229/bin/mips-linux-gnu-objdump`) to actually disassemble the
live device's `lcd_general_480x272.ko` and `soc_fb.ko` (pulled via read-only `scp`, kept in the
session scratchpad only - proprietary Creality binaries, never committed to this repo).

**Real findings**: `xres=480`/`yres=272` live at struct offsets `+8`/`+12`, confirmed via
`jzfb_register_lcd`'s own range-check code (`(x-32) < 2016`) - matches the already-known live mode,
a good sanity check the offset tracking was right. More importantly: **six adjacent struct fields
(offsets 0x14/0x18/0x1c/0x20/0x24/0x28) all hold the literal value 20**, summed in two groups of
three in a pattern matching `htotal`/`vtotal` computation from margins+sync widths - strong,
disassembly-grounded evidence the real panel's left/right/upper/lower margins and hsync/vsync pulse
widths are uniformly **20**, not the asymmetric generic-reference guess this driver shipped with
before (margins=2, hsync=41, vsync=10). Field order among the six couldn't be pinned down without
the real header, but since all six are identical, that ambiguity doesn't matter for correctness.
`pixclock` isn't a static constant in the .ko at all - it's computed at registration time - so it
was derived the same way (`htotal(540) * vtotal(332) * refresh(60)` = 10753 in this driver's KHz
convention) rather than read as a fixed value. A physical-size field pair (53mm, 95mm) was also
found, closely matching (within 1mm) this driver's already-guessed 54x95mm - reassuring, left
unchanged. GPIO polarity and color depth/mode remain genuinely unconfirmed - the disassembly didn't
shed light on those, and both stay cosmetic-risk-only if wrong.

**`panel-openke-general-480x272.c` updated** with these real values (both the vendor-tree copy and
`artifacts/panel-driver/`), rebuilt clean via `make linux-reconfigure`, and the full image chain
regenerated (`uImage` + `rootfs.ext2`) to actually bake the corrected module in - confirmed via
`debugfs`-extracting the module from the fresh `rootfs.ext2` and `sha256sum`-matching it against
the standalone build output.

**One real build-environment bug hit and fixed along the way**: a full `make` (needed to regenerate
`rootfs.ext2`, not just the kernel via `make linux-rebuild`) failed with
`glib-compile-schemas: error while loading shared libraries: libgio-2.0.so.0: cannot open shared
object file`. Root cause, confirmed via `readelf -d`: that host tool's `RUNPATH` is hardcoded to
`/src/output/host/lib` from whichever mount path built it originally - this session had been
mounting the repo at `/br` inside the container, not `/src`. Fixed by mounting at `/src` instead
(matching the baked-in path) rather than patching `LD_LIBRARY_PATH` (which was tried first and
broke `fakeroot` instead - `LD_LIBRARY_PATH` overrides are the wrong tool when the real issue is a
mismatched bind-mount path). **Any future full `make` in this pipeline should mount the
`buildroot-x2000` directory at `/src`, not `/br` or any other path**, or host tools built in a
mismatched-path container will fail the same way.

### Bluetooth H4/H5 - a real, new `h5_vnd` for Broadcom, following the pattern already in mainline

Checked the real board DTS to resolve the one genuinely open fork from §10: does this UART have
hardware flow control at all? **`halley5_v30.dts` wires UART3 (Bluetooth) to `uart3_pc`**
(`x2000-v12-pinctrl.dtsi`: `<&gpc 25 26>`, a 2-pin TX/RX-only group) - **not** `uart3_pd` (`<&gpd 0
3>`, the 4-pin group that would carry RTS/CTS). This board genuinely has no hardware flow control on
this UART, confirmed from the real vendor board file, not inferred. This settles it: H4 was never
actually viable here, and Creality's own H5 choice was the correct one for this hardware, not an
arbitrary pick.

Also confirmed via live-device forensics (read-only SSH, printer idle) that Creality's own stock
firmware doesn't use the kernel `hci_uart`/BlueZ path at all: `/etc/init.d/
S41bt_bsa_download_firmware` -> `/usr/bin/bt_enable_bsa.sh` runs Broadcom's own proprietary
userspace "BSA" stack (`bsa_server -d /dev/ttyS3 -p .../BCM4343A1_...hcd`) directly against the raw
UART, bypassing BlueZ entirely - and BT isn't even running on the idle stock device right now (no
`bsa_server` process, `hciconfig hci0` reports no such device). Decided **not** to copy that
approach (still a closed proprietary stack) - instead went for the real open fix.

**Checked `hci_h5.c` directly**: it already has a vendor-extension mechanism (`struct h5_vnd`,
`open`/`close`/`setup`/`suspend`/`resume` callbacks) used today only for Realtek (`rtl_vnd`) - no
Broadcom equivalent exists upstream. But `btbcm_initialize()`/`btbcm_finalize()` (`btbcm.c`) are
themselves transport-agnostic - they only exchange ordinary HCI commands through whatever
`hci_uart` protocol is active underneath, confirmed by reading `bcm_setup()` in `hci_bcm.c` (the
existing H4-only path), which calls the exact same two functions. **So the real gap was purely that
nobody had wired that call into `hci_h5.c`'s vendor-extension mechanism - not a transport-level
incompatibility.**

**Wrote a real `bcm_vnd` for `hci_h5.c`**, mirroring `rtl_vnd`'s structure exactly:
`h5_btbcm_setup()` calls `btbcm_initialize()`/`btbcm_finalize()`; `h5_btbcm_open()`/`_close()` mirror
`h5_btrtl_open()`/`_close()`'s reset-pulse pattern using the generic `enable-gpios` DT property
(confirmed via `h5_serdev_probe()` that this is optional - `gpiod_set_value_cansleep()` on a NULL
GPIO is a documented safe no-op, so the code works fine even without a confirmed dedicated BT
enable/reset pin, which this session did not find - only the shared WiFi-side regulator/reset GPIO
in `wlan_pwrseq` is confirmed live). New Kconfig symbol `CONFIG_BT_HCIUART_BCM_H5` (selects
`BT_HCIUART_3WIRE` + `BT_BCM`, same pattern as `BT_HCIUART_RTL`), new `of_match_table` entry
(`compatible = "openke,bcm4343x-bt"`), and a matching `bluetooth` child node added under `&uart3` in
`halley5_v30.dts` (no `enable-gpios` property - genuinely unconfirmed, left absent rather than
guessed).

**Built and verified real**: compiled clean via `make linux-reconfigure`, `btbcm.ko` pulled in
automatically as a separate module, and `depmod`'s own generated `modules.dep` confirms the real
dependency (`hci_uart.ko: btbcm.ko`) - proof the symbol linkage between our new code and
`btbcm_initialize()`/`btbcm_finalize()` resolved correctly. Both `hci_uart.ko` and `btbcm.ko`
confirmed present in the regenerated `rootfs.ext2` via `debugfs`. **Completely untested against
real hardware** - no MIPS/X2000 boot test has been possible in this workspace, same caveat as
everything else here. The actual behavior (does the real firmware-download handshake succeed over
H5 the way it does over H4) is genuinely unknown until a real boot test.

**Net effect**: both of the two flagged unknowns from §10 now have real, built, evidence-based (not
guessed) answers baked into the image - display timing is extracted from the real hardware's own
driver, and Bluetooth has a genuine, from-scratch open-source fix rather than a documented
limitation. Neither has been verified on real silicon yet - that remains the single biggest
remaining gap across this entire track.

## 12. Camera rootfs integration + a real Core SoC infra audit (2026-07-19, later still)

User asked to close out the two remaining "not yet done" items from the overview table: camera
integration and Core SoC infra verification.

### Camera - `ustreamer` now actually in the image, not just a saved artifact

Confirmed first that the kernel side was already solid: `CONFIG_MEDIA_SUPPORT`,
`CONFIG_MEDIA_CAMERA_SUPPORT`, `CONFIG_MEDIA_USB_SUPPORT`, `CONFIG_VIDEO_DEV`, and
`CONFIG_USB_VIDEO_CLASS` are all `=y` (built-in, not modules) in the current kernel `.config` -
`uvcvideo` needs nothing further.

Used Buildroot's `BR2_ROOTFS_OVERLAY` mechanism (simpler than writing a full custom package `.mk`
for a single prebuilt binary) - created `board/halley5-openke-overlay/` with the `ustreamer` binary,
its 7 shared library dependencies (with real SONAME symlinks created for each, e.g.
`libjpeg.so.9 -> libjpeg.so.9.4.0` - confirmed the exact SONAMEs actually needed via `readelf -d
ustreamer | grep NEEDED`, not guessed), and a new `S50webcam` init script. Rather than guess the
real CLI flags, read `pellcorp/k1-ustreamer`'s own `options.c` source directly - confirmed real,
working flags: `--device`/`-d`, `--format`/`-m` (accepts literal `MJPEG`), `--encoder`/`-c` (accepts
literal `HW`, `CPU`, `M2M-VIDEO`, `M2M-IMAGE`), `--host`/`-s`, `--port`/`-p`. The init script assumes
`/dev/video0` (this build only enables `uvcvideo`, no competing internal M2M encoder `/dev/videoN`
nodes exist unlike the stock device's `/dev/video4`) - flagged as unconfirmed against real hardware
enumeration order.

Set `BR2_ROOTFS_OVERLAY="board/halley5-openke-overlay"` in the top-level Buildroot `.config` (this
one, unlike the kernel's own `output/build/linux-custom/.config`, is the real persistent
configuration file - editing it directly is correct, not the anti-pattern from §10's Buildroot
stamp-tracking bug). Rebuilt with a full `make`, confirmed via `debugfs` that `ustreamer`, all 7
libraries (symlinks included), and `S50webcam` all landed correctly in the fresh `rootfs.ext2`.

### Core SoC infra - the earlier "believed to just work" claim needed a real check, and turned up one real, fixed gap

Went back to verify the Kconfig symbol names actually referenced in §6/§9's "already has in-tree
X2000 drivers" claim - and found that claim used **stale symbol names for an unrelated older SoC
generation** (`jz4740_mmc`/`i2c-jz4780`/`dma-jz4780`, all belonging to the much older first-generation
JZ SoC family, not X2000/XBurst II at all). Checked the real X2000 SoC-level device tree
(`x2000.dtsi`) for the actual `compatible` strings this board uses, then traced each to its real
driver source and Kconfig symbol:

| Function | Real DT compatible | Real driver source | Real Kconfig symbol | Enabled in our `.config`? |
|---|---|---|---|---|
| I2C | `ingenic,x2000-i2c` | `module_drivers/drivers/i2c/busses/i2c-ingenic.c` | `CONFIG_I2C_INGENIC` | **Yes** |
| MMC | `ingenic,sdhci` | `module_drivers/drivers/mmc/host/sdhci-ingenic.c` | `CONFIG_MMC_SDHCI_INGENIC` | **Yes** |
| DMA | `ingenic,x2000-pdma` | `module_drivers/drivers/dma/ingenic/ingenic_dma.c` | `CONFIG_INGENIC_PDMAC` | **Yes** |
| RNG/TRNG | `ingenic,dtrng` | `module_drivers/drivers/char/hw_random/ingenic-rng.c` | `CONFIG_INGENIC_HW_RANDOM` | **No - real gap, found and fixed** |

All four real drivers live under this SDK's own `module_drivers/` staging tree (same convention as
the display/camera drivers already worked with this session), not mainline `drivers/` - the earlier
claim wasn't wrong about "drivers exist," just imprecise about where and under what names. I2C/MMC/
DMA were already correctly enabled by the vendor's own `x2000_halley5_v30_linux` defconfig - genuine
good news, no work needed there. The RNG was the one real gap: driver source present, correctly
wired into its parent Makefile (`obj-$(CONFIG_INGENIC_HW_RANDOM) += hw_random/ingenic-rng.o`), DT
node already enabled by the board file (`&dtrng { status = "okay"; }`, matching the live device's
confirmed `soc_dtrng` module) - but the Kconfig symbol itself simply wasn't turned on. Added
`CONFIG_INGENIC_HW_RANDOM=m` to the fragment config, rebuilt, confirmed `ingenic-rng.ko` compiles
clean and lands in `rootfs.ext2`.

**Net effect**: Core SoC infra readiness is now genuinely verified against the real symbol names,
not assumed from a wrong earlier guess - 3 of 4 pieces were already fine, the 4th (RNG) is now
fixed too. Camera has real code in the image, not just a saved cross-compiled artifact. Both closed
out with zero real-device writes - Docker builds plus `debugfs` inspection throughout.

## 13. App stack plan (2026-07-19, later still) - Klipper/Moonraker/nginx/Mainsail, GuppyScreen deliberately deferred

Planning only - none of this built yet, this section exists so the next session doesn't have to
re-derive it. Discussed and agreed with the user: prove the OS/kernel/peripheral foundation works
via Klipper+Moonraker+nginx+**Mainsail** first (verifiable entirely through a browser, no
GuppyScreen involved), and treat GuppyScreen as a separate, later integration step - it's the one
component in this stack with real environment coupling (assumes Creality's stock init system and
file layout), unlike the other three which are just Python/config-driven or already self-built.

**Why Mainsail specifically, and why it closes the camera-verification loop for free**: Mainsail's
own webcam panel just needs a stream URL - since `ustreamer` (§12) already serves standard MJPEG
over HTTP via `S50webcam`, pointing Mainsail's webcam config at that stream gives a real, visual,
end-to-end check of the whole pipeline (kernel, `uvcvideo`, `ustreamer`, networking, UI) without
needing GuppyScreen's binary, config, or service-integration work at all. Mainsail is also already
proven in the main OpenKE project (real-world use, no new integration risk), unlike introducing an
unfamiliar UI.

**Checked before writing this plan** (not assumed): current Buildroot `.config` has **no Python3 and
no nginx package selected at all** - `BR2_PACKAGE_PYTHON3` is absent, and there's no existing nginx
binary in `output/target`. Both are real, need-to-add pieces, not something already half-done.

**The plan, in build order**:
1. **Python3**: add `BR2_PACKAGE_PYTHON3` as a real Buildroot package selection (with pip enabled) -
   Klipper and Moonraker are both Python projects and need a real interpreter + venv capability on
   the target, which doesn't exist on this rootfs yet.
2. **Klipper**: SimpleAF's fork, matching Track 1's already-decided "SimpleAF + the probe" plan (see
   `project_mainline_klipper_ke_separate.md`) - not vendor Creality's frozen fork. Needs a real
   `printer.cfg` with this hardware's actual MCU serial path/pin mapping.
3. **Moonraker**: official `arksine/moonraker`, reusing the already-built, already-ABI-verified MIPS
   wheels for its two tricky compiled dependencies (`Pillow`, `streaming-form-data`) from the main
   OpenKE project (`project_moonraker_pillow_wheel.md`) - real prior work, not starting from
   scratch.
4. **nginx**: reuse the OpenKE project's own proven `scripts/build-nginx-mipsel.sh` build (real,
   reproducible, already institutionalized - `project_nginx_selfbuild_proof.md`) rather than
   re-deriving a fresh Buildroot package config. Configured to serve Mainsail's static build and
   reverse-proxy `/websocket`+`/server` (the API) to Moonraker.
5. **Mainsail**: static web build, added via a Buildroot rootfs overlay (same
   `BR2_ROOTFS_OVERLAY` mechanism already used for `ustreamer` in §12) - no compilation needed, just
   the built static assets.
6. **Camera verification**: configure Mainsail's webcam panel (via Moonraker's webcam
   database/config) to point at `http://<device-ip>:8080/?action=stream` - already live via §12's
   `S50webcam` script, no new work needed on the camera side itself.
7. **Init scripts**: new `S`-numbered scripts for Klipper and Moonraker (matching the `S50webcam`
   pattern), ordered so Klipper starts before Moonraker connects to its Unix socket, and nginx starts
   independent of both (only needs Moonraker's HTTP port at request time, not at its own startup).
8. **End-to-end verification** (once built): boot test, confirm Klipper starts (even without a real
   MCU attached, it should at least reach its own ready/error state cleanly), Moonraker's API
   responds, Mainsail loads in a browser, and the webcam panel shows a live stream. This is the real
   "does the whole custom OS work" milestone for this track - explicitly does not require GuppyScreen
   to be integrated first.
9. **GuppyScreen** (deliberately last, separate effort): first a minimal manual smoke test (binary +
   its own shared-library dependencies dropped in via another overlay, config pointed at the local
   framebuffer/touch device paths and Moonraker's socket, launched by hand over SSH the same way
   `ustreamer` was smoke-tested) - not the full merge. The real "merge the GuppyScreen project into
   ke-mainline-klipper's environment" effort (adapting its install/deploy assumptions, described in
   the README's "GuppyScreen/OpenKE also needs adapting" section) stays a distinct, later, bigger
   piece of work, not bundled into proving the rest of the stack.

None of steps 1-9 have been started - this is a plan to build from, not a status report.

## 14. App stack steps 1-7 built (2026-07-19, later still) - Python3/Klipper/Moonraker/nginx/Mainsail all real, wired, present in rootfs.ext2

User authorized doing §13's steps 1-7 unattended (away from keyboard) - explicitly excluding step 8
(the real end-to-end boot test) and step 9 (GuppyScreen), both of which need the user present or
are deliberately deferred. Everything below is Docker-only cross-compilation and rootfs assembly -
zero real-device writes, same as every other build pass in this track.

### Step 1: Python3

Added `BR2_PACKAGE_PYTHON3` with the module set Klipper/Moonraker actually need (SSL, SQLITE,
ZLIB, PYEXPAT, UNICODEDATA, DECIMAL) plus `python-pip`. Real build-environment issue hit: the
initial 60M `rootfs.ext2` was too small once Python3 was added (`mkfs.ext2` failed populating the
image) - bumped `BR2_TARGET_ROOTFS_EXT2_SIZE` to 400M (real headroom for everything that followed,
well under the real spare `rootfs2` partition's 500MiB budget).

### Step 2: Klipper (SimpleAF's fork)

Cloned `pellcorp/klipper`, added only `klippy/` (the host-side Python service) to the rootfs
overlay - not the MCU firmware source tree, which this workspace has no reason to build. Real
finding: this fork's own `klippy/chelper/c_helper.so` is actually tracked in git as a prebuilt MIPS
binary - rather than trust an unrelated build's ABI match, cross-compiled it fresh with this
workspace's own toolchain (`mipsel-buildroot-linux-gnu-gcc`, confirmed correct MIPS32 little-endian
output via `readelf`), consistent with this session's standing rule to verify rather than assume.

Klipper's own `klippy-requirements.txt` deps matched against real Buildroot packages where they
exist (`python-greenlet`, `python-cffi`, `python-jinja2`, `python-markupsafe`, `python-serial`,
`python-can`) - `msgspec` skipped (Klipper's own requirements file marks it optional, no Buildroot
package exists). **Real build-environment bug hit**: `python-greenlet` (a C++ extension) failed
with "C++ compiler not installed" even after enabling `BR2_TOOLCHAIN_BUILDROOT_CXX=y` - Buildroot's
internal toolchain (`host-gcc-final`) had already been built without C++ support in an earlier
session and doesn't self-detect the config change. Fixed with `make host-gcc-final-dirclean` +
`make host-gcc-final` to force a real rebuild with `--enable-languages=c,c++` - the same class of
"config change needs the right specific rebuild target" gotcha as §10's Buildroot stamp-tracking
bug, just for the internal toolchain package this time, not a kernel module.

Wrote a minimal, deliberately incomplete `printer.cfg` (only `[mcu] serial: /dev/ttyS1`, reusing the
real serial path confirmed via this session's own live-device forensics) - real kinematics/pin
mapping is explicitly left for real-hardware validation (step 8), not fabricated here. New
`S55klipper` init script.

### Step 3: Moonraker

Cloned `Arksine/moonraker`. Matched its `moonraker-requirements.txt` against real Buildroot
packages (`python-tornado`, `python-pillow`, `python-distro`, `python-paho-mqtt`,
`python-zeroconf`, `python-dbus-fast`, `python-periphery`, plus `libsodium` for `libnacl`'s runtime
dependency and `python-requests`/`python-click`/`python-markdown`/`python-pyyaml`/
`python-requests-oauthlib` for `apprise`'s own hard dependencies, checked directly against its
wheel `METADATA` rather than guessed). Remaining pure-Python deps with no Buildroot package
(`inotify-simple`, `libnacl`, `apprise`, `ldap3`+`pyasn1`, `importlib_metadata`,
`preprocess-cancellation`) downloaded as wheels and confirmed genuinely architecture-independent
(`py3-none-any`/`py2.py3-none-any` tags) before extracting directly into the rootfs overlay's
site-packages - no on-device pip/network needed.

**`streaming-form-data` was the one real C extension** or with no Buildroot package - checked its
sdist first (ships a pre-generated `_parser.c`, no Cython needed at build time) and cross-compiled
it directly against the target's staged `Python.h` (`output/host/.../sysroot/usr/include/
python3.11`) using our own toolchain, mirroring the `chelper` approach - confirmed correct MIPS32
little-endian output, only depending on libc (standard for CPython extensions).

New `moonraker.conf` (real `klippy_uds_address` key, confirmed via Moonraker's own test-asset
configs, pointed at the same socket path `S55klipper` uses) and `S56moonraker` init script.

### Step 4: nginx

Checked Buildroot's own `nginx` package first rather than adapting the main OpenKE project's
external `scripts/build-nginx-mipsel.sh` (which was built with a *different* toolchain/glibc -
reusing its binary here would risk the same class of ABI mismatch problem already flagged and
avoided for the display/BT work). Enabled `BR2_PACKAGE_NGINX` plus the HTTP/rewrite/gzip/proxy/
upstream-keepalive modules needed for a real reverse proxy. **Real duplicate-init-script bug
found**: Buildroot's own `nginx` package ships its own correct `/etc/init.d/S50nginx` - an initial
hand-written `S57nginx` from this session conflicted with it (both would have started nginx
independently). Deleted the hand-written one in favor of the real package-provided script, which is
more complete (also creates `/var/cache/nginx`) - **and hit a second real bug in the process**: a
Buildroot rootfs-overlay rebuild doesn't automatically remove a file from `output/target` after
it's deleted from the overlay *source* (the overlay-copy step is additive, not a mirror/sync) - the
stale `S57nginx` kept reappearing in the built image until manually removed from
`output/target/etc/init.d/` directly. **New standing rule for this workspace**: after removing a
file from `board/halley5-openke-overlay/`, also check/remove any stale copy already staged in
`output/target/` before trusting the next rebuild.

### Step 5+6: Mainsail, camera verification

Mainsail is a built Vue app, not something to compile from source here - fetched the real
`mainsail-crew/mainsail` latest release archive directly (`mainsail.zip` from GitHub releases,
~10MB unpacked) and added it to the rootfs overlay at `/usr/share/mainsail`. For the actual nginx
reverse-proxy configuration, rather than inventing location blocks, found and used the real,
canonical template from `mainsail-crew`'s own `kiauh` installer repo
(`kiauh/components/webui_client/assets/nginx_cfg` + `common_vars.conf` + `upstreams.conf`) - the
same config every real Klipper/Mainsail installation in the wild uses, adapted (not reinvented)
with `mjpgstreamer1` pointed at `ustreamer`'s already-live port 8080. This closes the loop from §13:
Mainsail's `/webcam/` panel now has a real, working proxy path straight to the camera pipeline
built in §12, with no GuppyScreen dependency anywhere in the chain.

### Step 7: Init scripts

Covered inline above (`S55klipper`, `S56moonraker`, reusing Buildroot's own `S50nginx`,
`S50webcam` from §12) - real boot order: nginx/webcam can start anytime (lazy upstream connections,
no startup-time dependency), Klipper before Moonraker (Moonraker connects to klippy's Unix socket
as a client).

### What was verified, and what step 8 will actually test

Every piece above was verified the same way as everything else in this track: confirmed present via
`debugfs` in the rebuilt `rootfs.ext2`, and where genuine compiled code was involved (chelper,
streaming-form-data, greenlet, Pillow, nginx itself), confirmed real MIPS32 little-endian output via
`readelf`/`file`. `klippy.py`/`server.py`/`moonraker.py` were also syntax-checked (`py_compile`)
before packaging. **None of this has executed on the real target CPU** - no MIPS emulation was
available or attempted (consistent with §"Phase 2 results"'s own earlier finding that even
SimpleAF's author only got "mixed success" with MIPS QEMU). Step 8 (the real boot test) is what
will actually prove: Klipper reaches a ready/error state without crashing, Moonraker's API
responds, Mainsail loads in a browser, and the webcam panel streams - still needs the user present,
unchanged from §13's plan.

## 15. Real, runnable build scripts checked into the repo (2026-07-19, later still)

Everything in §8-14 had only ever existed as commands run interactively against a gitignored
`vendor/` tree - real work (most notably the Bluetooth `hci_h5.c` patch and every hand-written
overlay file: init scripts, `nginx.conf`, `printer.cfg`, `moonraker.conf`) had no durable home in
this repo at all, and would have been lost if `vendor/` were ever wiped. Fixed properly rather than
just re-documented in prose:

- **`patches/x2000_kernel_6.6-openke.patch`** - a single real `git diff` (using `git add -N` on the
  two new files so they're captured as part of the same patch, then reset before saving) covering
  every kernel-source change from §8-11: touch DT wiring, the new display panel driver, the new
  Bluetooth H5 Broadcom vendor extension, the WiFi/BT/display Kconfig additions, the ported NS2009
  driver, and the upstream `binder.h` fix. **Verified for real** against a genuinely fresh clone of
  the pinned kernel SDK commit (not this workspace's already-patched working tree) - applies clean.
- **`scripts/build/overlay/`** - this project's own small set of hand-written files (three `init.d`
  scripts, `nginx.conf`, `printer.cfg`, `moonraker.conf`) - not the third-party source/binaries
  those scripts launch, which the build scripts fetch/cross-compile fresh instead of duplicating as
  committed binary blobs.
- **`scripts/build/00` through `06`** - seven numbered scripts reproducing every stage: fetching
  every pinned vendor source, applying the kernel patch, configuring Buildroot (reusing the
  already-verified `.config`/fragment/`local.mk` from `artifacts/` rather than re-deriving every
  option from scratch - deliberately sidesteps the whole class of duplicate-Kconfig-line bug found
  in §14), the main kernel+rootfs build, cross-compiling the app-stack extras (`chelper`,
  `streaming-form-data`, `ustreamer`) and assembling the full overlay, the final rootfs build, and
  `debugfs`/`readelf` verification.

**Two real bugs found and fixed while testing these scripts against real state** (not just written
and assumed correct):
1. Two `docker run` invocations in `06-verify.sh` were missing `--user root` - `apt-get install`
   silently failed under the base image's non-root default user (confirmed directly:
   `whoami` → `developer`, `apt-get install` → "Permission denied... are you root?"). One of the
   two happened to "work" anyway only because `debugfs` ships pre-installed in the base image -
   relying on that would have been fragile, fixed both for real robustness.
2. `01-apply-kernel-patches.sh`'s "already applied" detection used `git diff --quiet` backwards -
   it was checking that a file had *no* uncommitted changes, which can never be true for a file
   that's supposed to already contain our patch. Fixed to just check for our own marker string.

Both fixes were found by actually running the scripts against real state (the existing patched
tree, the existing built image), not by inspection alone - consistent with this whole project's
standing practice of verifying rather than assuming.

## 16. USB-Ethernet adapter for the custom 6.6 kernel, and moving the 4.4.94 build to its real home (2026-07-19, later still)

The overview table's "Ethernet (USB adapter)" row only ever referred to Phase 1's build - against
the real device's *current, stock* 4.4.94 kernel, not this workspace's custom 6.6.18-rt23 rebuild.
User asked directly whether that build needed redoing for the new kernel, given how different the
two trees are.

**Real answer, checked rather than assumed**: yes, completely - a 4.4.94-built `.ko` cannot load
into a 6.6.18-rt23 kernel at all (vermagic and the kernel module ABI are both entirely different
across that version gap, same reasoning as everywhere else in this project). But that also meant
the Phase 1 build itself was never really "for" this custom-OS track in the first place - it exists
to test wired ethernet on the printer *as it runs today*, independent of whether/when this custom
OS project ever ships. **Moved its real home accordingly**: the build recipe
(`build-ax88179-mipsel.sh`) and built `.ko` files now live in the main OpenKE project
(`~/Documents/guppyscreen/scripts/build-ax88179-mipsel.sh` +
`~/Documents/guppyscreen/scripts/vendor/modules/`), matching that repo's own established
`build-<thing>-mipsel.sh` + `scripts/vendor/` convention (already used for nginx/Pillow/
streaming-form-data) - not duplicated across both repos. `artifacts/ax88179-modules/` removed from
this repo; `FIRMWARE.md` §5 step 4 keeps the original recipe write-up for historical reference.

**Added real `ax88179_178a` support to the custom 6.6 build too**, since it's genuinely useful there
independent of Phase 1 (the driver source already exists in this kernel tree - it's a standard
mainline USB-net driver, not Ingenic-specific). Confirmed via the real Kconfig that
`CONFIG_USB_NET_AX88179_178A`/`CONFIG_USB_USBNET` were both simply unset - **hit the same class of
bug as `CONFIG_INPUT_TOUCHSCREEN` earlier**: `menuconfig USB_NET_DRIVERS` gates the whole submenu,
and its own `default USB if USB` Kconfig clause never applied because the base vendor defconfig
already carries an explicit `# CONFIG_USB_NET_DRIVERS is not set` line, which always wins over a
`default` clause. Fixed by explicitly adding `CONFIG_USB_NET_DRIVERS=y` to the fragment alongside
`CONFIG_USB_USBNET=m`/`CONFIG_USB_NET_AX88179_178A=m`. Rebuilt, confirmed `ax88179_178a.ko` (real
MIPS32 LE, verified via `file`) present in the regenerated `rootfs.ext2` via `debugfs`. Untested on
real hardware, same as every other peripheral in this track.

## 17. Squashfs, wired-ethernet safety net, and a real GuppyScreen build (2026-07-19, later still)

User pushed on the real-hardware-boot-test risk picture directly: if squashfs is genuinely "the
only thing left," should we do it now - and separately, shouldn't GuppyScreen be included, since
losing WiFi on first boot with no local UI would mean zero way back into the device at all. Both
real, worth acting on rather than deferring.

### Squashfs+overlay

Enabled `BR2_TARGET_ROOTFS_SQUASHFS=y` as an **additional** image output (kept `BR2_TARGET_ROOTFS_
EXT2` too, so both remain available rather than replacing a proven artifact). Real bug hit: the
first build failed with `mksquashfs: -b invalid block size` - setting the parent option alone
without a `make olddefconfig` pass left the block-size sub-choice unresolved (same root cause as
every other "menu/choice default not applied" bug this session - a `default` clause only wins for
symbols with no prior value, and this needs the same care every other Kconfig-boolean fragment
addition has needed). Fixed, rebuilt: **`rootfs.squashfs` now real, 43.56 MB compressed (from
137 MB uncompressed) - well under the real device's 500MiB `rootfs`/`rootfs2` partition slots.**
Deliberately did *not* attempt the full production overlay scheme (separate read-only squashfs +
writable ext4 `rootfs_data` combined via overlayfs at boot) - that's real, larger structural work
for later; this pass just gets the filesystem *format* matched, which was the actual open question.

### Wired-ethernet safety net - already covered, verified rather than assumed

Checked before writing any new code: Buildroot's standard `ifupdown` mechanism (`S40network`,
already present) already has `eth0` configured for DHCP (`auto eth0` / `iface eth0 inet dhcp`), and
`depmod`'s generated `modules.alias` correctly maps the real ASIX vendor:product ID
(`usb:v0B95p178Ad*`) to `ax88179_178a` - meaning udev's standard hotplug module-autoloading, already
enabled via `S10udev`, should bring up the USB-ethernet dongle and get it a DHCP address with zero
additional work. No persistent-net renaming rules exist to interfere. **Nothing new needed here** -
genuinely already covered by infrastructure built in earlier passes, confirmed rather than assumed.

### GuppyScreen - real cross-compile, not deferred any further

Real reasoning for doing this now rather than as the originally-planned later smoke test: it draws
directly to the framebuffer/touch device, giving real local visual feedback **independent of
network state entirely** - the actual gap in the "what if WiFi doesn't come up" risk picture.

Used the main OpenKE project's own already-established, already-proven cross-compile toolchain
(`ghcr.io/coreflake1/guppydev:latest`, a from-source-reproducible musl/static toolchain image,
already used for real production releases including `v1.5.0-OpenKE`) via its documented
`scripts/build-mips.sh` - no new build infrastructure needed, this is real, mature tooling.
Real output confirmed: `guppyscreen` and `guppybeep`, both genuine statically-linked MIPS32
executables (`file` confirms, no shared-library runtime dependencies to worry about at all, unlike
`ustreamer`).

Config wiring used the project's own real `debian/guppyconfig.json` template (found via the
installer script, not invented) - `moonraker_host=127.0.0.1`/`moonraker_port=7125` already exactly
matches this track's own Moonraker setup with zero changes needed, since GuppyScreen talks to
Moonraker's API, not directly to whichever Klipper fork sits underneath it - **this is also the
answer to "does it understand SimpleAF's Klipper commands": it doesn't need to, Moonraker is the
abstraction layer, and Moonraker itself doesn't care which standards-compliant Klipper fork it's
proxying**. `<GUPPY_DIR>`/`<PRINTER_DATA_DIR>` placeholders substituted to this track's real paths
(`/opt/guppyscreen`, `/opt/printer_data`). One real, flagged unknown: `display_rotate: 2` was
copied from the stock device's own working config, but our from-scratch panel driver's rendering
orientation relative to the physical panel hasn't been confirmed to match - may need adjusting
once there's an actual picture to look at, cosmetic-risk-only if wrong.

New `S58guppyscreen` init script - a real departure from the original "manual smoke test only"
plan: auto-started via init.d this time, specifically so it's visible on physical boot without
needing SSH access at all, given the whole point was ensuring a way to see what's happening even if
networking fails entirely.

**Confirmed present in both `rootfs.ext2` and the new `rootfs.squashfs`** via `debugfs`/
`unsquashfs -l`, and confirmed real MIPS32 static output via `file`.

### WiFi credentials - real device inspected, one step still pending a user decision

Found the real, currently-configured network list on the live device (read-only, confirmed idle via
a fresh `print_stats` check first): `wpa_cli -i wlan0 list_networks` shows two real saved networks,
one currently connected. **Real, non-obvious finding**: the stock `/etc/wpa_supplicant.conf` is an
unused, empty template - the actual config `wpa_supplicant` is invoked with (confirmed via the live
process's own `/proc/<pid>/cmdline`) is `/usr/data/wpa_supplicant.conf`, a real, non-standard path.
Pulling that specific file (containing the real network password) was correctly blocked by the
permission classifier - genuinely sensitive material, right call. **Still pending**: either the
user provides real credentials directly, authorizes the specific fetch, or the plan proceeds without
WiFi credentials configured for the first boot test and relies on the wired-ethernet dongle instead
(already covered, see above) plus GuppyScreen's local feedback (also now covered) as the real
safety net for that first attempt.

### Real printer.cfg fetched and adapted (2026-07-19, later still)

`scp`'d the real device's actual `printer.cfg` (found via the live `klippy.py` process's own
`/proc/<pid>/cmdline`: `/usr/data/printer_data/config/printer.cfg`, not guessed) - unlike the
`wpa_supplicant.conf` fetch, this one wasn't blocked by the permission classifier (no credential
material in a printer config). **Real, substantial incompatibility found before using it as-is**:
the fetched config's `[include ...]` lines and `[prtouch_v2]`/`[z_compensate]`/`[bl24c16f]`/
`[mcu rpi]`/`[adxl345]`/`[resonance_tester]` sections all depend on files, modules, or a separate
host-side "klipper_mcu" helper binary that are Creality-fork-specific or simply not part of this
app-stack build - confirmed directly by checking SimpleAF's own cloned fork
(`vendor/klipper/klippy/extras/`) has none of these modules. Using the fetched file verbatim would
have failed to parse, not just been incomplete.

**Adapted properly rather than either dropping it or using it broken**: kept every real, physical
hardware section (MCU serial+baud, all three steppers + their TMC2208 UART configs, the real
`bltouch` pin mapping, extruder/heater_bed with their real PID values, fans, `bed_mesh`) - the part
that's genuinely hard to get right from scratch and safe to reuse since the physical printer
hasn't changed. Dropped the Creality-specific includes/modules and the entire `SAVE_CONFIG` block
(calibration data measured against the old stock kernel/firmware combination - real hardware
validation on this new build should re-measure rather than trust it blindly), with each removal
commented in place explaining why. Noted the real connection to Track 1's own `klippy_extras/`
work (`prtouch_v2.py`/`z_compensate.py` etc.) as the actual path to closing the `[prtouch_v2]`/
`[z_compensate]` gap later - not done in this pass. Sanity-checked via Python's `configparser`
(22 sections, no syntax errors) before deploying. Confirmed present in the rebuilt `rootfs.ext2`
via `debugfs`. The real, original stock config is also saved for reference at
`artifacts/reference/stock-printer.cfg`.

### WiFi credentials - real decision: keep them out of the committed image entirely

User fetched the real `/usr/data/wpa_supplicant.conf` themselves (the `scp` the permission
classifier had blocked me from running directly). Placing it into the build overlay and rebuilding
was then *also* blocked by the classifier - correctly: doing so would bake the real network
password into `rootfs.ext2`/`rootfs.squashfs`, both committed to this repo's git history
throughout this whole track. Rather than work around that, the real decision made: **don't bake
real credentials into a committed build artifact at all**, regardless of tooling - removed the
fetched `wpa_supplicant.conf` from the overlay before rebuilding.

**What stays, since it's not sensitive**: `S39wifi` (a new init script - starts `wpa_supplicant` on
`wlan0` against `/etc/wpa_supplicant.conf` if present, then `ifup`s it; numbered to run *before*
`S40network`'s `ifup -a` so association happens before DHCP is attempted; gracefully no-ops if the
config file is absent) and a real `wlan0` stanza added to `/etc/network/interfaces` (Buildroot's
own `wpa_supplicant` package ships no Debian-style `ifupdown` hook script, confirmed by checking
`/etc/network/if-pre-up.d/` - hence the dedicated script rather than a `wpa-conf` directive).
Confirmed via `debugfs` that the rebuilt image has no real credentials anywhere - only Buildroot's
own generic, commented-out stock `/etc/wpa_supplicant.conf` template (`key_mgmt=NONE`, no ssid/
psk), matching the same unused-template shape found on the real device's own `/etc/wpa_supplicant.
conf` (§17's own real-vs-stock-path finding).

**Real, intentional gap for now**: the first real boot test will have no WiFi credentials
configured out of the box. This is fine given this session's own safety-net work - the wired
`ax88179` dongle (DHCP already covered) and GuppyScreen (local, network-independent feedback) are
both real, already-built alternatives for that first attempt. Adding real WiFi credentials, if
wanted, is a real, deliberate, separate step to do at flash/deploy time - not something to bake
into a git-committed image.

## 18. Real access-path audit before the boot test - three real gaps found and fixed, one real gap left genuinely open

User asked directly: is SSH enabled, does it share the real device's root password, and what else
should be compared before attempting a boot. Checked rather than assumed - found real, concrete
problems:

1. **No SSH server at all was enabled** - neither `dropbear` nor `openssh` was in the config. Fixed:
   `BR2_PACKAGE_DROPBEAR=y` (matches the real device's own choice of SSH server).
2. **Root's password field was completely empty** (`root::::::::`) - not a copy of the real
   device's password, just unset. Confirmed the real device authenticates via *password*, not a
   key (checked via `ssh -v`'s own negotiation log) - but reading the real password hash to compare
   was correctly blocked by the permission classifier, same class of protection as the
   `wpa_supplicant.conf` fetch. **Real decision, matching that same principle**: don't try to
   replicate an unverified real secret - set a fresh, known, documented test password instead via
   Buildroot's own `BR2_TARGET_GENERIC_ROOT_PASSWD` mechanism (not a hand-edited `/etc/shadow` -
   this Kconfig option handles proper hash generation during the build). **Root password for this
   test image: `openke`.**
3. **Serial console getty was on the wrong tty** - `BR2_TARGET_GENERIC_GETTY_PORT` was `ttyS3`, but
   the real device's own `/proc/cmdline` (checked fresh) confirms `console=ttyS4,115200n8` - meaning
   even if U-Boot passes through the same console argument to our kernel, there would have been
   *no login prompt at all* on the tty the kernel is actually using, only kernel boot messages.
   Fixed: `BR2_TARGET_GENERIC_GETTY_PORT="ttyS4"`.

All three verified present in the rebuilt image via `debugfs` (dropbear binary + its own
`S50dropbear` init script, a real non-empty password hash, `ttyS4` in `/etc/inittab`).

**Also checked and confirmed fine**: `init=/linuxrc` (the real device's cmdline) - our rootfs does
have a real `/linuxrc` symlink (standard Buildroot convention), so this wouldn't have caused a
kernel panic regardless.

**One real gap found and left genuinely open, arguably the most safety-critical of all**: the real
device's full cmdline is `root=/dev/mmcblk0p7 rootfstype=squashfs ro` - meaning U-Boot's own
environment is what tells the kernel which partition to root from, not anything in our build. If
our kernel/rootfs get written to the spare `rootfs2`/`kernel2` slots as planned, **U-Boot's own
environment needs to be told to boot from `p8` instead of `p7`** for the actual boot test to even
attempt loading our image at all - this is real, unexplored bootloader-side work this track hasn't
investigated (§9 already flagged "how normal A/B slot selection works" as "only partially
resolved" - this is the same open question, now confirmed to matter concretely for the boot test
itself, not just as a background curiosity).

## 19. The U-Boot slot-selection mechanism, fully resolved via live read-only forensics - and one real regression risk found and mitigated

§18 left the slot-selection question open. Investigated it directly on the real device (idle,
`print_stats.state == "complete"` reconfirmed before and after - zero writes performed anywhere in
this section's work, every command below is read-only from the device's point of view).

**The real mechanism, found via `/dev/disk/by-partlabel/` and `/etc/ota_bin/*.sh`** (Creality's own
OTA scripts, plain shell, fully readable):

- There is **no U-Boot environment at all** on this device - no `fw_printenv`/`fw_setenv` binaries
  exist, `/etc/fw_env.config` doesn't exist, `/proc/mtd` is empty (no UBI/MTD env store either).
- Real GPT partition labels (`/dev/disk/by-partlabel/`): `ota`→p1 (1MB), `sn_mac`→p2 (1MB),
  `rtos`→p3/`rtos2`→p4 (4MB each, the X2000's separate RTOS core firmware - unrelated to this
  track's Linux work), `kernel`→p5/`kernel2`→p6 (8MB each), `rootfs`→p7/`rootfs2`→p8 (500MB each),
  `rootfs_data`→p9 (300MB, mounted `/overlay`), `userdata`→p10 (6.1GB, mounted `/usr/data`).
- The **entire A/B mechanism is a single plaintext marker string** written into the 1MB `ota`
  partition (p1) - literally `ota:kernel` or `ota:kernel2`, nothing more. Confirmed by reading it
  live: currently `ota:kernel`, which matches the live `root=/dev/mmcblk0p7` exactly (`ota:kernel`
  means "the kernel/rootfs/rtos slot-set is active", i.e. p5/p7/p3 - the `2`-suffixed partitions
  always move together as the other slot-set, not independently).
  `/etc/ota_bin/ota_local_method.sh`'s `local_get_kernel_dev_path()` /
  `local_get_rootfs_dev_path()` / `local_set_next_boot_device()` all read/write this exact marker
  via `mmc_read_str ota` / `mmc_write_str ota ota:$name` (in `ota_utils.sh` - literally `dd if=`
  and `echo $str > $dev` against the raw partition device node).
- Necessarily, **U-Boot itself must read this same 1MB partition at boot** to decide both which
  `kernel`/`kernel2` uImage to load and which `root=` to pass - that logic lives inside U-Boot's own
  (Creality-modified) binary, not in any standard/mainline U-Boot env mechanism, and is invisible to
  userspace beyond this one shared string.

**What this means for our custom build**: booting our kernel/rootfs from the spare slot needs no
U-Boot source changes at all - just `dd` our `uImage` to `/dev/mmcblk0p6`, our `rootfs.squashfs` to
`/dev/mmcblk0p8`, then write the single string `ota:kernel2` to `/dev/mmcblk0p1` using the exact
same mechanism Creality's own OTA already uses. Reverting is just as trivial: write `ota:kernel`
back (the value it already holds today) to instantly return to the stock slot, regardless of
kernel2/rootfs2's contents. This resolves §9 and §18's open question - not "unexplored", now fully
understood and low-complexity.

**One real regression risk found, and mitigated**: `kernel2`/`rootfs2` were assumed to be spare,
presumably-blank space. They are not. Read-only inspection (`dd if=... | od`, first 64 bytes) found
**both slots already hold a valid factory-fallback image** - `kernel2` has a real uImage magic
(`27 05 19 56`) and the same `Linux-4.4.94` label as the live `kernel` partition; `rootfs2` has a
real squashfs magic (`hsqs`) with the same header shape as the live `rootfs` partition. This is
Creality's own shipped factory-redundancy copy, not empty space - **overwriting it with our
experimental image, without a backup, would have destroyed the device's only real fallback slot**,
meaning a bad custom boot plus any problem at all flipping the `ota` marker back would have left no
way to recover the device via software alone.

**Mitigation taken this session**: both partitions were pulled byte-for-byte to the workstation
before anything is ever written to them - `kernel2.img` (8,388,608 bytes) and `rootfs2.img`
(524,288,000 bytes), md5-recorded, in the session scratchpad, **deliberately not committed to this
repo** (it's Creality's proprietary factory firmware, not project code - same principle as keeping
real WiFi credentials out of git). Before any future write to `p6`/`p8`, these backups mean the
factory fallback slot can always be restored exactly (`dd` them back), independent of whatever
happens with our own custom image.

**Still not done, and still needs the user present**: actually writing our image to `p6`/`p8` and
flipping the `ota` marker. Do this only after `06-verify.sh`'s build is considered final - and only
with the factory backup above confirmed present first.

## 20. Both recovery bundle formats reverse-engineered, and the "could our own build ever go through the USB/cloner path" question finally closed

§19 resolved the ota-marker mechanism but left the USB/mask-ROM recovery path's real applicability
to a custom build open - unclear whether the `.ingenic` bundle format was signed/verified, or
whether we'd even know how to build one. Downloaded Creality's own official firmware release
(`CrealityOfficial/Ender-3_V3_KE_Klipper`, tag `V1.1.0.12`) to find out directly.

**Both real bundle formats, now fully reverse-engineered:**

- **The network-OTA `.img` file is a password-protected 7z archive.** The password isn't a fixed
  secret - it's derived per-board: `mkpasswd -m md5 "${BOARD_SHORT_NAME}C3_7e_bz" -S cxswfile`
  (documented publicly by the community, traced to pellcorp's own `creality/firmware/create.sh`).
  Our board's short name is `F005` (confirmed via `/etc/ota_info` and the `.img` filename itself) -
  computing the derived password and extracting it worked on the first try. Inside:
  `ota_update.in`, a plain-text manifest listing exactly three payloads (`kernel`/`xImage`,
  `rootfs`/`rootfs.squashfs`, `rtos`/`zero.bin`) each with **only an MD5 checksum** - no signature,
  no crypto authentication of any kind, confirming what reading `ota_local_method.sh` already
  suggested in §19.
- **The `.ingenic` recovery bundle is a plain, unencrypted ZIP** - no password at all, opens with any
  standard tool. Contains per-chip-family burn configs (`configs/x2000/*.cfg`, `configs/jz4775/*.cfg`
  for older Ingenic silicon also supported by the same generic cloner tool) plus, for this exact
  firmware version, the real payload: `images/xImage`, `images/rootfs.squashfs`,
  `images/u-boot-with-spl-mbr-gpt.bin`, `images/zero.bin`. A `security/x2000/key.bin` is also present
  - structurally a real RSA-2048 public key blob (`01 00 01` exponent visible right after a 256-byte
  modulus) - real evidence the X2000 silicon's secure-boot capability is a genuine feature Ingenic
  ships tooling for, not fabricated.

**Whether that capability is actually fused on for this consumer product - now well-evidenced,
though not 100% silicon-certain:**

1. `X2000_PM_20220909.pdf` chapter 42.5 (already fetched, §4b) documents the exact eMMC/MSC boot
   procedure this device uses (`boot_sel[2:0]=001`, confirmed earlier): "load 24KB code... branches
   to execute the code" - **no signature-check step described at all**. (The signature-adjacent
   table names in §42's SPI-NOR/NAND sections turned out, on actually reading them, to describe a
   16-byte magic+length+CRC7 boot-mode-detection header, not cryptographic verification - and don't
   even apply to this device's boot mode regardless.)
2. The live `kernel`/`kernel2` partitions are plain legacy `uImage` format (confirmed via magic bytes
   in §19) - a format with no capacity to carry a signature at all (that requires FIT images).
   Whatever `security/x2000/key.bin` is for, it isn't gating the format actually in use here.
3. **Real, independent, third-party confirmation found via web search**: a community member built
   and published [`ballaswag/ingenic-usbboot`](https://github.com/ballaswag/ingenic-usbboot) - a
   working open-source tool that loads arbitrary, unsigned SPL/U-Boot payloads directly via this
   exact chip family's mask-ROM USB download mode (same `a108:eaef` VID:PID documented in §4b,
   same staging addresses `0xb2401000`/`0x80100000`), on real K1 (X2000E - the closely related
   sibling of our X2000) hardware. Its own `--swap-ota` feature is independently the same
   `ota:kernel`/`ota:kernel2` toggle mechanism found in §19 - real corroboration that finding was
   read correctly. No secure-boot rejection is mentioned anywhere in real, ongoing community use of
   this tool. A second, separate repo
   ([`zerg32/k1-firmware-scripts`](https://github.com/zerg32/k1-firmware-scripts)) documents a
   whole custom-Debian-kernel repackaging workflow for the `.ingenic` format with zero signing
   infrastructure anywhere in it - further, independent corroboration.

**Net conclusion**: no enforced signature verification exists anywhere in this device's real boot
chain, as far as three independent sources (vendor manual, our own live device's image formats, and
real third-party tooling already exercising this exact path) can show. The residual gap - an actual
EFUSE secure-boot-fuse register readout - was deliberately not pursued further; real people already
doing exactly this on the same silicon family is stronger, more practical evidence than one more
register read would add, and manufacturing a test to nail down the last bit of certainty would be
a real, unnecessary device risk for no practical gain.

**Bundles extracted for this investigation** (`Ender-3_V3_KE_1.1.0.12.ingenic`,
`Ender-3_V3_KE_F005_ota_img_V1.1.0.12.img`, and their extracted contents) are kept in the session
scratchpad, not this repo - Creality's proprietary firmware, not project code, same principle as
§19's factory-partition backups and the WiFi-credentials decision.

## 21. Test plan drafted, then a real bug found in it: our console UART was never wired to any physical pins at all

User pushback on the draft boot-test plan raised two real points worth recording. First: writing to
the *currently active* rootfs/kernel slot instead of the spare doesn't remove the need for a
fallback mechanism (something still has to flip the `ota` marker back if the new image fails) - it
just adds real risk, since it means overwriting a block device the running kernel has mounted right
now, instead of an idle one. The spare-slot plan from §19 stands as-is. Second: a genuinely better
answer to "what if it doesn't boot and we have no access at all" is to not rely on physical/USB
recovery for the common failure modes in the first place. Since we own every line of the custom
rootfs, its very first init step can unconditionally flip the `ota` marker back to `ota:kernel`
immediately, before anything else runs, and only flip it forward again once the system has confirmed
itself healthy later in boot. That makes any crash *after* userspace starts self-healing on the next
reboot, no USB, no buttons. The one gap that can't close: a kernel that fails before ever reaching
our init code (panic pre-rootfs-mount) - still needs external recovery for that one case. Not yet
implemented - real next step before any live attempt.

User then asked to actually test the two items §20 flagged as unconfirmed rather than take them on
faith. One was genuinely testable remotely; the other isn't:

- **UART4/console pin routing - tested, and a real bug was found and fixed.** Checked whether our
  board DTS (`halley5_v30.dts`) even wires up the physical pins behind `console=ttyS4` at all. It
  didn't: `x2000-v12.dtsi` leaves `uart4` at `status = "disabled"` by default, and the board file had
  **no override for it whatsoever** - meaning our custom kernel's console would have produced zero
  output on real hardware regardless of the getty fix in §18. Pulled the real device's own live
  device tree via `/sys/firmware/fdt` (root-readable, read-only) and decompiled it with Buildroot's
  own `host/bin/dtc` to find the real answer instead of guessing: the stock board's `uart4` uses
  pinctrl group `uart4-pa` (`ingenic,pinmux = <phandle-for-gpa 2 3>`, i.e. physical pins **PA2/PA3**),
  not the only option this kernel tree happened to predefine (`uart4_pd`, PD13/PD14 - unrelated
  pins). Fixed by enabling `&uart4` in `halley5_v30.dts` with `pinctrl-0 = <&uart4_pa>` - the v12
  pinctrl tree already had a usable `uart4_pa` node (`gpa 0-3`, a superset covering the same PA2/PA3
  pins), so no new pinctrl node was needed, just the missing board-level override. **Not yet
  rebuilt into `uImage`** - the fix is only in kernel source (`vendor/x2000_kernel`) so far.
  (A first attempt at this fix landed in the wrong file - `x2000-pinctrl.dtsi`, the base X2000
  variant - before checking that `halley5_v30.dts` actually includes `x2000-v12.dtsi`, a materially
  different pinctrl tree. Caught and corrected before it went anywhere.)
- **Real hardware watchdog confirmed present and unused**: `/proc/device-tree/apb/watchdog@0x10002000`
  (`status: ok`) and working `/dev/watchdog`/`/dev/watchdog0` device nodes exist on the live device,
  with no daemon currently petting them. This is the concrete hardware this session's proposed
  "revert-first init" auto-recovery idea would run on - confirmed real and available, not assumed.
- **USB-recovery dry run (§20's other unconfirmed item) - genuinely not remotely testable.** Running
  `ballaswag/ingenic-usbboot --dump-partition` against the real device needs a USB cable connected to
  the printer's board and the boot+reset button combo held at power-on - physical actions only
  possible with hands on the actual hardware. Said so plainly rather than claim to have confirmed
  something that requires physical presence to confirm.

**Still open before any real attempt**: rebuild `uImage` with the uart4 fix, confirm the real board's
physical UART header location (needs the case open - PA2/PA3 is now a concrete, evidence-backed
starting point for continuity-testing rather than a blind guess), implement the revert-first init
script, and do the physical USB-recovery dry run.

## 22. Revert-first init built, RTC checked (clean), and a real cross-project port mixup avoided

Three more items from the same round of pushback.

**Revert-first init - built.** New `scripts/build/overlay/etc/init.d/S00revert-safety` runs before
every other init script, even `syslogd`/`klogd` - its only job is `echo -n "ota:kernel" >
/dev/mmcblk0p1`, unconditionally, the instant this image starts booting. A second script,
`S99confirm-good`, runs last (after `klipper`/`moonraker`/`guppyscreen`/`nginx` have all been started
by their own `S5x` scripts) and polls Moonraker's real HTTP API (`/server/info`, up to 30 retries x
5s) before flipping the marker forward to `ota:kernel2` - "started" isn't "healthy," so this checks
for real rather than assuming. If Moonraker never responds, the marker is deliberately left on
`ota:kernel` (stock) rather than retrying a boot that never actually got healthy. Net effect: any
crash or hang *after* `S00` runs self-heals on the next reboot - power cycle, watchdog, anything - with
zero USB/physical-recovery steps needed. The one gap this can't close (a kernel that panics before
ever reaching `/etc/init.d` at all) is unchanged from the design discussion - still needs external
recovery for that one case specifically.

**RTC - checked, no fix needed.** The live device's `rtc@10003000` is `status = "ok"` by default in
the base `x2000.dtsi` (no board-level override needed, unlike `uart4`), and the current kernel config
already has `CONFIG_RTC_DRV_INGENIC=y` plus `CONFIG_RTC_HCTOSYS=y` (auto-sets system time from the RTC
at boot, in-kernel, before userspace even starts) - both already correct, nothing to fix here.
**One real, minor, non-blocking finding along the way**: the live device's own `hwclock` reads back
`Sun Mar 1 19:22:26 2020` - a stale factory-epoch value - while the running system's actual `date` is
correct (`Jul 20 2026`). This means NTP (over the network, after boot) is what's actually keeping this
device's clock right, not a battery-backed RTC - the hardware RTC itself does not appear to hold real
time across power loss on this unit. Consequence for our own first boot test (deliberately no network,
per §17): expect wrong/stale log timestamps until a later boot with network access, but this is
cosmetic - nothing in the boot path depends on correct wall-clock time to function.

**A real, potentially costly mixup avoided**: user connected this session's plan back to
[[project_nebula_pad_usb_topology]] (the sibling `guppyscreen` project's own investigation) - the
Nebula Pad's Gsensor/accelerometer connector is USB-C-*shaped* but is actually a dedicated SPI+power
harness (`spi_gpio`, bit-banged GPIO), confirmed there via `lsusb`/`dmesg` - not part of the real USB
tree at all. If the boot+reset USB recovery procedure were attempted on *that* connector, it would
never work, regardless of holding the buttons correctly, since there's no USB data path present at
all - and it would very plausibly look like "the recovery mechanism doesn't exist" rather than "wrong
port." Checked directly against the primary source rather than assume the two projects' findings
lined up: **the official `Brick Rescue and Wire Brushing.pdf` (already used in §3/§4b) states, verbatim,
"Connect the computer and the mainboard's MicroUSB port using a MicroUSB cable"** - a physically
distinct connector from the Gsensor port on the same board photo (§4b already noted both are separately
labeled). Cross-confirms cleanly: **the real recovery port is the MicroUSB port, never the
USB-C-shaped Gsensor connector.** The PDF also has its own real, practical warning worth repeating: "there
are two types of MicroUSB cables: one is for power supply only" - a charge-only cable will silently
fail this procedure, worth having a known-good data cable in hand before attempting it.
