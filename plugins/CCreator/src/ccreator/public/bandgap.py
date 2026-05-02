"""Bandgap voltage reference — behavioral model, realistic divider, comprehensive testbenches.

Testbenches:
    BandgapPSRRTestbench      — AC sweep → PSRR at multiple frequencies
    BandgapLineRegTestbench   — DC supply sweep → line regulation, output accuracy
    BandgapLoadRegTestbench   — DC load sweep → load regulation, output impedance
    BandgapTransientTestbench — Transient → startup time, load step response, settling
    BandgapNoiseTestbench     — AC sweep → output noise characterization
"""
from __future__ import annotations

import numpy as np
import sympy as sp

from ccreator import behavioral, realistic
from ccreator.core.decorators import testbench
from ccreator.core import Port
from ccreator.public._signal_analysis import (
    find_f3db, measure_psrr_at_freq, measure_settling_time,
    measure_overshoot, measure_rise_time, measure_slew_rate,
)


# ---------------------------------------------------------------------------
# Behavioral model
# ---------------------------------------------------------------------------

@behavioral.analog
class IdealBandgap:
    """Ideal bandgap voltage reference with PSRR model.

    Models a reference that tracks Vref at DC with power supply
    rejection modeled as a low-pass from supply to output.

    H(s) = Vref * wc / (s + wc)
    wc = 2*pi*BW (regulation loop bandwidth)
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {
        'Vref': 1.2,
        'BW': 1e6,
        'PSRR_dB': 60,
    }

    def transfer_function(self, s):
        wc = 2 * sp.pi * self.BW
        return self.Vref * wc / (s + wc)

    def equations(self, t, y, u):
        import math
        wc = 2 * math.pi * self.BW
        return [-wc * y[0] + wc * self.Vref]


# ---------------------------------------------------------------------------
# Realistic circuits
# ---------------------------------------------------------------------------

@realistic.analog
class ResistiveDividerRef:
    """Resistive voltage divider reference.

    Vout = Vdd * R2 / (R1 + R2)
    Default: R1=8.2k, R2=3.3k → Vout ~ 1.2V at Vdd=3.3V
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {'R1': 8.2e3, 'R2': 3.3e3}

    def build(self, n):
        n.R('R1', 'in', 'out', self.R1)
        n.R('R2', 'out', 'gnd', self.R2)


@realistic.analog
class FilteredDividerRef:
    """Resistive divider with output decoupling capacitor.

    Adds supply rejection via RC filtering.
    Vout_dc = Vdd * R2 / (R1 + R2)
    PSRR improves with frequency due to capacitor.
    """
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {'R1': 8.2e3, 'R2': 3.3e3, 'C_out': 100e-9}

    def build(self, n):
        n.R('R1', 'in', 'out', self.R1)
        n.R('R2', 'out', 'gnd', self.R2)
        n.C('Cout', 'out', 'gnd', self.C_out)


# ---------------------------------------------------------------------------
# Testbench: PSRR (AC sweep)
# ---------------------------------------------------------------------------

@testbench
class BandgapPSRRTestbench:
    """AC sweep for supply rejection characterization.

    Injects AC signal on supply, measures output.
    Extracts: PSRR at DC, 1kHz, 10kHz, 100kHz, 1MHz; PSRR bandwidth.
    """
    parameters = {
        'dut': None,
        'Vdd': 3.3,
        'fstart': 1,
        'fstop': 100e6,
        'points': 300,
    }

    def build(self, tb):
        if self.dut is None:
            dut = FilteredDividerRef()
        else:
            dut = self.dut
        tb.instance(dut, name='DUT',
                    connections={'in': 'vdd', 'out': 'vref', 'gnd': '0'})
        tb.V('Vdd', 'vdd', '0', ac=1, dc=self.Vdd)
        tb.probe('vref')

    def analysis(self, tb):
        tb.ac(variation='dec', points=self.points, fstart=self.fstart, fstop=self.fstop)

    def characterize(self, result):
        freqs = result.x
        mag_db = result.y.get('vref_magnitude_db', np.array([]))
        phase_deg = result.y.get('vref_phase_deg', np.array([]))
        if len(mag_db) == 0:
            return {}

        specs = {
            'dc_gain_db': float(mag_db[0]),
        }

        # PSRR = -20*log10(Vout_ac / Vdd_ac) = -mag_db (since input is 1V AC)
        psrr_db = -mag_db
        specs['psrr_dc_db'] = float(psrr_db[0])

        for f_check in [100, 1e3, 10e3, 100e3, 1e6, 10e6]:
            if f_check <= freqs[-1] and f_check >= freqs[0]:
                specs[f'psrr_at_{f_check:.0f}Hz_db'] = measure_psrr_at_freq(freqs, mag_db, f_check)

        # PSRR -3dB frequency (where PSRR degrades by 3dB from DC value)
        psrr_3db = find_f3db(freqs, psrr_db)
        specs['psrr_3db_hz'] = psrr_3db

        if len(phase_deg) > 0:
            specs['phase_at_dc_deg'] = float(phase_deg[0])

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        psrr_dc = specs.get('psrr_dc_db', 0)
        assert psrr_dc > 0, f"PSRR at DC = {psrr_dc:.1f}dB (should be positive)"


