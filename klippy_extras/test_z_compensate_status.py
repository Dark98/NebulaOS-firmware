# Structured status contract tests for ZCompensate.get_status() - calibration_id/state/
# z_offset/error, the machine-readable replacement for GuppyScreen's old "z_offset:"/
# "PR_ERR_CODE" terminal-text parsing. See docs/z_compensate_status_api.md for the contract
# itself. Drives the real ZCompensate.cmd_z_offset_calibration against the fake environment
# with only the probe/measurement stubbed - everything else (config, coordinate math,
# _probe_overrides, persistence gating) is the real production code, matching
# test_z_compensate.py's own existing convention.
#
# Run from the repo root: python3 -m unittest klippy_extras.test_z_compensate_status -v
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import contextlib
import math
import unittest

from klippy_extras import prtouch_safety_guard as guard_mod
from klippy_extras import prtouch_test_support as fake
from klippy_extras import prtouch_v2
from klippy_extras import z_compensate


def _build(zcompensate_overrides=None, stub_measurement=0.0):
    printer, mcu, pins, values = fake.build_environment()
    prtouch_config = fake.make_prtouch_v2_config(printer, pins, values)
    pv2 = prtouch_v2.PRTouchV2(prtouch_config)
    printer.add_object('prtouch_v2', pv2)

    zc_values = dict(fake.REAL_Z_COMPENSATE_CONFIG)
    if zcompensate_overrides:
        zc_values.update(zcompensate_overrides)
    zc_config = fake.make_z_compensate_config(printer, zc_values)
    zc = z_compensate.ZCompensate(zc_config)

    fake.connect(printer, mcu)
    prtouch_config.assert_all_consumed()
    zc_config.assert_all_consumed()

    def fake_touch_probe(down_min_z, **kwargs):
        if isinstance(stub_measurement, Exception):
            raise stub_measurement
        return stub_measurement

    pv2.touch_probe = fake_touch_probe
    return printer, mcu, pv2, zc


def assert_no_mcu_motion(testcase, mcu):
    """touch_probe is stubbed at the PRTouchV2 level in every test in this file, so the raw
    MCU protocol layer (prtouch_mcu.py) must never be touched at all - not even a zero/stop
    call. A regression that accidentally bypassed the stub and reached the real
    PrtouchProbe/PrtouchMCU code would show up here as a non-empty sent_commands list."""
    testcase.assertEqual(mcu.sent_commands, [],
                          "no MCU command of any kind should be sent - touch_probe is stubbed")


class InitialStateTest(unittest.TestCase):
    def test_fresh_object_state(self):
        _, _, _, zc = _build()
        status = zc.get_status(0)
        self.assertEqual(status["calibration_id"], 0)
        self.assertEqual(status["calibration_state"], "idle")
        self.assertIsNone(status["calibration_z_offset"])
        self.assertIsNone(status["calibration_error"])

    def test_get_status_returns_a_fresh_dict_each_call(self):
        _, _, _, zc = _build()
        d1 = zc.get_status(0)
        d1["calibration_state"] = "tampered"
        d1["calibration_id"] = 999
        d2 = zc.get_status(0)
        self.assertEqual(d2["calibration_state"], "idle")
        self.assertEqual(d2["calibration_id"], 0)
        self.assertIsNot(d1, d2)


class SuccessfulCalibrationTest(unittest.TestCase):
    def test_full_success_contract(self):
        printer, mcu, pv2, zc = _build(stub_measurement=0.05)
        seen_during_probe = {}

        def probing_touch_probe(down_min_z, **kwargs):
            # snapshot status from *inside* the probe call - proves "running" was published
            # before probing began, not just eventually.
            seen_during_probe['status'] = zc.get_status(0)
            return 0.05

        pv2.touch_probe = probing_touch_probe
        gcmd = fake.FakeGCmd()

        self.assertEqual(zc.calibration_id, 0)
        zc.cmd_z_offset_calibration(gcmd)

        self.assertEqual(seen_during_probe['status']['calibration_state'], 'running')
        self.assertEqual(seen_during_probe['status']['calibration_id'], 1)
        self.assertIsNone(seen_during_probe['status']['calibration_z_offset'])
        self.assertIsNone(seen_during_probe['status']['calibration_error'])

        final = zc.get_status(0)
        self.assertEqual(final['calibration_id'], 1)
        self.assertEqual(final['calibration_state'], 'complete')
        self.assertAlmostEqual(final['calibration_z_offset'], 0.05 + zc.tri_expand_mm)
        self.assertIsNone(final['calibration_error'])

        # human text remains present but is not what these assertions rely on -
        # non-authoritative, exactly as the contract requires.
        self.assertTrue(gcmd.responses)
        self.assertIn('measured', gcmd.responses[0])

        # session-only by default - no persistence command executed.
        joined = ' '.join(pv2.gcode.scripts_run)
        self.assertNotIn('SAVE_CONFIG', joined)
        self.assertNotIn('Z_OFFSET_APPLY_PROBE', joined)

        assert_no_mcu_motion(self, mcu)

    def test_offset_published_matches_persistable_value_exactly(self):
        # calibration_z_offset must be the FINAL value (measurement + tri_expand_mm), not the
        # raw pre-correction probe reading - "do not expose an intermediate raw probe
        # measurement under this field" (task spec).
        _, _, pv2, zc = _build(stub_measurement=-0.2)
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)
        applied_script = next(s for s in pv2.gcode.scripts_run if 'SET_GCODE_OFFSET' in s)
        # the exact numeric string applied to the live offset and the published status field
        # must agree - both derive from the same final `measured_z`, not two computations.
        self.assertIn('Z=%.5f' % zc.calibration_z_offset, applied_script)


