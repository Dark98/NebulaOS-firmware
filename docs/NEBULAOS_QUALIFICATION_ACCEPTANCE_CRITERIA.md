# NebulaOS Qualification Acceptance/Rejection Criteria

Pre-qualification mission Phase A10 (2026-07-31). Defined **before** any
hardware testing begins, so Phase B's real results are interpreted against
thresholds fixed in advance - not opportunistically after the fact. Cross-
references the actual mechanisms built in Phases A3-A9.

## Stable Wi-Fi MAC (Phase A3)

**Accept only if all of:**
- Identical MAC address across 5 warm reboots and 3 cold boots
  (`nebulaos_derive_mac_from_identifier` is deterministic for a fixed
  input by construction and by its own 13 offline tests - this criterion
  is about confirming the real eMMC CID input itself is actually stable
  across those cycles, which offline tests cannot prove).
- Identical MAC across an A/B rootfs/kernel slot switch (both slots share
  the same physical eMMC, so the CID input is identical by hardware
  construction - confirm this holds in practice, not just in theory).
- The applied MAC is a valid locally-administered unicast address (local
  bit set, multicast bit clear - already proven by construction in the
  offline tests, confirm the live `ip link show wlan0` address matches).
- No collision with any other known device's MAC on the same test network.
- Wi-Fi association remains healthy with the new MAC (no regression from
  today's real, already-proven-working association, FIRMWARE.md sec 53).

**Reject if:** the MAC changes across any reboot/slot-switch cycle, is not
a valid locally-administered address, or association becomes unreliable
after the MAC change.

## SDIO device-tree variants (Phase A4: W1 `cap-sdio-irq`, W2 `cap-sd-highspeed`, W3 both)

**Reject immediately (before any further comparison) if any of:**
- Wi-Fi fails to enumerate at boot.
- Association becomes unreliable (a real regression from today's proven
  end-to-end success).
- Any SDIO/MMC error or firmware reset appears in `dmesg` that wasn't
  already present on the W0 baseline.
- Packet loss increases materially over the W0 baseline.
- Throughput decreases materially over the W0 baseline.
- Warm or cold boot reliability decreases (any boot that previously
  succeeded now fails, across 5 warm + 3 cold boots).

**Accept only if**, in addition to passing every rejection check above,
at least one of these shows a measurable improvement with no material
regression elsewhere:
- Host-side polling overhead (proxy: idle CPU, context-switch rate)
- Latency (ping median/P95/P99 via `lan-performance-test.sh`)
- Jitter (ping P99 - P50 spread)
- Throughput (`lan-performance-test.sh`'s TCP upload test)
- Reconnect behavior (time to re-associate after a simulated AP restart)

**Ordering**: test W1 and W2 independently first; only proceed to W3 if
both W1 and W2 individually pass every rejection check above. Never test
W3 first.

## Wi-Fi power-save off (Phase A5, P1)

**Accept only if** responsiveness/latency/jitter/packet-loss/streaming
reliability improves by an amount that justifies the measured power/
temperature cost - not "any" measurable difference, a difference large
enough to matter for real print-time usage. Do not accept based on
subjective impression alone (the `nebulaos_wifi_ps_apply`/CLI mechanism
makes this trivially reversible per-boot if the numbers don't hold up).

**Reject if:** no measurable responsiveness improvement, or the idle-
power/temperature cost is not offset by any real benefit.

## Event-driven boot-association wait (Phase A6)

No formal accept/reject gate defined by the mission itself beyond "must
not regress boot-to-network reliability" - this is a minor optimization,
not a core decision. Accept only if:
- Boot-to-network time improves on the common (fast-association) case.
- No regression in the slow-association case (a real weak-signal or
  retry-heavy association must still complete reliably within a
  reasonable bound - use the same timeout already configured,
  `NEBULAOS_WIFI_BOOT_WAIT_TIMEOUT`).

**Reject if:** any real boot shows worse network readiness than the
original fixed `sleep 2` path.

## Camera 1080p15 (Phase A7, C1)

**Accept as the production default only if** its network/CPU/stability
gain is meaningful enough to justify the real, visible loss of motion
smoothness versus the already-qualified 30fps default (S50webcam's own
real prior qualification: 29.69fps average, 6.9-7.6% CPU). It may instead
ship only as an optional low-bandwidth mode, not necessarily replace C0.

**Do not claim** 15fps changes the ~8,000/sec USB SOF interrupt rate -
per the source analysis, that rate is tied to `VIDIOC_STREAMON` being
active at all, not the configured frame rate, and this mission's own
measurements must not contradict that already-proven mechanism.

## Camera idle pause (Phase A7, C2)

**Reject if any of:**
- First-frame delay after resuming from a pause is unacceptable for
  real use (define "unacceptable" against actual Mainsail/GuppyScreen
  camera-panel UX expectations during Phase B6, not a number invented in
  advance).
- Resume fails and the retry/backoff mechanism
  (`nebulaos_camera_resume_with_retry`) cannot recover it.
- The camera panel gets stuck (paused with no resume) in Mainsail.
- GuppyScreen's own camera panel breaks (source-unavailable, so this can
  only be confirmed live - flagged as a required test, not assumed safe).
- USB storage hotplug regresses while the idle controller is active.
- Camera recovery after a reboot regresses.
- The 100-cycle reopen test (`REQUIRED_LATER_TEST` from the source
  analysis, sec 11) fails at any point.

**Accept only if**, with none of the above triggered:
- Idle USB IRQ and/or CPU reduction is significant (compare against the
  W0/C0 baseline's own already-measured ~8,000/sec and aggregate CPU%).
- Camera reliability remains production-grade across the full test matrix
  in sec 18.18 Stage D and the mission's own repetition counts (100
  pause/resume cycles, 20 camera-service restarts, 20 USB insert/remove
  cycles, 5 warm reboots, 3 cold boots).

## PREEMPT_RT (Phase A8, R1)

**Reject before any physical print test if any of:**
- Worst-case scheduling latency (via `cyclictest`, Phase A8's diagnostic
  tooling plan) does not improve meaningfully over R0 - RT with no real
  latency benefit is pure downside for this board.
- Idle CPU increases materially over R0.
- Context switches increase excessively over R0 - this is the primary,
  already-flagged risk (DWC2's ~8,000/sec IRQ has no `IRQF_NO_THREAD` and
  will be force-threaded under R1; the source analysis rates this the
  dominant open risk for the whole RT question).
- DWC2 loses camera frames (frame-continuity collector, Phase A9).
- Camera reliability regresses in any other way.
- Wi-Fi regresses (already source-analyzed as Low risk, but must be
  confirmed live, not assumed).
- Boot time regresses materially with no compensating benefit (RT is not
  expected to help boot time at all - any regression here is pure cost).
- MCU communication (UART, Klipper's own comms) becomes less stable.

**Accept only if** a demonstrated worst-case-latency or reliability
benefit is shown with none of the above rejection conditions triggered.
Per the mission's own explicit framing: **PREEMPT_RT is a latency
experiment, not a boot-time, RAM, or throughput optimization** - do not
accept it on any basis other than a real latency/reliability win.

## Cross-cutting rules (apply to every candidate above)

- Never combine more than one experimental variable in a single A/B
  comparison (SDIO variant, power-save state, camera mode, and preemption
  model must each be tested holding all the others fixed).
- Never proceed to a full physical print test for a candidate that has
  already failed a cheap rejection check.
- A candidate that is rejected stays rejected - do not re-test the exact
  same variant again without a real code change between attempts.
- Every accepted candidate must be recorded in the Phase B7 decision
  record with which specific measurement justified acceptance, not just
  "it seemed fine."
