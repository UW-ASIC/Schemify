"""ADC — behavioral model, realistic front-end, and comprehensive testbenches.

Testbenches:
    ADCStaticTestbench    — DC ramp sweep → DNL, INL, offset, gain error, monotonicity
    ADCDynamicTestbench   — Single-tone transient → SNDR, SFDR, ENOB, THD, SNR
    ADCBandwidthTestbench — AC sweep → signal bandwidth, gain flatness, rolloff
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
    compute_dnl, compute_inl, measure_offset_error, measure_gain_error,
    check_monotonicity, extract_code_widths,
)


# ---------------------------------------------------------------------------
# Behavioral model
# ---------------------------------------------------------------------------

@behavioral.analog
class IdealADC:
    """Ideal N-bit ADC: gain stage with Nyquist bandwidth limit.

    Linearized model: H(s) = Gain * wc / (s + wc)
    Gain = (2^N - 1) / Vref
    wc = pi * fs (Nyquist bandwidth)
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
        gain = (2**self.N - 1) / self.Vref
        wc = sp.pi * self.fs
        return gain * wc / (s + wc)

    def equations(self, t, y, u):
        import math
        gain = (2**self.N - 1) / self.Vref
        wc = math.pi * self.fs
        return [-wc * y[0] + wc * gain * u['in']]


# ---------------------------------------------------------------------------
# Realistic circuit — resistive attenuator front-end
# ---------------------------------------------------------------------------

@realistic.analog
class ResistiveADCFrontend:
    """Resistive attenuator for ADC input conditioning.

    Vout = Vin * R_fb / (R_in + R_fb)
    Default: gain ~ 0.91 (10k / (1k + 10k))
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {'R_in': 1e3, 'R_fb': 10e3}

    def build(self, n):
        n.R('Rin', 'in', 'out', self.R_in)
        n.R('Rfb', 'out', 'gnd', self.R_fb)


@realistic.analog
class RCADCFrontend:
    """RC anti-aliasing filter for ADC input.

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


# ---------------------------------------------------------------------------
# Testbench: Static (DC ramp)
# ---------------------------------------------------------------------------

