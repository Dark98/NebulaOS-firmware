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
   anything bigger. **Not started - next concrete step, ready to attempt.**

**Phase 2 - real custom builds, moderate risk, only after Phase 1 succeeds**
5. Build a custom Buildroot-based rootfs image (newer Buildroot release, more modern package
   versions, our own choice of what to include) using the confirmed-matching kernel/toolchain -
   this is the actual "more lightweight, more up to date OS" the user asked about, and it's
   realistically achievable *because* Phase 0/1 de-risked the toolchain/source-match question first.
   Test-boot via whatever safe recovery mechanism Phase 0 identified, not by overwriting the only
   working rootfs slot blind.
6. Only if there's a specific concrete reason (not yet identified): consider kernel changes beyond
   adding modules (e.g. a newer Ingenic-community kernel fork, if the version gap turns out small).

**Phase 3 - only if everything above is solid and validated**
7. A real flash of kernel+rootfs to the live printer, using the platform's own confirmed recovery
   path as a safety net, only after dry-running the process as many times as reasonably possible
   against non-production copies (e.g. test on the paired/backup partition slot if p3/p4 or
   p7/p8 really are A/B pairs, confirmed in Phase 0).

**Explicitly not recommended, no real reason to do it here**: replacing the bootloader (`xboot`) -
no concrete benefit identified for this project, and it's the single highest-risk component to get
wrong regardless of how well-documented the recovery path turns out to be.

Nothing above has been started. This is a plan to execute in later sessions, one phase at a time,
with the user's explicit go-ahead before any step that touches the real device beyond read-only
queries - fully consistent with how every other risky-adjacent step in this workspace has been
handled so far.
