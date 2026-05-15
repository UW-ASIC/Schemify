# API Reference

Complete reference for all CCreator modules.

## Top-Level Exports (`ccreator`)

```python
import ccreator

ccreator.behavioral        # decorator module for behavioral circuits
ccreator.realistic         # decorator module for realistic circuits
ccreator.testbench         # @testbench decorator
ccreator.Port              # Port(name, direction, kind, width=1)
ccreator.simulate          # simulate(circuit) -> SimulatorProxy
ccreator.compare           # compare(r1, r2) -> ComparisonResult
ccreator.CircuitDefinitionError
ccreator.ToolNotFoundError
ccreator.SimulationError
```

---

## `ccreator.core.port.Port`

```python
@dataclass
class Port:
    name: str
    direction: Literal['input', 'output', 'inout']
    kind: Literal['voltage', 'current', 'logic', 'analog']
    width: int = 1
```

---

## `ccreator.core.circuit.BaseCircuit`

Base class for all circuits (injected by decorators).

### Methods

#### `export -> ExportProxy`

Property returning the export interface.

**Note:** `switch_pdk()` and `optimize()` have been removed.
PDK switching is handled by the PDKSwitcher plugin.
gm/Id optimization is handled by the core Schemify optimizer via host API.

---

## `ccreator.core.circuit.ExportProxy`

### Methods

#### `veriloga(path: str)`
Export behavioral analog circuit as Verilog-A.

#### `spice(path: str)`
Export realistic analog circuit as SPICE `.subckt`.

#### `verilog(path: str)`
Write digital RTL source to file.

#### `synthesize(output: str, liberty: str | None = None, sv2v: bool = False)`
Synthesize digital circuit via Yosys.

#### `schemify(path: str | None = None) -> list`
Export as component dicts using built-in minimal parser.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `path` | `str \| None` | `None` | Output directory. `None` = return objects without writing. |

**Returns:** List of component dicts.

**Note:** For full SPICE import with placement and routing, use the core
Schemify host API (spiceImport command) instead.

---

## `ccreator.simulate`

```python
def simulate(circuit: BaseCircuit) -> SimulatorProxy
```

### `SimulatorProxy` Methods

| Method | Signature | Circuit Types |
|--------|-----------|--------------|
| `ac` | `(fstart=1.0, fstop=1e6, points=200, variation='dec')` | Behavioral analog, Realistic analog |
| `dc` | `(start=0.0, stop=5.0, step=0.1)` | Behavioral analog, Realistic analog |
| `tran` | `(step=1e-6, end=1e-3, **kwargs)` | Behavioral analog, Realistic analog |
| `functional` | `(inputs: dict)` | Digital |
| `rtl` | `(cycles=100, clk_period_ns=10)` | Digital |

All return `SimulationResult`.

---

## `ccreator.core.simulation_result.SimulationResult`

```python
@dataclass
class SimulationResult:
    kind: Literal['ac', 'dc', 'tran', 'functional', 'rtl']
    circuit: object
    x: np.ndarray                    # frequency or time axis
    y: dict[str, np.ndarray]         # probe name -> data
    metadata: dict

    def metrics(self, probe=None) -> Metrics: ...
    def plot(self, **kwargs): ...
    def report(self): ...
```

---

## `ccreator.compare`

```python
def compare(r1: SimulationResult, r2: SimulationResult) -> ComparisonResult
```

```python
@dataclass
class ComparisonResult:
    r1: SimulationResult
    r2: SimulationResult

    def metrics(self) -> dict: ...   # max_error_db, mean_error_db, f3db_r1, f3db_r2
    def plot(self, **kwargs): ...
    def report(self): ...
```

---

## `ccreator.compare.metrics.Metrics`

```python
@dataclass
class Metrics:
    f3db: float | None
    max_error_db: float | None
    snr: float | None
    timing_errors: int | None
    functional_eq: bool | None
    extra: dict                     # circuit-specific metrics
```

---

## `ccreator.core.errors`

```python
class CircuitDefinitionError(Exception):
    def __init__(self, circuit_name: str, reason: str): ...

class ToolNotFoundError(Exception):
    def __init__(self, tool_name: str, install_hint: str): ...

class SimulationError(Exception):
    def __init__(self, circuit_name: str, tool: str, stderr: str): ...
```

---

## `ccreator.realistic._analog.netlist_builder.NetlistBuilder`

```python
class NetlistBuilder:
    def __init__(self, name, ground=None, _pyspice_obj=None): ...

    def R(self, name, n1, n2, value): ...
    def C(self, name, n1, n2, value): ...
    def L(self, name, n1, n2, value): ...
    def V(self, name, n1, n2, **kwargs): ...
    def I(self, name, n1, n2, **kwargs): ...
    def MOSFET(self, name, drain, gate, source, bulk, model, **kwargs): ...
    def BJT(self, name, collector, base, emitter, model, **kwargs): ...
    def raw(self, spice_line: str): ...
```
