# Transistor Optimization

`circuit.optimize()` runs Bayesian optimization of MOSFET gm/Id ratios to meet testbench specifications. It uses Gaussian Process surrogates with Expected Improvement acquisition (via BoTorch) and evaluates candidates by running ngspice simulations.

## Quick Start

```python
from ccreator import realistic, Port, testbench

@realistic.analog
class OTA:
    ports = [Port('inp', 'input', 'analog'), Port('inn', 'input', 'analog'),
             Port('out', 'output', 'analog'),
             Port('vdd', 'inout', 'voltage'), Port('vss', 'inout', 'voltage')]

    def build(self, n):
        n.MOSFET('M1', 'd1', 'inp', 'vs', 'vss', 'sky130_fd_pr__nfet_01v8', W='5u', L='0.5u')
        n.MOSFET('M2', 'd2', 'inn', 'vs', 'vss', 'sky130_fd_pr__nfet_01v8', W='5u', L='0.5u')
        n.MOSFET('M3', 'd1', 'd1',  'vdd', 'vdd', 'sky130_fd_pr__pfet_01v8', W='10u', L='0.5u')
        n.MOSFET('M4', 'out', 'd1',  'vdd', 'vdd', 'sky130_fd_pr__pfet_01v8', W='10u', L='0.5u')
        n.MOSFET('M5', 'vs', 'vbias','vss', 'vss', 'sky130_fd_pr__nfet_01v8', W='20u', L='1u')

@testbench
class OTATestbench:
    def build(self, tb):
        tb.instance(OTA(), 'dut', {'inp': 'inp', 'inn': 'inn', 'out': 'out', 'vdd': 'vdd', 'vss': 'gnd'})
        tb.V('vdd', 'vdd', 'gnd', dc=1.8)
        tb.V('vcm', 'inn', 'gnd', dc=0.9)
        tb.V('vin', 'inp', 'gnd', dc=0.9, ac=1)
        tb.probe('out')
        tb.ac(fstart=1, fstop=1e9, points=200)

my_tb = OTATestbench()

ota = OTA()
result = ota.optimize(
    targets=[
        {'name': 'gain_db',      'kind': 'maximize'},
        {'name': 'phase_margin', 'kind': '>=', 'target': 60.0},
        {'name': 'ugbw',         'kind': '>=', 'target': 10e6},
        {'name': 'power_uw',     'kind': '<=', 'target': 200.0},
    ],
    testbench=my_tb,
    model_lib='/path/to/sky130_fd_pr__tt.pm3.spice',
    vdd=1.8,
    max_iter=100,
    initial_samples=30,
)

if result.best_params:
    print("Best design:")
    for inst, params in result.best_params.items():
        print(f"  {inst}: gm/Id={params['gm/Id']:.1f}, W={params['W_um']:.2f}um, Av={params['intrinsic_gain']:.1f}")
```

## API

```python
circuit.optimize(
    targets: list[dict],          # Specification list
    testbench=None,               # CCreator testbench instance
    model_lib: str = '',          # Path to SPICE model library
    vdd: float = 1.8,            # Supply voltage
    max_iter: int = 50,          # Maximum optimization iterations
    initial_samples: int = 20,   # LHS samples before GP fitting
    seed: int = 42,              # Random seed
    cache_dir: str | None = None,  # Characterization cache directory
    callback=None,               # Progress callback(iteration, observation)
) -> OptimizationResult
```

### Target Specification

Each target is a dict with:

| Key | Type | Description |
|-----|------|-------------|
| `name` | str | Measurement name (must match `.meas` output from testbench) |
| `kind` | str | One of: `"maximize"`, `"minimize"`, `">="`, `"<="`, `"=="`, `"range"` |
| `target` | float | Target value (for `>=`, `<=`, `==`) |
| `target_upper` | float | Upper bound (for `"range"` kind) |
| `weight` | float | Objective weight (default 1.0) |

Targets with `kind` = `"maximize"` or `"minimize"` become **objectives** (what the optimizer tries to improve). All others become **constraints** (must be satisfied for a solution to be feasible).

### OptimizationResult

```python
@dataclass
class OptimizationResult:
    best_params: dict | None       # {instance: {gm/Id, W_um, L, Vgs, intrinsic_gain}}
    best_objectives: np.ndarray | None
    observations: list[Observation]  # all evaluated points
    lookups: dict[str, GmIdLookup]   # cached LUTs
    iterations: int
    feasible_count: int
```

## How It Works

### Design Variables

The optimizer does **not** directly optimize W. Instead:

- **gm/Id ratio** per transistor (continuous, bounded by `gmid_min`/`gmid_max`, default 3–25 V^-1)
- **L is fixed** (never changed during optimization — this makes characterization cacheable)
- **W is derived** from the gm/Id lookup table: `W = Id_target / Jd(gm/Id)`

This is the gm/Id methodology: the designer's knob is the efficiency-speed tradeoff (gm/Id), not raw device dimensions.

### Optimization Loop

