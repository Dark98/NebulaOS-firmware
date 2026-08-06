# Part 8 offline integration harness (backend half) - generates an ordered, wire-shaped
# trace of z_compensate status snapshots bracketing one real Z_OFFSET_CALIBRATION
# invocation, for a success run and a failure run. Entirely offline: PRTouchV2's
# touch_probe is stubbed to a pure Python function and every collaborator (printer, mcu,
# toolhead, gcode) is the fake test-support harness used throughout this repo's test
# suite - there is no real MCU, no real motion, nothing to physically move even if this
# file had a bug.
#
# Direct single-process Python<->C++ linking is impractical for this small, stable
# four-field contract (see docs/z_compensate_status_api.md's versioning note); this file
# and its nebulaos-guppyscreen counterpart (tests/test_integration_harness.cpp) instead
# share a documented *serialized-fixture boundary*: this file writes the real backend's
# actual get_status() output at each step to docs/z_compensate_integration_trace_
# {success,failure}.json, and the C++ side replays those exact snapshots through the real
# frontend parser/tracker/persistence code. Together the two sides prove the same 10
# proof points Part 8 asks for without an artificial in-process bridge.
#
# Run from the repo root: python3 -m unittest klippy_extras.test_z_compensate_integration_trace -v
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import json
import os
import unittest

from klippy_extras import prtouch_test_support as fake
from klippy_extras import prtouch_v2
from klippy_extras import z_compensate

SUCCESS_PATH = os.path.join(os.path.dirname(__file__), '..', 'docs',
                             'z_compensate_integration_trace_success.json')
FAILURE_PATH = os.path.join(os.path.dirname(__file__), '..', 'docs',
                             'z_compensate_integration_trace_failure.json')


def _build(stub_measurement):
    printer, mcu, pins, values = fake.build_environment()
    prtouch_config = fake.make_prtouch_v2_config(printer, pins, values)
    pv2 = prtouch_v2.PRTouchV2(prtouch_config)
    printer.add_object('prtouch_v2', pv2)
    zc_config = fake.make_z_compensate_config(printer, dict(fake.REAL_Z_COMPENSATE_CONFIG))
    zc = z_compensate.ZCompensate(zc_config)
    fake.connect(printer, mcu)
    prtouch_config.assert_all_consumed()
    zc_config.assert_all_consumed()
    zc.tri_expand_mm = 0.0  # isolate: publish the raw stub value exactly, as elsewhere

    def fake_touch_probe(down_min_z, **kwargs):
        if isinstance(stub_measurement, Exception):
            raise stub_measurement
        return stub_measurement

    pv2.touch_probe = fake_touch_probe
    return pv2, zc


class IntegrationTraceTest(unittest.TestCase):
    """Builds the offline success/failure traces the C++ side consumes. Each trace records
    three snapshots (proof point 1: 'before_command' captured prior to ever sending the
    command; proof point 4/6: 'mid_probe' captured from inside the real touch_probe call,
    proving 'running' genuinely precedes the terminal result rather than being skipped
    over; and the final terminal snapshot) plus the literal command name actually invoked
    (proof point 3: unchanged from before this task - still 'Z_OFFSET_CALIBRATION')."""

    def _run(self, path, stub_measurement, expect_success):
        pv2, zc = _build(stub_measurement)
        trace = {'command': 'Z_OFFSET_CALIBRATION', 'steps': []}

        before = zc.get_status(0)
        trace['steps'].append({'label': 'before_command', 'status': before})
        self.assertEqual(before['calibration_state'], 'idle')

        captured = {}
        original_probe = pv2.touch_probe

        def probing(down_min_z, **kwargs):
            # Captured from *inside* the real probe call, before it returns/raises - proves
            # the 'running' status genuinely precedes the terminal outcome rather than the
            # two being indistinguishable to an observer polling get_status().
            captured['mid_probe'] = zc.get_status(0)
            return original_probe(down_min_z, **kwargs)

        pv2.touch_probe = probing

        gcmd = fake.FakeGCmd()
        if expect_success:
            zc.cmd_z_offset_calibration(gcmd)
        else:
            with self.assertRaises(fake.CommandError):
                zc.cmd_z_offset_calibration(gcmd)

        trace['steps'].append({'label': 'mid_probe', 'status': captured['mid_probe']})
        trace['steps'].append({'label': 'after_terminal', 'status': zc.get_status(0)})

        with open(path, 'w') as f:
            json.dump(trace, f, indent=2, sort_keys=True)
            f.write('\n')
        return trace

    def test_success_trace(self):
        trace = self._run(SUCCESS_PATH, -0.12734, expect_success=True)
        self.assertEqual(trace['steps'][1]['status']['calibration_state'], 'running')
        final = trace['steps'][2]['status']
        self.assertEqual(final['calibration_state'], 'complete')
        self.assertAlmostEqual(final['calibration_z_offset'], -0.12734)
        self.assertIsNone(final['calibration_error'])

    def test_failure_trace(self):
        trace = self._run(
            FAILURE_PATH, fake.CommandError('Load-cell trigger not detected'),
            expect_success=False)
        self.assertEqual(trace['steps'][1]['status']['calibration_state'], 'running')
        final = trace['steps'][2]['status']
        self.assertEqual(final['calibration_state'], 'error')
        self.assertIsNone(final['calibration_z_offset'])
        self.assertEqual(final['calibration_error'], 'Load-cell trigger not detected')


if __name__ == '__main__':
    unittest.main()
