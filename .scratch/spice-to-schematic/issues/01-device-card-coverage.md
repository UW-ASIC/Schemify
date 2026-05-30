---
id: s2s/01
title: "Device-card coverage: J/K/S/W/B/T silently dropped"
status: done
priority: high
labels: [s2s, parser, feature-gap]
closed: 2026-05-30
commit: a4cc5bd
---

# 01 — Device-card coverage: J/K/S/W/B/T silently dropped

## Status: done

JFET (J) and behavioral source (B) added with 3 parser unit tests,
pin geometry, DeviceKind mapping. Remaining cards (K/S/W/T/O/U) are
exotic — surface them via s2s/05 diagnostics rather than adding
speculative support.