```
1. CHARACTERIZE
   For each unique (model, L) pair in the circuit:
     - Run GmIDVisualizer C++ FFI or ngspice Vgs sweep
     - Build interpolation tables: gm/Id -> Jd, Vgs, Av
     - Cache as .npz

2. INITIALIZE
   - Generate N latin-hypercube samples in [gmid_min, gmid_max]^k space
   - Evaluate each by running the testbench in ngspice
   - Collect objective values and constraint violations

3. BAYESIAN LOOP (for max_iter iterations)
   a. Fit a SingleTaskGP (Gaussian Process) to all valid observations
   b. Optimize LogExpectedImprovement acquisition function
      (10 random restarts, 256 raw samples)
   c. Decode candidate: for each transistor, look up W from gm/Id
   d. Substitute W, L into testbench netlist
   e. Run ngspice, parse .meas results
   f. Score: objectives + constraint violations
   g. Feed observation back to GP

4. RETURN best feasible design
```

### Why gm/Id (Not W)?

Directly optimizing W creates a high-dimensional, poorly-conditioned search space. The gm/Id methodology reduces dimensionality:

| Direct sizing | gm/Id methodology |
|---|---|
| Variables: W1, W2, ..., Wn (each 1um–1000um) | Variables: gmid1, gmid2, ..., gmidn (each 3–25) |
| Correlated: changing W changes Id, gm, gds | Decoupled: gm/Id directly controls speed-power tradeoff |
| Need bias point extraction per iteration | Bias point encoded in lookup table |
| L must also be optimized | L is fixed (architecture decision) |

The optimizer explores a compact, well-bounded [3, 25]^n space instead of a sprawling [1e-6, 1e-3]^(2n) space.

### Bayesian Optimization

The backend uses [BoTorch](https://botorch.org/) (built on GPyTorch and PyTorch):

- **Surrogate:** `SingleTaskGP` with `Standardize` outcome transform
- **Acquisition:** `LogExpectedImprovement` (numerically stable in log-space)
- **Optimization:** `optimize_acqf` with 10 restarts, 256 raw samples
- **Initial samples:** Latin Hypercube Sampling via `scipy.stats.qmc.LatinHypercube`

Constraints are handled by the `Observation.is_feasible` flag — the best solution must satisfy all constraints.

## MOSFET Extraction

When you call `circuit.optimize()`, CCreator automatically:

1. Builds the circuit's netlist via `build(n)`
2. Scans PySpice elements for MOSFET instances (lines starting with `M`)
3. Extracts model name, L from parameters
4. Infers kind (`nmos`/`pmos`) from model name
5. Creates a `Transistor` for each with default bounds (gm/Id: 3–25, nf: 1–20)

No manual problem definition needed.

## Progress Callback

```python
def my_callback(iteration, obs):
    status = "FEASIBLE" if obs.is_feasible else "infeasible"
    print(f"Iter {iteration}: [{status}] obj={obs.objectives} meas={obs.measurements}")

result = ota.optimize(
    targets=[...],
    testbench=my_tb,
    model_lib='...',
    callback=my_callback,
)
```

## Direct Subpackage Usage

For full control, use the optimizer directly:

```python
from ccreator.gmid_optimizer import Problem, Transistor, Specification, SpecKind, GMIDOptimizer
from ccreator.gmid_optimizer.problem import Testbench
from pathlib import Path

transistors = [
    Transistor(instance='M1', model='sky130_fd_pr__nfet_01v8', kind='nmos', L=0.5e-6, gmid_min=5, gmid_max=20),
    Transistor(instance='M2', model='sky130_fd_pr__nfet_01v8', kind='nmos', L=0.5e-6, gmid_min=5, gmid_max=20),
    Transistor(instance='M3', model='sky130_fd_pr__pfet_01v8', kind='pmos', L=0.5e-6, gmid_min=5, gmid_max=20),
]

specs = [
    Specification(name='gain_db', kind=SpecKind.MAXIMIZE, weight=1.0),
    Specification(name='phase_margin', kind=SpecKind.GREATER_EQUAL, target=60.0),
]

testbenches = [
    Testbench(path='tb_ota.sp', name='AC', specs=specs, timeout_s=30.0),
]

problem = Problem(transistors=transistors, testbenches=testbenches)

optimizer = GMIDOptimizer(
    problem=problem,
    model_lib_path='/path/to/models.lib',
    vdd=1.8,
    cache_dir=Path('.gmid_cache'),
    max_iter=100,
    initial_samples=30,
)

result = optimizer.run()
```

## Configuration from .chn Files

The optimizer can also read its configuration from a `PLUGIN Optimizer` block embedded in a `.chn` schematic file:

```
PLUGIN Optimizer
  version: 1
  tb.0: /path/to/testbench.chn_tb
  transistor.M1: model=sky130_fd_pr__nfet_01v8 kind=nmos L=5.0000e-07 gmid_min=5 gmid_max=20
  transistor.M2: model=sky130_fd_pr__nfet_01v8 kind=nmos L=5.0000e-07 gmid_min=5 gmid_max=20
  obj.gain_db: kind=maximize target=0.0000e+00 weight=1.0000e+00
  obj.phase_margin: kind=geq target=6.0000e+01 weight=1.0000e+00
  settings.max_iter: 100
  settings.lhc_samples: 30
  settings.model_lib: /path/to/models.lib
  settings.vdd: 1.8
```

Parse it with:

```python
from ccreator.gmid_optimizer.config import parse_config, config_to_problem

with open('my_circuit.chn') as f:
    cfg = parse_config(f.read())

problem = config_to_problem(cfg)
```
