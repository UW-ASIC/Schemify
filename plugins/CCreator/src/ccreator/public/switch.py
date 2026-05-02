"""Analog Switch — behavioral model, realistic circuits, and comprehensive testbenches.

Testbenches:
    SwitchRonTestbench        — DC sweep → on-resistance, Ron flatness
    SwitchIsolationTestbench  — AC sweep (off state) → off-isolation, off-capacitance
    SwitchBandwidthTestbench  — AC sweep (on state) → bandwidth, insertion loss
    SwitchTransientTestbench  — Transient → switching time, charge injection, settling
    SwitchDistortionTestbench — Transient + FFT → THD, linearity
"""
from __future__ import annotations

import numpy as np
import sympy as sp

from ccreator import behavioral, realistic
from ccreator.core.decorators import testbench
from ccreator.core import Port
from ccreator.public._signal_analysis import (
    find_f3db, compute_fft, find_fundamental, compute_thd,
    measure_settling_time, measure_rise_time, measure_fall_time,
    measure_charge_injection, measure_off_isolation,
    measure_ron, measure_ron_flatness,
)


# ---------------------------------------------------------------------------
# Behavioral model — ideal switch as controlled attenuator
# ---------------------------------------------------------------------------

@behavioral.analog
class IdealSwitch:
    """Ideal analog switch modeled as frequency-limited gain path.

    On-state: H(s) = wc / (s + wc)  (unity gain, bandwidth-limited)
    Models the on-resistance bandwidth limit: f3dB = 1/(2*pi*Ron*Cload)

    The behavioral model represents the SIGNAL PATH when switch is on.
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {
        'Ron': 10.0,
        'Cload': 10e-12,
        'BW': None,  # auto-computed from Ron*Cload if None
    }

    def transfer_function(self, s):
        if self.BW is not None:
            bw = self.BW
        else:
            bw = 1.0 / (2 * sp.pi * self.Ron * self.Cload)
        wc = 2 * sp.pi * bw
        return wc / (s + wc)

    def equations(self, t, y, u):
        import math
        if self.BW is not None:
            bw = self.BW
        else:
            bw = 1.0 / (2 * math.pi * self.Ron * self.Cload)
        wc = 2 * math.pi * bw
        return [-wc * y[0] + wc * u['in']]


# ---------------------------------------------------------------------------
# Realistic circuits
# ---------------------------------------------------------------------------

@realistic.analog
class ResistiveSwitch:
    """Switch modeled as series resistance with parasitic capacitance.

    On-state: Ron in series between in and out, Coff to ground.
    This models the signal path of a closed analog switch.
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {
        'Ron': 10.0,
        'Coff': 1e-12,
        'Cload': 10e-12,
    }

    def build(self, n):
        n.R('Ron', 'in', 'out', self.Ron)
        n.C('Cpar', 'in', 'gnd', self.Coff)
        n.C('Cload', 'out', 'gnd', self.Cload)


@realistic.analog
class ResistiveSwitchOff:
    """Switch in OFF state — high resistance with parasitic coupling.

    Models the off-state isolation path.
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {
        'Roff': 1e9,
        'Coff': 1e-12,
        'Cload': 10e-12,
    }

    def build(self, n):
        n.R('Roff', 'in', 'out', self.Roff)
        n.C('Coff', 'in', 'out', self.Coff)
        n.C('Cload', 'out', 'gnd', self.Cload)


@realistic.analog
class TransmissionGate:
    """CMOS transmission gate approximation using parallel RC paths.

    Models the complementary NMOS/PMOS switch with Ron varying by signal level.
    Uses two parallel RC branches for N and P paths.
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {
        'Ron_n': 100.0,
        'Ron_p': 150.0,
        'Cg_n': 0.5e-12,
        'Cg_p': 0.5e-12,
        'Cload': 10e-12,
    }

    def build(self, n):
        # NMOS path
        n.R('Rn', 'in', 'out', self.Ron_n)
        n.C('Cgn', 'in', 'gnd', self.Cg_n)
        # PMOS path (parallel)
        n.R('Rp', 'in', 'out', self.Ron_p)
        n.C('Cgp', 'in', 'gnd', self.Cg_p)
        # Load
        n.C('Cload', 'out', 'gnd', self.Cload)


