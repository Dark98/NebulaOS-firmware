# Persistent `/usr/data` lifecycle

2026-08-07/08, Clean-Update + Virgin Baseline mission, Phase 3. Answers one
question: when a device is reflashed with a new image, what happens to
everything that lives on the persistent partition (`mmcblk0p10`,
`$NEBULAOS_ROOT` = `/usr/data/nebulaos`) - which was never touched by the
reflash itself, since kernel2/rootfs2 writes are squashfs-only (see
`docs/NEBULAOS_UPDATE_OWNERSHIP.md`)?

This is the exact gap `docs/NEBULAOS_CANONICAL_DEPLOYMENT_QUALIFICATION.md`
found live: a "clean" reflash still reported the OLD Klipper version, because
nothing ever re-seeds an already-populated `$APPS` from the new image's
pinned commits.

## File classification

Every path under `$NEBULAOS_ROOT` falls into exactly one of three classes.
Classification is enforced by directory separation, not per-file logic -
each class lives in its own subtree, and each script that acts on one class
never reads or writes into another's.

| Class | Paths | Meaning | Owner |
|---|---|---|---|
| IMAGE OWNED | `apps/klipper`, `apps/moonraker` | Git checkouts of NebulaOS-pinned source. Nothing user-authored inside them. Safe to fully replace when the image's pin moves forward. | `S04nebulaos-factory-seed` (first boot) + `S04nebulaos-migrate` (later boots, generation mismatch) |
| USER OWNED | `printer_data/config` (printer.cfg, macros, moonraker.conf) | Hand-edited by the printer owner. Never touched by seeding or migration - a completely separate directory tree, full stop. | The user, via Moonraker/Mainsail/direct edit |
| GENERATED | `envs/*`, `database`, `printer_data/{gcodes,logs,database}` | Regenerated or repopulated naturally by the running application. Out of scope for this mission's migration system (see below). | The application itself |

`apps/mainsail` is a deliberate, documented exception (see
`NEBULAOS_UPDATE_OWNERSHIP.md`'s Mainsail section) - IMAGE OWNED in principle
but intentionally also independently self-updatable via Moonraker's web
updater, matching standard Klipper-ecosystem practice.

`envs/klipper` and `envs/moonraker` (the Python venvs) are explicitly OUT OF
SCOPE for `S04nebulaos-migrate`: they are derived from the Buildroot/kernel
pin, not the Klipper/Moonraker source pin, and change far less often. A
future mission can extend migration to cover them the same way, if that ever
becomes necessary.

## Version tracking

`$SYSTEM/app-generation.json` (`$NEBULAOS_ROOT/system/app-generation.json`)
is the on-device record of what generation of IMAGE OWNED content is
currently installed:

```json
{
  "migration_version": "<16-hex-char sha256 prefix>",
  "recorded_at": "<UTC ISO8601>",
  "klipper_commit": "<sha or 'unseeded'>",
  "moonraker_commit": "<sha or 'unseeded'>"
}
```

`migration_version` is a content-derived hash
(`sha256(klipper_seed_commit:moonraker_seed_commit:GUPPYSCREEN_PIN)`,
truncated to 16 hex chars), computed at build time by
`04-cross-compile-app-stack.sh` and written into the squashfs's own
`/opt/nebulaos-seeds/seed-manifest.json`. Deliberately NOT a manually
maintained counter - a hand-bumped counter is exactly the kind of thing a
future change can forget to increment, silently reintroducing the same
class of bug this mission exists to close. Any change to any of the three
pinned commits changes the hash automatically.

The full version-truth surface (firmware tag/SHA, kernel SHA, Klipper SHA,
GuppyScreen SHA, `migration_version`, persistent app generation) is exposed
at runtime by Phase 6's work (not yet implemented as of this document).

## Boot-time flow

Both scripts run in the `S04` init slot, in order:

1. **`S04nebulaos-factory-seed`** - asks only "does `$APPS/klipper/.git`
   exist at all?" If not, this is a genuinely fresh/wiped namespace's first
   boot: seed everything from the squashfs's own archives, offline, with no
   network dependency. Once seeded, this script never looks again, on any
   later boot, with any later image - that is correct for what it exists to
   guarantee (a first boot must never depend on network), but leaves the
   later-reflash gap below.
2. **`S04nebulaos-migrate`** - asks "does the installed `migration_version`
   match the image's expected `migration_version`?" If they match, no-op. If
   `$APPS/klipper/.git` doesn't exist yet, this is the same fresh-namespace
   case S04 just handled (or is about to handle on the very next entry, in
   the first-boot no-network case) - nothing to back up or replace, so this
   just records the baseline generation for future comparisons. Otherwise: a
   real device that's already been running is being reflashed with an image
   whose pins moved forward. Migration is needed.

## Migration semantics

When a real migration runs (`S04nebulaos-migrate`'s `start()` →
`reseed_git_app()` per component):

1. **Gate**: same `maintenance_gate_ok()` safety check `S04` itself uses -
   refuses to run while a print is active, an update-transaction lock is
   held, or no memory-resilience swap is active. Any block just retries next
   boot; nothing is ever forced through.
2. **Backup**: the entire current `$APPS/<name>` tree is moved (not copied -
   this is a 208MB-RAM device, and mv within the same partition is instant
   and atomic) to a timestamped directory under
   `$SYSTEM/migration-backups/<UTC-timestamp>/` BEFORE anything new is
   written. Not deleted automatically - left for the operator to remove by
   hand once the new generation is confirmed working.
3. **Compare/update**: the new archive is extracted to a `.migrate-partial`
   sibling directory, then verified (correct branch, correct origin, clean
   working tree modulo the one known-safe `c_helper.so` exception) BEFORE
   being swapped in via a single `mv`. If any verification step fails, the
   partial directory is discarded and the OLD tree - already safely backed
   up - is left exactly where it was. The component is simply left one
   generation behind; nothing is destroyed.
4. **Verify + record**: only once every component either migrated
   successfully or was already up to date does `record_generation()` write
   the new `migration_version` to `$GENERATION_FILE`. If any component
   failed, the generation is NOT advanced - the whole migration retries on
   the next boot, and the failure is logged with an explicit statement of
   what's still safe (every component's pre-migration tree is intact,
   whatever succeeded before the failure is in the backup directory).

