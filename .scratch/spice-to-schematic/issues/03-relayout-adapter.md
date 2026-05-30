---
id: s2s/03
title: "Schematic <-> s2s-IR pure adapter (enables re-layout)"
status: done
priority: high
labels: [s2s, refactor]
closed: 2026-05-30
commit: 15af9ba
---

# 03 — Schematic <-> s2s-IR pure adapter (enables re-layout)

## Status: done

`adapter.rs` (968 LOC) with `schematic_from_subcircuit`,
`subcircuit_from_schematic`, and `relayout`. 20 unit tests covering
forward, reverse, and round-trip conversion. Unblocks gui/02
(AutoLayout) and s2s/02 (hierarchical import).
