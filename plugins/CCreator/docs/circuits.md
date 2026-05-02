# Defining Circuits

CCreator circuits are plain Python classes wrapped by decorators. The decorator injects the framework base class, validation, and the `.export` / `.switch_pdk()` / `.optimize()` API.

## Realistic Analog Circuits

These are component-level netlists — MOSFETs, resistors, capacitors — built imperatively using a `NetlistBuilder`.

### Minimal Example

```python
from ccreator import realistic, Port

@realistic.analog
class Inverter:
    ports = [
        Port('in',  'input',  'analog'),
        Port('out', 'output', 'analog'),
        Port('vdd', 'inout',  'voltage'),
        Port('vss', 'inout',  'voltage'),
    ]

    def build(self, n):
        n.MOSFET('Mp', 'out', 'in', 'vdd', 'vdd', 'sky130_fd_pr__pfet_01v8', W='2u', L='0.15u')
        n.MOSFET('Mn', 'out', 'in', 'vss', 'vss', 'sky130_fd_pr__nfet_01v8', W='1u', L='0.15u')
```

### The `build(self, n)` Method

`n` is a `NetlistBuilder`. It provides:

| Method | Signature | SPICE equivalent |
|--------|-----------|-----------------|
| `n.MOSFET` | `(name, drain, gate, source, bulk, model, **kwargs)` | `Mname drain gate source bulk model W=... L=...` |
| `n.R` | `(name, n1, n2, value)` | `Rname n1 n2 value` |
| `n.C` | `(name, n1, n2, value)` | `Cname n1 n2 value` |
| `n.L` | `(name, n1, n2, value)` | `Lname n1 n2 value` |
| `n.V` | `(name, n1, n2, **kwargs)` | `Vname n1 n2 dc=... ac=...` |
| `n.I` | `(name, n1, n2, **kwargs)` | `Iname n1 n2 dc=...` |
| `n.BJT` | `(name, collector, base, emitter, model, **kwargs)` | `Qname c b e model` |
| `n.raw` | `(spice_line)` | Appends raw SPICE text |

`**kwargs` are passed directly to PySpice. For MOSFETs, common kwargs are `W`, `L`, `M` (multiplier), `nf` (fingers), `ad`, `as`.

Node names are strings. They become net names in the SPICE netlist. The `ports` list declares which nodes are external pins.

### Port Definition

```python
from ccreator.core.port import Port

Port(name, direction, kind, width=1)
```

| Field | Values | Meaning |
|-------|--------|---------|
| `name` | any string | Net name exposed as a pin |
| `direction` | `'input'`, `'output'`, `'inout'` | Signal direction (for symbol generation) |
| `kind` | `'voltage'`, `'current'`, `'logic'`, `'analog'` | Signal type |
| `width` | int (default 1) | Bus width (for digital) |

### Parameters

Circuits can accept parameters at instantiation:

```python
@realistic.analog
class ResistorDivider:
    ports = [Port('in', 'input', 'analog'), Port('out', 'output', 'analog'), Port('gnd', 'inout', 'voltage')]
    parameters = {'r1': 10e3, 'r2': 10e3}

    def build(self, n):
        n.R('R1', 'in',  'out', self.r1)
        n.R('R2', 'out', 'gnd', self.r2)

# Use default parameters
div = ResistorDivider()

# Override at instantiation
div = ResistorDivider(r1=20e3, r2=5e3)
```

### SPICE Export

```python
amp = FoldedCascode()

# Export as SPICE subcircuit string
from ccreator.realistic._analog.spice_export import to_spice_string
print(to_spice_string(amp))

# Or write to file
amp.export.spice('output/folded_cascode.lib')
```

Output:
```spice
.subckt FoldedCascode inp inn out vdd vss
M1 tail1 inp vs vss sky130_fd_pr__nfet_01v8 W=5u L=0.5u
M2 tail2 inn vs vss sky130_fd_pr__nfet_01v8 W=5u L=0.5u
M3 tail1 tail1 vdd vdd sky130_fd_pr__pfet_01v8 W=10u L=0.5u
M4 out tail1 vdd vdd sky130_fd_pr__pfet_01v8 W=10u L=0.5u
M5 vs vbias vss vss sky130_fd_pr__nfet_01v8 W=20u L=1u
.ends FoldedCascode
```

---

## Behavioral Analog Circuits

These define circuits as transfer functions — ideal, PDK-independent, simulated with SciPy.

### Minimal Example

