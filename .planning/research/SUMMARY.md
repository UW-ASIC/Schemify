# Project Research Summary

**Project:** Schemify GUI Redesign
**Domain:** EDA schematic editor (immediate-mode GUI, dual-backend)
**Researched:** 2026-04-04
**Confidence:** HIGH

## Executive Summary

Schemify is a Zig-based EDA schematic editor with dual native (raylib) and web (WASM) backends, a mature plugin system (ABI v6), and a command-queue architecture. The GUI is currently a broken shell -- layout renders but most interactions are stubs or non-functional. The central technical problem is Renderer.zig (1152 LOC), a monolith handling viewport transforms, grid rendering, symbol drawing, wire rendering, selection, and mouse interaction with zero test coverage. The redesign decomposes this into a Canvas/ subfolder with single-responsibility components while rebuilding every editor interaction from the ground up.

The recommended approach is strict bottom-up construction following the feature dependency chain: canvas foundation first (pan, zoom, grid, coordinate transforms), then read-only rendering (symbols, wires, labels), then selection, then editing (move, drag, rotate, wire draw), then productivity features (properties, undo/redo fix, file operations). This order is non-negotiable -- every higher-level feature depends on correct viewport math and grid snapping. Building wire drawing before canvas pan/zoom works, or property editing before selection works, produces cascading bugs that are impossible to debug because you cannot isolate which layer caused the problem.

Schemify has three genuine differentiators that no competitor matches simultaneously: (1) vim-style command bar for power-user workflows -- no other EDA tool has this; (2) dual native/WASM deployment enabling browser-based usage without install -- no open-source EDA tool runs in the browser; (3) a mature multi-language plugin system with UI rendering capability -- ahead of KiCad's Python scripting and Xschem's Tcl. These must be preserved and polished, not rebuilt. The three highest risks are dvui text entry instability (mitigated by command bar workaround), WASM backend silently breaking during native-focused development (mitigated by testing both backends each phase), and the broken redo system (must be fixed as infrastructure, not deferred).

## Key Findings

### Recommended Stack

No new dependencies. The existing stack is correct for the domain. See [STACK.md](STACK.md) for full analysis.

**Core technologies:**
- **Zig 0.15.x**: Language and build system -- data-oriented design (SoA, comptime tables) is ideal for EDA data structures
- **dvui 0.4.0-dev**: Immediate-mode GUI framework -- provides both native (raylib) and web (WASM/canvas) backends from the same Zig code
- **raylib (bundled)**: Native rendering backend -- hardware-accelerated 2D rendering, sufficient for schematic work

**Critical constraint:** dvui text entry is unstable. All free-form text input (property editing, search, save-as path) must route through the command bar. This is both a necessary workaround and a differentiator (vim-style interaction). Do not attempt WYSIWYG text editing on the canvas or in dialogs.

**Dual backend constraint:** All GUI code must work identically on native and web. No platform-specific GUI code. No system dialogs (file picker must be custom). No threading (WASM is single-threaded).

### Expected Features

See [FEATURES.md](FEATURES.md) for full competitive analysis against KiCad 9/10, Xschem, LTspice, EasyEDA, Altium, and Cadence Virtuoso.

**Must have (table stakes):**
- Canvas pan/zoom/grid with cursor-centered zoom and configurable grid snap
- Component symbol rendering, wire rendering, net labels, ref-des/value display
- Click-to-select, rubber-band box selection (directional: L-to-R enclosed, R-to-L intersecting), multi-select
- Component placement from library, move (disconnect), drag (rubber-band wires), rotate, flip, delete, nudge
- Wire drawing (click-to-route, orthogonal routing default, junction dots, wire-to-pin auto-connect)
- Undo AND redo -- redo is currently broken, this is a critical fix
- File operations (new, open, save, save-as with custom file picker) plus unsaved changes warning
- Property viewing and editing (via command bar workaround for dvui text instability)
- Context menus, keyboard shortcuts (50+ keybinds exist), keybinds help dialog
- Selection highlighting, theme support (dark/light)

