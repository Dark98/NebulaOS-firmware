# Virgin-Baseline Fix + Rebuild mission (2026-08-08): offline Klipper config validation for
# the REAL printer.cfg this build ships, not a hand-copied fixture dict - parses
# scripts/build/overlay/opt/printer_data/config/printer.cfg's actual [prtouch_v2]/
# [z_compensate] sections straight off disk and drives them through the real production
# PRTouchV2/ZCompensate __init__ exactly as fake.build_environment()'s other callers do
# (see prtouch_test_support.py). This is what proves the real, shipped file - not a
# fixture that could silently drift from it - parses cleanly.
#
# Direct regression coverage for the historical bug this mission fixes: printer.cfg's real
# bed_add_temp: 60 (Creality's own factory default, see artifacts/reference/stock-
# printer.cfg) was being rejected by an earlier, too-narrow bed_add_temp maxval=20 bound,
# halting Klipper entirely. z_compensate.py's current maxval=100 accepts it with headroom;
# this test fails loudly if that regresses.
#
# Run from the repo root: python3 -m unittest klippy_extras.test_printer_cfg_config_validation -v
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import configparser
import os
import unittest

from klippy_extras import prtouch_test_support as fake
from klippy_extras import prtouch_v2
from klippy_extras import z_compensate

PRINTER_CFG = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    'scripts', 'build', 'overlay', 'opt', 'printer_data', 'config', 'printer.cfg')


def _real_section(section):
    """Extracts one section's raw key/value pairs straight from the real, shipped
    printer.cfg - deliberately not configparser-ing the WHOLE file (Klipper's format has
    extensions, like the SAVE_CONFIG block's own markers, that a strict/interpolating
    parser can choke on elsewhere in the file; this mission only needs these two
    sections). interpolation=None because Klipper values may contain literal '%' (none in
    these two sections today, but no reason to risk it)."""
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    with open(PRINTER_CFG) as f:
        text = f.read()
    # Line-anchored - a bare substring search for "[section]" can false-match this exact
    # text appearing inside a prose comment elsewhere in the file (confirmed real: this
    # file's own header comment mentions "[prtouch_v2]" as prose before the real section).
    marker = '\n[%s]\n' % section
    start = text.index(marker) + 1  # +1 to keep the leading "["
    # Up to the next top-level "[" at column 0 after this section starts, or EOF.
    next_bracket = text.find('\n[', start + 1)
    chunk = text[start:next_bracket if next_bracket != -1 else len(text)]
    parser.read_string(chunk)
    return dict(parser[section])


class RealPrinterCfgValidationTest(unittest.TestCase):
    def test_prtouch_v2_section_parses_cleanly(self):
        values = _real_section('prtouch_v2')
        printer, mcu, pins, _ = fake.build_environment()
        config = fake.make_prtouch_v2_config(printer, pins, values)
        pv2 = prtouch_v2.PRTouchV2(config)
        printer.add_object('prtouch_v2', pv2)
        fake.connect(printer, mcu)
        config.assert_all_consumed()

    def test_z_compensate_section_parses_cleanly(self):
        prtouch_values = _real_section('prtouch_v2')
        printer, mcu, pins, _ = fake.build_environment(prtouch_v2_values=prtouch_values)
        prtouch_config = fake.make_prtouch_v2_config(printer, pins, prtouch_values)
        pv2 = prtouch_v2.PRTouchV2(prtouch_config)
        printer.add_object('prtouch_v2', pv2)

        zc_values = _real_section('z_compensate')
        zc_config = fake.make_z_compensate_config(printer, zc_values)
        zc = z_compensate.ZCompensate(zc_config)

        fake.connect(printer, mcu)
        prtouch_config.assert_all_consumed()
        zc_config.assert_all_consumed()

        # Direct regression check for the historical halt: bed_add_temp: 60 (Creality's
        # real factory value) must be accepted, not rejected, by config-time validation.
        self.assertEqual(zc.bed_add_temp, 60.0)

    def test_bl_offset_matches_real_bltouch_section(self):
        """bl_offset must match [bltouch]'s own x_offset/y_offset exactly - both read
        straight from the real file, not hardcoded twice."""
        bltouch = _real_section('bltouch')
        prtouch_values = _real_section('prtouch_v2')
        printer, mcu, pins, _ = fake.build_environment(prtouch_v2_values=prtouch_values)
        prtouch_config = fake.make_prtouch_v2_config(printer, pins, prtouch_values)
        pv2 = prtouch_v2.PRTouchV2(prtouch_config)
        printer.add_object('prtouch_v2', pv2)

        zc_values = _real_section('z_compensate')
        zc_config = fake.make_z_compensate_config(printer, zc_values)
        zc = z_compensate.ZCompensate(zc_config)
        fake.connect(printer, mcu)
        self.assertEqual(zc.bl_offset_x, float(bltouch['x_offset']))
        self.assertEqual(zc.bl_offset_y, float(bltouch['y_offset']))


if __name__ == '__main__':
    unittest.main()