# ---------------------------------------------------------------------------
# Testbench: Line regulation (DC supply sweep)
# ---------------------------------------------------------------------------

@testbench
class BandgapLineRegTestbench:
    """DC supply sweep for line regulation measurement.

    Sweeps Vdd and measures Vref stability.
    Extracts: output voltage, line regulation (mV/V), dropout voltage.
    """
    parameters = {
        'dut': None,
        'vdd_start': 1.5,
        'vdd_stop': 5.0,
        'vdd_step': 0.01,
    }

    def build(self, tb):
        if self.dut is None:
            dut = ResistiveDividerRef()
        else:
            dut = self.dut
        tb.instance(dut, name='DUT',
                    connections={'in': 'vdd', 'out': 'vref', 'gnd': '0'})
        tb.V('Vdd', 'vdd', '0', dc=self.vdd_start)
        tb.probe('vref')

    def analysis(self, tb):
        tb.dc(source='Vdd', start=self.vdd_start, stop=self.vdd_stop, step=self.vdd_step)

    def characterize(self, result):
        vdd = result.x
        vref = result.y.get('vref', np.array([]))
        if len(vref) == 0:
            return {}

        # Nominal output at mid-supply
        mid_idx = len(vdd) // 2
        vref_nom = float(vref[mid_idx])

        # Line regulation = dVref/dVdd (mV/V)
        dvref = np.diff(vref)
        dvdd = np.diff(vdd)
        line_reg = dvref / dvdd  # V/V
        mean_line_reg = float(np.mean(line_reg) * 1000)  # mV/V

        # Vref variation over full supply range
        vref_min = float(np.min(vref))
        vref_max = float(np.max(vref))
        vref_spread = vref_max - vref_min

        # Dropout: Vdd where Vref drops below 95% of nominal
        dropout = None
        target = vref_nom * 0.95
        below = np.where(vref < target)[0]
        if len(below) > 0:
            dropout = float(vdd[below[-1]])

        # Temperature coefficient proxy (line sensitivity as regulation quality)
        specs = {
            'vref_nominal_v': vref_nom,
            'vref_min_v': vref_min,
            'vref_max_v': vref_max,
            'vref_spread_mv': float(vref_spread * 1000),
            'line_regulation_mv_per_v': mean_line_reg,
            'max_line_regulation_mv_per_v': float(np.max(np.abs(line_reg)) * 1000),
        }
        if dropout is not None:
            specs['dropout_voltage_v'] = dropout

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        spread = specs.get('vref_spread_mv', 0)
        # For resistive divider, spread is large; for real bandgap, should be small
        # Use a generous limit as default
        assert spread < specs['vref_nominal_v'] * 1000 * 0.5, \
            f"Vref spread {spread:.1f}mV exceeds 50% of nominal"


# ---------------------------------------------------------------------------
# Testbench: Load regulation (DC load sweep)
# ---------------------------------------------------------------------------

@testbench
class BandgapLoadRegTestbench:
    """Load regulation via variable load resistance.

    Uses a second voltage source to inject load current.
    Extracts: load regulation, output impedance.
    """
    parameters = {
        'dut': None,
        'Vdd': 3.3,
        'i_start': 0.0,
        'i_stop': 1e-3,
        'i_step': 10e-6,
    }

    def build(self, tb):
        if self.dut is None:
            dut = ResistiveDividerRef()
        else:
            dut = self.dut
        tb.instance(dut, name='DUT',
                    connections={'in': 'vdd', 'out': 'vref', 'gnd': '0'})
        tb.V('Vdd', 'vdd', '0', dc=self.Vdd)
        # Load current source pulling from output
        tb.I('load', 'vref', '0', dc=self.i_start)
        tb.probe('vref')

    def analysis(self, tb):
        tb.dc(source='load', start=self.i_start, stop=self.i_stop, step=self.i_step)

    def characterize(self, result):
        i_load = result.x
        vref = result.y.get('vref', np.array([]))
        if len(vref) == 0:
            return {}

        # Load regulation = dVref / dIload
        dvref = np.diff(vref)
        di = np.diff(i_load)
        load_reg = dvref / di  # V/A = Ohms (output impedance)

        vref_no_load = float(vref[0])
        vref_full_load = float(vref[-1])

        specs = {
            'vref_no_load_v': vref_no_load,
            'vref_full_load_v': vref_full_load,
            'voltage_drop_mv': float((vref_no_load - vref_full_load) * 1000),
            'load_regulation_mv_per_ma': float(np.mean(load_reg) * 1000 / 1000),
            'output_impedance_ohm': float(np.mean(np.abs(load_reg))),
            'max_output_impedance_ohm': float(np.max(np.abs(load_reg))),
        }

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        drop = specs.get('voltage_drop_mv', 0)
        assert abs(drop) < specs['vref_no_load_v'] * 1000 * 0.2, \
            f"Load drop {drop:.1f}mV exceeds 20% of no-load voltage"


