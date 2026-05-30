# 01 — Device-card coverage: J/K/S/W/B/T silently dropped

Status: ready-for-agent
Labels: feature-gap
Crate: schemify-handler (parser + spice_import), schemify-core (DeviceKind)
Complexity: M

## Problem

`crates/handler/src/s2s/parser/mod.rs:265-283` dispatches device cards by prefix.
Unknown prefixes hit the `_ =>` arm (`parser/mod.rs:279-282`) and are **silently
ignored**. Missing: J (JFET), K (coupled/mutual inductor), S/W (switches),
B (behavioral source), T/O/U (transmission/lossy line).

`spice_import.rs:273-291` `map_device_kind` has no arm for these, and
`schemify-core::DeviceKind` likely lacks the variants.

## Acceptance criteria (TDD)

1. For each newly-supported card, a parser unit test: the SPICE line parses to
   the correct `Primitive` with the correct pin count.
2. New `DeviceKind` / `Primitive` variants added with documented pin geometry in
   `s2s/output/schemify.rs`.
3. Round-trip: importing a netlist containing the new card and re-emitting
   (`netlist.rs`) reproduces an equivalent card.
4. Prioritise by demand — JFET (J) and behavioral source (B) first; gate the
   rest behind issue 05's diagnostics data if unsure.
5. `cargo nextest run` green.

Depends on: 05 (diagnostics) is useful to ship first to quantify which cards
actually appear in real inputs.
