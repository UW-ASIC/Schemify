#!/usr/bin/env python3
"""Analytical testbench for opamp_inverting optimization.

Reads resistor values from environment variables (set by the optimizer):
  SCHEMIFY_Ri_W, SCHEMIFY_Ri_L  -> Ri = sheet_rho * L / W
  SCHEMIFY_Rf_W, SCHEMIFY_Rf_L  -> Rf = sheet_rho * L / W

Computes gain and bandwidth analytically (no SPICE needed for verification).
Outputs JSON measurements to stdout.
"""
import json
import math
import os

# Sheet resistance (Ohms/square) — typical poly resistor
SHEET_RHO = 200.0

# Parasitic feedback capacitance (pF) — models bandwidth limit
CF = 0.5e-12


def get_resistance(instance: str) -> float:
    """Compute resistance from W and L env vars: R = rho_sheet * L / W."""
    w = float(os.environ.get(f"SCHEMIFY_{instance}_W", "1e-6"))
    l = float(os.environ.get(f"SCHEMIFY_{instance}_L", "10e-6"))
    if w <= 0:
        w = 1e-6
    return SHEET_RHO * l / w


def main():
    ri = get_resistance("Ri")
    rf = get_resistance("Rf")

    # Inverting amplifier gain: -Rf/Ri (magnitude in dB)
    gain_ratio = rf / ri
    gain_db = 20.0 * math.log10(max(gain_ratio, 1e-9))

    # Bandwidth limited by feedback pole: f_3dB = 1 / (2*pi*Rf*Cf)
    bandwidth_hz = 1.0 / (2.0 * math.pi * rf * CF)

    # Phase margin: simplified model — decreases as gain increases
    # PM ≈ 90 - arctan(gain_ratio) * (180/pi) * 0.5
    phase_margin = 90.0 - math.atan(gain_ratio) * (180.0 / math.pi) * 0.5

    measurements = [
        {"name": "gain_db", "value": gain_db, "unit": "dB"},
        {"name": "bandwidth_hz", "value": bandwidth_hz, "unit": "Hz"},
        {"name": "phase_margin", "value": phase_margin, "unit": "deg"},
    ]

    print(json.dumps({"measurements": measurements}))


if __name__ == "__main__":
    main()
