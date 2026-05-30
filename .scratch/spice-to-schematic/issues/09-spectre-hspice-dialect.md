---
id: s2s/09
title: Spectre and HSPICE dialect support
status: wontfix
priority: low
labels: [s2s, parser]
---

# Spectre and HSPICE dialect support

## Status: wontfix

Closed 2026-05-30. PySpice generates ngspice-format SPICE — all input to
the S2S parser comes through PySpice, so there is no user-facing need for
Spectre/HSPICE parsing. If a user has a Spectre netlist, they convert it
to ngspice before importing (or PySpice handles it upstream).
