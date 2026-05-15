# simulation

SPICE netlist generation, simulation result types, waveform post-processing, and gm/Id MOSFET sizing optimizer.

## Functionality

Three concerns, loosely layered:

1. **Netlist generation** -- Schematic model to SPICE text (raw netlist or PySpice Python script). Handles subcircuit wrapping, `spice_format` template expansion, PDK preamble injection, code blocks, analyses, and measures.
2. **SPICE intermediate representation** -- Typed structs for every SPICE construct (components, analyses, sweeps, measures, UQ distributions). Builder API on `SpiceIF.Netlist`. Emission targets ngspice; other backends are type-defined but emission is ngspice-only.
3. **Results & post-processing** -- `SimResult`/`Waveform` containers plus waveform arithmetic (magnitude dB, phase, bandwidth, UGF, phase margin, slew rate, settling time, min/max).
4. **gm/Id optimizer** -- Standalone MOSFET sizing via gm/Id methodology. Cubic spline LUTs over characterization data, analytical EKV fallback, LHS exploration + adaptive grid refinement. Zero heap allocation (all fixed-capacity inline storage).

Removed: `VerilogNetlist.zig` (zero callers), `RawFile.zig` (zero callers).

## Public API

### lib.zig re-exports

| Symbol | Source | Purpose |
|--------|--------|---------|
| `SpiceIF` | `SpiceIF.zig` | SPICE IR namespace |
| `Netlist` | `Netlist.zig` | Netlist generation namespace |
| `results` | `results.zig` | Result types + waveform math |
| `optimizer` | `optimizer/lib.zig` | gm/Id optimizer namespace |

### Netlist.zig

| Symbol | Signature | Purpose |
|--------|-----------|---------|
| `emitSpice` | `fn(model: anytype, gpa: Allocator, pdk: ?*const Devices.Pdk) ![]u8` | Schematic model to raw SPICE netlist string |
| `emitPySpice` | `fn(model: anytype, gpa: Allocator, pdk: ?*const Devices.Pdk) ![]u8` | Schematic model to PySpice Python script |

### SpiceIF.zig

| Symbol | Kind | Purpose |
|--------|------|---------|
| `Value` | `union(enum){literal,param,expr}` | Scalar parameter value (numeric, named param, expression) |
| `ParamOverride` | struct | Name+Value pair for instance parameter overrides |
| `SpiceComponent` | `union(enum)` | Typed emittable device (resistor, capacitor, inductor, diode, mosfet, bjt, jfet, independent_source, behavioral, vcvs/vccs/ccvs/cccs, subcircuit, raw) |
| `emitComponent` | `fn(writer, SpiceComponent) !void` | Write one component to any writer |
| `SourceWaveform` | `union(enum)` | DC, AC, SIN, PULSE, PWL, SFFM, EXP, PAT |
| `IndependentSource` | struct | V/I source with optional waveform |
| `emitIndependentSource` | `fn(writer, IndependentSource) !void` | Emit source with waveform |
| `Analysis` | `union(enum)` | OP, DC, AC, TRAN, NOISE, SENS, TF, PZ, DISTO, PSS, SP, HB, MPDE, FOUR |
| `emitAnalysisNgspice` | `fn(writer, Analysis) !void` | Emit analysis directive for ngspice |
| `SweepKind` | `enum{lin,dec,oct}` | Frequency/parameter sweep type |
| `StepSweep` | struct | Parameter step sweep (lin/dec/oct/list) |
| `Distribution` | `union(enum){normal,uniform,lognormal}` | Statistical distribution for UQ |
| `Sampling` | struct | Monte Carlo / LHS sampling config |
| `EmbeddedSampling` | struct | Embedded sampling config |
| `PCE` | struct | Polynomial Chaos Expansion config |
| `DataTable` | struct | Tabular parameter data |
| `Sweep` | `union(enum){step,sampling,embedded_sampling,pce,data}` | Top-level sweep variant |
| `MeasureMode` | `enum{tran,ac,dc,noise}` | Measure domain |
| `Measure` | struct | Measurement spec (trig/targ, find, min/max, when) |
| `emitMeasureShared` | `fn(writer, Measure) !void` | Emit .meas directive |
| `PrintDirective` | struct | .print directive |
| `emitPrintShared` | `fn(writer, PrintDirective) !void` | Emit .print directive |
| `Netlist` | struct | Full IR container with builder API (`addParam`, `addAnalysis`, `addComponent`, `addSource`, `addSweep`, `addMeasure`, `addRaw`) and `emit`/`emitTo` |

