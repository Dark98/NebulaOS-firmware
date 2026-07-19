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
