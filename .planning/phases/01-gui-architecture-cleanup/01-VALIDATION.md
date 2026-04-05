---
phase: 1
slug: gui-architecture-cleanup
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-04
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Zig built-in test + custom runner |
| **Config file** | `build.zig` test_defs array |
| **Quick run command** | `zig build` |
| **Full suite command** | `zig build && zig build -Dbackend=web && zig build test` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `zig build` (native compile check)
- **After every plan wave:** Run `zig build && zig build -Dbackend=web && zig build test`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 01-01-xx | 01 | 1 | INFRA-01 | smoke | `zig build` | Wave 0 | ⬜ pending |
| 01-01-xx | 01 | 1 | INFRA-02 | smoke | `zig build` | Wave 0 | ⬜ pending |
| 01-01-xx | 01 | 1 | INFRA-03 | manual | Run app, verify menus | N/A | ⬜ pending |
| 01-01-xx | 01 | 1 | INFRA-04 | unit | `grep "^var " src/gui/ -r` returns empty | Wave 0 | ⬜ pending |
| 01-01-xx | 01 | 1 | INFRA-05 | smoke | `test ! -f src/state.zig` | Already true | ⬜ pending |
| 01-01-xx | 01 | 1 | INFRA-06 | smoke | `find src/ -name Arch.md` returns empty | Wave 0 | ⬜ pending |
| 01-01-xx | 01 | 1 | INFRA-07 | unit | `grep "page_allocator" src/gui/ -r` returns empty | Wave 0 | ⬜ pending |
| 01-01-xx | 01 | 1 | INFRA-08 | smoke | `zig build && zig build -Dbackend=web` | Wave 0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] Lint check for module-level var detection in gui/ (`grep "^var " src/gui/ -r`)
- [ ] Lint check for page_allocator usage in gui/ (`grep "page_allocator" src/gui/ -r`)
- [ ] No new test files needed — this is a structural refactoring phase. Compile success is the primary validation.

*Existing infrastructure covers most phase requirements via compile checks.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Toolbar shows only File/Edit/View | INFRA-03 | Visual verification — menu content depends on runtime rendering | Run `zig build run`, check toolbar has exactly 3 menus |
| Both backends render GUI shell | INFRA-08 | Visual verification — compile success doesn't guarantee rendering | Run native and serve web, confirm GUI renders in both |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