### results.zig

| Symbol | Kind | Purpose |
|--------|------|---------|
| `Severity` | `enum(u8)` | info/warning/error/fatal |
| `SimError` | struct | Error with line number, severity, message |
| `Waveform` | struct | x/y data + optional y_imag for complex; `len()`, `isComplex()` |
| `SimStatus` | `enum(u8)` | success, convergence_error, syntax_error, timeout, backend/pyspice/python_not_found, unknown_error |
| `OpPoint` | struct | Named scalar (name, value, unit) |
| `SimResult` | struct | Top-level result: status, waveforms, op_values, errors, raw_output; `isSuccess()`, `waveformByName()` |
| `Measurement` | struct | Scalar extraction result (name, value, unit, valid) |
| `magnitudeDb` | `fn(arena, *Waveform) !Waveform` | Complex waveform to dB magnitude |
| `phaseDeg` | `fn(arena, *Waveform) !Waveform` | Complex waveform to phase (degrees) |
| `bandwidth3dB` | `fn(*Waveform) Measurement` | Find -3dB frequency from dB response |
| `unityGainFreq` | `fn(*Waveform) Measurement` | Find 0dB crossing frequency |
| `phaseMargin` | `fn(gain_wf, phase_wf) Measurement` | 180 + phase at UGF |
| `dcGain` | `fn(*Waveform) Measurement` | First point of magnitude response |
| `slewRate` | `fn(*Waveform) Measurement` | Max \|dy/dx\| from transient response |
| `settlingTime` | `fn(*Waveform, tolerance) Measurement` | Time to enter tolerance band of final value |
| `minMax` | `fn(*Waveform) {min,max,min_x,max_x}` | Extrema with x-coordinates |
| `extractAcMetrics` | `fn(arena, *SimResult, node) ![4]Measurement` | Batch: [gain, BW, PM, UGF] |

### optimizer/

| Symbol | Kind | Purpose |
|--------|------|---------|
| `MosfetKind` | `enum(u1){nmos,pmos}` | Transistor polarity |
| `Transistor` | struct | MOSFET with fixed L, gm/Id bounds, finger count |
| `Resistor` | struct | Tunable resistor with R bounds and optional step |
| `Parameter` | struct | Generic tunable parameter with bounds |
| `SpecKind` | `enum(u3)` | minimize/maximize/greater_equal/less_equal/equal/range |
| `Specification` | struct | Performance spec; `toConstraint(measured) -> f64` |
| `Problem` | struct | Full problem definition: transistors, resistors, parameters, specs; `designVarCount()`, `objectiveCount()`, `getBounds()`, `applyDesignVector()` |
| `DeviceResult` | struct | Per-transistor result: gmid, W, L, nf, Vgs, Id, gm, gds, fT, intrinsic_gain |
| `Observation` | struct | Single sweep evaluation: x, objectives, constraints; `isFeasible()`, `objectiveSum()` |
| `OptimizationResult` | struct | Full result: devices, best_x, iterations, converged; `totalPower(vdd)`, `totalArea()` |
| `CubicSpline` | struct | Natural cubic spline, inline storage (max 1024 knots), O(log n) eval; `build()`, `eval()`, `evalExtrapolate()`, `derivative()` |
| `GmIdLookup` | struct | Interpolation LUT for one (model, L) pair; `buildFromArrays()`, `lookupVgs/Jd/IntrinsicGain/Gm/Gds/Ft()`, `computeW()`, `computeMetrics()` |
| `DeviceMetrics` | struct | W_um, Vgs, Id, gm, gds, fT, intrinsic_gain, gmid |
| `Optimizer` | struct | High-level orchestrator; `init()`, `run() -> OptimizationResult` |
| `optimizeSingle` | fn | Convenience: single-transistor optimization |
| `sweepGmId` | fn | Fill arrays with metrics at evenly-spaced gm/Id points |
| `SweepEngine` | struct | LHS + adaptive grid refinement engine; `init()`, `run()`, `bestObservation()` |
| `SweepConfig` | struct | Sweep parameters (samples, iterations, seed, sim_callback) |
| `SimCallback` | `*const fn(x, problem, obj_out, con_out) bool` | External SPICE simulation hook |
| `FixedList(T, N)` | generic struct | Inline fixed-capacity list (no heap) |
| `cleanForInterp` | fn | Sort, deduplicate, ensure strict monotonicity for spline input |
| Analytical functions | `analyticalJd`, `analyticalVgs`, `analyticalIntrinsicGain`, `analyticalFt` | EKV/ACM fallback when no characterization data |

