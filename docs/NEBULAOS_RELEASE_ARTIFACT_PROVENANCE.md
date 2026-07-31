# NebulaOS Release Artifact Provenance

Tracks every prebuilt/downloaded binary or archive this build consumes that
is not itself built from vendored source in this repo. Written 2026-07-31 as
part of closing the vendor/artifact reproducibility gaps identified in
`docs/NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md` (§2).

For each artifact: exact path, size, SHA-256, known origin, and — where full
upstream provenance isn't available — an honest statement of the
reconstruction limitation, rather than a claim that it's reconstructable
when it isn't.

## Mainsail release archive

| Field | Value |
|---|---|
| Path | `vendor/mainsail-dist/mainsail.zip` (gitignored, fetched by `scripts/build/00-fetch-vendor-sources.sh`) |
| Size | 3,133,520 bytes |
| SHA-256 | `df2ba7c301f7bfc8ac9f122741a6ba08356d679ecfa1f62f898d0337802d5de5` |
| Version | `v2.18.2` (confirmed from the archive's own internal `.version` file, not assumed) |
| Origin | `https://github.com/mainsail-crew/mainsail/releases/download/v2.18.2/mainsail.zip` — a real, official GitHub release asset from the `mainsail-crew/mainsail` project |
| Reconstruction | Fully reconstructable — download the same tagged release asset from the URL above and verify the SHA-256 matches. **This was previously not pinned at all** — the fetch script downloaded from `.../releases/latest/...`, a URL that silently follows whatever GitHub considers "latest" at fetch time. Fixed 2026-07-31 to pin the exact tag and verify the downloaded archive's hash, failing loudly on either a wrong tag or a byte-different artifact under that tag. |

## GuppyScreen binaries

| Field | Value |
|---|---|
| Path | `artifacts/guppyscreen-mips/guppyscreen` (git-tracked in this repo) |
| Size | 7,293,272 bytes |
| SHA-256 | `810d895675198b3f73cd8552656f5bfbe593b8faca5883c201807d006e2bdbe4` |
| Path | `artifacts/guppyscreen-mips/guppybeep` (git-tracked in this repo) |
| Size | 103,356 bytes |
| SHA-256 | `4a2a719411944e5c2d0f7a9231440487073ce454e398d61f27181a821f2a9d76` |
| Origin | Prebuilt MIPS binaries only — **no fetch-script entry, no declared source commit, no download URL exists anywhere in this repo for these two files.** They predate this project's current vendoring conventions. |
| Reconstruction | **Limited.** These binaries are git-tracked (so they will not silently disappear or drift once committed — any future change to them would show as a real git diff), but there is no documented way to rebuild them from source, and no record of which upstream GuppyScreen commit or release they came from. If they were ever lost from git history entirely, they could not currently be reconstructed. This is the least-reproducible artifact in the whole build and is flagged as such, not glossed over. |

## Wi-Fi firmware and calibration

| Field | Value |
|---|---|
| Path | `scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.bin` (git-tracked) |
| Size | 406,602 bytes |
| SHA-256 | `60dbb5b77b2c232e513322e0ff4350ab5dab5a9fcad0e26e80a2f089e652d720` |
| Path | `scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.txt` (git-tracked; NVRAM/board-calibration override) |
| Size | 962 bytes |
| SHA-256 | `78fee458ab69c0a66ea462f6d6769e15b36f73582693f4dbb5a0e8e8be3cfb0a` |
| Origin | Confirmed (`docs/NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md` §18.3, citing FIRMWARE.md §57) SHA-256-identical to the real stock device's own board-calibrated firmware (`cyw43438-7.46.58.13.bin`) and NVRAM (`nvram_azw372.txt`, board id `BCM943430WLSELG`), extracted directly from the physical printer and renamed to mainline `brcmfmac`'s own naming convention. Real, board-specific, not a generic/mismatched file. |
| Reconstruction | Fully reconstructable — git-tracked directly in this repo; provenance is a real physical device extraction, documented in FIRMWARE.md. |

## Regulatory database

| Field | Value |
|---|---|
| Path | `scripts/build/overlay/lib/firmware/regulatory.db` (git-tracked) |
| Size | 4,896 bytes |
| SHA-256 | `0a4abd7ae20d07bb70642937ccb2293a72a6504730eea45a698882599f586368` |
| Path | `scripts/build/overlay/lib/firmware/regulatory.db.p7s` (git-tracked, detached signature) |
| Size | 1,182 bytes |
| SHA-256 | `bcd81aed039ea6b9b6f3726fbf26911a0caf4a5d894210e0fa2effb384d6b326` |
| Origin | `wireless-regdb` project's signed regulatory database, baked into the kernel image via `CONFIG_EXTRA_FIRMWARE` (see `halley5-nebulaos-fragment.config`'s own dated comment for why — a rootfs-not-yet-mounted boot timing fix). |
| Reconstruction | Fully reconstructable — git-tracked directly in this repo, and `wireless-regdb` is itself an actively-maintained public project if a newer database is ever needed. |

## Verification

Every hash above is checked by `scripts/build/06-verify.sh`'s
`check_artifact_sha256()` gate (added alongside the existing
`check_vendor_pin()` vendor-source gate), so a drifted or substituted
artifact shows as an explicit `MISS` line in a build's verification output,
not a silent difference only this document would reveal.

## Orphaned vendor tree resolution (2026-07-31)

Two gitignored `vendor/` trees had no fetch-script provenance and were
flagged as candidates for either removal or documented retention:

- **`vendor/x2000_kernel`** (Jubian540/x2000_kernel, the real stock 4.4.94
  kernel SDK, distinct from the custom image's `x2000_kernel_6.6`) —
  **retained**. Confirmed via `README.md:176`, `FIRMWARE.md` (multiple
  sections, e.g. line 120, 251-287, 377, 578), and
  `docs/PIN_OWNERSHIP_MAP.md:221` that this tree has real, ongoing reference
  value: it was used to cross-compile a real stock-vermagic-matching kernel
  module (`ax88179_178a`/USB Ethernet), to confirm the exact stock kernel
  version (`4.4.94`), and as a generic reference-tree search target during
  pin-conflict investigations. Not consumed by the numbered `00`-`06` build
  pipeline for the custom image, but genuinely useful and already documented
  elsewhere — correcting this project's own earlier, too-hasty
  characterization of it as "likely a stale leftover" in
  `NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md`'s original vendor-pin audit.
- **`vendor/mainsail`** (a plain git clone of `mainsail-crew/mainsail`,
  distinct from the actually-used `mainsail-dist/mainsail.zip` release
  archive) — **removed**. Confirmed via a repo-wide grep that nothing
  anywhere (build scripts or documentation) ever referenced this tree by
  path; it was a clean, unmodified, trivially re-clonable mirror (8.9 MB,
  zero local changes) with no unique content. Deleted 2026-07-31; re-clone
  from `https://github.com/mainsail-crew/mainsail` if a source-level Mainsail
  reference is ever genuinely needed again.