**Should have (differentiators -- already partially built, polish them):**
- Vim-style command bar -- unique in EDA tools
- Web/WASM deployment -- unique for open-source EDA
- Plugin ecosystem (ABI v6) with multi-language SDKs and UI rendering
- Net highlighting with distinct colors
- Schematic/symbol view toggle in one window
- Hierarchy navigation (descend/ascend subcircuits)
- Export to SVG/PNG/PDF

**Defer (future milestones):**
- Inline waveform display, ERC, built-in symbol editor, bus notation
- Marketplace UI (blocked by dvui text entry)
- Move stretch/insert modes (high complexity wire tracking)
- Runtime-customizable keybinds, design variants, mobile/touch
- Cross-document copy/paste guarantees

### Architecture Approach

See [ARCHITECTURE.md](ARCHITECTURE.md) for full component boundaries, data flow diagrams, and code patterns.

Decompose the monolithic Renderer.zig into a Canvas/ subfolder with isolated single-responsibility components. All persistent GUI state moves into AppState.gui (eliminating stale-reference bugs from module-level `var` declarations). All schematic mutations go through the command queue (no direct state mutation from GUI code). Canvas sub-renderers are called in a documented, enforced z-order by Canvas/lib.zig.

**Major components:**
1. **Canvas/Viewport.zig** -- world-to-screen coordinate transforms, pan/zoom state. Single source of truth for all coordinate math. Implements `zoomAtPoint()`.
2. **Canvas/GridRenderer.zig** -- grid dots/lines rendering, adaptive density based on zoom level
3. **Canvas/SymbolRenderer.zig** -- component symbol drawing with subcircuit cache (needs LRU eviction, max 256 entries)
4. **Canvas/WireRenderer.zig** -- wire segments, junction dots, net label rendering
5. **Canvas/SelectionOverlay.zig** -- selection highlights, rubber-band rectangle/lasso preview
6. **Canvas/InteractionHandler.zig** -- mouse/keyboard canvas events translated to CanvasEvents for gui/lib.zig to process
7. **gui/lib.zig** -- frame orchestration, z-order enforcement (existing pattern, preserved)
8. **Actions.zig + CommandBar.zig** -- command dispatch and vim-style text input (existing, enhanced)
9. **Dialogs/SaveWarningDialog.zig** -- new, for unsaved changes confirmation
10. **Dialogs/FilePickerDialog.zig** -- new, extends FileExplorer for save-as

**Key patterns to follow:**
- Immediate-mode components read from AppState, render, dispatch commands. No component stores persistent state.
- Comptime tables for menus and keybinds (O(log n) binary search, zero allocation, compile-time verified).
- Canvas render order contract: Grid -> Wires -> Junctions -> Symbols -> Labels -> Selection overlay -> Rubber-band preview -> Crosshair.
- ArenaAllocator for per-frame temporaries. Thread GPA to all modules. Never use page_allocator in hot paths.

**Anti-patterns to eliminate:**
- Module-level `var` in GUI files (causes stale state across document switches)
- Silent `catch {}` error swallowing (90+ occurrences -- log at minimum, propagate where possible)
- Direct state mutation from GUI code (must go through command queue for undoable operations)

### Critical Pitfalls

See [PITFALLS.md](PITFALLS.md) for the complete list with detection tests and prevention strategies.

1. **Building features out of dependency order** -- Canvas viewport math and grid snap must be solid before any editing interaction. If you are writing coordinate fudge factors or "+1" offsets in higher-level code, the foundation is broken. Go fix it first.
2. **Zoom not centered on cursor** -- Implement `zoomAtPoint(cursor_screen_x, cursor_screen_y, factor)` using before/after world-coordinate adjustment. Test: zoom with cursor at screen edge. If view shifts toward center, it is wrong.
3. **Move vs Drag confusion** -- Implement BOTH from the start. Default to Drag (rubber-band). KiCad convention: `M` = move (disconnect), `G` = drag (rubber-band). Shipping only Move makes rearrangement tedious (80% of schematic work).
4. **Redo not working** -- Store forward+inverse command pairs. On undo, push forward to redo stack. Clear redo stack on any new edit. Current system discards forward commands entirely.
5. **No unsaved changes warning** -- Check dirty flag on every close_tab and exit path. Show Save/Discard/Cancel dialog. Low complexity, high trust impact.

