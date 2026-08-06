# Cross-project contract fixture generator/verifier - drives the real ZCompensate class to
# the four canonical states (idle/running/complete/error) from docs/
# z_compensate_status_api.md's own worked examples, and writes the exact serialized JSON
# both this repo's own docs and the nebulaos-guppyscreen fork's C++ tests reference. The
# nebulaos-guppyscreen copy (tests/fixtures/z_compensate_status_contract.json) is a literal
# duplicate of this file's own output, kept in sync manually (small, stable contract - not
# worth a cross-repo code-generation pipeline, see Part 7 of the task this was built under).
#
# Run from the repo root: python3 -m unittest klippy_extras.test_z_compensate_contract_fixture -v
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import json
import os
import unittest

from klippy_extras import prtouch_test_support as fake
from klippy_extras import prtouch_v2
from klippy_extras import z_compensate

FIXTURE_PATH = os.path.join(os.path.dirname(__file__), '..', 'docs',
                             'z_compensate_status_contract_fixture.json')


def _build(stub_measurement=0.0):
    printer, mcu, pins, values = fake.build_environment()
    prtouch_config = fake.make_prtouch_v2_config(printer, pins, values)
    pv2 = prtouch_v2.PRTouchV2(prtouch_config)
    printer.add_object('prtouch_v2', pv2)
    zc_config = fake.make_z_compensate_config(printer, dict(fake.REAL_Z_COMPENSATE_CONFIG))
    zc = z_compensate.ZCompensate(zc_config)
    fake.connect(printer, mcu)
    prtouch_config.assert_all_consumed()
    zc_config.assert_all_consumed()

    def fake_touch_probe(down_min_z, **kwargs):
        if isinstance(stub_measurement, Exception):
            raise stub_measurement
        return stub_measurement

    pv2.touch_probe = fake_touch_probe
    return pv2, zc


class ContractFixtureTest(unittest.TestCase):
    """Generates docs/z_compensate_status_contract_fixture.json from the real ZCompensate
    class's actual get_status() output at each of the four canonical states, and asserts
    the result matches the task's own worked examples exactly (id=1, offset=-0.12734,
    error message text) - proving the fixture is genuine backend output, not hand-typed
    JSON that merely looks plausible."""

    def test_generate_and_verify_canonical_fixture(self):
        fixture = {}

        # idle: fresh object, before any invocation.
        _, zc_idle = _build()
        fixture['idle'] = zc_idle.get_status(0)
        self.assertEqual(fixture['idle'], {
            'calibration_id': 0, 'calibration_state': 'idle',
            'calibration_z_offset': None, 'calibration_error': None,
        })

        # running: captured mid-probe via a stub that snapshots status before returning.
        captured = {}

        def probing(down_min_z, **kwargs):
            captured['running'] = zc_running.get_status(0)
            return -0.12734  # exact value from docs/task's own "complete" worked example

        pv2_running, zc_running = _build()
        pv2_running.touch_probe = probing
        zc_running.tri_expand_mm = 0.0  # isolate: publish the raw stub value exactly
        gcmd = fake.FakeGCmd()
        zc_running.cmd_z_offset_calibration(gcmd)
        fixture['running'] = captured['running']
        self.assertEqual(fixture['running']['calibration_id'], 1)
        self.assertEqual(fixture['running']['calibration_state'], 'running')
        self.assertIsNone(fixture['running']['calibration_z_offset'])
        self.assertIsNone(fixture['running']['calibration_error'])

        # complete: same invocation, final state.
        fixture['complete'] = zc_running.get_status(0)
        self.assertEqual(fixture['complete']['calibration_id'], 1)
        self.assertEqual(fixture['complete']['calibration_state'], 'complete')
        self.assertAlmostEqual(fixture['complete']['calibration_z_offset'], -0.12734)
        self.assertIsNone(fixture['complete']['calibration_error'])

        # error: fresh object, one failed invocation - matches the task's own worked
        # example error message verbatim.
        pv2_err, zc_err = _build(
            stub_measurement=fake.CommandError("Load-cell trigger not detected"))
        gcmd = fake.FakeGCmd()
        with self.assertRaises(fake.CommandError):
            zc_err.cmd_z_offset_calibration(gcmd)
        fixture['error'] = zc_err.get_status(0)
        self.assertEqual(fixture['error'], {
            'calibration_id': 1, 'calibration_state': 'error',
            'calibration_z_offset': None,
            'calibration_error': 'Load-cell trigger not detected',
        })

        with open(FIXTURE_PATH, 'w') as f:
            json.dump(fixture, f, indent=2, sort_keys=True)
            f.write('\n')


if __name__ == '__main__':
    unittest.main()
