---
id: gen/02
title: Complete PySpice simulation pipeline
status: ready-for-agent
priority: critical
labels: [sim, handler]
---

# Complete PySpice simulation pipeline

## Problem

`RunSim` command exists but simulation pipeline incomplete:
- `pyspice.rs` — env var lookup only, no subprocess invocation
- `netlist.rs` — generates CircuitIR but no actual netlist text output
- No JSON serialization to PySpice
- No result parser (waveforms, op-points)

## Acceptance criteria

- [ ] CircuitIR → SPICE netlist text emission
- [ ] Python subprocess launcher (uses PYSPICE_MODULE_DIR)
- [ ] JSON request → PySpice → JSON response roundtrip
- [ ] Parse SimResult from PySpice output (Waveform, OpPoint, Measurement)
- [ ] RunSim command produces actual SimResult in AppState
- [ ] Error handling: missing Python, missing PySpice, sim failure → user-facing error

## Files

- `crates/sim/src/pyspice.rs`
- `crates/sim/src/ir.rs`
- `crates/handler/src/dispatch.rs` — RunSim handler
- `crates/handler/src/netlist.rs`
