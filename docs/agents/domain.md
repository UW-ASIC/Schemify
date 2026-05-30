# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

This is a **multi-context** repo: `CONTEXT-MAP.md` at the root maps the workspace
crates, and each crate carries its own `CONTEXT.md` + `docs/adr/`.

## Before exploring, read these

- **`CONTEXT-MAP.md`** at the repo root — it describes the crate dependency graph and what lives where. Start here.
- **`crates/<crate>/CONTEXT.md`** — read each one relevant to the topic for the crate's domain language.
- **`docs/adr/`** at the root for system-wide decisions, and **`crates/<crate>/docs/adr/`** for context-scoped decisions in the crate you're about to work in.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The producer skill (`/grill-with-docs`) creates them lazily when terms or decisions actually get resolved.

## File structure

This repo (multi-context — `CONTEXT-MAP.md` present at the root):

```
/
├── CONTEXT-MAP.md                     ← crate dependency graph, what lives where
├── docs/adr/                          ← system-wide decisions
└── crates/
    ├── core/
    │   ├── CONTEXT.md
    │   └── docs/adr/                  ← context-specific decisions
    ├── handler/
    │   ├── CONTEXT.md
    │   └── docs/adr/
    ├── display/
    │   ├── CONTEXT.md
    │   └── docs/adr/
    ├── sim/
    ├── io/
    ├── engine/
    └── plugins/
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in the relevant `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/grill-with-docs`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-001 (core/state boundary) — but worth reopening because…_
