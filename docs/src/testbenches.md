# Testbenches

A testbench wraps a design-under-test (DUT) with stimulus and measurement setup. In Schemify, testbenches are `.chn_tb` files.

## Structure

A testbench typically contains:

1. **DUT instance** -- your circuit, instantiated as a subcircuit
2. **Stimulus sources** -- voltage/current sources that drive the inputs
3. **Load components** -- resistors, capacitors modeling the output load
4. **Probes** -- voltage and current probes marking nodes to observe
5. **Analysis configuration** -- what simulation to run (DC, AC, transient)

## Creating a Testbench

1. Create a new file with the `.chn_tb` extension (or use the new-testbench command)
2. Place your DUT as a `subckt` instance -- it references the `.chn` file
3. Add stimulus: voltage sources with DC, pulse, sine, or custom waveforms
4. Add probes on the nodes you want to observe
5. Press **F5** to simulate

## Example: CMOS Inverter VTC

A voltage transfer characteristic (VTC) testbench for a CMOS inverter:

```
┌─────────────────────────────────────────┐
│  Testbench: tb_cmos_inverter_vtc        │
│                                         │
│  V1 (DC sweep 0→1.8V) ──► INV.in       │
│                                         │
│  INV.out ──► vprobe (output)            │
│                                         │
│  VDD = 1.8V                             │
│  Analysis: DC sweep V1 0 1.8 0.01       │
└─────────────────────────────────────────┘
```

This sweeps the input voltage from 0 to 1.8V and plots the output, producing the classic inverter S-curve.

## Example: Transient Analysis

```
┌─────────────────────────────────────────┐
│  Testbench: tb_common_source_ac         │
│                                         │
│  V1 (AC source, 1kHz sine) ──► AMP.in   │
│  VDD = 3.3V                             │
│                                         │
│  AMP.out ──► vprobe                     │
│  Analysis: AC dec 10 1 10G              │
└─────────────────────────────────────────┘
```

## Included Testbenches

Schemify ships with ready-to-run testbenches in the `examples/` directory:

| Testbench | Circuit | Analysis |
|---|---|---|
| `tb_cmos_inverter_vtc` | CMOS inverter | DC sweep (VTC) |
| `tb_cmos_inverter_transient` | CMOS inverter | Transient (pulse response) |
| `tb_common_source_ac` | Common-source amplifier | AC (frequency response) |
| `tb_common_source_dc` | Common-source amplifier | DC (bias point) |
| `tb_common_source_sweep` | Common-source amplifier | DC sweep |
| `tb_bandgap_temp` | Bandgap reference | Temperature sweep |
| `tb_buck_converter_waveform` | Buck converter | Transient (switching waveform) |
| `tb_charge_pump_waveform` | Charge pump | Transient |
| `tb_cascode_spectre` | Cascode amplifier | Spectre-dialect testbench |

## Running from CLI

```sh
# Run the CMOS inverter VTC simulation
schemify --file examples/tb_cmos_inverter_vtc.chn_tb run-sim

# Run with a specific file
schemify --file my_testbench.chn_tb run-sim
```

## Tips

- Keep testbenches separate from the circuit -- one `.chn` design, multiple `.chn_tb` testbenches
- Name your probes descriptively (`vout`, `ibias`, `clk`) -- they become trace labels in the output
- Start with a DC operating point analysis to verify bias before running transient or AC