## Implications for Roadmap

### Phase 1: Canvas Foundation
**Rationale:** Everything depends on correct viewport transforms and grid rendering. This is the base layer. No editing feature works without it. Also the phase where Renderer.zig decomposition happens -- the hardest architectural change.
**Delivers:** A canvas that pans, zooms (centered on cursor), displays configurable grid, shows coordinates in status bar. Read-only rendering of components, wires, net labels, ref-des from the existing core data model. The decomposed Canvas/ subfolder structure with documented z-order.
**Features from FEATURES.md:** Canvas pan/zoom/grid, grid snap, crosshair cursor, coordinates display, component symbol rendering, wire rendering, net label display, ref-des/value display, grid toggle (dots/lines/none).
**Pitfalls to avoid:** Zoom not centered on cursor (Pitfall 2), render order bugs during decomposition (Moderate Pitfall 5), grid rendering performance at high zoom (use adaptive grid density).
**Architecture work:** Decompose Renderer.zig into Canvas/ subfolder. Establish Viewport.zig. Move module-level `var` state into AppState.gui. Enforce canvas render z-order.

### Phase 2: Selection and Core Editing
**Rationale:** Selection is the prerequisite for all editing operations. Grouping selection with move/drag/rotate/delete avoids building editing without working selection. Move-vs-drag must be implemented together to avoid the single most frustrating EDA UX pitfall.
**Delivers:** Full interactive editing -- click-select, box-select (directional), multi-select, move, drag (rubber-band), rotate, flip, delete, nudge, duplicate (with wires).
**Features from FEATURES.md:** Click-to-select, rubber-band box selection, multi-select (Shift+click), select all/none, selection highlighting, move (disconnect), drag (rubber-band), rotate CW/CCW, flip H/V, delete, nudge (arrow keys), duplicate (fix to include wires), align to grid.
**Pitfalls to avoid:** Move vs Drag confusion (Pitfall 3), off-grid placement (Moderate Pitfall 1), box selection direction convention (document: L-to-R enclosed, R-to-L intersecting).

### Phase 3: Wire Drawing and Connectivity
**Rationale:** Wire drawing depends on working grid snap (Phase 1) and interacts with selection (Phase 2). Junction dots require correct wire connectivity analysis. Grouping wire drawing with junctions and net tracing avoids partial connectivity bugs.
**Delivers:** Complete wire routing -- click-to-route, orthogonal routing (default), junction dot auto-placement, wire-to-pin auto-connect, cancel wire (Escape), select-connected (net tracing with fixed junction detection and improved BFS).
**Features from FEATURES.md:** Wire drawing (click-to-route), orthogonal routing modes, junction dot rendering, wire-to-pin auto-connection, wire segment deletion, cancel wire, select connected.
**Pitfalls to avoid:** Off-grid wire endpoints (force snap, round not truncate), junction dot ambiguity (auto-place on 3+ endpoints, never on crossings), collinear segment collapse after placement.

### Phase 4: Undo/Redo and File Operations
**Rationale:** Undo/redo is independent of the canvas chain but blocks user trust in all editing. File operations are independent but block real-world usage. Grouping them as a "reliability and data safety" phase. Can potentially be parallelized with Phase 2/3 since undo and file ops are architecturally independent.
**Delivers:** Bidirectional undo/redo (forward+inverse pairs), full file operations (new/open/save/save-as with custom file picker), unsaved changes warning (SaveWarningDialog.zig), tab close behavior polish (switch to adjacent tab).
**Features from FEATURES.md:** Undo fix, redo implementation, file new/open/save/save-as, unsaved changes warning, multi-tab management, recent files list.
**Pitfalls to avoid:** Redo broken (Pitfall 4), no unsaved warning (Pitfall 5), save-as needs custom file picker not native dialog (WASM incompatible), redo stack corruption (clear on ANY new undoable command).

