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

## Result: `.125` does not work on this platform (2026-08-09)

Live-tested 6 independent boot attempts via `S98nebulaos-wifi-125-failsafe`'s
own persisted diagnostics (`/usr/data/wifi-125-test-diagnostics.log` -
survives the automatic revert-to-stock, since it's on the shared
partition). Every attempt identical:

```
brcmf_c_preinit_dcmds: Firmware: BCM43430/1 wl0: ... version 7.45.98.125 (5b7978c CY) FWID 01-f420b81d
```

- `.bin` loads correctly (matches expected version/FWID exactly).
- CLM blob load fails with `error -2` (the same pre-existing control-baseline
  quirk above) - and unlike control, brcmfmac then produces **zero further
  log output**: `wlan0` never appears with a carrier, `wpa_supplicant`
  stays at `wpa_state=DISCONNECTED` for the full 120s timeout, every time.

Root cause, confirmed via `strings` on both binaries' own embedded build
tags: control's 7.46.58.13 build carries neither `clm_min` nor `noclminc`
(ships its own built-in channel data, so it merely warns when the external
CLM load fails). This `.125` build is compiled with `noclminc clm_min` -
no built-in data, external CLM required - so the identical `-2` failure
that control shrugs off leaves this candidate with no usable channel list
at all, and the interface never comes up.

### Attempted fix: bake CLM into the kernel via CONFIG_EXTRA_FIRMWARE - REVERTED, made things worse

