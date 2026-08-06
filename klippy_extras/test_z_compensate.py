# z_compensate.py audit - coordinate math, offset sign, persistence policy, and cleanup,
# tested entirely without motion by stubbing PRTouchV2.touch_probe() (the one call that
# would otherwise reach the real MCU state machine, already covered separately by
# test_prtouch_orchestration.py) with a controlled synthetic measurement.
#
# Run from the repo root: python3 -m unittest klippy_extras.test_z_compensate -v
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import unittest

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

    calls = []

    def fake_touch_probe(down_min_z, **kwargs):
        calls.append({'down_min_z': down_min_z, 'kwargs': kwargs})
        return stub_measurement

    pv2.touch_probe = fake_touch_probe
    return printer, mcu, pv2, zc, calls


class CoordinateMathTest(unittest.TestCase):
    """1. directly supported by stock configuration evidence: bed-mesh-center + bl_offset
    is the target point, matching bl_offset's own real value (0, 27) against [bltouch]'s
    real y_offset (27) exactly - see module docstring / DESIGN.md."""

    def test_target_is_bed_center_plus_bl_offset(self):
        printer, mcu, pv2, zc, calls = _build()
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)
        move_script = pv2.gcode.scripts_run[0]  # the G1 positioning move, sent first
        bed_mesh = printer.objects['bed_mesh']
        min_x, min_y = bed_mesh.bmc.mesh_min
        max_x, max_y = bed_mesh.bmc.mesh_max
        expected_x = min_x + (max_x - min_x) / 2. + zc.bl_offset_x
        expected_y = min_y + (max_y - min_y) / 2. + zc.bl_offset_y
        self.assertIn('X%.3f' % expected_x, move_script)
        self.assertIn('Y%.3f' % expected_y, move_script)
        self.assertIn('Z%.3f' % zc.hover_height, move_script)

    def test_bl_offset_matches_real_bltouch_y_offset(self):
        _, _, _, zc, _ = _build()
        self.assertEqual(zc.bl_offset_y, fake.REAL_BLTOUCH_Y_OFFSET)


class OffsetSignAndApplicationTest(unittest.TestCase):
    """2. directly supported by wrapper strings / call names: SET_GCODE_OFFSET Z=<raw
    measurement + tri_expand_mm>, no inversion - see cmd_z_offset_calibration's own
    docstring for the sign-convention derivation against pellcorp/klipper's probe.py."""

    def test_positive_measurement_applied_verbatim_plus_tri_expand_mm(self):
        _, _, pv2, zc, calls = _build(stub_measurement=0.123)
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)
        expected = 0.123 + zc.tri_expand_mm
        offset_script = next(s for s in pv2.gcode.scripts_run if 'SET_GCODE_OFFSET' in s)
        self.assertIn('Z=%.5f' % expected, offset_script)
        self.assertIn('MOVE=0', offset_script)

    def test_negative_measurement_applied_verbatim_not_flipped(self):
        _, _, pv2, zc, calls = _build(stub_measurement=-0.456)
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)
        expected = -0.456 + zc.tri_expand_mm
        offset_script = next(s for s in pv2.gcode.scripts_run if 'SET_GCODE_OFFSET' in s)
        self.assertIn('Z=%.5f' % expected, offset_script)

    def test_zero_measurement_still_applies_tri_expand_mm_correction(self):
        _, _, pv2, zc, calls = _build(stub_measurement=0.0)
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)
        offset_script = next(s for s in pv2.gcode.scripts_run if 'SET_GCODE_OFFSET' in s)
        self.assertIn('Z=%.5f' % zc.tri_expand_mm, offset_script)

    def test_touch_probe_receives_pr_probe_cnt(self):
        _, _, pv2, zc, calls = _build()
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)
        self.assertEqual(calls[0]['kwargs'].get('pro_cnt'), zc.pr_probe_cnt)
        self.assertEqual(calls[0]['down_min_z'], zc.down_min_z)


class PersistenceIsSessionOnlyByDefaultTest(unittest.TestCase):
    """3. new project policy, deliberately conservative: persist_offset defaults False,
    and the task brief is explicit - "do not pretend CXSAVE_CONFIG equivalence exists
    unless it is proven" / "keep session-only behavior as the safe default"."""

    def test_persist_offset_defaults_false(self):
        _, _, _, zc, _ = _build()
        self.assertFalse(zc.persist_offset)

    def test_default_never_calls_apply_probe_or_save_config(self):
        _, _, pv2, zc, _ = _build()
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)
        joined = ' '.join(pv2.gcode.scripts_run)
        self.assertNotIn('Z_OFFSET_APPLY_PROBE', joined)
        self.assertNotIn('SAVE_CONFIG', joined)

    def test_persist_offset_true_calls_apply_then_save_in_order(self):
        _, _, pv2, zc, _ = _build(zcompensate_overrides={'persist_offset': 'True'})
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)
        scripts = pv2.gcode.scripts_run
        apply_idx = scripts.index('Z_OFFSET_APPLY_PROBE')
        save_idx = scripts.index(zc.save_config_command)
        self.assertLess(apply_idx, save_idx,
                         "Z_OFFSET_APPLY_PROBE must run before the save command")

    def test_save_config_command_defaults_to_the_real_restarting_command_not_a_guess(self):
        # must default to Klipper's real, genuinely restart-triggering SAVE_CONFIG - not a
        # silently-assumed CXSAVE_CONFIG-equivalent that has never been confirmed to exist
        # in this fork (see module docstring's open question).
        _, _, _, zc, _ = _build()
        self.assertEqual(zc.save_config_command, 'SAVE_CONFIG')

    def test_save_config_command_is_overridable_for_a_future_confirmed_equivalent(self):
        # the escape hatch this design leaves open, without assuming it's usable today.
        _, _, pv2, zc, _ = _build(zcompensate_overrides={
            'persist_offset': 'True', 'save_config_command': 'CXSAVE_CONFIG'})
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)
        self.assertIn('CXSAVE_CONFIG', pv2.gcode.scripts_run)
        self.assertNotIn('SAVE_CONFIG', [s for s in pv2.gcode.scripts_run if s != 'CXSAVE_CONFIG'])