This gives the four required properties: backup before touching anything,
compare installed vs. expected generation, update only IMAGE OWNED files
while USER OWNED files are architecturally untouched, and a fully recoverable
failure path that never advances the generation record on partial success.

## Fresh-boot ordering: no redundant reseed

`S04nebulaos-factory-seed` and `S04nebulaos-migrate` share the same `S04`
init slot, factory-seed running first (filename ordering). Without care,
this creates a real gap: on a genuinely fresh boot, factory-seed seeds
`$APPS/klipper` for the first time, then migrate runs immediately after,
sees no recorded generation yet, and (before this fix) treated that as a
real mismatch - backing up and re-seeding the exact content factory-seed
had just installed. Harmless (identical source) but wasteful, and it left
a spurious backup directory on every single first boot.

Fixed by having `S04nebulaos-factory-seed` itself call a new
`record_initial_generation()` right after a successful fresh seed - it
reads `migration_version` from the same `seed-manifest.json` and writes
`$SYSTEM/app-generation.json` at the moment it knows the installed content
matches the image exactly. `S04nebulaos-migrate`'s own top-of-`start()`
generation comparison then short-circuits to a clean no-op on the very
next boot-slot entry, with zero special-casing needed in migrate itself.
Covered by `tests/app-migration-tests.sh`'s
`test_no_redundant_reseed_after_fresh_factory_seed`.

## Factory-clean provisioning

`scripts/build/overlay/opt/nebulaos/factory-clean-provision.sh` (squashfs-
resident, always available) is the on-demand tool for simulating a genuinely
new install on an already-provisioned device, without touching stock or
destroying anything: `factory-clean-provision.sh --archive-and-reset`
archives (moves, never deletes) `apps/`, `envs/`, and `system/` to a
timestamped directory under `$NEBULAOS_ROOT/factory-clean-backups/`, then
recreates an empty namespace via the same idempotent
`S02nebulaos-namespace` used at every real boot. `printer_data/config`
(USER OWNED) and `printer_data/{gcodes,logs,database}` are never touched -
a separate directory tree the script doesn't even reference. Requires a
reboot afterward: `S04nebulaos-factory-seed` then re-seeds everything fresh
from the image's own archives, and `S04nebulaos-migrate` records the new
baseline generation, exactly as a real new device would.

## Testing

`tests/app-migration-tests.sh` exercises the migration script offline,
following the same real-git-fixture convention as
`tests/factory-seed-git-tests.sh`: a no-op when generations already match,
correct baseline recording on a genuinely fresh namespace, a real
generation-mismatch migration (backup created, new checkout's commit
verified to be the real seed commit, generation advanced), the
missing-archive failure path (existing installation completely untouched,
generation not advanced), and the fresh-boot-ordering no-op above.

`tests/factory-clean-provision-tests.sh` exercises the provisioning tool
against a real, populated fixture namespace: refusal without the
confirmation flag, a real archive+reset run (backup verified to hold the
real pre-reset checkout, namespace reset to empty, USER OWNED
`printer_data` left byte-for-byte untouched), and the missing-namespace-
script failure path (archived state remains fully intact and recoverable).
