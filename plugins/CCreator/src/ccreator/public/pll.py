"""PLL — behavioral model, realistic loop filter, and comprehensive testbenches.

Testbenches:
    PLLLoopFilterTestbench  — AC sweep → loop filter bandwidth, phase margin, gain margin
    PLLLockTestbench        — Transient → lock time, frequency accuracy, settling
    PLLJitterTestbench      — Long transient → period jitter (rms, pp, c2c), duty cycle
    PLLPhaseNoiseTestbench  — Long transient → phase noise at offset frequencies
"""
from __future__ import annotations

import numpy as np
import sympy as sp

from ccreator import behavioral, realistic
from ccreator.core.decorators import testbench
from ccreator.core import Port
from ccreator.public._signal_analysis import (
    find_f3db, measure_phase_margin, measure_gain_margin, measure_ugf,
    measure_frequency, measure_periods, measure_period_jitter,
    measure_duty_cycle, measure_settling_time,
    find_zero_crossings, estimate_phase_noise,
)


# ---------------------------------------------------------------------------
# Behavioral model — closed-loop PLL transfer function
# ---------------------------------------------------------------------------

@behavioral.analog
class IdealPLL:
    """Ideal Type-II PLL: second-order closed-loop transfer function.

    H(s) = (2*zeta*wn*s + wn^2) / (s^2 + 2*zeta*wn*s + wn^2)

    Models the reference-to-output phase transfer function.
    wn = natural frequency, zeta = damping factor.
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {
        'f_out': 100e6,
        'f_ref': 1e6,
        'BW': 1e6,
        'zeta': 0.707,
    }

    def transfer_function(self, s):
        wn = 2 * sp.pi * self.BW
        z = self.zeta
        N = self.f_out / self.f_ref
        return N * (2 * z * wn * s + wn**2) / (s**2 + 2 * z * wn * s + wn**2)

    def equations(self, t, y, u):
        import math
        wn = 2 * math.pi * self.BW
        z = self.zeta
        N = self.f_out / self.f_ref
        # State: y[0] = output, y[1] = d(output)/dt
        dydt0 = y[1]
        dydt1 = -wn**2 * y[0] - 2 * z * wn * y[1] + wn**2 * N * u['in'] + 2 * z * wn * N * u['in']
        return [dydt0, dydt1]


# ---------------------------------------------------------------------------
# Realistic circuit — charge-pump PLL loop filter
# ---------------------------------------------------------------------------

@realistic.analog
class CPPLLLoopFilter:
    """Charge-pump PLL loop filter (second-order RC network).

    Topology: C1 in series with R1, with C2 in parallel.
    This is the standard type-II CP-PLL filter.

    Transfer impedance: Z(s) = (1 + s*R1*C1) / (s * (C1 + C2) * (1 + s*R1*C1*C2/(C1+C2)))
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {
        'R1': 10e3,
        'C1': 100e-12,
        'C2': 10e-12,
    }

    def build(self, n):
        # C1 in series with R1 from in to out
        n.R('R1', 'in', 'mid', self.R1)
        n.C('C1', 'mid', 'out', self.C1)
        # C2 from in to gnd (parallel path)
        n.C('C2', 'in', 'gnd', self.C2)
        # Tie output reference to gnd through high-impedance
        n.R('Rbias', 'out', 'gnd', 1e9)