## Internal Structure

| File | LOC (approx) | Purpose |
|------|-------------|---------|
| `lib.zig` | 12 | Re-exports, comptime validation |
| `Netlist.zig` | 852 | SPICE + PySpice emission from schematic model; template expansion (`@token`, `@@pin`); analysis parsing; subcircuit call emission; code block ordering |
| `SpiceIF.zig` | 520 | SPICE IR types (components, analyses, sweeps, measures, UQ); `Netlist` builder+emitter; ngspice `.control` section generation |
| `results.zig` | 458 | SimResult/Waveform containers; waveform arithmetic; scalar measurement extraction; linear interpolation |
| `optimizer/lib.zig` | 360 | `Optimizer` orchestrator; `optimizeSingle`/`sweepGmId` convenience fns; tests |
| `optimizer/types.zig` | 486 | Problem definition types; `FixedList`; constraint evaluation |
| `optimizer/gmid.zig` | 678 | `CubicSpline` (Thomas algorithm); `GmIdLookup` with 6 splines; EKV analytical model; `cleanForInterp` |
| `optimizer/sweep.zig` | 554 | `SweepEngine`; LHS generation; grid search; analytical evaluation; metric matching |

## Dependencies

- **schematic** -- `types.Property`, `types.Conn`, `types.Net`, `types.DeviceKind`, `devices.Devices`, `helpers`
- **std** -- `mem`, `fmt`, `math`, `io`, `debug`, `Random.Xoshiro256`, `sort`

No dependency on: gui, commands, plugins, import, agent, settings, utility.

The optimizer submodule has zero external dependencies (pure `std` only).

## Gaps

### Missing Features

| Gap | Impact | Notes |
|-----|--------|-------|
| **No simulation execution** | Cannot run SPICE from Zig | Module generates netlists and holds result types, but has no process spawning, IPC, or shared-library binding to any simulator. Simulation runs happen externally (PySpice Python side). |
| **No raw file parser** | Cannot load `.raw` waveform files | `RawFile.zig` was deleted (zero callers). No replacement exists. SimResult/Waveform structs exist but nothing populates them from simulator output. |
| **No backend abstraction** | Locked to ngspice syntax | `emitAnalysisNgspice` is the only emission path. HB and MPDE emit "UNSUPPORTED" comments. Xyce, Spectre, HSPICE would need parallel emitters. SpiceIF types already carry enough info to support them. |
| **No corner/PVT analysis** | No process-voltage-temperature sweeps | The `Sweep` union has `sampling` and `data` variants that could represent corners, but no corner definition type or automated corner matrix exists. |
| **No Monte Carlo orchestration** | Sampling types exist, no runner | `Sampling`, `Distribution`, `EmbeddedSampling`, `PCE` are defined in SpiceIF but never constructed or consumed anywhere in the module. The ngspice control section emitter handles them, but nothing builds them. |
| **No yield estimation** | No statistical post-processing | No pass/fail counting, sigma estimation, or histogram binning over Monte Carlo results. |
| **No mismatch analysis** | No device mismatch modeling | No Pelgrom model, no local variation parameters. |
| **No result caching** | Repeated netlist generation is redundant | No hash-based cache to skip regeneration when schematic hasn't changed. |
| **No incremental netlisting** | Full regeneration every time | `emitSpice` walks all instances unconditionally. No dirty tracking. |
| **No back-annotation** | No layout parasitics path | No RC extraction import, no post-layout simulation support. |
| **No noise analysis helpers** | Noise analysis exists but no post-processing | `AnalysisNoise` emits correctly, but `results.zig` has no noise-specific measurement (input-referred noise, spot noise, integrated noise). |
| **No stability analysis** | Phase/gain margin only via manual waveform math | No Bode plot automation, no loop-breaking injection, no Middlebrook method. |
| **No sensitivity post-processing** | `.sens` emits but no result parsing | Sensitivity results would need dedicated extraction. |
| **No waveform database** | In-memory only | No persistent storage, no waveform viewer protocol, no cross-session comparison. |
| **No optimizer serialization** | Problem/Result are not serializable | Cannot save/load optimization runs. Fixed inline arrays make JSON round-tripping awkward. |
| **No multi-objective Pareto** | Single weighted sum | `objectiveSum()` reduces all objectives to one scalar. No Pareto front tracking, no NSGA-II or similar. |
| **No temperature-aware LUTs** | GmIdLookup is single-temperature | Characterization at multiple temperatures would need a 2D lookup (gmid, T). |

