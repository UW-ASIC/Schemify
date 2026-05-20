# A9: Backend Integration

**Wave**: 3
**Depends on**: A7 (netlist generation)

## Goal
Launch SPICE simulators as subprocesses, feed netlists, parse results back into `SimResult`. Support ngspice first, then Xyce.

## Branch
`feat/sim-backend`

## Zig Reference Files
- `../Schemify/src/simulation/results.zig` — result parsing (raw file format)
- `../Schemify/src/simulation/json_results.zig` — JSON result storage

## Crate/File Map

### sim (`crates/sim/src/`)
- NEW `backend/mod.rs` — `trait SimBackend`, backend registry
- NEW `backend/ngspice.rs` — ngspice subprocess launch + raw file parsing
- NEW `backend/xyce.rs` — Xyce subprocess launch + CSV/PRN parsing
- NEW `results_parser.rs` — parse .raw binary format (ngspice), CSV (Xyce)
- NEW `probe.rs` — detect available backends on system (which ngspice, etc.)

## API

```rust
pub trait SimBackend {
    fn name(&self) -> &str;
    fn is_available(&self) -> bool;
    fn run(&self, netlist: &str, work_dir: &Path) -> Result<SimResult, SimError>;
}

pub fn probe_backends() -> BackendAvailability;
pub fn run_simulation(netlist: &SpiceNetlist, dialect: Dialect, backend: &dyn SimBackend) -> Result<SimResult, SimError>;
```

## ngspice .raw Format
- Binary header: title, date, plotname, flags, variables, points
- Variable list: name + type (voltage, current, time, frequency)
- Binary data: f64 per variable per point (column-major)
- Parse into `Vec<Waveform>` for SimResult

## Checklist
- [ ] `backend/mod.rs`: `SimBackend` trait definition
- [ ] `probe.rs`: detect ngspice/xyce on PATH
- [ ] `backend/ngspice.rs`: spawn `ngspice -b -r output.raw input.sp`
- [ ] `results_parser.rs`: parse ngspice .raw binary format
- [ ] Map parsed data → `SimResult` (waveforms, measurements, op points)
- [ ] Error extraction: parse stderr for convergence/syntax errors
- [ ] `backend/xyce.rs`: spawn Xyce, parse CSV/PRN output
- [ ] Tests: mock ngspice output, verify parsed SimResult
- [ ] Tests: backend availability probing
- [ ] Commit after each meaningful change

## Do NOT Touch
- `sim/src/ir.rs` / `sim/src/emit.rs` — A4 territory
- `sim/src/netlist.rs` — A7 territory (you consume its output)
- `core/` — SimResult types already defined
- `handler/` — handler calls sim, not the other way
