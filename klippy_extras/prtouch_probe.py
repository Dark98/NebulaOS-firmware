# prtouch_v2 touch-probe orchestration - send/poll/retry, delegates math to prtouch_calibration
#
# Rewrite of Creality's run_step_prtouch()/safe_move_z() (prtouch_v2_wrapper.py, GPLv3, see
# reference/), documented in full in ../ANALYSIS.md secs 3-4. Skeleton only - no logic yet.
#
# This file may be distributed under the terms of the GNU GPLv3 license.

from . import prtouch_calibration


class PrtouchProbe:
    def __init__(self, mcu, toolhead, bed_mesh, config):
        self.mcu = mcu
        self.toolhead = toolhead
        self.bed_mesh = bed_mesh
        # TODO: mm_per_step, tri_* tuning params from config (already live in printer.cfg's
        # [prtouch_v2] section - tri_min_hold/tri_max_hold/tri_z_down_spd/etc.)

    def touch_probe(self, down_min_z, tolerance, retries=3, consistent_needed=3):
        """run_step_prtouch-equivalent (ANALYSIS.md sec 3): send start_step+start_pres
        concurrently via self.mcu, poll both buffers via collect_step_samples/
        collect_pres_samples, call prtouch_calibration.compute_trigger_z(), retry with
        Z-zero self-correction on a no-trigger, average/median over `consistent_needed`
        agreeing samples within `tolerance`. Raises command_error after repeated failure -
        always lifts Z a safe distance first (ck_and_raise_error's safety courtesy)."""
        raise NotImplementedError

    def safe_move_z(self, direction, distance, speed):
        """Non-probing raw Z move via the same MCU step command - used for the pre-error
        safety lift and general manual moves outside a probe cycle."""
        raise NotImplementedError
