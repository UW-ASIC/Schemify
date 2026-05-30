# HANDOFF — SchemifyRS Implementation Gaps

Generated: 2026-05-30 | Branch: `dev` (HEAD `99c7718`)

Issues live as markdown under `.scratch/` (see `docs/agents/issue-tracker.md`).

## Workflow Rules — READ BEFORE STARTING

### One issue → one commit (mandatory)

Per CLAUDE.md: when an issue's acceptance criteria are met and `cargo nextest run` is green, **commit immediately** before starting the next issue. Do not batch. Message format:

```
feat(area): short description [issue-id]
```

Run `cargo fmt` and `cargo clippy --all-targets -- -D warnings` before each commit. All commands inside `nix develop`.

### Commit before parallelizing with git worktrees

Before launching parallel/worktree agents:

```
[ ] All current changes committed (clean git status)
[ ] cargo nextest run passes
[ ] Each agent targets DIFFERENT crate or non-overlapping files
[ ] No two agents touch Cargo.toml simultaneously
[ ] Merge worktree results one at a time, test after each merge
```

Sequence: finish + commit current issue → spawn worktree agents (one issue each, no shared deps) → each agent commits in its worktree → merge back one at a time → `cargo nextest run` after each merge.

---

## Issue Index

### Spice-to-Schematic (`.scratch/spice-to-schematic/issues/`)

S2S importer exists (~13.5k LOC in `handler/src/s2s/`). These are gaps, not greenfield.

| ID | Title | Status | Pri | Deps |
|----|-------|--------|-----|------|
| s2s/01 | Device card coverage (J/K/S/W/B/T silent drop) | ready-for-agent | high | — |
| s2s/02 | Hierarchical subcircuit import (multi-sheet) | ready-for-agent | high | s2s/03 |
| s2s/03 | Relayout adapter (Schematic ↔ s2s-IR) | ready-for-agent | high | — |
| s2s/04 | Surface validation diagnostics to user | ready-for-agent | medium | — |
| s2s/05 | Ignored card diagnostics (parser warnings) | ready-for-agent | medium | s2s/01 |
| s2s/06 | WASM import smoke test + PySpice UX | ready-for-agent | low | — |
| s2s/07 | Document S2S + fix CONTEXT-MAP drift | ready-for-agent | low | — |
| s2s/08 | Simulation result back-annotation | needs-info | high | gen/02 |
| s2s/09 | Spectre/HSPICE dialect support | needs-info | low | — |

### GUI Linking (`.scratch/gui-linking/issues/`)

| ID | Title | Status | Pri | Deps |
|----|-------|--------|-----|------|
| gui/01 | Text tool → canvas handlers (tool exists, no interaction) | ready-for-agent | high | — |
| gui/02 | AutoLayout stub (returns error msg) | ready-for-agent | medium | s2s/03 |
| gui/03 | Audit control wiring (full inventory) | ready-for-agent | medium | — |
| gui/04 | SetStimulusLang — no UI dispatches it | ready-for-agent | medium | — |
| gui/05 | Hierarchy navigation (disabled stubs) | needs-info | medium | s2s/02 |
| gui/06 | Bus mode flag — verify propagates to AddWire | ready-for-agent | medium | — |
| gui/07 | Disabled menu items (SVG, highlight nets) | ready-for-agent | low | — |
| gui/08 | PluginMutation handler (no-op) | ready-for-agent | low | — |

### General Infrastructure (`.scratch/general/issues/`)

| ID | Title | Status | Pri | Deps |
|----|-------|--------|-----|------|
| gen/01 | Unblock 53 ignored spice roundtrip tests | ready-for-agent | critical | gen/02 |
| gen/02 | Complete PySpice simulation pipeline | ready-for-agent | critical | — |
| gen/03 | Display crate unit tests (zero today) | ready-for-agent | high | — |
| gen/04 | Plugin host panic → Result hardening (33 panics) | ready-for-agent | high | — |
| gen/05 | Criterion benchmarks for hot paths | ready-for-agent | medium | — |
| gen/06 | Engine crate tests (zero today) | ready-for-agent | medium | — |

### IO/Plugins (`.scratch/io-plugins-gaps/`) — from prior HANDOFF

| ID | Title | Status | Pri | Deps |
|----|-------|--------|-----|------|
| io/01 | Writer drops drawing shapes (roundtrip loss) | ready-for-agent | medium | — |
| io/02 | Plugin subprocess transport stubbed | needs-info | medium | — |
| io/03 | Plugin Command/undo stream | needs-info | medium | io/02 |

---

## Recommended Execution Order

### Phase 1 — Unblock simulation (sequential, same crate)
1. **gen/02** — PySpice pipeline (sim + handler)
2. **gen/01** — Unblock 53 roundtrip tests (depends on gen/02)

### Phase 2 — S2S core (parallelizable via worktrees)
3. **s2s/03** — Relayout adapter ← worktree A (handler/s2s)
4. **s2s/01** — Device card coverage ← worktree B (handler/s2s — different files)
5. **s2s/05** — Ignored card diagnostics (after s2s/01, same worktree)

### Phase 3 — GUI wiring (parallelizable)
6. **gui/01** — Text tool ← worktree A (display/canvas)
7. **gui/06** — Bus mode verify ← worktree B (display/canvas — audit only)
8. **gui/04** — Stimulus lang UI (display/chrome)
9. **gui/03** — Audit control wiring (comprehensive sweep)

### Phase 4 — Robustness (parallelizable across crates)
10. **gen/04** — Plugin panic hardening ← worktree A (plugins)
11. **gen/03** — Display tests ← worktree B (display)
12. **gen/06** — Engine tests ← worktree C (engine)
13. **gen/05** — Benchmarks (new benches/ dir)
14. **io/01** — Writer shape roundtrip (io)

### Phase 5 — Hierarchy + back-annotation (sequential, cross-crate)
15. **s2s/02** — Hierarchical subcircuit import
16. **gui/05** — Hierarchy navigation (depends on s2s/02)
17. **s2s/08** — Sim result back-annotation (depends on gen/02)
18. **gui/02** — AutoLayout (depends on s2s/03)

### Phase 6 — Polish
19. **s2s/04** — Surface validation
20. **s2s/07** — Documentation + CONTEXT-MAP
21. **gui/07** — Disabled menu items
22. **gui/08** — PluginMutation
23. **s2s/06** — WASM smoke test
24. **io/02** → **io/03** — Plugin transport (triage needs-info first)
25. **s2s/09** — Spectre/HSPICE (future)

---

## Totals

**25 issues across 4 tracks**

- **Critical:** 2 (simulation pipeline, roundtrip tests)
- **High:** 6 (device cards, relayout, text tool, back-annotation, display tests, plugin hardening)
- **Medium:** 11 (various GUI, infra, IO)
- **Low:** 6 (docs, WASM, dialects, polish)
- **Needs-info:** 5 (require triage/clarification before agent work)