```python
from ccreator import behavioral, Port
import sympy as sp

@behavioral.analog
class IdealLowpass:
    ports = [Port('in', 'input', 'analog'), Port('out', 'output', 'analog')]
    parameters = {'f3db': 1e6, 'gain': 1.0}

    def transfer_function(self, s):
        wc = 2 * sp.pi * self.f3db
        return self.gain * wc / (s + wc)

    def equations(self, t, y, u):
        """State-space ODE for transient simulation."""
        wc = 2 * 3.14159 * self.f3db
        dydt = -wc * y[0] + wc * self.gain * u
        return [dydt]
```

### Required Methods

| Method | Purpose | Used by |
|--------|---------|---------|
| `transfer_function(self, s)` | SymPy expression in Laplace variable `s` | AC simulation, Verilog-A export |
| `equations(self, t, y, u)` | ODE system `dy/dt = f(t, y, u)` | Transient simulation |

### Verilog-A Export

```python
filt = IdealLowpass(f3db=1e6)
filt.export.veriloga('output/lowpass.va')
```

The codegen extracts numerator/denominator coefficients from the transfer function and generates a synthesizable Verilog-A module with `laplace_nd()`.

---

## Behavioral Digital Circuits

For digital blocks defined as Verilog RTL:

```python
from ccreator import behavioral, Port

@behavioral.digital
class Counter4bit:
    ports = [
        Port('clk', 'input', 'logic'),
        Port('rst', 'input', 'logic'),
        Port('count', 'output', 'logic', width=4),
    ]

    rtl = """
    module Counter4bit(input clk, input rst, output reg [3:0] count);
        always @(posedge clk or posedge rst)
            if (rst) count <= 0;
            else count <= count + 1;
    endmodule
    """
```

Or load from a file:

```python
@behavioral.digital
class MyModule:
    ports = [...]
    rtl_file = 'hdl/my_module.v'  # relative to the Python file
```

### Exports

```python
counter = Counter4bit()
counter.export.verilog('output/counter.v')                      # write RTL
counter.export.synthesize('output/counter_synth.v', liberty='cells.lib')  # Yosys synthesis
```

---

## Realistic Digital Circuits

Same as behavioral digital (Verilog RTL source), but wrapped with `@realistic.digital`. The distinction exists for type-level dispatch — realistic digital circuits are expected to target a specific standard cell library.

```python
from ccreator import realistic, Port

@realistic.digital
class ShiftRegister:
    ports = [...]
    rtl_file = 'hdl/shift_reg.v'
```

---

## Simulation

All circuits can be simulated through the unified `simulate()` proxy:

```python
from ccreator import simulate

amp = FoldedCascode()

# AC analysis
ac_result = simulate(amp).ac(fstart=1, fstop=1e9, points=200)
ac_result.plot()
ac_result.report()

# Transient analysis
tran_result = simulate(amp).tran(step=1e-9, end=1e-6)

# DC sweep
dc_result = simulate(amp).dc(start=0, stop=1.8, step=0.01)
```

### Simulator Selection

The simulator is auto-selected based on circuit type:

| Circuit type | Simulator | Backend |
|---|---|---|
| `BehavioralAnalogCircuit` | `ScipyAnalogSimulator` | `scipy.signal.freqs`, `solve_ivp` |
| `RealisticAnalogCircuit` | `PySpiceSimulator` | ngspice subprocess |
| `BehavioralDigitalCircuit` | `VerilatorSimulator` | Verilator C++ testbench |
| `RealisticDigitalCircuit` | `VerilatorSimulator` | Verilator C++ testbench |

### SimulationResult

Every simulation returns a `SimulationResult`:

```python
@dataclass
class SimulationResult:
    kind: str            # 'ac', 'dc', 'tran', 'functional', 'rtl'
    circuit: object      # the circuit that produced this result
    x: np.ndarray        # frequency (Hz) or time (s) axis
    y: dict[str, np.ndarray]  # probe name -> data array
    metadata: dict       # simulator-specific info

    def metrics(self, probe=None) -> Metrics: ...
    def plot(self, **kwargs): ...
    def report(self): ...
```

### Comparing Results

```python
from ccreator import simulate, compare

r1 = simulate(behavioral_amp).ac(fstart=1, fstop=1e9)
r2 = simulate(realistic_amp).ac(fstart=1, fstop=1e9)

comp = compare(r1, r2)
comp.plot()       # overlaid plots
comp.report()     # max error, f3dB difference, etc.
print(comp.metrics())
# {'max_error_db': 2.3, 'mean_error_db': 0.8, 'f3db_r1': 1.2e6, 'f3db_r2': 1.1e6}
```
