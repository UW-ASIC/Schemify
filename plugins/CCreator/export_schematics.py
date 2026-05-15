#!/usr/bin/env python3
"""Export GEMM sky130 circuits to .chn and .chn_tb schematics.

Generates Schemify schematic files using the export.schemify() pipeline:
    Python circuit -> SPICE -> Parse -> Place -> Route -> .chn JSON

Usage:
    python export_schematics.py
"""
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).parent))

from project.gemm_sky130 import IMCTileSky130, SampleHoldBankSky130, TGateMuxSky130
from ccreator.testbench.spice_export import to_spice_string
from ccreator.testbench.builder import TestbenchBuilder
from ccreator.core.circuit import _fallback_parse_spice

OUT_DIR = pathlib.Path('./schematics')
OUT_DIR.mkdir(parents=True, exist_ok=True)

SEP = '=' * 60


def export_circuit(circuit, label):
    """Export a circuit to .chn via export.schemify()."""
    outputs = circuit.export.schemify(str(OUT_DIR))
    for o in outputs:
        print(f"  {o.filename}: {len(o.components)} devices, "
              f"{len(o.wires)} wires, {len(o.pins)} pins")
    return outputs


def export_testbench(tb_builder, label):
    """Export a TestbenchBuilder to JSON via SPICE -> fallback parser.

    NOTE: For full-fidelity SPICE import with placement and routing, use
    the core Schemify host API (spiceImport command) instead.
    """
    import json
    spice = to_spice_string(tb_builder)
    name = tb_builder._name
    components = _fallback_parse_spice(spice)
    out_file = OUT_DIR / f"{name}_tb.json"
    out_file.write_text(json.dumps(components, indent=2))
    print(f"  {name}_tb.json: {len(components)} components")
    return components


# ===================================================================
# Circuit schematics (.chn)
# ===================================================================
print(f"\n{SEP}")
print("  CIRCUIT SCHEMATICS")
print(SEP)

# IMC Tile (identity weights)
print("\nIMCTileSky130 (identity weights):")
tile = IMCTileSky130()
export_circuit(tile, 'IMC Tile')

# IMC Tile with GEMM weights
print("\nIMCTileSky130 (GEMM weights):")
tile_gemm = IMCTileSky130(
    w00=1/6, w01=0.0,  w02=0.5/6, w03=0.0,
    w10=0.5/6, w11=1/6, w12=0.0,   w13=0.0,
    w20=0.0, w21=0.5/6, w22=1/6,  w23=0.5/6,
    w30=0.0, w31=0.0,  w32=0.5/6, w33=1/6,
)
export_circuit(tile_gemm, 'IMC Tile GEMM')

# Sample-and-Hold Bank
print("\nSampleHoldBankSky130:")
sh = SampleHoldBankSky130()
export_circuit(sh, 'Sample-Hold Bank')

# Transmission Gate Mux
print("\nTGateMuxSky130:")
mux = TGateMuxSky130()
export_circuit(mux, 'T-Gate Mux')


# ===================================================================
# Testbench schematics (.chn_tb)
# ===================================================================
print(f"\n{SEP}")
print("  TESTBENCH SCHEMATICS")
print(SEP)

# --- TB 1: IMC Tile DC Test ---
print("\ntb_imc_tile: DC input test")
tb = TestbenchBuilder('tb_imc_tile')
tile = IMCTileSky130()
tb.instance(tile, name='TILE', connections={
    'x0': 'x0', 'x1': 'x1', 'x2': 'x2', 'x3': 'x3',
    'y0': 'y0', 'y1': 'y1', 'y2': 'y2', 'y3': 'y3',
    'rst': 'rst', 'vdd': 'vdd', 'gnd': '0',
})
tb.V('Vdd', 'vdd', '0', dc=1.8)
tb.V('Vrst', 'rst', '0', dc=1.8)
tb._sources[-1]['pulse'] = {
    'initial': 1.8, 'pulsed': 0,
    'delay': 0.5e-6, 'rise': 1e-9, 'fall': 1e-9,
    'width': 10e-6, 'period': 20e-6,
}
for i, v in enumerate([0.3, 0.6, 0.9, 1.2]):
    tb.V(f'Vx{i}', f'x{i}', '0', dc=0)
    tb._sources[-1]['pulse'] = {
        'initial': 0, 'pulsed': v,
        'delay': 1e-6, 'rise': 1e-9, 'fall': 1e-9,
        'width': 10e-6, 'period': 20e-6,
    }
for i in range(4):
    tb.probe(f'y{i}')
tb.tran(step=5e-9, end=5e-6)
export_testbench(tb, 'IMC Tile TB')

# --- TB 2: Sample-and-Hold Test ---
print("\ntb_sample_hold: track and hold test")
tb = TestbenchBuilder('tb_sample_hold')
sh = SampleHoldBankSky130()
tb.instance(sh, name='SH', connections={
    'in0': 'in0', 'in1': 'in1', 'in2': 'in2', 'in3': 'in3',
    'out0': 'out0', 'out1': 'out1', 'out2': 'out2', 'out3': 'out3',
    'sample': 'sample', 'gnd': '0',
})
tb.V('Vsample', 'sample', '0', dc=1.8)
tb._sources[-1]['pulse'] = {
    'initial': 1.8, 'pulsed': 0,
    'delay': 3e-6, 'rise': 1e-9, 'fall': 1e-9,
    'width': 6e-6, 'period': 12e-6,
}
for i, v in enumerate([0.3, 0.6, 0.9, 1.1]):
    tb.V(f'Vin{i}', f'in{i}', '0', dc=v)