### API Issues

| Issue | Location | Detail |
|-------|----------|--------|
| **`emitSpice`/`emitPySpice` take `anytype` model** | `Netlist.zig:29,192` | Duck-typed on field layout of `Schemify.zig`. No interface, no compile error messages if fields are missing. Caller gets cryptic "no such field" deep in the function. |
| **`emitPySpice` ignores `pdk` parameter** | `Netlist.zig:195` | `_ = pdk` -- marked "reserved for future" but the function signature promises PDK-awareness it doesn't deliver. |
| **Two `Netlist` types** | `Netlist.zig` (file) vs `SpiceIF.Netlist` (struct) | Same name, completely different things. `Netlist.emitSpice` generates from schematic; `SpiceIF.Netlist` is a builder IR. Confusing at import site. |
| **No constructors for SpiceIF.Netlist** | `SpiceIF.zig:329` | All fields default to empty. No `init()` that validates or sets title. Caller must remember to call `deinit()`. |
| **Hardcoded ngspice in Netlist.zig** | `Netlist.zig:817-819` | `shouldEmitCode` checks `simulator == "ngspice"` literally. No backend enum or config. |
| **Hardcoded ngspice in SpiceIF.Netlist.emitTo** | `SpiceIF.zig:387` | `emitTo` calls `emitAnalysisNgspice` unconditionally. No way to target another backend. |
| **PAT waveform unsupported** | `SpiceIF.zig:184` | `emitIndependentSource` emits a comment for PAT. Type exists but can't be used. |
| **`pyUnitValue` is a no-op for most inputs** | `Netlist.zig:396-405` | Only handles empty strings; all other values pass through raw. PySpice unit conversion is incomplete. |
| **`analyticalVgs` has dead code** | `gmid.zig:464-465` | `weak_term` is computed then discarded with `_ = weak_term`. |
| **Power metric uses `transistor.L` instead of Vdd** | `sweep.zig:412` | `matchMetric` for "power" computes `|Id| * L` which is dimensionally wrong. Should be `|Id| * Vdd`. |
| **Fixed-capacity limits are arbitrary** | `types.zig` | `max_design_vars=64`, `max_specs=64`, `max_name_len=63`. No overflow detection at runtime (debug assert only). |
| **`Observation` is 8+ KB** | `types.zig:358` | `[64]f64 * 3 + overhead` per observation, `SweepEngine` holds 16384 of them = ~130 MB stack. May cause stack overflow. |
| **No error returns from optimizer** | `optimizer/lib.zig:92` | `Optimizer.run()` returns `OptimizationResult` directly. Infeasibility, no-convergence, and degenerate problems are silent (just `converged=false`). |
