# prtouch_v2 - load-cell/pressure-probe touch detection, host-side Klipper extra
#
# Drop-in rewrite of Creality's compiled prtouch_v2_wrapper.so, using entirely standard Klipper
# host APIs (the same pattern hx711s.py/dirzctl.py already prove work on this exact device).
# Named/config-section-compatible with the existing [prtouch_v2] printer.cfg section on purpose -
# see ../DESIGN.md's "one real design decision" section. See ../ANALYSIS.md for the full protocol
# and algorithm this replaces. Skeleton only - no logic yet.
#
# This file may be distributed under the terms of the GNU GPLv3 license.

from . import prtouch_mcu
from . import prtouch_probe
from . import prtouch_nozzle


class PRTouchV2:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.gcode = self.printer.lookup_object('gcode')
        # TODO: build PrtouchMCU from config (pins, tri_* tuning params - already live in
        # printer.cfg's [prtouch_v2] section, same names as the original)
        # TODO: build PrtouchProbe(mcu, toolhead, bed_mesh, config) - toolhead/bed_mesh looked
        # up lazily at connect time (printer objects aren't ready during __init__)
        # TODO: register the gcode commands actually load-bearing in real production
        # (ANALYSIS.md sec 7/8) - NOZZLE_CLEAR, SAFE_MOVE_Z, PRTOUCH_READY at minimum. The
        # diagnostic set (TEST_PRTH, TRIG_TEST, TRIG_BED_TEST, READ_PRES, DEAL_AVGS, TEST_SWAP)
        # is optional for v1 - cheap and useful for bring-up, not blocking.
        # Deliberately NOT porting: run_G28_Z/run_G29_Z/bed_mesh_post_proc/run_re_g29s/
        # correct_bed_mesh_data and CHECK_BED_MESH/ACCURATE_HOME_Z - confirmed dead code in
        # real production, BLTouch owns homing/bed-mesh (ANALYSIS.md sec 7).
        raise NotImplementedError

    def touch_probe(self, down_min_z, tolerance, **kwargs):
        """Public API for z_compensate.py (and anything else) to call into - thin passthrough
        to self.probe.touch_probe()."""
        raise NotImplementedError

    def clear_nozzle(self, hot_min_temp, hot_max_temp, bed_max_temp):
        """Public API passthrough to prtouch_nozzle.clear_nozzle()."""
        raise NotImplementedError


def load_config(config):
    return PRTouchV2(config)
