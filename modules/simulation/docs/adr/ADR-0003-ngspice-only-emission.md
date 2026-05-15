# ADR-0003: ngspice as sole netlist emission target

## Status: accepted

## Context

The `SpiceIF` IR defines analysis types for 14 analyses including ngspice-specific ones (PSS) and non-ngspice ones (HB, MPDE, SP). The project uses PySpice (which wraps ngspice) as its simulation backend. Supporting Xyce, Spectre, or HSPICE emission would require per-backend emitters and testing infrastructure that doesn't exist.

## Decision

Only `emitAnalysisNgspice` exists. `SpiceIF.Netlist.emitTo` calls it unconditionally. HB and MPDE emit `* [UNSUPPORTED]` comments. The `Backend` enum that was once defined has been removed; the code is ngspice-native throughout.

`Netlist.zig` also hardcodes ngspice: `shouldEmitCode` skips code blocks where `simulator != "ngspice"`.

## Consequences

- **Simple.** One emission path, one dialect to test.
- **Locked in.** Adding Xyce or Spectre requires: (1) a backend selector threaded through `emitTo` and `emitSpice`, (2) per-analysis emission functions, (3) control section differences (Xyce uses `.STEP` not `.control`/`foreach`). The IR types already carry enough information; the gap is purely in emission code.
- **Type waste.** `AnalysisHB`, `AnalysisMPDE`, `AnalysisSP` exist as types but cannot produce usable output. They serve as forward declarations for future backends.
