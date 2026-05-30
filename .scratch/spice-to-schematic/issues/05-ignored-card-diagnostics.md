# 05 — Diagnostics for ignored/unknown SPICE cards (no silent data loss)

Status: ready-for-agent
Labels: feature-gap, correctness
Crate: schemify-handler
Complexity: S

## Problem

`s2s/parser/mod.rs:279-282` silently drops device cards with unrecognised
prefixes. A netlist with, say, a `B` source or `J` JFET imports "successfully"
while losing devices — silent data loss reads as "fully imported".

## Acceptance criteria (TDD)

1. The parser collects ignored lines (prefix + line number) into a diagnostic
   list instead of dropping them silently.
2. A test parses a netlist containing a `B` source and asserts the diagnostics
   report it ("1 device line ignored, prefix B").
3. Diagnostics flow to the same surface as issue 04 (import dialog / accessor).
4. `cargo nextest run` green.

This is cheap and should ship **before** issue 01 — it quantifies which
unsupported cards actually occur in real inputs, prioritising 01's work.