class RepeatedSuccessTest(unittest.TestCase):
    def test_ids_increment_and_second_result_replaces_first(self):
        _, _, pv2, zc = _build(stub_measurement=0.10)
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)
        self.assertEqual(zc.calibration_id, 1)
        self.assertAlmostEqual(zc.calibration_z_offset, 0.10 + zc.tri_expand_mm)

        pv2.touch_probe = lambda down_min_z, **kw: 0.40
        zc.cmd_z_offset_calibration(gcmd)
        self.assertEqual(zc.calibration_id, 2)
        self.assertAlmostEqual(zc.calibration_z_offset, 0.40 + zc.tri_expand_mm)
        self.assertEqual(zc.calibration_state, 'complete')
        self.assertIsNone(zc.calibration_error)


class FailureDuringProbingTest(unittest.TestCase):
    def test_command_error_during_probe_sets_error_state(self):
        _, mcu, pv2, zc = _build(stub_measurement=fake.CommandError("prtouch: no trigger"))
        gcmd = fake.FakeGCmd()
        with self.assertRaises(fake.CommandError):
            zc.cmd_z_offset_calibration(gcmd)
        self.assertEqual(zc.calibration_id, 1)
        self.assertEqual(zc.calibration_state, 'error')
        self.assertIsNone(zc.calibration_z_offset)
        self.assertEqual(zc.calibration_error, 'prtouch: no trigger')
        joined = ' '.join(pv2.gcode.scripts_run)
        self.assertNotIn('SET_GCODE_OFFSET', joined)
        self.assertNotIn('SAVE_CONFIG', joined)
        assert_no_mcu_motion(self, mcu)


class FailureDuringComputationTest(unittest.TestCase):
    """"Computation" here is the finite-value check added alongside this contract (see
    z_compensate.py's own comment) - a NaN/inf measurement is now rejected explicitly,
    before ever being applied as a live offset or published as a completed result."""

    def test_nan_measurement_is_rejected_not_published(self):
        _, mcu, pv2, zc = _build(stub_measurement=float('nan'))
        gcmd = fake.FakeGCmd()
        with self.assertRaises(fake.CommandError):
            zc.cmd_z_offset_calibration(gcmd)
        self.assertEqual(zc.calibration_state, 'error')
        self.assertIsNone(zc.calibration_z_offset)
        self.assertIsNotNone(zc.calibration_error)
        self.assertIn('finite', zc.calibration_error)
        self.assertNotIn('Traceback', zc.calibration_error)
        joined = ' '.join(pv2.gcode.scripts_run)
        self.assertNotIn('SET_GCODE_OFFSET', joined)

    def test_infinite_measurement_is_rejected_not_published(self):
        _, mcu, pv2, zc = _build(stub_measurement=float('inf'))
        gcmd = fake.FakeGCmd()
        with self.assertRaises(fake.CommandError):
            zc.cmd_z_offset_calibration(gcmd)
        self.assertEqual(zc.calibration_state, 'error')
        self.assertIsNone(zc.calibration_z_offset)


class FailureApplyingSessionOffsetTest(unittest.TestCase):
    def test_set_gcode_offset_failure_leaves_no_complete_state_observable(self):
        printer, mcu, pv2, zc = _build(stub_measurement=0.05)
        real_run = pv2.gcode.run_script_from_command

        def flaky_run(script):
            if script.startswith('SET_GCODE_OFFSET'):
                raise RuntimeError("simulated failure applying live offset")
            return real_run(script)

        pv2.gcode.run_script_from_command = flaky_run
        gcmd = fake.FakeGCmd()
        with self.assertRaises(RuntimeError):
            zc.cmd_z_offset_calibration(gcmd)
        self.assertEqual(zc.calibration_state, 'error')
        self.assertIsNone(zc.calibration_z_offset)
        self.assertIn('simulated failure applying live offset', zc.calibration_error)