class FailureHandlingTest(unittest.TestCase):
    """4/5. failure before offset application / invalid measurement: touch_probe raising
    must propagate (never silently swallowed into a fabricated offset), and must not leave
    the shared PrtouchProbe's tri_min_hold/tri_max_hold/tri_z_down_spd permanently
    clobbered by this section's own overrides (see _probe_overrides' try/finally)."""

    def test_touch_probe_failure_propagates_not_swallowed(self):
        printer, mcu, pins, values = fake.build_environment()
        prtouch_config = fake.make_prtouch_v2_config(printer, pins, values)
        pv2 = prtouch_v2.PRTouchV2(prtouch_config)
        printer.add_object('prtouch_v2', pv2)
        zc_config = fake.make_z_compensate_config(printer, dict(fake.REAL_Z_COMPENSATE_CONFIG))
        zc = z_compensate.ZCompensate(zc_config)
        fake.connect(printer, mcu)

        def raising_touch_probe(down_min_z, **kwargs):
            raise fake.CommandError("prtouch: simulated no-trigger failure")

        pv2.touch_probe = raising_touch_probe
        gcmd = fake.FakeGCmd()
        with self.assertRaises(fake.CommandError):
            zc.cmd_z_offset_calibration(gcmd)
        # no fabricated offset must have been applied
        self.assertFalse(any('SET_GCODE_OFFSET' in s for s in pv2.gcode.scripts_run))

    def test_probe_overrides_restored_even_when_touch_probe_raises(self):
        printer, mcu, pins, values = fake.build_environment()
        prtouch_config = fake.make_prtouch_v2_config(printer, pins, values)
        pv2 = prtouch_v2.PRTouchV2(prtouch_config)
        printer.add_object('prtouch_v2', pv2)
        zc_config = fake.make_z_compensate_config(printer, dict(fake.REAL_Z_COMPENSATE_CONFIG))
        zc = z_compensate.ZCompensate(zc_config)
        fake.connect(printer, mcu)
        original_tri_min_hold = pv2.probe.tri_min_hold
        original_tri_z_down_spd = pv2.probe.tri_z_down_spd
        self.assertNotEqual(original_tri_min_hold, zc.tri_min_hold,
                             "test requires the two sections' values to genuinely differ")

        def raising_touch_probe(down_min_z, **kwargs):
            # by the time this runs, _probe_overrides has already applied zc's own values
            self.assertEqual(pv2.probe.tri_min_hold, zc.tri_min_hold)
            raise fake.CommandError("simulated failure mid-probe")

        pv2.touch_probe = raising_touch_probe
        gcmd = fake.FakeGCmd()
        with self.assertRaises(fake.CommandError):
            zc.cmd_z_offset_calibration(gcmd)
        self.assertEqual(pv2.probe.tri_min_hold, original_tri_min_hold,
                          "tri_min_hold must be restored to prtouch_v2's own value")
        self.assertEqual(pv2.probe.tri_z_down_spd, original_tri_z_down_spd,
                          "tri_z_down_spd must be restored to prtouch_v2's own value")


class RepeatedInvocationTest(unittest.TestCase):
    def test_second_call_reflects_only_its_own_measurement(self):
        _, _, pv2, zc, calls = _build(stub_measurement=0.05)
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)
        pv2.touch_probe = lambda down_min_z, **kw: 0.30
        zc.cmd_z_offset_calibration(gcmd)
        offset_scripts = [s for s in pv2.gcode.scripts_run if 'SET_GCODE_OFFSET' in s]
        self.assertEqual(len(offset_scripts), 2)
        self.assertIn('Z=%.5f' % (0.05 + zc.tri_expand_mm), offset_scripts[0])
        self.assertIn('Z=%.5f' % (0.30 + zc.tri_expand_mm), offset_scripts[1])

    def test_probe_overrides_symmetric_across_repeated_calls(self):
        _, _, pv2, zc, calls = _build()
        original = pv2.probe.tri_min_hold
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)
        self.assertEqual(pv2.probe.tri_min_hold, original)
        zc.cmd_z_offset_calibration(gcmd)
        self.assertEqual(pv2.probe.tri_min_hold, original)


class NozzleClearUsesOwnSectionConfigTest(unittest.TestCase):
    """cmd_nozzle_clear must call prtouch_nozzle.clear_nozzle() with THIS section's own
    ClearNozzleConfig (real clr_noz_start_x=-3), not [prtouch_v2]'s (which has none of
    these keys) - see z_compensate.py's own module docstring for why this matters."""

    def test_clear_nozzle_receives_z_compensate_owned_config(self):
        printer, mcu, pv2, zc, _ = _build()
        captured = {}
        original_clear_nozzle = z_compensate.prtouch_nozzle.clear_nozzle

        def spy(probe, toolhead, gcode, heaters, params, *a, **kw):
            captured['params'] = params
            return None

        z_compensate.prtouch_nozzle.clear_nozzle = spy
        try:
            gcmd = fake.FakeGCmd()
            zc.cmd_nozzle_clear(gcmd)
        finally:
            z_compensate.prtouch_nozzle.clear_nozzle = original_clear_nozzle
        self.assertIs(captured['params'], zc.clear_nozzle_config)
        self.assertEqual(captured['params'].clr_noz_start_x, -3.0)


if __name__ == '__main__':
    unittest.main()