@realistic.analog
class ThirdOrderLoopFilter:
    """Third-order PLL loop filter with additional RC pole.

    Adds extra R3-C3 stage for spur attenuation.
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {
        'R1': 10e3, 'C1': 100e-12,
        'C2': 10e-12,
        'R3': 1e3, 'C3': 10e-12,
    }

    def build(self, n):
        n.R('R1', 'in', 'n1', self.R1)
        n.C('C1', 'n1', 'n2', self.C1)
        n.C('C2', 'in', 'gnd', self.C2)
        n.R('R3', 'n2', 'out', self.R3)
        n.C('C3', 'out', 'gnd', self.C3)
        n.R('Rbias', 'n2', 'gnd', 1e9)


# ---------------------------------------------------------------------------
# Testbench: Loop filter AC characterization
# ---------------------------------------------------------------------------

@testbench
class PLLLoopFilterTestbench:
    """AC sweep of PLL loop filter impedance/transfer function.

    Extracts: bandwidth, phase margin, gain margin, zero/pole locations,
    DC impedance, unity-gain frequency.
    """
    parameters = {
        'dut': None,
        'fstart': 1,
        'fstop': 1e9,
        'points': 500,
    }

    def build(self, tb):
        if self.dut is None:
            dut = CPPLLLoopFilter()
        else:
            dut = self.dut
        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})
        tb.V('Vin', 'vin', '0', ac=1, dc=0)
        tb.probe('vout')

    def analysis(self, tb):
        tb.ac(variation='dec', points=self.points, fstart=self.fstart, fstop=self.fstop)

    def characterize(self, result):
        freqs = result.x
        mag_db = result.y.get('vout_magnitude_db', np.array([]))
        phase_deg = result.y.get('vout_phase_deg', np.array([]))
        if len(mag_db) == 0:
            return {}

        f3db = find_f3db(freqs, mag_db)
        ugf = measure_ugf(freqs, mag_db)

        specs = {
            'dc_gain_db': float(mag_db[0]),
            'f3db_hz': f3db,
            'ugf_hz': ugf,
        }

        if len(phase_deg) > 0:
            pm = measure_phase_margin(freqs, mag_db, phase_deg)
            gm = measure_gain_margin(freqs, mag_db, phase_deg)
            specs['phase_margin_deg'] = pm
            specs['gain_margin_db'] = gm
            specs['phase_at_dc_deg'] = float(phase_deg[0])

        # Attenuation at reference spur frequencies
        for f_check in [1e6, 10e6, 100e6]:
            if f_check <= freqs[-1]:
                idx = np.argmin(np.abs(freqs - f_check))
                specs[f'attenuation_at_{f_check/1e6:.0f}MHz_db'] = float(-mag_db[idx])

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        pm = specs.get('phase_margin_deg')
        if pm is not None:
            assert pm > 30, f"Phase margin {pm:.1f}° below 30°"


# ---------------------------------------------------------------------------
# Testbench: Lock time (transient)
# ---------------------------------------------------------------------------

@testbench
class PLLLockTestbench:
    """Transient test for PLL lock acquisition.

    Applies step input (reference frequency onset) and measures settling.
    Extracts: lock time, settling time, overshoot, final value accuracy.
    """
    parameters = {
        'dut': None,
        'v_step': 1.0,
        't_end': 100e-6,
        'step_time': 1e-9,
    }

    def build(self, tb):
        if self.dut is None:
            dut = CPPLLLoopFilter()
        else:
            dut = self.dut
        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})
        # Step input simulating charge pump current pulse
        tb.V('Vin', 'vin', '0', dc=0)
        tb._sources[-1]['pulse'] = {
            'initial': 0, 'pulsed': self.v_step,
            'delay': 1e-9, 'rise': 1e-12, 'fall': 1e-12,
            'width': self.t_end, 'period': self.t_end * 2,
        }
        tb.probe('vout')

    def analysis(self, tb):
        tb.tran(step=self.step_time, end=self.t_end)

    def characterize(self, result):
        t = result.x
        v_out = result.y.get('vout', np.array([]))
        if len(v_out) == 0:
            return {}

        final_val = v_out[-1]
        settling_1pct = measure_settling_time(t, v_out, final_val, tolerance=0.01)
        settling_01pct = measure_settling_time(t, v_out, final_val, tolerance=0.001)

        from ccreator.public._signal_analysis import measure_overshoot, measure_rise_time
        overshoot = measure_overshoot(t, v_out, final_val)
        rise = measure_rise_time(t, v_out)

        return {
            'final_value_v': float(final_val),
            'settling_1pct_s': float(settling_1pct),
            'settling_0.1pct_s': float(settling_01pct),
            'overshoot_pct': float(overshoot * 100),
            'rise_time_s': float(rise),
        }

    def assertions(self, result):
        specs = self.characterize(result)
        assert specs['settling_1pct_s'] < self.t_end, \
            f"Did not settle within {self.t_end*1e6:.0f}us"


# ---------------------------------------------------------------------------
# Testbench: Jitter (long transient)
# ---------------------------------------------------------------------------

@testbench
class PLLJitterTestbench:
    """Long transient for PLL output jitter characterization.

    Drives DUT with periodic signal and measures output timing.
    Extracts: period jitter (rms, pp), cycle-to-cycle jitter, duty cycle.
    """
    parameters = {
        'dut': None,
        'f_osc': 1e6,
        'n_cycles': 1000,
    }

    def build(self, tb):
        if self.dut is None:
            dut = CPPLLLoopFilter()
        else:
            dut = self.dut
        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})
        period = 1.0 / self.f_osc
        self._t_end = self.n_cycles * period
        self._step = period / 20
        # Square wave input
        tb.V('Vin', 'vin', '0', dc=0)
        tb._sources[-1]['pulse'] = {
            'initial': 0, 'pulsed': 1.0,
            'delay': 0, 'rise': period * 0.01, 'fall': period * 0.01,
            'width': period * 0.5, 'period': period,
        }
        tb.probe('vout')

    def analysis(self, tb):
        tb.tran(step=self._step, end=self._t_end)

    def characterize(self, result):
        t = result.x
        v_out = result.y.get('vout', np.array([]))
        if len(v_out) == 0:
            return {}

        periods = measure_periods(t, v_out)
        if len(periods) == 0:
            return {'note': 'No oscillation detected'}

        freq = measure_frequency(t, v_out)
        jitter = measure_period_jitter(periods)
        duty = measure_duty_cycle(t, v_out)

        return {
            'frequency_hz': float(freq),
            'mean_period_s': float(np.mean(periods)),
            'period_jitter_rms_s': jitter['rms'],
            'period_jitter_pp_s': jitter['peak_to_peak'],
            'cycle_to_cycle_jitter_rms_s': jitter['cycle_to_cycle_rms'],
            'duty_cycle': float(duty),
            'frequency_error_ppm': float((freq - self.f_osc) / self.f_osc * 1e6)
                if freq > 0 else 0.0,
        }

    def assertions(self, result):
        specs = self.characterize(result)
        if 'period_jitter_rms_s' in specs:
            mean_period = specs.get('mean_period_s', 1.0 / self.f_osc)
            jitter_pct = specs['period_jitter_rms_s'] / mean_period * 100
            assert jitter_pct < 10, f"Period jitter {jitter_pct:.2f}% exceeds 10%"


# ---------------------------------------------------------------------------
# Testbench: Phase noise (long transient → FFT of phase)
# ---------------------------------------------------------------------------

@testbench
class PLLPhaseNoiseTestbench:
    """Long transient for PLL phase noise estimation.

    Extracts: phase noise at standard offsets (1kHz, 10kHz, 100kHz, 1MHz).
    """
    parameters = {
        'dut': None,
        'f_osc': 1e6,
        'n_cycles': 2000,
        'offsets_hz': [1e3, 10e3, 100e3],
    }

    def build(self, tb):
        if self.dut is None:
            dut = CPPLLLoopFilter()
        else:
            dut = self.dut
        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})
        period = 1.0 / self.f_osc
        self._t_end = self.n_cycles * period
        self._step = period / 20
        tb.V('Vin', 'vin', '0', dc=0)
        tb._sources[-1]['pulse'] = {
            'initial': 0, 'pulsed': 1.0,
            'delay': 0, 'rise': period * 0.01, 'fall': period * 0.01,
            'width': period * 0.5, 'period': period,
        }
        tb.probe('vout')

    def analysis(self, tb):
        tb.tran(step=self._step, end=self._t_end)

    def characterize(self, result):
        t = result.x
        v_out = result.y.get('vout', np.array([]))
        if len(v_out) == 0:
            return {}

        pn = estimate_phase_noise(t, v_out, offsets_hz=self.offsets_hz)

        specs = {'frequency_hz': float(measure_frequency(t, v_out))}
        for offset, value in pn.items():
            label = f'phase_noise_at_{offset/1e3:.0f}kHz_dBcHz'
            specs[label] = value

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        # Phase noise assertions are design-specific; basic sanity check
        for key, val in specs.items():
            if 'phase_noise' in key and val is not None:
                assert val < 0, f"{key}={val:.1f} should be negative (dBc/Hz)"
