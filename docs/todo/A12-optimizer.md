# A12: Optimizer

**Wave**: 4 (post-MVP)
**Depends on**: A9 (backend integration — needs working simulation)

## Goal
Circuit optimizer: gm/ID design tables, parameter sweeps, multi-objective NSGA-II optimization. Drives simulation backend to evaluate circuit performance.

## Branch
`feat/optimizer`

## Zig Reference Files
- `../Schemify/src/simulation/optimizer/lib.zig` — module exports
- `../Schemify/src/simulation/optimizer/types.zig` — optimizer types
- `../Schemify/src/simulation/optimizer/gmid.zig` — gm/ID lookup tables (MOSFETs)
- `../Schemify/src/simulation/optimizer/gmic.zig` — gm/IC lookup tables (BJTs)
- `../Schemify/src/simulation/optimizer/spline.zig` — cubic spline interpolation
- `../Schemify/src/simulation/optimizer/sweep.zig` — parameter sweep engine
- `../Schemify/src/simulation/optimizer/nsga2.zig` — NSGA-II multi-objective GA
- `../Schemify/src/simulation/optimizer/testbench.zig` — testbench management
- `../Schemify/src/simulation/optimizer/characterize.zig` — PDK characterization

## Crate/File Map

### sim (`crates/sim/src/`)
- NEW `optimizer/mod.rs` — public API
- NEW `optimizer/types.rs` — OptConfig, ObjectiveFn, Constraint, SearchSpace
- NEW `optimizer/gmid.rs` — gm/ID lookup table loading + interpolation
- NEW `optimizer/gmic.rs` — gm/IC lookup table loading + interpolation
- NEW `optimizer/spline.rs` — cubic spline interpolation (used by gmid/gmic)
- NEW `optimizer/sweep.rs` — parameter sweep engine
- NEW `optimizer/nsga2.rs` — NSGA-II algorithm (selection, crossover, mutation, Pareto ranking)
- NEW `optimizer/testbench.rs` — link .chn_tb files, extract measurements
- NEW `optimizer/characterize.rs` — PDK characterization (run sweeps, build lookup tables)

## Key Algorithms

### gm/ID Methodology
- Load pre-characterized lookup tables (gm/ID vs ID/W, fT, gds, etc.)
- Interpolate using cubic splines
- Given spec (gm, bandwidth, etc.) → find optimal (W/L, ID) for each transistor

### NSGA-II
- Population of parameter vectors
- Non-dominated sorting (Pareto fronts)
- Crowding distance for diversity
- Tournament selection, SBX crossover, polynomial mutation
- Each evaluation = modify schematic params → run sim → extract measurements

### Sweep Engine
- Define parameter ranges (min, max, steps)
- Cartesian product or latin hypercube sampling
- Run sim for each point
- Collect results in grid

## Checklist
- [ ] `optimizer/spline.rs`: cubic spline interpolation (build + evaluate)
- [ ] `optimizer/gmid.rs`: load gm/ID table from file, interpolate
- [ ] `optimizer/gmic.rs`: load gm/IC table from file, interpolate
- [ ] `optimizer/types.rs`: OptConfig, SearchSpace, Objective, Constraint
- [ ] `optimizer/sweep.rs`: parameter sweep engine (cartesian + LHS)
- [ ] `optimizer/sweep.rs`: integrate with SimBackend (run sim per point)
- [ ] `optimizer/nsga2.rs`: population initialization
- [ ] `optimizer/nsga2.rs`: non-dominated sorting
- [ ] `optimizer/nsga2.rs`: crowding distance
- [ ] `optimizer/nsga2.rs`: selection, crossover, mutation operators
- [ ] `optimizer/nsga2.rs`: generation loop with sim evaluation
- [ ] `optimizer/testbench.rs`: load .chn_tb, extract measurement declarations
- [ ] `optimizer/testbench.rs`: map measurements to objectives/constraints
- [ ] `optimizer/characterize.rs`: run characterization sweeps
- [ ] `optimizer/characterize.rs`: build lookup tables from sweep results
- [ ] Tests: cubic spline interpolation accuracy
- [ ] Tests: NSGA-II on known Pareto front (e.g. ZDT1)
- [ ] Tests: sweep engine produces correct parameter grid
- [ ] Commit after each meaningful change

## Do NOT Touch
- `sim/src/ir.rs` / `sim/src/emit.rs` — IR layer, consume only
- `sim/src/backend/` — backend layer, consume only
- `core/` — types already defined
- `handler/` — handler drives optimizer via commands
- `display/` — optimizer UI is in display (separate concern)
