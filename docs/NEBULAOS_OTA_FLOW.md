# The canonical NebulaOS OTA flow

Clean-Update + Virgin Baseline mission, Phase 7 (2026-08-08). Every real
mechanism referenced here already exists (built across this and earlier
missions) - this document is the first place that states the full,
end-to-end flow in one place and names the one script/init-script
responsible for each step. **The one hard rule this flow exists to
enforce: a raw `git pull` (or any other ad hoc update mechanism) must
never be how a device's software actually changes.** Every real update
path goes through this flow, all the way to a device.

```
git main/tag
     |  (git tag -a, human-reviewed, see "who creates a tag" below)
     v
reproducible build            scripts/build/build-qualified-baseline.sh
     |  (fresh clone only - see Phase 8/build.sh --containerized)
     v
versioned release package     scripts/build/package-deployment.sh
     |  (images, configs, decompiled DTB)
     v
manifest + SHA256              build-manifest.txt + SHA256SUMS
     |  (in the same package directory)
     v
GitHub Release                 scripts/release.sh <tag>
     |  (tag-verified: refuses to publish unless the tag is pushed and
     |   matches origin exactly - see that script's own checks)
     v
verified download              gh release download / manual curl + sha256sum -c
     |  (operator or a future automated updater - not yet built, see
     |  "not yet automated" below)
     v
inactive slot write             scripts/flash-spare-slot.sh
     |  (hardcoded to slot2 only; refuses if slot2 is currently active;
     |  full safety preconditions - idle, no active print, heaters off)
     v
read-back verification          scripts/flash-spare-slot.sh's own post-write
     |  (byte-for-byte compare against the source image, not just a
     |  "write succeeded" return code)
     v
reboot                          operator-triggered (see FIRMWARE.md sec 21/22
     |                          for why this project never automates reboot)
     v
persistent migration            S04nebulaos-factory-seed + S04nebulaos-migrate
     |  (compares installed migration_version against this image's own -
     |  see docs/NEBULAOS_PERSISTENT_LIFECYCLE.md for the full mechanics)
     v
confirm-good                    S99confirm-good
     |  (polls Moonraker's own /server/info klippy_state - only flips the
     |  OTA marker forward once the real app stack is actually healthy,
     |  not just "init reached this point")
     v
rollback-on-failure             S00revert-safety (already armed BEFORE this
                                 boot even starts - see below)
```

## Rollback is armed before the new boot, not after

`S00revert-safety` runs first, before every other init script, and
unconditionally points the OTA marker back at the STOCK slot the instant a
custom-slot boot begins at all. Only `S99confirm-good` - running last, after
klipper/moonraker/guppyscreen/nginx are all up, and only once Moonraker's
`klippy_state` genuinely reports `ready` - flips the marker forward again.

This means the "rollback on failure" step in the flow above is not a
separate mechanism bolted onto the end of an update - it is *already true
of every single boot*, update or not, before this mission ever started. If
anything after `S00revert-safety` crashes, hangs, or never reaches
`S99confirm-good`, the next reboot (power cycle, watchdog, anything) lands
back on stock automatically, with no cable, no button, no working shell
required. An update simply rides this same mechanism rather than needing
its own.

## Persistent migration is what makes a slot-flash-only update actually work

A `flash-spare-slot.sh` write only ever touches the squashfs
(kernel2/rootfs2) - never `/usr/data`. Before Phase 3/4 of this mission,
that meant a Klipper/Moonraker source update baked into a new image never
actually reached an already-provisioned device's persistent checkout (the
exact bug `docs/NEBULAOS_CANONICAL_DEPLOYMENT_QUALIFICATION.md` found
live). `S04nebulaos-migrate` closes that gap on every boot after a
successful flash+reboot, comparing the new image's `migration_version`
against what is actually installed and re-seeding only what changed - see
`docs/NEBULAOS_PERSISTENT_LIFECYCLE.md` for the complete mechanics.

## Who creates a tag

A canonical baseline tag is a deliberate, human-reviewed act - never
something a script creates as a side effect of building or packaging.
`scripts/release.sh` enforces this structurally: it refuses to publish a
release unless a tag *already exists* both locally and on `origin`, with
the two matching exactly. It cannot tag anything itself.

## Verified download

`SHA256SUMS` inside every release package covers every file in it. The
one supported verification is `sha256sum -c SHA256SUMS` run against the
downloaded files before they are ever passed to `flash-spare-slot.sh` -
that script does not re-verify hashes of its own accord, so skipping this
step means flashing unverified content.

## Not yet automated (real, honest gap)

There is currently no automated agent on a NebulaOS device that itself
performs "check for a new release, download it, verify it, flash it" -
every device-side step (download, `flash-spare-slot.sh`, reboot) is
currently operator-driven. This is intentional for now given this
project's own repeated finding that reboot and flash actions need a real
human confirming real device state immediately beforehand (see this
mission's own Phase 9/10 safety-check requirements) - a background
updater silently flashing an inactive slot while a print might be starting
is a real risk this flow does not yet take on. Building a supervised
on-device updater (one that still requires an explicit human trigger, but
automates the download/verify/flash sequence once triggered) is real,
separate, future work, not part of this mission.

## Scripts referenced by this flow

| Step | Script |
|---|---|
| Reproducible build | `scripts/build/build-qualified-baseline.sh`, `build.sh --containerized` |
| Package + manifest + SHA256 | `scripts/build/package-deployment.sh` |
| GitHub Release publish | `scripts/release.sh` |
| Inactive-slot flash + read-back | `scripts/flash-spare-slot.sh` |
| Rollback-armed-by-default | `scripts/build/overlay/etc/init.d/S00revert-safety` |
| Confirm-good (arms forward) | `scripts/build/overlay/etc/init.d/S99confirm-good` |
| Persistent migration | `scripts/build/overlay/etc/init.d/S04nebulaos-factory-seed`, `S04nebulaos-migrate` |
| Runtime version truth | `klippy_extras/nebulaos_version.py` (`[nebulaos_version]`) |
