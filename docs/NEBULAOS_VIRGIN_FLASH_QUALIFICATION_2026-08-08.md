# Virgin Flash + Verification mission (2026-08-08)

Running record for the Autonomous NebulaOS Virgin Flash + Verification
mission: deploying `build-work/deploy-packages/z-compensate-guppyscreen-
20260808T152643Z/` to the real device, proving first boot uses no previous
NebulaOS runtime state, live qualification, and the resulting canonical
baseline tag. Appended to as each phase completes.

## Phase 1: traceability correction

The package under deployment was built from a genuinely fresh clone at
firmware commit `91a190e` (`build: pin pellcorp/k1-bash-build by immutable
digest`). One further commit, `f939141` (`docs: record explicit load-cell
scope + exclude uncommitted safety fix`), landed on `main` afterward -
**independently re-verified here** via `git diff --stat 91a190e f939141`:
exactly one file changed, `docs/NEBULAOS_PRINTER_CFG_LOADCELL_GAP.md`, pure
Markdown, zero lines touched in any script, manifest, `klippy_extras/`
module, or `printer.cfg`. Confirmed documentation-only; no rebuild
performed, per this mission's own explicit instruction.

```
BUILT_FROM_FIRMWARE_SHA=91a190e4cd6b128de1cc071012e899cbd44b53a4
CURRENT_DOCUMENTATION_HEAD=f939141afa5dcbd30472f37e94bb233013e7d0c1
```

Full commit SHAs, for the record:

- `BUILT_FROM_FIRMWARE_SHA` = `91a190e4cd6b128de1cc071012e899cbd44b53a4`
  (matches this package's own `build-manifest.txt`'s `git_commit_main` and
  `/opt/nebulaos-version.json`'s `firmware_sha`, independently confirmed by
  direct `unsquashfs` inspection of the packaged `rootfs.squashfs` during
  the prior mission's own artifact-inspection step)
- `CURRENT_DOCUMENTATION_HEAD` = `f939141afa5dcbd30472f37e94bb233013e7d0c1`
  (current `origin/main` tip at the time this deployment mission began)

The canonical baseline tag this mission creates (Phase 11) is placed on
`91a190e` - the commit that actually produced the flashed bytes - not on
the later docs-only HEAD, so the tag always points at something a fresh
clone can rebuild byte-reproducibly-equivalent to what is actually running
on the device.
