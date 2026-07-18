# prtouch_v2 MCU protocol - oid/config setup, raw command send, response buffering
#
# Rewrite of Creality's prtouch_v2_wrapper.py's MCU-facing half (GPLv3, see reference/), using the
# same standard Klipper host APIs hx711s.py already proves work on this exact device. See
# ../ANALYSIS.md secs 1-2 for the full wire protocol and ../DESIGN.md for the module layout this
# belongs to. Skeleton only - signatures and docstrings, no logic yet.
#
# This file may be distributed under the terms of the GNU GPLv3 license.

MAX_BUF_LEN = 32


class PrtouchMCU:
    def __init__(self, config, step_pins, pres_pins):
        # TODO: self.step_mcu/self.pres_mcu via config.get_printer().lookup_object('mcu ...')
        # TODO: self.step_oid, self.pres_oid = create_oid() x2
        # TODO: add_config_cmd() x4: config_step_prtouch, add_step_prtouch, config_pres_prtouch,
        #       add_pres_prtouch (ANALYSIS.md sec 1 config-commands table)
        # TODO: lookup_command() for the 8 runtime commands (same table, runtime-commands section)
        # TODO: register_response() for debug_prtouch, result_run_step_prtouch,
        #       result_run_pres_prtouch, result_read_pres_prtouch
        raise NotImplementedError

    def start_step(self, direction, step_cnt, step_us, acc_ctl_cnt, send_ms=5, auto_rtn=False):
        """start_step_prtouch - arm the MCU's step-pulse timer (own timer + sigmoid ramp,
        ANALYSIS.md sec 2 - not a Klipper trapq move). step_cnt=0 stops/idles."""
        raise NotImplementedError

    def start_pres(self, direction, acq_ms, send_ms, need_cnt, hftr_cut, lftr_k1,
                    min_hold, max_hold):
        """start_pres_prtouch - arm MCU-side sampling + trigger detection
        (check_pres_tri_prtouch runs on the MCU itself, not host-side)."""
        raise NotImplementedError

    def stop(self):
        """Send both start_step/start_pres with zeroed params - the idle/shutdown state."""
        raise NotImplementedError

    def deal_avgs(self, base_cnt=8):
        """deal_avgs_prtouch - tare/baseline the pressure channels before a probe cycle."""
        raise NotImplementedError

    def read_swap(self):
        """read_swap_prtouch -> bool. Used by the sync-pin self-test."""
        raise NotImplementedError

    def write_swap(self, state):
        """write_swap_prtouch(sta) - drives the sync line directly (self-test only)."""
        raise NotImplementedError

    def collect_step_samples(self, timeout_s):
        """Poll (10ms cadence) until MAX_BUF_LEN samples collected or timeout. Re-fetch any
        gaps via manual_get_steps (ck_and_manual_get_step-equivalent packet-loss repair).
        Returns [{'tick': float, 'step': int, 'index': int}, ...]; raises after repeated loss."""
        raise NotImplementedError

    def collect_pres_samples(self, timeout_s):
        """Same shape as collect_step_samples, manual_get_pres-equivalent repair. Returns
        [{'tick': float, 'ch0': int, 'ch1': int, 'ch2': int, 'ch3': int, 'index': int}, ...]."""
        raise NotImplementedError
