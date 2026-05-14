# simulation

SPICE netlist generation, result types, waveform analysis, and gm/Id optimizer.

## Functionality

- SPICE netlist generation from schematic data (subcircuit, template expansion)
- PySpice netlist generation for Python-based simulation
- SPICE intermediate representation: components, analyses, sweeps, measures, UQ
- Simulation result types and waveform arithmetic (magnitude, phase, measurements)
- gm/Id MOSFET sizing optimizer with LHS sampling and adaptive grid refinement

Removed in cleanup: VerilogNetlist.zig (zero callers, referenced nonexistent API), RawFile.zig (zero callers).

## Public API

| Symbol | Purpose |
|--------|---------|
| `SpiceIF` | SPICE IR types: `Value`, `SpiceComponent`, `Analysis`, `Sweep`, `Measure`, ngspice emission |
| `Netlist.emitSpice` | Schematic → SPICE netlist string |
| `Netlist.emitPySpice` | Schematic → PySpice Python script |
| `results.SimResult` | Simulation output: waveforms, op-points, errors |
| `results.magnitudeDb` | Complex waveform → dB magnitude |
| `results.phaseDeg` | Complex waveform → phase in degrees |
| `results.bandwidth3dB` | AC response → -3dB frequency |
| `results.extractAcMetrics` | Full AC analysis → [gain, BW, PM, UGF] |
| `optimizer.Optimizer` | gm/Id optimization engine |
| `optimizer.sweepGmId` | Parameter sweep over gm/Id space |

## Internal Structure

| File | Purpose |
|------|---------|
| `lib.zig` | Module entry point, re-exports |
| `Netlist.zig` | SPICE + PySpice netlist generation |
| `SpiceIF.zig` | SPICE IR types and ngspice emission |
| `results.zig` | SimResult, Waveform, measurement functions |
| `optimizer/lib.zig` | Optimizer entry point |
| `optimizer/types.zig` | Problem, Transistor, Specification types |
| `optimizer/gmid.zig` | CubicSpline, GmIdLookup, analytical models |
| `optimizer/sweep.zig` | SweepEngine, LHS sampling, grid refinement |

## Dependencies

- `schematic` — Instance, Wire, DeviceKind, Property, Schemify, helpers