# ---------------------------------------------------------------------------
# Testbench: On-resistance (DC sweep)
# ---------------------------------------------------------------------------

@testbench
class SwitchRonTestbench:
    """DC sweep for on-resistance characterization.

    Sweeps input voltage and measures output through a known load.
    Extracts: Ron, Ron flatness, Ron vs signal voltage.
    """
    parameters = {
        'dut': None,
        'v_start': -1.0,
        'v_stop': 1.0,
        'v_step': 0.01,
        'R_load': 10e3,
    }

    def build(self, tb):
        if self.dut is None:
            dut = ResistiveSwitch()
        else:
            dut = self.dut
        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vmid', 'gnd': '0'})
        tb.V('Vin', 'vin', '0', dc=self.v_start)
        # Load resistor forms voltage divider with switch Ron
        from ccreator import realistic
        from ccreator.core import Port

        @realistic.analog
        class _RonLoad:
            ports = [Port('in', 'input', 'voltage'), Port('out', 'output', 'voltage'),
                     Port('gnd', 'inout', 'voltage')]
            parameters = {'R': self.R_load}
            def build(self_inner, n):
                n.R('Rload', 'in', 'out', self_inner.R)
        load = _RonLoad(R=self.R_load)
        tb.instance(load, name='LOAD',
                    connections={'in': 'vmid', 'out': '0', 'gnd': '0'})
        tb.probe('vmid')

    def analysis(self, tb):
        tb.dc(source='Vin', start=self.v_start, stop=self.v_stop, step=self.v_step)

    def characterize(self, result):
        v_in = result.x
        v_out = result.y.get('vmid', np.array([]))
        if len(v_out) == 0:
            return {}

        # Ron from voltage divider: Vout = Vin * Rload / (Ron + Rload)
        # gain = Rload / (Ron + Rload) → Ron = Rload * (1/gain - 1)
        coeffs = np.polyfit(v_in, v_out, 1)
        gain = coeffs[0]
        if gain > 0 and gain < 1:
            ron_from_gain = self.R_load * (1.0 / gain - 1.0)
        else:
            ron_from_gain = None

        # Point-by-point Ron: (Vin - Vout) / (Vout / Rload)
        i_load = v_out / self.R_load
        v_drop = v_in - v_out
        valid = np.abs(i_load) > 1e-15
        if not np.any(valid):
            return {'ron_ohm': float('inf'), 'note': 'No measurable current'}

        ron_local = np.abs(v_drop[valid] / i_load[valid])
        flatness = measure_ron_flatness(v_drop[valid], i_load[valid])

        specs = {
            'ron_ohm': float(ron_from_gain) if ron_from_gain is not None else float(np.mean(ron_local)),
            'ron_min_ohm': float(np.min(ron_local)),
            'ron_max_ohm': float(np.max(ron_local)),
            'ron_mean_ohm': float(np.mean(ron_local)),
            'ron_flatness_pct': flatness['spread_pct'],
            'dc_gain': float(gain),
            'insertion_loss_db': float(-20 * np.log10(abs(gain))) if abs(gain) > 1e-10 else float('inf'),
        }

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        ron = specs.get('ron_ohm', float('inf'))
        assert ron < 1e6, f"Ron={ron:.0f}Ω too high"


# ---------------------------------------------------------------------------
# Testbench: Off-state isolation (AC sweep)
# ---------------------------------------------------------------------------

