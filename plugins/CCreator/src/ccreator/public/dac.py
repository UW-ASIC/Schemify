"""DAC — behavioral model, realistic filter, and comprehensive testbenches.

Testbenches:
    DACStaticTestbench    — DC code ramp → DNL, INL, offset, gain error, monotonicity
    DACDynamicTestbench   — Single-tone transient → SFDR, THD, SNR, glitch, settling
    DACFilterTestbench    — AC sweep → reconstruction filter bandwidth, rolloff
"""
from __future__ import annotations

import numpy as np
import sympy as sp

from ccreator import behavioral, realistic
from ccreator.core.decorators import testbench
from ccreator.core import Port
from ccreator.public._signal_analysis import (
    compute_fft, find_fundamental, compute_thd, compute_sfdr,
    compute_snr, compute_sndr, compute_enob,
    find_f3db, measure_settling_time, measure_slew_rate,
    measure_glitch_energy, measure_overshoot,
    compute_dnl, compute_inl, check_monotonicity, extract_code_widths,
)


# ---------------------------------------------------------------------------
# Behavioral model
# ---------------------------------------------------------------------------

@behavioral.analog
class IdealDAC:
    """Ideal N-bit DAC: gain stage with reconstruction filter.

    Linearized model: H(s) = Gain * wc / (s + wc)
    Gain = Vref / (2^N - 1)
    wc = pi * fs (reconstruction filter bandwidth)
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {
        'N': 10,
        'Vref': 1.2,
        'fs': 1e6,
    }

    def transfer_function(self, s):
        gain = self.Vref / (2**self.N - 1)
        wc = sp.pi * self.fs
        return gain * wc / (s + wc)

    def equations(self, t, y, u):
        import math
        gain = self.Vref / (2**self.N - 1)
        wc = math.pi * self.fs
        return [-wc * y[0] + wc * gain * u['in']]


# ---------------------------------------------------------------------------
# Realistic circuits
# ---------------------------------------------------------------------------

@realistic.analog
class RCReconstructionFilter:
    """First-order RC reconstruction filter for DAC output.

    f3dB = 1 / (2*pi*R*C)
    Default: R=1k, C=159pF → f3dB ≈ 1 MHz
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {'R': 1e3, 'C': 159e-12}

    def build(self, n):
        n.R('R1', 'in', 'out', self.R)
        n.C('C1', 'out', 'gnd', self.C)


