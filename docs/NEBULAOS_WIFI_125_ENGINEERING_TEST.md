# CYW43430 Wi-Fi firmware engineering test: 7.46.58.13 (control) vs 7.45.98.125 (Infineon)

Engineering test only. Not a baseline change. See
`scripts/build/wifi-firmware-125-variant.sh` for the apply/revert tool this
record backs.

## Control baseline

Frozen at tag `nebulaos-canonical-baseline-2026-08-08-chelper-fix-live-qualified`
(commit `42d469897d1eff290f4fd43da7544652b4ce6578`) - the exact commit that
produced the currently-running, live-qualified image on the real device
(genuine virgin flash + first boot + Moonraker Recovery, all passed
2026-08-08).

## Firmware lookup (from the real device, not assumed)

Confirmed directly from `dmesg` on the live device - not inferred from
filenames:

```
[1.779165] brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac43430-sdio for chip BCM43430/1
[1.779580] brcmfmac mmc1:0001:1: Direct firmware load for brcm/brcmfmac43430-sdio.clm_blob failed with error -2
[1.893475] brcmfmac: brcmf_c_process_clm_blob: no clm_blob available (err=-2), device may have limited channels available
[1.893929] brcmfmac: brcmf_c_preinit_dcmds: Firmware: BCM43430/1 wl0: Apr 19 2018 21:18:23 version 7.46.58.13 (r688474 CY) FWID 01-d4334d3d es4.c3.n4
```

Note this important, pre-existing, control-baseline fact: **the control
baseline's own CLM blob already fails to load** (`error -2` = ENOENT, at
the exact instant brcmfmac's own early probe requests it - likely a
boot-time ordering/overlay-mount timing gap, unrelated to this test, not
investigated further here since fixing it is out of this test's scope -
see "Do not change: kernel/brcmfmac/DT" in the mission instructions).
`/lib/firmware/brcm/brcmfmac43430-sdio.clm_blob` (a symlink to
`../cypress/cyfmac43430-sdio.clm_blob`) exists on disk post-boot, but
brcmfmac's own early request for it fails every boot on the control
baseline. Wi-Fi still associates and passes traffic fine without it
("device may have limited channels available" is a warning, not a fatal
error) - this is simply the control baseline's real, current, accepted
shipping state, and the `.125` test replicates the identical file
layout/paths, not a "fixed" boot-ordering setup.

Resolved real files (control):

| Purpose | Path (as requested by brcmfmac) | Real file | SHA256 |
|---|---|---|---|
| `.bin` | `brcm/brcmfmac43430-sdio.bin` | same (real file, not a symlink for this chip) | `60dbb5b77b2c232e513322e0ff4350ab5dab5a9fcad0e26e80a2f089e652d720` |
| `.clm_blob` | `brcm/brcmfmac43430-sdio.clm_blob` | symlink -> `../cypress/cyfmac43430-sdio.clm_blob` | `3376b9c9b32d16bf762e21c7fafb665365070ae240d092498d0d1987c22022aa` |
| NVRAM `.txt` | `brcm/brcmfmac43430-sdio.txt` | same | `78fee458ab69c0a66ea462f6d6769e15b36f73582693f4dbb5a0e8e8be3cfb0a` |

`.bin` and `.txt` come from this project's own `scripts/build/fetch-wifi-
firmware.sh` (extracted live, read-only, from stock's real Azurewave
module files - `wifi_bcm/cyw43438-7.46.58.13.bin` /
`wifi_bcm/nvram_azw372.txt`), staged into the gitignored overlay path
`scripts/build/overlay/lib/firmware/brcm/`. The `.clm_blob` is **not**
staged by this project at all - it comes entirely from Buildroot's own
`linux-firmware` package (a generic, freely-redistributable upstream
copy), which is why no `cypress/` overlay directory exists in this repo
today.

An `brcmfmac43430-sdio.ingenic,halley5.bin` board-type-suffixed symlink
also exists (-> the plain `.bin`) but is confirmed **unused**: the real
dmesg request line above never includes any board suffix, only the plain
chip name. brcmfmac auto-probes BCM43430/1 via SDIO vendor/device ID, not
a DT `compatible` string - the DT's own `compatible = "android,bcmdhd_wlan"`
node is vestigial (that compatible string belongs to the older, unused
out-of-tree Broadcom `bcmdhd` vendor driver, not the in-tree `brcmfmac`
this kernel actually runs).

## `.125` candidate

Source: `github.com/Infineon/ifx-linux-firmware`, tag
`release-v5.10.9-2022_0909` (an annotated tag; git resolves it to commit
`4334275b5801bcf5256c3101395e7bc983ce640d`, whose own commit message
reads "2022_0914 Release" - an upstream naming quirk, not a mismatch;
the tag name itself is exactly what was requested and resolves cleanly).

```
firmware/cyfmac43430-sdio.bin        sha256: 82ed67a211877efa47aff4aab83d6d2d1ccf3d5d0f5c396df97f292ade01de9e
firmware/cyfmac43430-sdio.clm_blob   sha256: 1dbe1a396b68786bb189b7c255318ae546fd2e9d15f70ccc8ecbdc52b6cd4c47
```

Runtime version independently confirmed via `strings` on the fetched
`.bin` itself (not trusted from the filename/repo path alone):

```
43430a1-roml/sdio-g-pool-p2p-pktfilter-keepalive-aoe-lpc-swdiv-srfast-fuart-btcxhybridhw-noclminc-clm_min-fbt-mfp-tko-extsae
Version: 7.45.98.125 (5b7978c CY) CRC: 262ed39e Date: Tue 2022-08-16 03:07:39 PDT
Ucode Ver: 1043.213706 FWID 01-f420b81d
```

Exactly matches the mission's expected `BCM43430/1 7.45.98.125 (5b7978c CY)
FWID 01-f420b81d`.

## What the variant changes (and only this)

`scripts/build/wifi-firmware-125-variant.sh apply <bin> <clm>`:

- Overwrites `scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.bin`
  (was control 7.46.58.13, becomes the verified `.125` binary)
- Adds `scripts/build/overlay/lib/firmware/cypress/cyfmac43430-sdio.clm_blob`
  (a new overlay file, overriding Buildroot's own linux-firmware-supplied
  generic CLM at the same final rootfs path)
- Never touches `.txt` (NVRAM, byte-identical to control), the kernel,
  brcmfmac driver source, DT, ROAMOFF1, IRQ priority, power-save config,
  MAC provisioning, or any camera/display/system configuration.

`revert` removes both overrides, restoring the exact control lookup
(re-run `fetch-wifi-firmware.sh` to restore the real control `.bin` from
stock; the `.clm_blob` override's removal alone is sufficient to restore
control CLM behavior since Buildroot's own package supplies it again).

This is a temporary engineering-test tool. It is intentionally not wired
into `apply-qualified-baseline.sh`'s 8 accepted baseline variants and must
never run as part of a normal `./build.sh`.
