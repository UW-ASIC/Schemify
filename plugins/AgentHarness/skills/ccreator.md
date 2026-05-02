# CCreator Plugin

Bidirectional `.chn` <-> Python circuit generator. Converts schematics to Python classes and vice versa.

## Commands

All issued via Schemify's command system:

```
plugin ccreator export [path]      — export current .chn as Python generator class
plugin ccreator import <path>      — import a CCreator Python file into schematic
plugin ccreator template <name>    — import a built-in template by class name
```

## Decorators

CCreator Python classes use decorators to define circuit type:

| Decorator | Purpose |
|-----------|---------|
| `@behavioral.analog` | Transfer-function model (Verilog-A output) |
| `@realistic.analog` | Transistor-level netlist (SPICE output) |
| `@testbench` | Testbench wrapping a DUT |

## Behavioral Circuits (`@behavioral.analog`)

Define a transfer function using SymPy:

```python
from ccreator import behavioral
from ccreator.core import Port

@behavioral.analog
class IdealADC:
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
```

### Required methods

- `transfer_function(self, s)` — return H(s) using SymPy symbols
- `equations(self, t, y, u)` — state-space form for transient sim (optional)

### Export

Generates Verilog-A with `laplace_nd()`:
```
plugin ccreator export /path/to/output.va
```

## Realistic Circuits (`@realistic.analog`)

Define a netlist using the `NetlistBuilder`:

```python
from ccreator import realistic
from ccreator.core import Port

@realistic.analog
class ResistiveADCFrontend:
    ports = [
        Port('in', 'input', 'voltage'),
        Port('out', 'output', 'voltage'),
        Port('gnd', 'inout', 'voltage'),
    ]
    parameters = {'R_in': 1e3, 'R_fb': 10e3}

    def build(self, n):
        n.R('Rin', 'in', 'out', self.R_in)
        n.R('Rfb', 'out', 'gnd', self.R_fb)
```

### NetlistBuilder methods (`n`)

| Method | Signature | Description |
|--------|-----------|-------------|
| `n.R()` | `(name, n1, n2, value)` | Resistor |
| `n.C()` | `(name, n1, n2, value)` | Capacitor |
| `n.L()` | `(name, n1, n2, value)` | Inductor |
| `n.V()` | `(name, n1, n2, **kwargs)` | Voltage source |
| `n.I()` | `(name, n1, n2, **kwargs)` | Current source |
| `n.MOSFET()` | `(name, drain, gate, source, bulk, model, **kwargs)` | MOSFET |
| `n.BJT()` | `(name, collector, base, emitter, model, **kwargs)` | BJT |
| `n.raw()` | `(spice_line)` | Raw SPICE line |

Node names correspond to port names. The `ground` port auto-maps to circuit GND.

## Testbenches (`@testbench`)

```python
from ccreator.core.decorators import testbench

@testbench
class ADCStaticTestbench:
    parameters = {
        'dut': None,        # circuit instance to test
        'v_start': 0.0,
        'v_stop': 1.2,
        'v_step': 0.001,
    }

    def build(self, tb):
        dut = self.dut or RCADCFrontend()
        tb.instance(dut, name='DUT',
                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})
        tb.V('Vin', 'vin', '0', dc=self.v_start)
        tb.probe('vout')

    def analysis(self, tb):
        tb.dc(source='Vin', start=self.v_start, stop=self.v_stop, step=self.v_step)

    def characterize(self, result):
        # Extract metrics from simulation result
        return {'dc_gain': ..., 'offset_v': ...}

    def assertions(self, result):
        specs = self.characterize(result)
        assert abs(specs['gain_error_pct']) < 5
```

### TestbenchBuilder methods (`tb`)