@realistic.analog
class SecondOrderReconstructionFilter:
    """Second-order Sallen-Key style reconstruction filter (passive approx).

    Two cascaded RC stages for steeper rolloff.
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {'R1': 1e3, 'C1': 159e-12, 'R2': 1e3, 'C2': 159e-12}

    def build(self, n):
        n.R('R1', 'in', 'mid', self.R1)
        n.C('C1', 'mid', 'gnd', self.C1)
        n.R('R2', 'mid', 'out', self.R2)
        n.C('C2', 'out', 'gnd', self.C2)


# ---------------------------------------------------------------------------
# Testbench: Static (DC ramp)
# ---------------------------------------------------------------------------

@testbench
class DACStaticTestbench:
    """DC ramp for DAC transfer function linearity.

    Sweeps input voltage (representing code sweep) and measures output.
    Extracts: DC gain, offset, gain error, linearity.
    """
    parameters = {
        'dut': None,
        'v_start': 0.0,
        'v_stop': 1.2,
        'v_step': 0.001,
        'ideal_gain': 1.0,
    }

    def build(self, tb):
        if self.dut is None:
            dut = RCReconstructionFilter()
            self.ideal_gain = 1.0  # passthrough at DC
        else:
            dut = self.dut
        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})
        tb.V('Vin', 'vin', '0', dc=self.v_start)
        tb.probe('vout')

    def analysis(self, tb):
        tb.dc(source='Vin', start=self.v_start, stop=self.v_stop, step=self.v_step)

    def characterize(self, result):
        v_in = result.x
        v_out = result.y.get('vout', np.array([]))
        if len(v_out) == 0:
            return {}

        coeffs = np.polyfit(v_in, v_out, 1)
        actual_gain = coeffs[0]
        offset = coeffs[1]
        fit = np.polyval(coeffs, v_in)
        linearity_error = v_out - fit

        specs = {
            'dc_gain': float(actual_gain),
            'offset_v': float(offset),
            'gain_error_pct': float((actual_gain - self.ideal_gain) / self.ideal_gain * 100)
                if self.ideal_gain != 0 else 0.0,
            'max_linearity_error_v': float(np.max(np.abs(linearity_error))),
            'rms_linearity_error_v': float(np.sqrt(np.mean(linearity_error**2))),
        }

        # Quantized output detection
        dv = np.diff(v_out)
        unique_steps = np.unique(np.round(dv, decimals=6))
        if len(unique_steps) < len(v_out) / 4:
            codes = np.round(v_out / np.median(dv[dv > 0])).astype(int) if np.any(dv > 0) else v_out.astype(int)
            widths = extract_code_widths(v_in, codes)
            if len(widths) > 1:
                dnl = compute_dnl(widths)
                inl = compute_inl(dnl)
                specs['dnl_max_lsb'] = float(np.max(np.abs(dnl)))
                specs['inl_max_lsb'] = float(np.max(np.abs(inl)))
                specs['monotonic'] = check_monotonicity(codes)

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        assert abs(specs.get('gain_error_pct', 0)) < 5, \
            f"Gain error {specs['gain_error_pct']:.2f}% exceeds 5%"


# ---------------------------------------------------------------------------
# Testbench: Dynamic (transient)
# ---------------------------------------------------------------------------

@testbench
class DACDynamicTestbench:
    """Single-tone transient for DAC dynamic performance.

    Applies sine wave through reconstruction filter, measures output.
    Extracts: SNDR, SFDR, THD, SNR, ENOB, settling time, slew rate, glitch.
    """
    parameters = {
        'dut': None,
        'fin': 100e3,
        'amplitude': 0.5,
        'dc_bias': 0.6,
        'n_cycles': 64,
        'oversample': 20,
    }

    def build(self, tb):
        if self.dut is None:
            dut = RCReconstructionFilter()
        else:
            dut = self.dut
        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})
        period = 1.0 / self.fin
        self._t_end = self.n_cycles * period
        self._step = period / self.oversample
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

        # Skip settling
        skip = len(t) // 10
        t_ss, v_ss = t[skip:], v_out[skip:]

        freqs, mag_dbfs = compute_fft(t_ss, v_ss, window='blackmanharris')
        f0, f0_power = find_fundamental(freqs, mag_dbfs, fmin=self.fin * 0.5)

        sndr = compute_sndr(freqs, mag_dbfs, f0)
        sfdr = compute_sfdr(freqs, mag_dbfs, f0)
        thd = compute_thd(freqs, mag_dbfs, f0)
        snr = compute_snr(freqs, mag_dbfs, f0)
        enob = compute_enob(sndr)
        slew = measure_slew_rate(t_ss, v_ss)

        specs = {
            'fundamental_hz': float(f0),
            'fundamental_dbfs': float(f0_power),
            'sndr_db': float(sndr),
            'sfdr_dbc': float(sfdr),
            'thd_db': float(thd),
            'snr_db': float(snr),
            'enob': float(enob),
            'slew_rate_v_per_s': float(slew),
            'output_amplitude_vpp': float(np.max(v_ss) - np.min(v_ss)),
        }

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        if 'thd_db' in specs:
            assert specs['thd_db'] < -20, f"THD={specs['thd_db']:.1f}dB exceeds -20dB"


# ---------------------------------------------------------------------------
# Testbench: Filter / bandwidth (AC sweep)
# ---------------------------------------------------------------------------

@testbench
class DACFilterTestbench:
    """AC sweep for DAC reconstruction filter characterization.

    Extracts: f3dB, DC gain, passband ripple, rolloff rate, phase response.
    """
    parameters = {
        'dut': None,
        'fstart': 100,
        'fstop': 100e6,
        'points': 200,
    }

    def build(self, tb):
        if self.dut is None:
            dut = RCReconstructionFilter()
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

        # Passband ripple
        if f3db is not None:
            pb_mask = freqs <= f3db
        else:
            pb_mask = np.ones(len(freqs), dtype=bool)
        pb_mag = mag_db[pb_mask]
        ripple = float(np.max(pb_mag) - np.min(pb_mag)) if len(pb_mag) > 1 else 0.0

        # Rolloff
        rolloff = None
        if f3db is not None:
            above = freqs > f3db
            if np.sum(above) > 1:
                f_ab = freqs[above]
                m_ab = mag_db[above]
                decades = np.log10(f_ab[-1] / f_ab[0]) if f_ab[0] > 0 else 0
                if decades > 0:
                    rolloff = float((m_ab[-1] - m_ab[0]) / decades)

        # Stopband attenuation at Nyquist multiples
        specs = {
            'dc_gain_db': dc_gain_db,
            'f3db_hz': f3db,
            'passband_ripple_db': ripple,
            'rolloff_db_per_decade': rolloff,
        }

        if len(phase_deg) > 0:
            specs['phase_at_dc_deg'] = float(phase_deg[0])
            if f3db is not None:
                idx = np.argmin(np.abs(freqs - f3db))
                specs['phase_at_f3db_deg'] = float(phase_deg[idx])

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        if specs.get('f3db_hz') is not None:
            assert specs['passband_ripple_db'] < 3.0, \
                f"Passband ripple {specs['passband_ripple_db']:.2f}dB exceeds 3dB"