# ---------------------------------------------------------------------------
# Testbench: Transient (startup / load step)
# ---------------------------------------------------------------------------

@testbench
class BandgapTransientTestbench:
    """Transient test for startup and load step response.

    Measures: startup time, settling time, overshoot, slew rate.
    """
    parameters = {
        'dut': None,
        'Vdd': 3.3,
        't_end': 1e-3,
        'step_time': 1e-9,
    }

    def build(self, tb):
        if self.dut is None:
            dut = FilteredDividerRef()
        else:
            dut = self.dut
        tb.instance(dut, name='DUT',
                    connections={'in': 'vdd', 'out': 'vref', 'gnd': '0'})
        # Supply ramp-up (startup)
        tb.V('Vdd', 'vdd', '0', dc=0)
        tb._sources[-1]['pulse'] = {
            'initial': 0, 'pulsed': self.Vdd,
            'delay': 1e-9, 'rise': 10e-6, 'fall': 10e-6,
            'width': self.t_end, 'period': self.t_end * 2,
        }
        tb.probe('vref')

    def analysis(self, tb):
        tb.tran(step=self.step_time, end=self.t_end)

    def characterize(self, result):
        t = result.x
        vref = result.y.get('vref', np.array([]))
        if len(vref) == 0:
            return {}

        final_val = vref[-1]
        settling_1pct = measure_settling_time(t, vref, final_val, tolerance=0.01)
        settling_01pct = measure_settling_time(t, vref, final_val, tolerance=0.001)
        overshoot = measure_overshoot(t, vref, final_val)
        rise = measure_rise_time(t, vref)
        slew = measure_slew_rate(t, vref)

        return {
            'final_value_v': float(final_val),
            'startup_settling_1pct_s': float(settling_1pct),
            'startup_settling_0.1pct_s': float(settling_01pct),
            'overshoot_pct': float(overshoot * 100),
            'rise_time_s': float(rise),
            'slew_rate_v_per_s': float(slew),
        }

    def assertions(self, result):
        specs = self.characterize(result)
        assert specs['startup_settling_1pct_s'] < self.t_end, \
            f"Did not settle within {self.t_end*1e6:.0f}us"


# ---------------------------------------------------------------------------
# Testbench: Noise (AC — output noise characterization)
# ---------------------------------------------------------------------------

@testbench
class BandgapNoiseTestbench:
    """AC sweep for output noise estimation.

    Uses the supply-to-output transfer function as a proxy for noise shaping.
    Extracts: noise gain at various frequencies, integrated noise bandwidth.
    """
    parameters = {
        'dut': None,
        'Vdd': 3.3,
        'fstart': 1,
        'fstop': 10e6,
        'points': 200,
    }

    def build(self, tb):
        if self.dut is None:
            dut = FilteredDividerRef()
        else:
            dut = self.dut
        tb.instance(dut, name='DUT',
                    connections={'in': 'vdd', 'out': 'vref', 'gnd': '0'})
        tb.V('Vdd', 'vdd', '0', ac=1, dc=self.Vdd)
        tb.probe('vref')

    def analysis(self, tb):
        tb.ac(variation='dec', points=self.points, fstart=self.fstart, fstop=self.fstop)

    def characterize(self, result):
        freqs = result.x
        vref_complex = result.y.get('vref', np.array([]))
        mag_db = result.y.get('vref_magnitude_db', np.array([]))
        if len(mag_db) == 0:
            return {}

        # Noise transfer gain at various frequencies
        specs = {'dc_noise_gain_db': float(mag_db[0])}

        for f_check in [10, 100, 1e3, 10e3, 100e3, 1e6]:
            if f_check <= freqs[-1] and f_check >= freqs[0]:
                idx = np.argmin(np.abs(freqs - f_check))
                specs[f'noise_gain_at_{f_check:.0f}Hz_db'] = float(mag_db[idx])

        # Integrated noise (approximate): integral of |H(f)|^2 over frequency
        if len(vref_complex) > 0:
            mag_lin = np.abs(vref_complex)
            # Trapezoidal integration of magnitude^2
            noise_power = float(np.trapezoid(mag_lin**2, freqs))
            specs['integrated_noise_power_v2'] = noise_power
            specs['integrated_rms_noise_v'] = float(np.sqrt(noise_power))

        # Noise bandwidth
        f3db = find_f3db(freqs, mag_db)
        specs['noise_bandwidth_hz'] = f3db

        return specs

    def assertions(self, result):
        specs = self.characterize(result)
        # Noise should decrease at high frequency for a filtered reference
        dc_gain = specs.get('dc_noise_gain_db', 0)
        hf_gain = specs.get('noise_gain_at_1000000Hz_db')
        if hf_gain is not None:
            assert hf_gain <= dc_gain + 3, \
                "Noise gain increases at high frequency — check filter"