### Phase 5: Properties, Command Bar, and Productivity
**Rationale:** Property editing depends on working selection (Phase 2) and is blocked by dvui text instability. The command bar workaround must be polished. Context menus, find/search, clipboard operations round out the editor for real work.
**Delivers:** Property viewing (read-only dialog), property editing via command bar (`:set refdes R1`, `:set value 10k`), functional context menus, find/search via command bar, clipboard operations (copy/paste), library browser for component placement, keybinds dialog.
**Features from FEATURES.md:** Property viewing/editing, context menus, find dialog, copy/paste, component placement from library, keybinds dialog, reference designator annotation.
**Pitfalls to avoid:** Command bar text conflicts with shortcuts (suppress keybinds when command bar has focus), dvui text entry crashes (use command bar for ALL text input), clipboard without visual feedback (flash status bar message).

### Phase 6: Plugin Integration and Dual Backend Validation
**Rationale:** Plugin panel rendering already works. This phase polishes integration with the new Canvas/ architecture and validates BOTH backends work identically. This is the final phase because it is validation and polish, not new capability.
**Delivers:** Plugin panels rendering correctly in new architecture, event dispatch verified, both native and WASM backends tested and working, performance validated on WASM, theme refinement.
**Features from FEATURES.md:** Plugin panel rendering, plugin event dispatch, dual backend verification, net highlighting polish, hierarchy navigation polish, export verification.
**Pitfalls to avoid:** WASM silently broken (Moderate Pitfall 4 -- test both backends), ParsedWidget ABI breakage (never modify format, only extend enum at end), WASM canvas DPI differences (use dvui DPI-aware scaling).

### Phase Ordering Rationale

- **Bottom-up by dependency chain:** The critical path is canvas -> rendering -> selection -> editing -> wire drawing -> productivity. Phases 1-3 follow this chain strictly. Each phase produces a testable, demonstrable increment.
- **Risk front-loaded:** The hardest architectural work (Renderer.zig decomposition, viewport math, move-vs-drag) is in Phases 1-2. If anything requires rethinking, it happens early when the cost of change is lowest.
- **Infrastructure grouped:** Undo/redo and file operations (Phase 4) are independent of the canvas chain. They can potentially be parallelized with Phases 2-3.
- **dvui workaround deferred:** Property editing (Phase 5) comes after core editing is solid, and uses the command bar workaround. If dvui stabilizes text entry by then, the approach can shift.
- **Validation at the end:** Plugin integration and dual-backend testing (Phase 6) validate the entire system. Breaking plugin ABI or WASM support is caught here, not discovered in production.

### Research Flags

**Phases needing deeper research during planning:**
- **Phase 2 (Selection and Editing):** Rubber-band drag (wire following during component move) is complex geometry. Research dvui drag event model and wire endpoint tracking before implementation.
- **Phase 3 (Wire Drawing):** Orthogonal wire routing state machine (click-to-place points, ESC to cancel, auto-connect on pin). Research how KiCad implements the routing interaction model.
- **Phase 4 (Undo/Redo):** Current undo stores only inverse commands. Redesigning to forward+inverse pairs may require changes to CommandQueue and History types. Review existing implementation before committing to approach.

