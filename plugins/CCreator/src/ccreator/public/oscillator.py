"""Oscillator — behavioral model, realistic circuits, and comprehensive testbenches.

Testbenches:
    OscillatorACTestbench         — AC sweep → resonance, Q factor, peak gain
    OscillatorFreqTestbench       — Transient → oscillation frequency, amplitude, duty cycle
    OscillatorJitterTestbench     — Long transient → period jitter, frequency stability
    OscillatorPhaseNoiseTestbench — Long transient → phase noise at offsets
    OscillatorStartupTestbench    — Transient → startup time, startup waveform
    OscillatorTHDTestbench        — Transient → output THD, harmonics
"""
from __future__ import annotations

import numpy as np
import sympy as sp

from ccreator import behavioral, realistic
from ccreator.core.decorators import testbench
from ccreator.core import Port
from ccreator.public._signal_analysis import (
    find_f3db, find_peak_response, measure_quality_factor,
    measure_frequency, measure_periods, measure_period_jitter,
    measure_duty_cycle, measure_settling_time,
    compute_fft, find_fundamental, compute_thd, find_harmonics,
    estimate_phase_noise, measure_rise_time,
)


# ---------------------------------------------------------------------------
# Behavioral model — second-order bandpass (resonant)
# ---------------------------------------------------------------------------

@behavioral.analog
class IdealResonator:
    """Ideal second-order bandpass (resonator) behavioral model.

    H(s) = (s * w0/Q) / (s^2 + s*w0/Q + w0^2)

    Models an LC tank or crystal resonator.
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {
        'f0': 1e6,
        'Q': 50,
    }

    def transfer_function(self, s):
        w0 = 2 * sp.pi * self.f0
        return (s * w0 / self.Q) / (s**2 + s * w0 / self.Q + w0**2)

    def equations(self, t, y, u):
        import math
        w0 = 2 * math.pi * self.f0
        # State: y[0] = output, y[1] = derivative
        dydt0 = y[1]
        dydt1 = -w0**2 * y[0] - (w0 / self.Q) * y[1] + (w0 / self.Q) * u['in']
        return [dydt0, dydt1]


# ---------------------------------------------------------------------------
# Realistic circuits
# ---------------------------------------------------------------------------

@realistic.analog
class LCTank:
    """Series RLC resonant circuit (bandpass filter).

    Resonant frequency: f0 = 1 / (2*pi*sqrt(L*C))
    Quality factor: Q = (1/R) * sqrt(L/C)

    Default: L=100uH, C=253pF → f0 ~ 1 MHz
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {
        'L': 100e-6,
        'C': 253e-12,
        'R': 10.0,
    }

    def build(self, n):
        n.L('L1', 'in', 'mid', self.L)
        n.R('R1', 'mid', 'out', self.R)
        n.C('C1', 'out', 'gnd', self.C)


@realistic.analog
class RCOscillatorStage:
    """Single RC phase-shift stage.

    Three of these cascaded give 180° phase shift for RC oscillator.
    f_osc ≈ 1 / (2*pi*R*C*sqrt(6))
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {'R': 10e3, 'C': 1e-9}

    def build(self, n):
        n.R('R1', 'in', 'out', self.R)
        n.C('C1', 'out', 'gnd', self.C)


@realistic.analog
class ParallelLCTank:
    """Parallel RLC tank circuit.

    Resonant frequency: f0 = 1 / (2*pi*sqrt(L*C))
    Quality factor: Q = R * sqrt(C/L)

    Shows high impedance at resonance (anti-resonance).
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {
        'L': 100e-6,
        'C': 253e-12,
        'R_loss': 10.0,
        'R_load': 1e6,
    }

    def build(self, n):
        # Input coupling
        n.R('Rloss', 'in', 'out', self.R_loss)
        # Parallel LC from out to gnd
        n.L('L1', 'out', 'gnd', self.L)
        n.C('C1', 'out', 'gnd', self.C)
        n.R('Rload', 'out', 'gnd', self.R_load)


# ---------------------------------------------------------------------------
# Testbench: AC resonance characterization
# ---------------------------------------------------------------------------

