---
id: s2s/08
title: Simulation result back-annotation to schematic
status: needs-info
priority: high
labels: [s2s, sim, handler]
---

# Simulation result back-annotation

## Problem

Can simulate (SimResult, Waveform, OpPoint types exist) but no path to display results on schematic. No `Command::AnnotateWithResults`. No probe-to-property mapping.

## Acceptance criteria

- [ ] New Command: `AnnotateSimResults { results: SimResult }`
- [ ] Operating point voltages/currents displayed at instance pins
- [ ] Measurement values displayed as annotations
- [ ] Annotations clearable via separate command
- [ ] Waveform viewer hookup (future — at minimum store results in AppState)

## Dependencies

- Simulation pipeline must produce SimResult (general/02)

## Files

- `crates/core/src/commands.rs` — new Command variant
- `crates/core/src/simulation.rs` — SimResult already defined
- `crates/handler/src/dispatch.rs` — new handler
- `crates/display/src/canvas.rs` — render annotations
