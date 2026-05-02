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

# Lazy-loaded subpackages
ccreator.pdk_switcherino   # PDK switching engine
ccreator.gmid_optimizer    # Bayesian optimization engine
ccreator.spice2schematic   # SPICE-to-schematic converter
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

#### `switch_pdk(target, source=None, use_lut=True) -> str`

Remap this circuit's SPICE netlist to a different PDK.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `target` | `str` | required | Target PDK name |
| `source` | `str \| None` | `None` | Source PDK (auto-detected if None) |
| `use_lut` | `bool` | `True` | Attempt gm/Id LUT remap |

**Returns:** Remapped SPICE netlist string.

**Raises:** `CircuitDefinitionError` if source PDK cannot be auto-detected.

#### `optimize(targets, testbench=None, model_lib='', ...) -> OptimizationResult`

Run Bayesian gm/Id optimization.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `targets` | `list[dict]` | required | Spec list (see [Optimization](optimization.md)) |
| `testbench` | testbench instance | `None` | Evaluation testbench |
| `model_lib` | `str` | `''` | Path to SPICE model library |
| `vdd` | `float` | `1.8` | Supply voltage |
| `max_iter` | `int` | `50` | Max optimization iterations |
| `initial_samples` | `int` | `20` | LHS initial samples |
| `seed` | `int` | `42` | Random seed |
| `cache_dir` | `str \| None` | `None` | Cache directory |
| `callback` | `callable \| None` | `None` | `callback(iteration, observation)` |

**Returns:** `OptimizationResult`

**Raises:** `CircuitDefinitionError` if no MOSFETs found.

#### `export -> ExportProxy`

Property returning the export interface.

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

#### `schemify(path: str | None = None) -> list[SchematicOutput]`
Export as Schemify `.chn` schematic.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `path` | `str \| None` | `None` | Output directory. `None` = return objects without writing. |

**Returns:** List of `SchematicOutput` objects.

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

---

## `ccreator.pdk_switcherino`

### Core Classes

```python
@dataclass
class PDK:
    name: str
    display: str
    vdd: float                           # supply voltage (V)
    l_min: float                         # min channel length (m)
    nfet: str                            # default NMOS model name
    pfet: str                            # default PMOS model name
    model_lib: str                       # path from PDK root to .lib
    corner: str = 'tt'
    corners: list[str] = ['tt']
    discrete_lengths: list[float] = []   # available L values (um)
    max_finger_w: float = 50e-6
    device_map: dict[str, str] = {}
    spice_preamble: str = ''
    root: Path | None = None
    volare_family: str | None = None

class PDKSwitcher:
    def __init__(self, source: PDK, target: PDK): ...
    def load_luts(self, src_nfet, src_pfet, tgt_nfet, tgt_pfet): ...
    def load_lut_families(self, src_nfet, src_pfet, tgt_nfet_family, tgt_pfet_family): ...
    def remap_device(self, model, w, l, nf=1, bias_current=0.0) -> RemapResult: ...
    def map_model(self, model) -> str: ...
    def remap_netlist(self, spice, bias_currents) -> str: ...

@dataclass
class RemapResult:
    model: str
    w: float
    l: float
    nf: int
    gmid: float
    av_src: float
    av_tgt: float
    warnings: list[str]
```

### Functions

```python
get_pdk(name: str) -> PDK
list_pdks() -> list[str]
register_pdk(pdk: PDK) -> None
auto_root(pdk: PDK) -> PDK            # returns copy with root auto-detected
get_lut(pdk, device, kind, L_um) -> DeviceLUT
sweep_device(pdk, device, kind, L_um) -> dict
installed_pdks() -> list[str]
pdk_root(name: str) -> Path | None
detect_volare() -> str | None
```

### Built-in PDKs

```python
from ccreator.pdk_switcherino import SKY130, IHP_SG13G2, GF180MCU
```

---

## `ccreator.gmid_optimizer`

### Core Classes

```python
@dataclass
class Transistor:
    instance: str
    model: str
    kind: str          # 'nmos' or 'pmos'
    L: float           # channel length (meters), FIXED during optimization
    gmid_min: float = 3.0
    gmid_max: float = 25.0
    nf_min: int = 1
    nf_max: int = 20

@dataclass
class Resistor:
    instance: str
    R_min: float = 100
    R_max: float = 100e3
    step: float | None = None

class SpecKind(Enum):
    MINIMIZE, MAXIMIZE, GREATER_EQUAL, LESS_EQUAL, EQUAL, RANGE

@dataclass
class Specification:
    name: str
    kind: SpecKind
    target: float = 0.0
    target_upper: float | None = None
    weight: float = 1.0

@dataclass
class Testbench:
    path: str
    name: str
    specs: list[Specification]
    timeout_s: float = 60.0

@dataclass
class Problem:
    transistors: list[Transistor]
    resistors: list[Resistor] = []
    parameters: list[Parameter] = []
    testbenches: list[Testbench] = []

class GMIDOptimizer:
    def __init__(self, problem, model_lib_path, vdd=1.8,
                 cache_dir=None, max_iter=50, initial_samples=20, seed=42): ...
    def characterize(self) -> None: ...
    def run(self, callback=None) -> OptimizationResult: ...

@dataclass
class OptimizationResult:
    best_params: dict | None
    best_objectives: np.ndarray | None
    observations: list[Observation]
    lookups: dict[str, GmIdLookup]
    iterations: int
    feasible_count: int
```

---

## `ccreator.spice2schematic`

### Top-Level Functions

```python
def parse(source: str) -> Netlist: ...
def place(elements, models) -> list[PlacedElement]: ...
def route(elements, placed) -> RouteResult: ...
def convert(netlist, source_path='', flatten=False) -> list[SchematicOutput]: ...
def import_spice(source, source_path='') -> list[SchematicOutput]: ...
```

### Key Data Classes

```python
@dataclass
class Netlist:
    title: str
    subckts: list[Subckt]
    top_elements: list[Element]
    models: list[Model]
    params: list[Param]
    globals: list[str]
    analyses: list[Analysis]
    measures: list[Measure]
    control_block: str | None

@dataclass
class Element:
    prefix: str            # lowercase: 'r', 'c', 'm', 'v', etc.
    name: str              # instance name
    nodes: list[str]       # net names
    value: str | None
    model: str | None
    params: list[Param]

@dataclass
class SchematicOutput:
    filename: str
    stype: str             # 'component' or 'testbench'
    name: str
    pins: list[Pin]
    components: list[Component]
    wires: list[Wire]
    power_symbols: list[dict]
    sym_props: dict[str, str]
    globals: list[str]
    plugin_block: dict[str, str]
    control_block: str | None

    def to_dict(self) -> dict: ...
    def to_json(self, indent=2) -> str: ...
    def write_json(self, output_dir) -> Path: ...
```