@testbench
class OscillatorACTestbench:
    """AC sweep for resonant circuit characterization.

    Extracts: resonant frequency, peak gain, Q factor, -3dB bandwidth,
    phase response at resonance.
    """
    parameters = {
        'dut': None,
        'fstart': 100e3,
        'fstop': 10e6,
        'points': 500,
    }

    def build(self, tb):
        if self.dut is None:
            dut = LCTank()
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

        f_peak, peak_gain = find_peak_response(freqs, mag_db)
        Q = measure_quality_factor(freqs, mag_db)
        f3db = find_f3db(freqs, mag_db)

        specs = {
            'resonant_frequency_hz': float(f_peak),
            'peak_gain_db': float(peak_gain),
            'quality_factor': float(Q) if Q is not None else None,
            'f3db_hz': f3db,
        }

        if Q is not None and f_peak > 0:
            specs['bandwidth_3db_hz'] = float(f_peak / Q)

        if len(phase_deg) > 0:
            idx_peak = np.argmin(np.abs(freqs - f_peak))
            specs['phase_at_resonance_deg'] = float(phase_deg[idx_peak])
            specs['phase_at_dc_deg'] = float(phase_deg[0])

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        assert specs.get('resonant_frequency_hz', 0) > 0, "No resonance detected"
        Q = specs.get('quality_factor')
        if Q is not None:
            assert Q > 0.5, f"Q={Q:.2f} too low for useful oscillation"


# ---------------------------------------------------------------------------
# Testbench: Frequency measurement (transient)
# ---------------------------------------------------------------------------

@testbench
class OscillatorFreqTestbench:
    """Transient test for oscillation frequency and amplitude.

    Drives circuit with a wideband stimulus and measures output.
    Extracts: frequency, amplitude, peak-to-peak, DC offset, duty cycle.
    """
    parameters = {
        'dut': None,
        'f_expected': 1e6,
        'n_cycles': 100,
        'v_drive': 1.0,
    }

    def build(self, tb):
        if self.dut is None:
            dut = LCTank()
        else:
            dut = self.dut
        period = 1.0 / self.f_expected
        self._t_end = self.n_cycles * period
        self._step = period / 20

        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})
        # Drive with sine at expected frequency
        tb.V('Vin', 'vin', '0', dc=0)
        tb._sources[-1]['sin'] = {
            'offset': 0,
            'amplitude': self.v_drive,
            'frequency': self.f_expected,
        }
        tb.probe('vout')

    def analysis(self, tb):
        tb.tran(step=self._step, end=self._t_end)

    def characterize(self, result):
        t = result.x
        v_out = result.y.get('vout', np.array([]))
        if len(v_out) == 0:
            return {}

        # Skip first 20% for settling
        skip = len(t) // 5
        t_ss, v_ss = t[skip:], v_out[skip:]

        freq = measure_frequency(t_ss, v_ss)
        duty = measure_duty_cycle(t_ss, v_ss)
        vpp = float(np.max(v_ss) - np.min(v_ss))
        v_mean = float(np.mean(v_ss))

        specs = {
            'frequency_hz': float(freq),
            'frequency_error_ppm': float((freq - self.f_expected) / self.f_expected * 1e6)
                if freq > 0 else None,
            'amplitude_vpp': vpp,
            'amplitude_vpeak': vpp / 2,
            'dc_offset_v': v_mean,
            'duty_cycle': float(duty),
        }

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        freq = specs.get('frequency_hz', 0)
        assert freq > 0, "No oscillation detected"
        error = abs(specs.get('frequency_error_ppm', 0))
        assert error < 50000, f"Frequency error {error:.0f}ppm exceeds 5%"


# ---------------------------------------------------------------------------
# Testbench: Jitter (long transient)
# ---------------------------------------------------------------------------