class FailureDuringCleanupTest(unittest.TestCase):
    """_probe_overrides' own restore step is the only real "cleanup" in this command - see
    z_compensate.py. Substituting it for one call (rather than reaching into PrtouchProbe's
    attribute plumbing) is a deliberate, minimal way to exercise "cleanup itself raises"
    without touching the production _probe_overrides implementation at all."""

    def test_cleanup_failure_after_successful_measurement_is_reported_as_error(self):
        _, mcu, pv2, zc = _build(stub_measurement=0.05)

        @contextlib.contextmanager
        def raising_cleanup():
            yield pv2.probe
            raise RuntimeError("simulated cleanup failure restoring probe overrides")

        zc._probe_overrides = raising_cleanup
        gcmd = fake.FakeGCmd()
        with self.assertRaises(RuntimeError):
            zc.cmd_z_offset_calibration(gcmd)
        self.assertEqual(zc.calibration_state, 'error')
        self.assertIsNone(zc.calibration_z_offset)
        self.assertIn('simulated cleanup failure', zc.calibration_error)
        # the pre-existing measurement must not leak through as a "complete" result just
        # because the *measurement itself* succeeded before cleanup failed.
        joined = ' '.join(pv2.gcode.scripts_run)
        self.assertNotIn('SET_GCODE_OFFSET', joined)


class PreviousSuccessFollowedByFailureTest(unittest.TestCase):
    def test_second_failed_invocation_clears_first_successful_result(self):
        _, mcu, pv2, zc = _build(stub_measurement=0.08)
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)
        self.assertEqual(zc.calibration_id, 1)
        self.assertEqual(zc.calibration_state, 'complete')
        first_offset = zc.calibration_z_offset
        self.assertIsNotNone(first_offset)

        pv2.touch_probe = lambda down_min_z, **kw: (_ for _ in ()).throw(
            fake.CommandError("prtouch: second attempt failed"))
        with self.assertRaises(fake.CommandError):
            zc.cmd_z_offset_calibration(gcmd)

        self.assertEqual(zc.calibration_id, 2)
        self.assertEqual(zc.calibration_state, 'error')
        self.assertIsNone(zc.calibration_z_offset)
        self.assertEqual(zc.calibration_error, 'prtouch: second attempt failed')
        # the first invocation's real offset must not still be sitting in the published
        # status looking like it belongs to the failed second attempt.
        self.assertNotEqual(zc.calibration_z_offset, first_offset)


class StatusTypeContractTest(unittest.TestCase):
    def test_types_match_the_documented_contract(self):
        _, _, pv2, zc = _build(stub_measurement=0.05)
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)
        status = zc.get_status(0)
        self.assertIsInstance(status['calibration_id'], int)
        self.assertIn(status['calibration_state'], ('idle', 'running', 'complete', 'error'))
        self.assertTrue(status['calibration_z_offset'] is None
                         or isinstance(status['calibration_z_offset'], float))
        self.assertTrue(status['calibration_error'] is None
                         or isinstance(status['calibration_error'], str))

    def test_error_state_has_null_offset_and_string_error(self):
        _, _, pv2, zc = _build(stub_measurement=fake.CommandError("boom"))
        gcmd = fake.FakeGCmd()
        with self.assertRaises(fake.CommandError):
            zc.cmd_z_offset_calibration(gcmd)
        status = zc.get_status(0)
        self.assertIsNone(status['calibration_z_offset'])
        self.assertIsInstance(status['calibration_error'], str)

    def test_error_message_is_sanitized_single_line_and_bounded(self):
        long_multiline = "line one\nline two\n" + ("x" * 500)
        _, _, pv2, zc = _build(stub_measurement=RuntimeError(long_multiline))
        gcmd = fake.FakeGCmd()
        with self.assertRaises(RuntimeError):
            zc.cmd_z_offset_calibration(gcmd)
        err = zc.calibration_error
        self.assertNotIn('\n', err)
        self.assertLessEqual(len(err), 200)
        self.assertNotIn('Traceback', err)
        self.assertNotIn('0x', err)  # no object/memory-address reprs


class MovementGuardProofTest(unittest.TestCase):
    """Direct proof the safety guard would intercept the real motion path this new code
    calls into, if the stub weren't in place - the strongest available demonstration that
    every OTHER test in this file (which stubs touch_probe and therefore never reaches the
    MCU layer at all) is genuinely not exercising any motion-capable command."""

    def test_guard_blocks_the_real_probe_path_from_cmd_z_offset_calibration(self):
        printer, mcu, pins, values = fake.build_environment()
        prtouch_config = fake.make_prtouch_v2_config(printer, pins, values)
        pv2 = prtouch_v2.PRTouchV2(prtouch_config)
        printer.add_object('prtouch_v2', pv2)
        zc_config = fake.make_z_compensate_config(printer, dict(fake.REAL_Z_COMPENSATE_CONFIG))
        zc = z_compensate.ZCompensate(zc_config)
        fake.connect(printer, mcu)
        # deliberately NOT stubbing touch_probe here - this is the one test in the file that
        # exercises the real orchestration path, specifically to prove the guard catches it.
        gcmd = fake.FakeGCmd()
        with guard_mod.guard(pv2):
            with self.assertRaises(guard_mod.MovementBlockedError):
                zc.cmd_z_offset_calibration(gcmd)
        # the attempt must have been recorded as a failure in the structured status too -
        # the guard's exception is just another exception to cmd_z_offset_calibration's own
        # try/except.
        self.assertEqual(zc.calibration_state, 'error')


if __name__ == '__main__':
    unittest.main()
