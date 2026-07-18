# prtouch_v2 nozzle-wipe routine
#
# Rewrite of Creality's clear_nozzle() (prtouch_v2_wrapper.py, GPLv3, see reference/),
# documented in ../ANALYSIS.md sec 4. Skeleton only - no logic yet.
#
# This file may be distributed under the terms of the GNU GPLv3 license.


def clear_nozzle(probe, toolhead, heaters, config, hot_min_temp, hot_max_temp, bed_max_temp):
    """clear_nozzle()-equivalent: heat bed/nozzle, probe two randomized XY points on the wipe
    pad via probe.touch_probe() to find local Z at each, drag the nozzle between them at wipe
    temp, cool down. Config-driven - clr_noz_start_x/y, clr_noz_len_x/y, pa_clr_dis_mm_x/y are
    already live in printer.cfg's [z_compensate] section, same parameter names."""
    raise NotImplementedError
