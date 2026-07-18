# z_compensate - per-print auto-Z-offset orchestration, host-side Klipper extra
#
# NEW code, not a port - Creality's real z_compensate_wrapper.so has no published source anywhere
# (confirmed via GitHub org-wide search, ANALYSIS.md sec 5). Design below is inferred from strong
# evidence (ANALYSIS.md sec 7): the real z_compensate_wrapper.so registers no MCU commands of its
# own, it does lookup_object('prtouch_v2') and calls straight into its primitives, and its
# bl_offset config value matches [bltouch]'s own y_offset exactly. Named/config-section-compatible
# with the existing [z_compensate] printer.cfg section on purpose - see ../DESIGN.md. Skeleton
# only - no logic yet, and the design itself is still open (see ../DESIGN.md "not decided yet").
#
# This file may be distributed under the terms of the GNU GPLv3 license.


class ZCompensate:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.gcode = self.printer.lookup_object('gcode')
        self.prtouch = None  # resolved via lookup_object('prtouch_v2') at connect time
        self.probe = None    # resolved via lookup_object('probe') (BLTouch) at connect time
        # TODO: read hot_start_temp/hot_rub_temp/hot_end_temp/bed_add_temp/clr_noz_*/bl_offset/
        # noz_pos_center/noz_pos_offset/pumpback_mm/vs_start_z_pos/pr_probe_cnt/
        # pr_clear_probe_cnt from config - already live in printer.cfg's [z_compensate] section
        self.gcode.register_command('CRTENSE_NOZZLE_CLEAR', self.cmd_nozzle_clear,
                                     desc=self.cmd_nozzle_clear_help)
        self.gcode.register_command('Z_OFFSET_CALIBRATION', self.cmd_z_offset_calibration,
                                     desc=self.cmd_z_offset_calibration_help)
        # Z_OFFSET_AUTO: registered by the real z_compensate_wrapper.so but never actually
        # called by any macro on this printer (ANALYSIS.md/DESIGN.md "not decided yet" #2) -
        # not registering for v1 unless something turns out to need it.

    cmd_nozzle_clear_help = "Wipe the nozzle before Z-offset calibration"

    def cmd_nozzle_clear(self, gcmd):
        """Reads HOT_START_TEMP/HOT_RUB_TEMP/BED_ADDTEMP params - matches the real call site
        in custom_macro.py's CX_PRINT_LEVELING_CALIBRATION exactly. Delegates to
        self.prtouch.clear_nozzle()."""
        raise NotImplementedError

    cmd_z_offset_calibration_help = "Auto-tune Z offset via the load-cell nozzle touch"

    def cmd_z_offset_calibration(self, gcmd):
        """NEW logic (design not final, see ../DESIGN.md): touch-probe at the point BLTouch
        already homed (current XY, adjusted by bl_offset) via self.prtouch.touch_probe(), diff
        the result against self.probe's current z_offset, apply the correction - almost
        certainly via 'Z_OFFSET_APPLY_PROBE' (stock Klipper, confirmed present in
        z_compensate_wrapper.so's strings)."""
        raise NotImplementedError


def load_config(config):
    return ZCompensate(config)
