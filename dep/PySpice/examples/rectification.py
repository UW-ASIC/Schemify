"""
Half and Full Wave Rectification — ported from upstream PySpice examples.

Demonstrates half-wave and full-wave bridge rectifier with filtering.

Original: PySpice-org/PySpice/examples/diode/rectification.py
"""
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V, u_Ohm, u_mF, u_Hz

# 1N4148 diode model
def add_diode_model(circuit):
    circuit.model("1N4148", "D", IS=2.52e-9, RS=0.568, N=1.752, BV=100, IBV=100e-6)

# ── Half-Wave Rectifier ──

hw = Circuit("Half-Wave Rectifier")
add_diode_model(hw)
hw.SinusoidalVoltageSource("input", "in", hw.gnd,
                            dc_offset=0.0, offset=0.0,
                            amplitude=10.0, frequency=50.0)
hw.D("1", "in", "out", model="1N4148")
hw.R("load", "out", hw.gnd, 100.0)

print("--- Half-Wave Rectifier ---")
print(hw)

# ── Half-Wave with Filter ──

hwf = Circuit("Half-Wave Rectifier with Filter")
add_diode_model(hwf)
hwf.SinusoidalVoltageSource("input", "in", hwf.gnd,
                             dc_offset=0.0, offset=0.0,
                             amplitude=10.0, frequency=50.0)
hwf.D("1", "in", "out", model="1N4148")
hwf.C("1", "out", hwf.gnd, 1e-3)
hwf.R("load", "out", hwf.gnd, 100.0)

print("\n--- Half-Wave with Filter ---")
print(hwf)

# ── Full-Wave Bridge Rectifier ──

fw = Circuit("Full-Wave Bridge Rectifier")
add_diode_model(fw)
fw.SinusoidalVoltageSource("input", "ac_p", "ac_m",
                            dc_offset=0.0, offset=0.0,
                            amplitude=10.0, frequency=50.0)
fw.D("1", "ac_p", "out_p", model="1N4148")
fw.D("2", "out_m", "ac_p", model="1N4148")
fw.D("3", "ac_m", "out_p", model="1N4148")
fw.D("4", "out_m", "ac_m", model="1N4148")
fw.R("load", "out_p", "out_m", 100.0)
fw.V("ref", "out_m", fw.gnd, 0.0)

print("\n--- Full-Wave Bridge Rectifier ---")
print(fw)

# ── Full-Wave with Filter ──

fwf = Circuit("Full-Wave Bridge with Filter")
add_diode_model(fwf)
fwf.SinusoidalVoltageSource("input", "ac_p", "ac_m",
                             dc_offset=0.0, offset=0.0,
                             amplitude=10.0, frequency=50.0)
fwf.D("1", "ac_p", "out_p", model="1N4148")
fwf.D("2", "out_m", "ac_p", model="1N4148")
fwf.D("3", "ac_m", "out_p", model="1N4148")
fwf.D("4", "out_m", "ac_m", model="1N4148")
fwf.C("1", "out_p", "out_m", 1e-3)
fwf.R("load", "out_p", "out_m", 100.0)
fwf.V("ref", "out_m", fwf.gnd, 0.0)

print("\n--- Full-Wave with Filter ---")
print(fwf)
