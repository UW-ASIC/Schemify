---
id: gen/01
title: Unblock 53 ignored spice roundtrip tests
status: ready-for-agent
priority: critical
labels: [testing, sim, handler]
---

# Unblock spice roundtrip tests

## Problem

`crates/handler/tests/spice_roundtrip.rs` has 53 tests all marked `#[ignore = "TODO: rewrite to call pyspice-rs via Python"]`. `roundtrip_to_spice()` calls `unimplemented!()`. Cannot verify schematic ↔ netlist fidelity.

## Root cause

PySpice integration bridge lacks JSON→Python subprocess invocation. `bridge_ir + Spice3CodeGen::emit_netlist()` not wired.

## Acceptance criteria

- [ ] `roundtrip_to_spice()` implemented: Schematic → CircuitIR → emit netlist → re-parse → compare
- [ ] At least basic circuits pass (voltage divider, RC filter, BJT amp)
- [ ] `#[ignore]` removed from passing tests
- [ ] Remaining failures documented as known issues

## Files

- `crates/handler/tests/spice_roundtrip.rs`
- `crates/sim/src/pyspice.rs` — bridge implementation
- `crates/handler/src/netlist.rs` — CircuitIR generation
