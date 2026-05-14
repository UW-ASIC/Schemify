"""
Tests that all Python examples execute without errors.

Each example generates a netlist and prints it. We import and run them
to verify no crashes in the circuit builder or unit system.

Run: maturin develop && pytest tests/test_python_examples.py -v
"""
import pytest
import subprocess
import sys
from pathlib import Path

EXAMPLES_DIR = Path(__file__).parent.parent / "examples"


def _skip_if_not_built():
    try:
        import pyspice_rs
    except ImportError:
        pytest.skip("pyspice_rs not built")


def run_example(filename):
    """Run an example script as subprocess, return (returncode, stdout, stderr)."""
    _skip_if_not_built()
    script = EXAMPLES_DIR / filename
    if not script.exists():
        pytest.skip(f"{filename} not found")
    result = subprocess.run(
        [sys.executable, str(script)],
        capture_output=True, text=True, timeout=30,
    )
    return result


# ── Original examples (circuit building) ──

class TestOriginalExamples:
    def test_01_voltage_divider(self):
        r = run_example("01_voltage_divider.py")
        assert r.returncode == 0, r.stderr
        assert ".title Voltage Divider" in r.stdout

    def test_02_rc_lowpass(self):
        r = run_example("02_rc_lowpass.py")
        assert r.returncode == 0, r.stderr
        assert ".title RC Low-Pass Filter" in r.stdout

    def test_03_bjt_amplifier(self):
        r = run_example("03_bjt_amplifier.py")
        assert r.returncode == 0, r.stderr
        assert "Q1" in r.stdout

    def test_04_cmos_inverter(self):
        r = run_example("04_cmos_inverter.py")
        assert r.returncode == 0, r.stderr
        assert "M1" in r.stdout
        assert "M2" in r.stdout

    def test_05_opamp_inverting(self):
        r = run_example("05_opamp_inverting.py")
        assert r.returncode == 0, r.stderr
        assert "B1" in r.stdout

    def test_06_rlc_bandpass(self):
        r = run_example("06_rlc_bandpass.py")
        assert r.returncode == 0, r.stderr
        assert "L1" in r.stdout

    def test_07_diode_rectifier(self):
        r = run_example("07_diode_rectifier.py")
        assert r.returncode == 0, r.stderr
        assert "D1" in r.stdout
        assert "D4" in r.stdout

    def test_08_differential_pair(self):
        r = run_example("08_differential_pair.py")
        assert r.returncode == 0, r.stderr
        assert "M1" in r.stdout
        assert "M2" in r.stdout

    def test_09_current_mirror(self):
        r = run_example("09_current_mirror.py")
        assert r.returncode == 0, r.stderr

    def test_10_ring_oscillator(self):
        r = run_example("10_ring_oscillator.py")
        assert r.returncode == 0, r.stderr
        assert "M3n" in r.stdout


# ── Ported upstream examples ──

class TestUpstreamExamples:
    def test_voltage_current_divider(self):
        r = run_example("voltage_current_divider.py")
        assert r.returncode == 0, r.stderr
        assert "Voltage Divider" in r.stdout

    def test_thevenin_norton(self):
        r = run_example("thevenin_norton.py")
        assert r.returncode == 0, r.stderr
        assert "9.901" in r.stdout

    def test_diode_characteristic(self):
        r = run_example("diode_characteristic.py")
        assert r.returncode == 0, r.stderr
        assert "1N4148" in r.stdout

    def test_nmos_characteristic(self):
        r = run_example("nmos_characteristic.py")
        assert r.returncode == 0, r.stderr
        assert "nmos_65nm" in r.stdout

    def test_ac_coupled_amplifier(self):
        r = run_example("ac_coupled_amplifier.py")
        assert r.returncode == 0, r.stderr
        assert "Q1" in r.stdout

    def test_low_pass_rc_filter(self):
        r = run_example("low_pass_rc_filter.py")
        assert r.returncode == 0, r.stderr
        assert "Break frequency" in r.stdout

    def test_rlc_filter(self):
        r = run_example("rlc_filter.py")
        assert r.returncode == 0, r.stderr
        assert "Resonant frequency" in r.stdout

    def test_rectification(self):
        r = run_example("rectification.py")
        assert r.returncode == 0, r.stderr
        assert "Half-Wave" in r.stdout
        assert "Full-Wave" in r.stdout
