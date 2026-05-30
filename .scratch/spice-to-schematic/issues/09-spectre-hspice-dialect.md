---
id: s2s/09
title: Spectre and HSPICE dialect support
status: needs-info
priority: low
labels: [s2s, parser]
---

# Spectre and HSPICE dialect support

## Problem

Parser only handles ngspice dialect. Spectre (Cadence) and HSPICE netlists fail. Industry uses these heavily.

## Scope

- Spectre: different parameter syntax, node ordering, `subckt`/`ends` keywords
- HSPICE: `.hdl`, `.data` directives, H-parameters
- Xyce: parallel SPICE extensions

## Acceptance criteria

- [ ] Dialect auto-detection from file header/extension
- [ ] Spectre parser covers subcircuits, device cards, parameters
- [ ] HSPICE extensions parsed (at minimum `.hdl`, `.data`)
- [ ] Unknown dialect → clear error message, not silent failure