for i in range(4):
    tb.probe(f'out{i}')
tb.tran(step=3e-9, end=6e-6)
export_testbench(tb, 'Sample-Hold TB')

# --- TB 3: Transmission Gate Mux Test ---
print("\ntb_tgate_mux: mux select test")
tb = TestbenchBuilder('tb_tgate_mux')
mux = TGateMuxSky130()
tb.instance(mux, name='MUX', connections={
    'a0': 'a0', 'a1': 'a1', 'a2': 'a2', 'a3': 'a3',
    'b0': 'b0', 'b1': 'b1', 'b2': 'b2', 'b3': 'b3',
    'out0': 'out0', 'out1': 'out1', 'out2': 'out2', 'out3': 'out3',
    'sel': 'sel', 'vdd': 'vdd', 'gnd': '0',
})
tb.V('Vdd', 'vdd', '0', dc=1.8)
tb.V('Vsel', 'sel', '0', dc=0)
tb._sources[-1]['pulse'] = {
    'initial': 0, 'pulsed': 1.8,
    'delay': 2e-6, 'rise': 1e-9, 'fall': 1e-9,
    'width': 2e-6, 'period': 4e-6,
}
# A inputs: fixed voltages
for i, v in enumerate([0.3, 0.6, 0.9, 1.2]):
    tb.V(f'Va{i}', f'a{i}', '0', dc=v)
# B inputs: different voltages
for i, v in enumerate([1.2, 0.9, 0.6, 0.3]):
    tb.V(f'Vb{i}', f'b{i}', '0', dc=v)
for i in range(4):
    tb.probe(f'out{i}')
tb.tran(step=2e-9, end=4e-6)
export_testbench(tb, 'T-Gate Mux TB')

# --- TB 4: Full Pipeline (IMC -> S&H -> Mux) ---
print("\ntb_gemm_pipe: full datapath pipeline")
tb = TestbenchBuilder('tb_gemm_pipe')

tile = IMCTileSky130()
tb.instance(tile, name='TILE', connections={
    'x0': 'x0', 'x1': 'x1', 'x2': 'x2', 'x3': 'x3',
    'y0': 'ty0', 'y1': 'ty1', 'y2': 'ty2', 'y3': 'ty3',
    'rst': 'rst', 'vdd': 'vdd', 'gnd': '0',
})

sh = SampleHoldBankSky130()
tb.instance(sh, name='SH', connections={
    'in0': 'ty0', 'in1': 'ty1', 'in2': 'ty2', 'in3': 'ty3',
    'out0': 'sh0', 'out1': 'sh1', 'out2': 'sh2', 'out3': 'sh3',
    'sample': 'sh_en', 'gnd': '0',
})

mux = TGateMuxSky130()
tb.instance(mux, name='MUX', connections={
    'a0': 'ty0', 'a1': 'ty1', 'a2': 'ty2', 'a3': 'ty3',
    'b0': 'sh0', 'b1': 'sh1', 'b2': 'sh2', 'b3': 'sh3',
    'out0': 'out0', 'out1': 'out1', 'out2': 'out2', 'out3': 'out3',
    'sel': 'mux_sel', 'vdd': 'vdd', 'gnd': '0',
})

# Supply
tb.V('Vdd', 'vdd', '0', dc=1.8)

# Reset pulse (first 0.5us)
tb.V('Vrst', 'rst', '0', dc=1.8)
tb._sources[-1]['pulse'] = {
    'initial': 1.8, 'pulsed': 0,
    'delay': 0.5e-6, 'rise': 1e-9, 'fall': 1e-9,
    'width': 10e-6, 'period': 20e-6,
}

# Inputs step on at 1us
for i, v in enumerate([0.3, 0.6, 0.9, 1.2]):
    tb.V(f'Vx{i}', f'x{i}', '0', dc=0)
    tb._sources[-1]['pulse'] = {
        'initial': 0, 'pulsed': v,
        'delay': 1e-6, 'rise': 1e-9, 'fall': 1e-9,
        'width': 10e-6, 'period': 20e-6,
    }

# S&H: sample during compute (1-4us), hold after (4-8us)
tb.V('Vsh', 'sh_en', '0', dc=1.8)
tb._sources[-1]['pulse'] = {
    'initial': 1.8, 'pulsed': 0,
    'delay': 4e-6, 'rise': 1e-9, 'fall': 1e-9,
    'width': 8e-6, 'period': 16e-6,
}

# Mux: select IMC direct (0-4us), then S&H (4-8us)
tb.V('Vmux', 'mux_sel', '0', dc=0)
tb._sources[-1]['pulse'] = {
    'initial': 0, 'pulsed': 1.8,
    'delay': 4e-6, 'rise': 1e-9, 'fall': 1e-9,
    'width': 8e-6, 'period': 16e-6,
}

for i in range(4):
    tb.probe(f'ty{i}', f'sh{i}', f'out{i}')
tb.tran(step=4e-9, end=8e-6)
export_testbench(tb, 'GEMM Pipeline TB')


# ===================================================================
# Summary
# ===================================================================
print(f"\n{SEP}")
print("  DONE")
print(SEP)

chn_files = list(OUT_DIR.glob('*.chn*'))
print(f"\n  Generated {len(chn_files)} files in {OUT_DIR}/:")
for f in sorted(chn_files):
    size = f.stat().st_size
    print(f"    {f.name:40s} {size:>6,d} bytes")