@testbench
class SwitchIsolationTestbench:
    """AC sweep in off-state for isolation characterization.

    Extracts: off-isolation at various frequencies, off-capacitance estimate.
    """
    parameters = {
        'dut': None,
        'fstart': 1e3,
        'fstop': 1e9,
        'points': 300,
    }

    def build(self, tb):
        if self.dut is None:
            dut = ResistiveSwitchOff()
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
        if len(mag_db) == 0:
            return {}

        specs = {
            'worst_case_isolation_db': float(-np.max(mag_db)),
        }

        for f_check in [1e3, 10e3, 100e3, 1e6, 10e6, 100e6, 1e9]:
            if self.fstart <= f_check <= self.fstop:
                isolation = measure_off_isolation(freqs, mag_db, f_check)
                specs[f'isolation_at_{f_check:.0f}Hz_db'] = float(isolation)

        # Estimate Coff from high-frequency slope
        # At high freq, isolation ≈ 20*log10(1/(2*pi*f*Coff*Rload))
        # Slope of +20dB/decade → capacitive coupling
        hf_mask = freqs > freqs[-1] / 10
        if np.sum(hf_mask) > 2:
            hf_freqs = freqs[hf_mask]
            hf_mag = mag_db[hf_mask]
            # mag_db ≈ 20*log10(2*pi*f*Coff) for capacitive feedthrough
            # Linear fit in log-frequency domain
            log_f = np.log10(hf_freqs)
            coeffs = np.polyfit(log_f, hf_mag, 1)
            slope = coeffs[0]  # should be ~+20 for capacitive
            specs['hf_slope_db_per_decade'] = float(slope)
            # Rough Coff estimate at a known frequency
            mid_idx = len(hf_freqs) // 2
            mid_f = hf_freqs[mid_idx]
            mid_mag_lin = 10 ** (hf_mag[mid_idx] / 20.0)
            coff_est = mid_mag_lin / (2 * np.pi * mid_f)
            if coff_est > 0:
                specs['estimated_coff_f'] = float(coff_est)

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        iso = specs.get('worst_case_isolation_db', 0)
        assert iso > 20, f"Worst-case isolation {iso:.1f}dB below 20dB"


# ---------------------------------------------------------------------------
# Testbench: On-state bandwidth (AC sweep)
# ---------------------------------------------------------------------------

@testbench
class SwitchBandwidthTestbench:
    """AC sweep in on-state for signal bandwidth characterization.

    Extracts: -3dB bandwidth, insertion loss, passband flatness.
    """
    parameters = {
        'dut': None,
        'fstart': 100,
        'fstop': 10e9,
        'points': 300,
    }

    def build(self, tb):
        if self.dut is None:
            dut = ResistiveSwitch()
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
        dc_gain_db = float(mag_db[0])

        # Passband flatness
        if f3db is not None:
            pb_mask = freqs <= f3db
        else:
            pb_mask = np.ones(len(freqs), dtype=bool)
        pb_mag = mag_db[pb_mask]
        ripple = float(np.max(pb_mag) - np.min(pb_mag)) if len(pb_mag) > 1 else 0.0

        specs = {
            'dc_gain_db': dc_gain_db,
            'insertion_loss_db': float(-dc_gain_db),
            'f3db_hz': f3db,
            'passband_ripple_db': ripple,
        }

        # Insertion loss at specific frequencies
        for f_check in [1e6, 10e6, 100e6, 1e9]:
            if self.fstart <= f_check <= self.fstop:
                idx = np.argmin(np.abs(freqs - f_check))
                specs[f'insertion_loss_at_{f_check:.0f}Hz_db'] = float(-mag_db[idx])

        if len(phase_deg) > 0:
            specs['phase_at_dc_deg'] = float(phase_deg[0])

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        il = specs.get('insertion_loss_db', float('inf'))
        assert il < 6, f"Insertion loss {il:.1f}dB exceeds 6dB"


# ---------------------------------------------------------------------------
# Testbench: Transient (switching time, charge injection)
# ---------------------------------------------------------------------------