@testbench
class OscillatorJitterTestbench:
    """Long transient for oscillator jitter characterization.

    Extracts: period jitter (rms, pp), cycle-to-cycle jitter, frequency stability.
    """
    parameters = {
        'dut': None,
        'f_expected': 1e6,
        'n_cycles': 1000,
        'v_drive': 1.0,
    }

    def build(self, tb):
        if self.dut is None:
            dut = LCTank()
        else:
            dut = self.dut
        period = 1.0 / self.f_expected
        self._t_end = self.n_cycles * period
        self._step = period / 40  # higher resolution for jitter

        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})
        tb.V('Vin', 'vin', '0', dc=0)
        tb._sources[-1]['sin'] = {
            'offset': 0,
            'amplitude': self.v_drive,
            'frequency': self.f_expected,
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

        periods = measure_periods(t_ss, v_ss)
        if len(periods) < 3:
            return {'note': 'Insufficient cycles for jitter analysis'}

        jitter = measure_period_jitter(periods)
        freq = 1.0 / np.mean(periods)

        # Frequency stability: std(frequency) / mean(frequency)
        freq_inst = 1.0 / periods
        freq_stability_ppm = float(np.std(freq_inst) / np.mean(freq_inst) * 1e6)

        return {
            'mean_frequency_hz': float(freq),
            'mean_period_s': float(np.mean(periods)),
            'period_jitter_rms_s': jitter['rms'],
            'period_jitter_rms_pct': float(jitter['rms'] / np.mean(periods) * 100),
            'period_jitter_pp_s': jitter['peak_to_peak'],
            'cycle_to_cycle_jitter_rms_s': jitter['cycle_to_cycle_rms'],
            'frequency_stability_ppm': freq_stability_ppm,
            'n_periods_measured': len(periods),
        }

    def assertions(self, result):
        specs = self.characterize(result)
        jitter_pct = specs.get('period_jitter_rms_pct', 0)
        assert jitter_pct < 5, f"Period jitter {jitter_pct:.2f}% exceeds 5%"


# ---------------------------------------------------------------------------
# Testbench: Phase noise
# ---------------------------------------------------------------------------

@testbench
class OscillatorPhaseNoiseTestbench:
    """Long transient for phase noise estimation.

    Extracts: phase noise at standard offsets (1kHz, 10kHz, 100kHz, 1MHz).
    """
    parameters = {
        'dut': None,
        'f_expected': 1e6,
        'n_cycles': 2000,
        'v_drive': 1.0,
        'offsets_hz': [1e3, 10e3, 100e3],
    }

    def build(self, tb):
        if self.dut is None:
            dut = LCTank()
        else:
            dut = self.dut
        period = 1.0 / self.f_expected
        self._t_end = self.n_cycles * period
        self._step = period / 40

        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})
        tb.V('Vin', 'vin', '0', dc=0)
        tb._sources[-1]['sin'] = {
            'offset': 0,
            'amplitude': self.v_drive,
            'frequency': self.f_expected,
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

        freq = measure_frequency(t_ss, v_ss)
        pn = estimate_phase_noise(t_ss, v_ss, offsets_hz=self.offsets_hz)

        specs = {'carrier_frequency_hz': float(freq)}
        for offset, value in pn.items():
            label = f'phase_noise_at_{offset/1e3:.0f}kHz_dBcHz'
            specs[label] = value

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        for key, val in specs.items():
            if 'phase_noise' in key and val is not None:
                assert val < 0, f"{key}={val:.1f} should be negative"


# ---------------------------------------------------------------------------
# Testbench: Startup
# ---------------------------------------------------------------------------

@testbench
class OscillatorStartupTestbench:
    """Transient test for oscillator startup behavior.

    Applies step drive and measures time to reach steady-state oscillation.
    Extracts: startup time, initial amplitude growth, final amplitude.
    """
    parameters = {
        'dut': None,
        'f_expected': 1e6,
        'n_cycles': 200,
        'v_drive': 1.0,
    }

    def build(self, tb):
        if self.dut is None:
            dut = LCTank()
        else:
            dut = self.dut
        period = 1.0 / self.f_expected
        self._t_end = self.n_cycles * period
        self._step = period / 20

        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})
        # Step-on the drive signal
        tb.V('Vin', 'vin', '0', dc=0)
        tb._sources[-1]['sin'] = {
            'offset': 0,
            'amplitude': self.v_drive,
            'frequency': self.f_expected,
        }
        tb.probe('vout')

    def analysis(self, tb):
        tb.tran(step=self._step, end=self._t_end)

    def characterize(self, result):
        t = result.x
        v_out = result.y.get('vout', np.array([]))
        if len(v_out) == 0:
            return {}

        # Envelope detection via Hilbert transform
        from scipy.signal import hilbert
        analytic = hilbert(v_out)
        envelope = np.abs(analytic)

        final_amplitude = float(np.mean(envelope[-len(envelope)//10:]))

        # Startup time: time to reach 90% of final amplitude
        target_90 = 0.9 * final_amplitude
        above = np.where(envelope >= target_90)[0]
        startup_time = float(t[above[0]] - t[0]) if len(above) > 0 else float(t[-1] - t[0])

        # Rise time of envelope
        rise = measure_rise_time(t, envelope)

        return {
            'final_amplitude_v': final_amplitude,
            'startup_time_to_90pct_s': startup_time,
            'envelope_rise_time_s': float(rise),
            'final_frequency_hz': float(measure_frequency(
                t[-len(t)//5:], v_out[-len(t)//5:])),
        }

    def assertions(self, result):
        specs = self.characterize(result)
        assert specs['final_amplitude_v'] > 0.01, "Oscillation did not start"
        period = 1.0 / self.f_expected
        assert specs['startup_time_to_90pct_s'] < self.n_cycles * period, \
            "Did not reach steady-state"


# ---------------------------------------------------------------------------
# Testbench: THD / spectral purity
# ---------------------------------------------------------------------------

@testbench
class OscillatorTHDTestbench:
    """Transient + FFT for oscillator output spectral purity.

    Extracts: THD, individual harmonic levels, spectral floor.
    """
    parameters = {
        'dut': None,
        'f_expected': 1e6,
        'n_cycles': 128,
        'v_drive': 1.0,
    }

    def build(self, tb):
        if self.dut is None:
            dut = LCTank()
        else:
            dut = self.dut
        period = 1.0 / self.f_expected
        self._t_end = self.n_cycles * period
        self._step = period / 20

        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})
        tb.V('Vin', 'vin', '0', dc=0)
        tb._sources[-1]['sin'] = {
            'offset': 0,
            'amplitude': self.v_drive,
            'frequency': self.f_expected,
        }
        tb.probe('vout')

    def analysis(self, tb):
        tb.tran(step=self._step, end=self._t_end)

    def characterize(self, result):
        t = result.x
        v_out = result.y.get('vout', np.array([]))
        if len(v_out) == 0:
            return {}

        skip = len(t) // 5
        t_ss, v_ss = t[skip:], v_out[skip:]

        freqs, mag_dbfs = compute_fft(t_ss, v_ss, window='blackmanharris')
        f0, f0_power = find_fundamental(freqs, mag_dbfs, fmin=self.f_expected * 0.5)
        thd = compute_thd(freqs, mag_dbfs, f0, n_harmonics=10)
        harmonics = find_harmonics(freqs, mag_dbfs, f0, n_harmonics=10)

        # Noise floor (median of all bins excluding signal and harmonics)
        all_bins = set(range(len(mag_dbfs)))
        sig_idx = np.argmin(np.abs(freqs - f0))
        exclude = {sig_idx}
        for h_f, _ in harmonics:
            exclude.add(np.argmin(np.abs(freqs - h_f)))
        noise_bins = sorted(all_bins - exclude)
        noise_floor = float(np.median(mag_dbfs[list(noise_bins)])) if noise_bins else -200.0

        specs = {
            'fundamental_hz': float(f0),
            'fundamental_dbfs': float(f0_power),
            'thd_db': float(thd),
            'noise_floor_dbfs': noise_floor,
        }

        for i, (h_f, h_db) in enumerate(harmonics[:5], start=2):
            specs[f'harmonic_{i}_hz'] = float(h_f)
            specs[f'harmonic_{i}_dbfs'] = float(h_db)
            specs[f'harmonic_{i}_dbc'] = float(f0_power - h_db)

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        thd = specs.get('thd_db', 0)
        assert thd < -10, f"THD={thd:.1f}dB exceeds -10dB"