Tried closing the CLM boot-timing gap the same way `.bin`/`.txt`/
`regulatory.db` already are (see `artifacts/buildroot-halley5-v30-image/
halley5-nebulaos-fragment.config`'s own existing comments on this exact
class of gap): add `brcm/brcmfmac43430-sdio.clm_blob` to
`CONFIG_EXTRA_FIRMWARE`, staged by a new `scripts/firmware/fetch-linux-
firmware-clm.sh` (same fetch-and-verify convention as `fetch-wireless-
regdb.sh`, mirroring Buildroot's own pinned `linux-firmware` package
exactly - the staged file's SHA256 was confirmed byte-identical to the
live control device's own already-running CLM blob before any of this).

Built and flash-tested on **control** (7.46.58.13, no `.125` variant)
first, specifically to prove no regression before ever combining it with
the `.125` candidate. Result: a real regression. The CLM blob is now
*found* (`-2`/ENOENT gone), but downloading it through the kernel's
built-in-firmware path fails differently:

```
brcmf_c_download_blob: clmload (4733 byte file) failed (-50)
brcmf_c_preinit_dcmds: download CLM blob file failed, -5
brcmf_sdio_firmware_callback: brcmf_attach failed
```

brcmfmac treats a *present-but-failed-to-download* CLM blob as fatal -
`brcmf_attach` aborts entirely, `wlan0` doesn't even exist. This is worse
than the original state, where a *missing* CLM blob was merely a warning.
Confirmed live, twice (the `S98` failsafe correctly detected and reverted
both times - it doesn't require a `.125`-specific sentinel context to
matter here, it just happened to still be present from an earlier build
due to a separate, unresolved stale-overlay issue noted below).

**Commit `2274450` (the CONFIG_EXTRA_FIRMWARE change) was reverted
(`3ab3c3c`).** The device was restored to the exact known-good control
package (`z-compensate-guppyscreen-20260808T202807Z`, tag
`nebulaos-canonical-baseline-2026-08-08-chelper-fix-live-qualified`) and
confirmed live: WiFi associated, -33 dBm, 72.2 Mbit/s, printer idle.

Why downloading identical bytes fails differently via `CONFIG_EXTRA_FIRMWARE`
vs. a normal rootfs file was not root-caused further - plausibly a real
size/alignment constraint or a different internal loading path
(`request_firmware` direct vs. built-in) that this driver's SDIO
CLM-download routine doesn't handle the same way. Worth a dedicated
follow-up if CLM support is ever revisited, but the straightforward
"just embed it" approach does not work and must not be reapplied as-is.

### Known open issue: stale overlay content can survive a source-level revert

While investigating the above, a real, reproducible bug was found: after
reverting the `.125` variant (`scripts/build/wifi-firmware-125-variant.sh
revert`, confirmed to correctly remove the sentinel file from the source
overlay tree) and rebuilding a control-only image, the packaged
`rootfs.squashfs` still contained the old `/etc/nebulaos-wifi-125-test-
marker` sentinel (confirmed via direct `unsquashfs` inspection, with a
~8-hour-stale mtime proving it). `02-configure-buildroot.sh` does
`rm -rf` the intermediate overlay staging directory before its `cp -r`,
so the staleness survives somewhere further into the pipeline (Buildroot's
own `output/target` incremental caching is the leading suspect, not yet
confirmed). Not root-caused or fixed in this session - flagged here for a
dedicated future investigation. Practical mitigation used here: manually
verify+clean stale files with `unsquashfs` inspection before trusting a
"reverted" build, same as this project's own established pattern for
this general bug class (see `feedback_nebulaos_stale_build_artifacts`
memory entry: 4th recurrence now).

### Conclusion (superseded - see correction below)

`.125` (`github.com/Infineon/ifx-linux-firmware @ release-v5.10.9-2022_0909`)
is **not a viable candidate for this platform as-is**. The failure is a
genuine firmware/platform incompatibility (this build's `clm_min`
dependency vs. this platform's current CLM delivery), not a NebulaOS
build defect. No further promotion recommended without either a
`clm_min`-free `.125` build or a correctly-working CLM-delivery fix
(the `CONFIG_EXTRA_FIRMWARE` approach tried here does not qualify).
Canonical baseline was never modified - the device is back on the
same tag it was live-qualified on before this test began.

## Correction (2026-08-09): the "not viable" conclusion above was wrong - the intended combination was never actually tested

External review (raised as a set of precise, evidence-demanding
questions - "is the exact combination `.125` + matching Infineon `.125`
CLM + current NVRAM + `CONFIG_EXTRA_FIRMWARE` actually tested, yes or
no") forced a re-check of what each of the two experiments above had
actually exercised. They did not overlap:

- The first `.125` boot test (the "Result" section above) staged the
  `.125` Infineon CLM at
  `scripts/build/overlay/lib/firmware/cypress/cyfmac43430-sdio.clm_blob`
  - a path `CONFIG_EXTRA_FIRMWARE` never reads and the rootfs mounts too
    late for brcmfmac's early probe to see. So this test hit the exact
    same pre-existing `-2`/ENOENT as control, and because `.125` has no
    built-in fallback (`clm_min`/`noclminc`), the interface never came
    up. This proved `.125` needs an external CLM before the rootfs
    mounts - it did not prove the CLM itself was bad.
- The "attempted fix" test (the `-50` regression) embedded via
  `CONFIG_EXTRA_FIRMWARE` at the correct, early-read path - but paired
  it with **control's own generic CLM** (from
  `scripts/firmware/fetch-linux-firmware-clm.sh`, byte-identical to what
  was already running live on control), never with `.125`'s own
  Infineon-supplied CLM. This proved embedding a mismatched/generic CLM
  via this path regresses even control - it said nothing about `.125`
  with its own matching CLM.

Root cause of the mixup: `scripts/build/wifi-firmware-125-variant.sh`'s
`apply()` staged the `.125` CLM at the wrong destination
(`lib/firmware/cypress/cyfmac43430-sdio.clm_blob` instead of
`lib/firmware/brcm/brcmfmac43430-sdio.clm_blob`, the latter being what
brcmfmac's own `brcmf_fw_alloc_request()` + `CONFIG_EXTRA_FIRMWARE`
actually resolve to for this chip/bus). **The one specific combination
that matters - `.125`'s own CLM, embedded via `CONFIG_EXTRA_FIRMWARE`,
at the correct path - had never been built or booted.**

### Fix and re-test result: SUCCESS

`wifi-firmware-125-variant.sh` (commit `30521ef`) now stages the CLM
override at the correct `brcm/brcmfmac43430-sdio.clm_blob` path, and a
small diagnostic patch (`apply_diag_patch()`/`revert_diag_patch()`,
covered by `tests/wifi-firmware-125-variant-tests.sh`) makes
`brcmfmac`'s internal `clmload_status` visible via `bphy_err` instead of
a compiled-out `brcmf_dbg(INFO, ...)` (this kernel has
`# CONFIG_BRCMDBG is not set`), so a future CLM failure would no longer
be a silent `-EIO` with no real status code logged.

Built in a fresh clone, staged in the correct build order (the WIFI-FW-125
CLM override and diagnostic patch applied *after*
`apply-qualified-baseline.sh`, so `wifi-roamoff-disable-variant.sh`'s own
unconditional `common.c` reset can't wipe it - both `ROAMOFF1` and the
diagnostic patch confirmed coexisting in the final compiled source).
Flashed to the (inactive) custom slot from stock via the standard
stock-mediated procedure, booted, and verified live:

```
brcmf_fw_alloc_request: using brcm/brcmfmac43430-sdio for chip BCM43430/1
brcmf_c_process_txcap_blob: no txcap_blob available (err=-2)
brcmf_c_preinit_dcmds: Firmware: BCM43430/1 wl0: Aug 16 2022 03:05:14 version 7.45.98.125 (5b7978c CY) FWID 01-f420b81d
```

No `clmload`/download-failure lines at all (the diagnostic patch's
`ENGINEERING DIAG clmload_status` line only fires inside
`brcmf_c_download_blob()`'s failure branch, so its absence plus a fully
associated `wlan0` is the positive evidence the download succeeded).
`wlan0` came up with `wpa_state=COMPLETED` on the real 2.4GHz SSID,
acquired a DHCP lease, SSH reachable, Klipper `ready`, Moonraker
healthy, GuppyScreen running. NVRAM (`brcmfmac43430-sdio.txt`,
`78fee458...`) confirmed byte-identical to control on the running
device. `S98nebulaos-wifi-125-failsafe`'s own persisted diagnostics log
recorded WiFi already healthy on its very first check (~124s uptime),
so the stock-revert path was armed but never triggered.

### Revised conclusion

`.125` **is viable on this platform**, provided its own matching
Infineon CLM blob is delivered via `CONFIG_EXTRA_FIRMWARE` at the
correct `brcm/brcmfmac43430-sdio.clm_blob` path. The original "not
viable" conclusion was an artifact of two non-overlapping, individually-
valid-looking experiments being conflated, not a real platform
limitation. The device was left running this corrected `.125` image
for the user's own manual WiFi evaluation (throughput/latency/range) -
no further automated A/B qualification was performed, per mission
scope. Promotion to the canonical baseline (new tag, tracked
`kernel.config`) is a separate, not-yet-taken decision.