**Phases with standard patterns (skip research-phase):**
- **Phase 1 (Canvas Foundation):** Viewport transforms, grid rendering, z-ordered immediate-mode rendering are well-documented. ARCHITECTURE.md already provides the Viewport.zig implementation pattern.
- **Phase 5 (Properties and Command Bar):** Command bar already works. Property display is a read-only dialog. Standard dvui widget patterns.
- **Phase 6 (Plugin Integration):** Plugin ABI v6 is stable and fully documented. This is testing and validation, not new development.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | No new technologies. Existing stack is well-understood. Zero risk from "no new dependencies" constraint. |
| Features | HIGH | Cross-referenced 6 professional EDA tools (KiCad 9/10, Xschem, LTspice, EasyEDA, Altium, Cadence). Feature expectations verified against official docs. |
| Architecture | HIGH | Based on existing codebase analysis (CLAUDE.md, CONCERNS.md, source files). Canvas/ decomposition follows established immediate-mode GUI patterns. |
| Pitfalls | HIGH | Derived from documented bugs in CONCERNS.md, known dvui limitations, and common 2D editor failure modes confirmed across multiple EDA tools and community forums. |

**Overall confidence:** HIGH

### Gaps to Address

- **dvui text entry timeline:** Unknown when dvui will stabilize text entry. The command bar workaround is solid, but if dvui fixes this mid-project, the property editing approach could shift. Check upstream before Phase 5.
- **Rubber-band drag complexity:** Wire-following-during-drag is acknowledged as high complexity. Phase 2 plans for basic rubber-band but stretch/insert modes are deferred. The boundary between "basic rubber-band" and "production-quality drag" needs precise definition during Phase 2 planning.
- **WASM performance ceiling:** No benchmarks exist for dvui + WASM canvas with 500+ component schematics. Phase 6 may reveal the need for viewport culling (only render visible elements). ARCHITECTURE.md scalability analysis suggests this becomes relevant at 5000+ components.
- **Undo system internals:** The exact data structures in the current History/CommandQueue need code review before committing to forward+inverse pair redesign. Do this during Phase 4 planning.
- **Test strategy:** GUI has zero test coverage. Research does not prescribe a testing approach for immediate-mode GUI components. Establish strategy (snapshot testing, AppState integration tests, or manual verification) during Phase 1 planning.
- **Subcircuit cache eviction:** Current cache never evicts entries. Need LRU eviction (max 256 entries) implemented during Phase 1 SymbolRenderer work.

## Sources

### Primary (HIGH confidence)
- Schemify CLAUDE.md -- GUI architecture, build commands, module rules, dvui widget patterns, frame z-order
- Schemify PROJECT.md -- Requirements, constraints, context, key decisions
- Schemify CONCERNS.md (referenced in research files) -- Documented bugs, performance issues, architectural problems
- [KiCad Schematic Editor Docs 9.0](https://docs.kicad.org/9.0/en/eeschema/eeschema.html) -- Feature reference
- [KiCad Schematic Editor Docs 10.0](https://docs.kicad.org/10.0/en/eeschema/eeschema.html) -- Latest features including dark mode, lasso, hop-over crossings
- [KiCad 10 Release Notes](https://www.kicad.org/blog/2026/03/Version-10.0.0-Released/) -- New features
- [Xschem GitHub + Docs](https://github.com/StefanSchippers/xschem) -- Hierarchy, commands, waveform display
- [EasyEDA Docs](https://docs.easyeda.com/en/Introduction/Schematic-Capture/) -- Grid snap, wiring, web-based editor patterns

### Secondary (MEDIUM confidence)
- [Altium Schematic Editing](https://techdocs.altium.com/node/296790) -- Move vs drag distinction, rubber-banding, "Always Drag" option
- [LTspice Schematic Editing](https://ltwiki.org/LTspiceHelpXVII/LTspiceHelp/html/Schematic_Editing.htm) -- Wire drawing, component placement, verb-noun interface
- [KiCad Forum: Moving Components](https://forum.kicad.info/t/moving-components-in-schematic-editor/36095) -- Community confusion about move vs drag UX
- [KiCad ERC Documentation](https://kicad-sch-api.readthedocs.io/en/latest/ERC_USER_GUIDE.html) -- ERC features (deferred)

### Tertiary (LOW confidence)
- Scalability estimates (5000+ component performance) -- inferred from general 2D rendering experience, not benchmarked against Schemify/dvui specifically
- dvui text entry stabilization timeline -- no official roadmap available

---
*Research completed: 2026-04-04*
*Ready for roadmap: yes*
