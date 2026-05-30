---
id: gen/05
title: Add criterion benchmarks for hot paths
status: ready-for-agent
priority: medium
labels: [testing, performance]
---

# Add benchmarks

## Problem

Zero benchmarks. CLAUDE.md says "Profile before optimizing; benchmark with criterion in benches/" but no benches/ exist. Performance regressions ship silently.

## Acceptance criteria

- [ ] `benches/` directory with criterion setup
- [ ] Benchmark: connectivity resolution (wire + instance iteration)
- [ ] Benchmark: CHN serialization roundtrip
- [ ] Benchmark: SPICE parse (medium-sized netlist)
- [ ] Benchmark: instance rendering loop (SoA iteration)
- [ ] CI runs benchmarks (at minimum, no regression check)
