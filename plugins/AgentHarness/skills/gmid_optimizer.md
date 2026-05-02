# GMIDOptimizer Plugin

Bayesian gm/Id circuit optimizer. Sizes MOSFETs by optimizing testbench measurements.

## Command

```
plugin gmidopt
```

Opens the optimizer panel. The plugin is primarily GUI-driven (panel buttons and sliders).

## Flow

1. Open a `.chn` component schematic
2. Plugin auto-detects MOSFETs from schematic instances
3. Scans project directory for linked `.chn_tb` testbenches
4. Parses `.meas` directives from testbenches as optimization targets
5. Configure optimization parameters (gm/Id range, nf range per transistor)
6. Run Bayesian optimization (GP surrogate + Expected Improvement)
7. Apply best results to schematic

## Panel Views

### Setup View
- **Transistor list**: auto-detected MOSFETs with configurable ranges
  - gm/Id range (default 5-20)
  - nf range (default 1-10)
  - Enable/disable per transistor
- **Targets**: parsed `.meas` directives with:
  - Kind: maximize, minimize, geq, leq, range
  - Weight: relative importance
  - Target value
- **Settings**: max iterations, LHC samples, VDD

### Running View
- Progress bar and iteration log

### History View
- Past optimization runs with best results
- Apply best result button

## MOSFET Detection

Recognizes these schematic symbols:
`nmos4`, `pmos4`, `nmos3`, `pmos3`, `nmos`, `pmos`

## Testbench Requirements

Testbenches (`.chn_tb` files) must contain `.meas` directives:
```
measures:
  measure.dc_gain: .meas ac dc_gain max vdb(out)
  measure.gbw: .meas ac gbw when vdb(out)=0
  measure.pm: .meas ac pm find vp(out) when vdb(out)=0
```

## Persistence

Optimization history is stored in the `PLUGIN Optimizer` block of the `.chn` file:
```
PLUGIN Optimizer
  history: [{"run_id": 1, "best_obj": 0.95, ...}]
```

## Workflow for LLM

1. Create a component schematic with MOSFETs
2. Create a testbench with `.meas` directives
3. Open the component: `plugin gmidopt` to launch optimizer
4. The optimizer handles sizing automatically
5. Apply best results from the history view

Since GMIDOptimizer is GUI-driven, the LLM's role is typically:
- Creating the schematic and testbench files
- Setting up `.meas` directives in testbenches
- Opening the optimizer via `plugin gmidopt`