@testbench
class ADCStaticTestbench:
    """DC ramp sweep for ADC linearity characterization.

    Extracts: DC gain, offset, gain error, linearity error.
    For quantized outputs: DNL, INL, monotonicity.

    Accepts any circuit with ports (in, out, gnd).
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
            dut = RCADCFrontend()
            self.ideal_gain = 1.0  # RC filter has unity DC gain
        else:
            dut = self.dut
        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})
        tb.V('Vin', 'vin', '0', dc=self.v_start)
        tb.probe('vout')

    def analysis(self, tb):
        tb.dc(source='Vin', start=self.v_start, stop=self.v_stop, step=self.v_step)

    def characterize(self, result):
        """Extract static linearity metrics from DC sweep result."""
        v_in = result.x
        v_out = result.y.get('vout', np.array([]))
        if len(v_out) == 0:
            return {}

        # Best-fit line
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

        # Check if output looks quantized (step detection)
        dv = np.diff(v_out)
        unique_steps = np.unique(np.round(dv, decimals=6))
        if len(unique_steps) < len(v_out) / 4:  # likely quantized
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
# Testbench: Dynamic (single-tone transient → FFT)
# ---------------------------------------------------------------------------

@testbench
class ADCDynamicTestbench:
    """Single-tone transient for ADC dynamic performance.

    Applies sine wave at fin, captures n_cycles, runs FFT.
    Extracts: SNDR, SFDR, ENOB, THD, SNR.
    """
    parameters = {
        'dut': None,
        'fin': 100e3,
        'fs': 1e6,
        'amplitude': 0.5,
        'dc_bias': 0.6,
        'n_cycles': 64,
    }

    def build(self, tb):
        if self.dut is None:
            dut = RCADCFrontend()
        else:
            dut = self.dut
        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})
        period = 1.0 / self.fin
        t_end = self.n_cycles * period
        step = 1.0 / (self.fs * 4)  # oversample 4x
        # SPICE SIN source: SIN(Voff Vamp Freq)
        tb.V('Vin', 'vin', '0', dc=self.dc_bias)
        tb._sources[-1]['sin'] = {
            'offset': self.dc_bias,
            'amplitude': self.amplitude,
            'frequency': self.fin,
        }
        tb.probe('vout')
        self._t_end = t_end
        self._step = step

    def analysis(self, tb):
        tb.tran(step=self._step, end=self._t_end)

    def characterize(self, result):
        """Extract dynamic specs via FFT from transient result."""
        t = result.x
        v_out = result.y.get('vout', np.array([]))
        if len(v_out) == 0:
            return {}

        # Skip initial settling (first 10% of data)
        skip = len(t) // 10
        t_ss = t[skip:]
        v_ss = v_out[skip:]

        freqs, mag_dbfs = compute_fft(t_ss, v_ss, window='blackmanharris')
        f0, f0_power = find_fundamental(freqs, mag_dbfs, fmin=self.fin * 0.5)

        sndr = compute_sndr(freqs, mag_dbfs, f0)
        sfdr = compute_sfdr(freqs, mag_dbfs, f0)
        thd = compute_thd(freqs, mag_dbfs, f0)
        snr = compute_snr(freqs, mag_dbfs, f0)
        enob = compute_enob(sndr)

        return {
            'fundamental_hz': float(f0),
            'fundamental_dbfs': float(f0_power),
            'sndr_db': float(sndr),
            'sfdr_dbc': float(sfdr),
            'thd_db': float(thd),
            'snr_db': float(snr),
            'enob': float(enob),
            'output_amplitude_vpp': float(np.max(v_ss) - np.min(v_ss)),
        }

    def assertions(self, result):
        specs = self.characterize(result)
        if 'thd_db' in specs:
            assert specs['thd_db'] < -20, f"THD={specs['thd_db']:.1f}dB exceeds -20dB"


# ---------------------------------------------------------------------------
# Testbench: Bandwidth (AC sweep)
# ---------------------------------------------------------------------------

@testbench
class ADCBandwidthTestbench:
    """AC sweep for ADC signal bandwidth characterization.

    Extracts: f3dB, DC gain, gain flatness, passband ripple.
    """
    parameters = {
        'dut': None,
        'fstart': 100,
        'fstop': 100e6,
        'points': 200,
    }

    def build(self, tb):
        if self.dut is None:
            dut = RCADCFrontend()
        else:
            dut = self.dut
        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})
        tb.V('Vin', 'vin', '0', ac=1, dc=0.6)
        tb.probe('vout')

    def analysis(self, tb):
        tb.ac(variation='dec', points=self.points, fstart=self.fstart, fstop=self.fstop)

    def characterize(self, result):
        """Extract bandwidth specs from AC result."""
        freqs = result.x
        mag_key = 'vout_magnitude_db'
        phase_key = 'vout_phase_deg'
        mag_db = result.y.get(mag_key, np.array([]))
        phase_deg = result.y.get(phase_key, np.array([]))
        if len(mag_db) == 0:
            return {}

        f3db = find_f3db(freqs, mag_db)
        dc_gain_db = float(mag_db[0])

        # Passband ripple (deviation from DC gain up to f3dB or end)
        if f3db is not None:
            pb_mask = freqs <= f3db
        else:
            pb_mask = np.ones(len(freqs), dtype=bool)
        pb_mag = mag_db[pb_mask]
        ripple = float(np.max(pb_mag) - np.min(pb_mag)) if len(pb_mag) > 1 else 0.0

        # Rolloff rate (dB/decade after f3dB)
        rolloff = None
        if f3db is not None:
            above = freqs > f3db
            if np.sum(above) > 1:
                f_above = freqs[above]
                m_above = mag_db[above]
                if f_above[-1] > f_above[0]:
                    decades = np.log10(f_above[-1] / f_above[0])
                    if decades > 0:
                        rolloff = float((m_above[-1] - m_above[0]) / decades)

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
        assert specs.get('f3db_hz') is not None, "No -3dB frequency found"
        assert specs['passband_ripple_db'] < 3.0, \
            f"Passband ripple {specs['passband_ripple_db']:.2f}dB exceeds 3dB"
