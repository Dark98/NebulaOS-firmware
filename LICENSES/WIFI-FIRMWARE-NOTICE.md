# WiFi firmware redistribution notice

Covers the two files published as the `wifi-firmware-1.0.0` GitHub Release
asset (`nebulaos-wifi-firmware-1.0.0.tar.gz`) and consumed automatically by
`scripts/build/00-fetch-vendor-sources.sh`:

- `brcmfmac43430-sdio.bin` — Cypress/Broadcom CYW43438 firmware image
- `brcmfmac43430-sdio.txt` — board-specific NVRAM/calibration data

## Provenance

Both files were extracted read-only from the vendor-installed firmware on a
real, physically-owned Creality Ender-3 V3 KE unit's stock filesystem
(`/lib/firmware/wifi_bcm/cyw43438-7.46.58.13.bin` and
`/lib/firmware/wifi_bcm/nvram_azw372.txt`), then renamed to the filenames
mainline Linux's `brcmfmac` driver requests for this exact hardware
(`brcmfmac43430-sdio.{bin,txt}`) — the driver, chip family, and rename are
public/documented; only the calibrated binary blob and board NVRAM
themselves are vendor-authored. See
`scripts/build/fetch-wifi-firmware.sh`'s own header and
`docs/NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md` for the extraction method and
SHA-256 verification against the stock device.

## License status

No license file, EULA, or copyright header accompanies these files anywhere
on the source device. They are Cypress/Broadcom proprietary binary firmware
and board-calibration data, functionally identical in kind to the firmware
every other CYW43438-equipped device (including stock Raspberry Pi OS,
which ships the same chip family's firmware under `firmware-brcm80211` /
`linux-firmware`) already redistributes as a practical necessity for the
hardware to function at all — there is no known restriction specific to
this printer's own copy beyond what already applies to that broader,
widely-redistributed firmware family.

**This redistribution is a deliberate, explicit decision by the repository
owner** (recorded 2026-08-07, NebulaOS Canonical Repository + Baseline
mission), made with the understanding above and not a claim that formal
written permission from Cypress/Broadcom was obtained. Redistribution is
limited to exactly the two files needed to bring this specific,
non-substitutable hardware up — no broader vendor SDK, toolchain, or
unrelated firmware is included.

## Verification

| File | SHA-256 |
|---|---|
| `nebulaos-wifi-firmware-1.0.0.tar.gz` (release archive) | `20c22ee2e3b7469b1240f991457e7217d3b1c8d858595754582e4f097311b08c` |
| `brcmfmac43430-sdio.bin` | `60dbb5b77b2c232e513322e0ff4350ab5dab5a9fcad0e26e80a2f089e652d720` |
| `brcmfmac43430-sdio.txt` | `78fee458ab69c0a66ea462f6d6769e15b36f73582693f4dbb5a0e8e8be3cfb0a` |

`scripts/build/00-fetch-vendor-sources.sh` downloads and verifies all three
hashes automatically on every build — a mismatch or download failure aborts
the build immediately, before any expensive step runs.

## Re-deriving from your own device instead

If you own the hardware and would rather extract fresh copies than trust
this release asset, `scripts/build/fetch-wifi-firmware.sh` still does the
original live-extraction this release was built from — point it at your own
stock device and it stages the files locally, bypassing the release
download.