@testbench
class SwitchTransientTestbench:
    """Transient test for switching dynamics.

    Applies step and measures output response.
    Extracts: rise time, fall time, settling time, overshoot.
    """
    parameters = {
        'dut': None,
        'v_step': 1.0,
        't_end': 1e-6,
        'step_time': 1e-12,
    }

    def build(self, tb):
        if self.dut is None:
            dut = ResistiveSwitch()
        else:
            dut = self.dut
        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})
        tb.V('Vin', 'vin', '0', dc=0)
        tb._sources[-1]['pulse'] = {
            'initial': 0, 'pulsed': self.v_step,
            'delay': self.t_end * 0.1,
            'rise': 1e-12, 'fall': 1e-12,
            'width': self.t_end * 0.4, 'period': self.t_end,
        }
        tb.probe('vout')

    def analysis(self, tb):
        tb.tran(step=self.step_time, end=self.t_end)

    def characterize(self, result):
        t = result.x
        v_out = result.y.get('vout', np.array([]))
        if len(v_out) == 0:
            return {}

        rise = measure_rise_time(t, v_out)
        fall = measure_fall_time(t, v_out)

        from ccreator.public._signal_analysis import measure_overshoot
        final = v_out[len(v_out) // 2]  # mid-point should be settled high
        settling = measure_settling_time(t[:len(t)//2], v_out[:len(t)//2], final, tolerance=0.01)
        overshoot = measure_overshoot(t[:len(t)//2], v_out[:len(t)//2], final)

        specs = {
            'rise_time_s': float(rise),
            'fall_time_s': float(fall),
            'settling_time_1pct_s': float(settling),
            'overshoot_pct': float(overshoot * 100),
            'propagation_delay_s': float(rise / 2),  # approximate
        }

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        assert specs['rise_time_s'] < self.t_end, "Rise time exceeds test window"


# ---------------------------------------------------------------------------
# Testbench: Distortion (transient + FFT)
# ---------------------------------------------------------------------------

@testbench
class SwitchDistortionTestbench:
    """Transient + FFT for switch signal distortion.

    Passes sine wave through on-state switch, measures output THD.
    Extracts: THD, SFDR, signal bandwidth degradation.
    """
    parameters = {
        'dut': None,
        'fin': 1e6,
        'amplitude': 0.5,
        'dc_bias': 0.0,
        'n_cycles': 64,
    }

    def build(self, tb):
        if self.dut is None:
            dut = ResistiveSwitch()
        else:
            dut = self.dut
        period = 1.0 / self.fin
        self._t_end = self.n_cycles * period
        self._step = period / 20

        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})
        tb.V('Vin', 'vin', '0', dc=self.dc_bias)
        tb._sources[-1]['sin'] = {
            'offset': self.dc_bias,
            'amplitude': self.amplitude,
            'frequency': self.fin,
        }
        tb.probe('vout')

    def analysis(self, tb):
        tb.tran(step=self._step, end=self._t_end)

    def characterize(self, result):
        t = result.x
        v_out = result.y.get('vout', np.array([]))
        if len(v_out) == 0:
            return {}

        skip = len(t) // 10
        t_ss, v_ss = t[skip:], v_out[skip:]

        freqs, mag_dbfs = compute_fft(t_ss, v_ss, window='blackmanharris')
        f0, f0_power = find_fundamental(freqs, mag_dbfs, fmin=self.fin * 0.5)
        thd = compute_thd(freqs, mag_dbfs, f0)

        from ccreator.public._signal_analysis import compute_sfdr, compute_sndr
        sfdr = compute_sfdr(freqs, mag_dbfs, f0)
        sndr = compute_sndr(freqs, mag_dbfs, f0)

        specs = {
            'fundamental_hz': float(f0),
            'fundamental_dbfs': float(f0_power),
            'thd_db': float(thd),
            'sfdr_dbc': float(sfdr),
            'sndr_db': float(sndr),
            'output_amplitude_vpp': float(np.max(v_ss) - np.min(v_ss)),
            'amplitude_attenuation_db': float(
                20 * np.log10((np.max(v_ss) - np.min(v_ss)) / (2 * self.amplitude))
            ) if self.amplitude > 0 else 0.0,
        }

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        thd = specs.get('thd_db', 0)
        assert thd < -20, f"THD={thd:.1f}dB exceeds -20dB"