| Method | Signature | Description |
|--------|-----------|-------------|
| `tb.instance()` | `(circuit, name, connections)` | Instantiate a DUT |
| `tb.V()` | `(name, n+, n-, **kwargs)` | Voltage source (dc=, ac=) |
| `tb.I()` | `(name, n+, n-, **kwargs)` | Current source |
| `tb.probe()` | `(*node_names)` | Probe nodes for output |
| `tb.ac()` | `(variation, points, fstart, fstop)` | AC analysis |
| `tb.tran()` | `(step, end)` | Transient analysis |
| `tb.dc()` | `(source, start, stop, step)` | DC sweep |

## Port Definition

```python
Port(name, direction, signal_type)
```

- `direction`: `'input'`, `'output'`, `'inout'`
- `signal_type`: `'voltage'` (analog)

## Built-in Templates

### ADC
| Class | Type | Description |
|-------|------|-------------|
| `IdealADC` | behavioral | Gain stage with Nyquist bandwidth |
| `ResistiveADCFrontend` | realistic | Resistive attenuator |
| `RCADCFrontend` | realistic | RC anti-aliasing filter |

### DAC
| Class | Type | Description |
|-------|------|-------------|
| `IdealDAC` | behavioral | Ideal DAC model |
| `RCReconstructionFilter` | realistic | RC reconstruction filter |
| `SecondOrderReconstructionFilter` | realistic | 2nd-order filter |

### PLL
| Class | Type | Description |
|-------|------|-------------|
| `IdealPLL` | behavioral | Ideal PLL model |
| `CPPLLLoopFilter` | realistic | Charge-pump loop filter |
| `ThirdOrderLoopFilter` | realistic | 3rd-order loop filter |

### Bandgap
| Class | Type | Description |
|-------|------|-------------|
| `IdealBandgap` | behavioral | Ideal bandgap reference |
| `ResistiveDividerRef` | realistic | Resistive divider reference |
| `FilteredDividerRef` | realistic | Filtered divider reference |

### Oscillator
| Class | Type | Description |
|-------|------|-------------|
| `IdealResonator` | behavioral | Ideal resonator |
| `LCTank` | realistic | LC tank oscillator |
| `RCOscillatorStage` | realistic | RC oscillator stage |

### Switch
| Class | Type | Description |
|-------|------|-------------|
| `IdealSwitch` | behavioral | Ideal switch |
| `ResistiveSwitch` | realistic | Resistive switch |
| `TransmissionGate` | realistic | Transmission gate |

## Testbench Categories

| Category | Available Testbenches |
|----------|----------------------|
| ADC | Static, Dynamic, Bandwidth |
| DAC | Static, Dynamic, Filter |
| PLL | LoopFilter, Lock, Jitter, PhaseNoise |
| Bandgap | PSRR, LineReg, LoadReg, Transient, Noise |
| Oscillator | AC, Frequency, Jitter, PhaseNoise, Startup, THD |
| Switch | Ron, Isolation, Bandwidth, Transient, Distortion |

## Export Proxy

Any circuit instance has an `.export` proxy:
```python
circuit = ResistiveADCFrontend(R_in=1e3, R_fb=10e3)
circuit.export.spice("/path/to/output.sp")     # SPICE netlist
circuit.export.veriloga("/path/to/output.va")   # Verilog-A (behavioral only)
circuit.export.verilog("/path/to/output.v")     # Verilog (digital only)
```

## Storage in .chn Files

CCreator code is stored in the `PLUGIN CCreator` block of `.chn` files:
```
PLUGIN CCreator
  testbench_code: @realistic.analog\nclass MyCircuit:\n    ...
  last_export: /tmp/my_circuit.py
```

The code is escaped (newlines as `\n`) in a single `testbench_code` key.
When the user opens a `.chn` file, CCreator reads this block to display
the Python equivalent. Changes to the Python code update this block on save.

## Typical Workflow

1. Create a schematic with primitives (place, add-wire, set-prop)
2. Export to Python: `plugin ccreator export`
3. Edit the generated Python class if needed (via `write_file`)
4. Re-import: `plugin ccreator import /path/to/circuit.py`
5. Or use a template: `plugin ccreator template ResistiveADCFrontend`
