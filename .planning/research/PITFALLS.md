# Domain Pitfalls: EDA Schematic Editor GUI

**Domain:** EDA schematic editor GUI redesign
**Researched:** 2026-04-04

---

## Critical Pitfalls

Mistakes that cause rewrites, major regressions, or fundamental UX failures.

### Pitfall 1: Building Features Out of Dependency Order

**What goes wrong:** Implementing wire drawing before canvas pan/zoom works correctly, or property editing before selection works. Features built on a broken foundation cascade into untestable, interdependent bugs.

**Why it happens:** Pressure to show visible progress leads to jumping to "interesting" features (wire routing, property dialogs) before the mundane foundation (viewport transforms, grid snap, click selection) is solid.

**Consequences:** Every higher-level feature has subtle bugs because the coordinate system is wrong, or snapping is off-by-one, or selection state is stale. Debugging becomes impossible because you cannot tell which layer caused the problem.

**Prevention:** Follow the dependency chain strictly:
1. Canvas rendering (pan, zoom, grid, coordinate display)
2. Component/wire display (read-only rendering from data model)
3. Selection (click, box, multi-select)
4. Editing (move, drag, rotate, delete, wire draw)
5. Productivity (properties, find, undo/redo fixes)

**Detection:** If you find yourself writing special-case coordinate adjustments or "plus-one" offsets in higher-level features, the viewport/grid layer is broken. Go fix it first.

### Pitfall 2: Zoom Not Centered on Cursor

**What goes wrong:** Scroll-wheel zoom zooms toward the viewport center instead of the cursor position. This is the single most common and most annoying canvas interaction bug in 2D editors.

**Why it happens:** Naive zoom implementation changes the zoom factor without adjusting the viewport offset. The math for cursor-centered zoom requires converting cursor position to world coordinates before AND after the zoom change, then adjusting the offset by the difference.

**Consequences:** Users cannot zoom into a specific area. They zoom, then pan, then zoom, then pan -- a frustrating loop. This makes the editor feel amateurish instantly.

**Prevention:** Implement `zoomAtPoint(cursor_screen_x, cursor_screen_y, zoom_factor)` that:
1. Convert cursor to world coords at current zoom
2. Apply zoom factor
3. Convert cursor to world coords at new zoom
4. Adjust offset by the difference

**Detection:** Zoom with the cursor at the edge of the screen. If the view shifts toward center, the zoom is wrong.

### Pitfall 3: Move vs Drag Confusion

**What goes wrong:** Users move a component expecting wires to follow (drag/rubber-band behavior) but wires disconnect. Or: there is only one mode and it always disconnects, making rearrangement tedious.

**Why it happens:** Move (disconnect) and Drag (rubber-band) are different operations. KiCad uses `M` for Move and `G` for Drag. Altium has a global "Always Drag" preference. LTspice's drag mode rubber-bands by default. If the editor only implements Move (easier), users coming from any other EDA tool will be confused and frustrated.

**Consequences:** Users spend enormous time rewiring after every component reposition. The editor becomes unusable for schematic refinement (which is 80% of schematic work after initial placement).

**Prevention:** Implement BOTH move (disconnect) and drag (rubber-band) from the start. Default should be drag (rubber-band) since this is what users expect. KiCad convention: `M` = move (disconnect), `G` = drag (rubber-band).

**Detection:** Place a resistor with wires on both sides. Press the drag key. If wires disconnect, drag is not working.

### Pitfall 4: Redo Not Working

**What goes wrong:** Users undo an action, then cannot redo it. Every undo is permanent.

**Why it happens:** The undo system stores only inverse commands. Forward commands are discarded, making redo impossible. This is Schemify's current state (documented in CONCERNS.md).

**Consequences:** Users lose trust in the editor. They avoid experimenting because undo is one-way. Ctrl+Z becomes a source of anxiety rather than safety.

**Prevention:** Store both the forward command AND its inverse as a pair in the undo history. On undo, push the forward command onto a redo stack. On redo, pop from redo stack, re-execute, push new inverse onto undo stack. Clear redo stack on any new edit.

**Detection:** Undo an action. Press Ctrl+Y. If nothing happens, redo is broken.

### Pitfall 5: No Unsaved Changes Warning

**What goes wrong:** Users close a tab or quit the application and lose unsaved work silently.

**Why it happens:** The close/quit code path does not check the document's dirty flag. This is Schemify's current state (documented in CONCERNS.md).

**Consequences:** Data loss destroys user trust permanently. Users who lose work once will either save obsessively (bad workflow) or stop using the tool entirely.

**Prevention:** Check `document.dirty` on every close_tab and exit path. Show a confirmation dialog with Save/Discard/Cancel options. This is a LOW complexity feature with HIGH impact.

**Detection:** Make an edit. Close the tab. If no warning appears, this is broken.

---

## Moderate Pitfalls

### Pitfall 1: Off-Grid Component Placement

**What goes wrong:** Components or wire endpoints are placed slightly off the grid. Pins do not connect even though they appear to overlap visually.

**Prevention:** Grid snap must be always-on by default. The snap algorithm should round to nearest grid point, not truncate. Pin positions in the symbol library must align to the grid size. EasyEDA docs strongly recommend: "keep Snap = Yes all the time."

### Pitfall 2: Junction Dot Ambiguity

**What goes wrong:** Two wires cross visually but are not electrically connected, or they are connected but no junction dot is shown. Users misread the schematic.

**Prevention:** Auto-place junction dots when 3+ wire endpoints share a coordinate. Two wires crossing (but not sharing an endpoint) must NOT show a junction. KiCad 10 added hop-over wire crossings for clarity. At minimum, junction dots must be correct.

### Pitfall 3: Stale Module-Level State Across Document Switches

**What goes wrong:** A dialog is open showing data from Document A. User switches to Document B tab. The dialog still shows Document A's data, or worse, an index that is now out of bounds in Document B.

**Prevention:** Move all dialog state into `AppState.gui` (GuiState struct). On document switch, close all open dialogs or revalidate their indices against the new active document.

### Pitfall 4: WASM Backend Silently Broken

**What goes wrong:** Development focuses on the native (raylib) backend. The WASM backend silently breaks. Nobody notices until it is time to demo the web version.

**Prevention:** Test both backends at the end of every phase. Add a CI check that builds with `-Dbackend=web`. The web demo is a key differentiator -- letting it rot defeats the purpose.

### Pitfall 5: Renderer Decomposition Creates Render Order Bugs

**What goes wrong:** Splitting Renderer.zig into multiple files introduces z-order bugs. Wires render on top of components, or selection overlay renders behind the grid.

**Prevention:** Document the required render order explicitly:
1. Grid (bottom)
2. Wires
3. Junction dots
4. Component symbols
5. Net labels / ref des text
6. Selection overlay (semi-transparent)
7. Rubber-band preview (wire in progress, box select in progress)
8. Cursor crosshair (top)

Each sub-renderer draws at its designated layer. The Canvas/lib.zig orchestrator calls them in order.

### Pitfall 6: Command Bar Text Input Conflicts with Keyboard Shortcuts

**What goes wrong:** When the command bar is active (user is typing a vim command), keyboard shortcuts fire. Typing "w" starts wire mode instead of being entered as text.

**Prevention:** When command bar has focus, suppress all keybind processing. Only Escape (exit command mode) and Enter (execute command) should be handled by the keybind system. All other keys go to the command bar text buffer.

---

## Minor Pitfalls

### Pitfall 1: Scroll Zoom Speed Too Fast or Too Slow

**What goes wrong:** One scroll notch zooms 50% or 5%. Either feels wrong.

**Prevention:** Use a zoom factor of 1.1-1.15 per scroll step (10-15% per notch). This matches the feel of KiCad and most 2D editors. Make it configurable via project config.

### Pitfall 2: Context Menu Appears in Wrong Position

**What goes wrong:** Right-click context menu opens at screen center or a fixed position instead of at the cursor.

**Prevention:** Pass cursor coordinates when opening the context menu. Use dvui floating window positioned at cursor.

### Pitfall 3: Clipboard Operations Without Visual Feedback

**What goes wrong:** User presses Ctrl+C. Nothing visible happens. They are unsure if it worked.

**Prevention:** Flash the status bar message ("Copied 3 instances, 5 wires") and briefly highlight the copied items.

### Pitfall 4: Tab Close Does Not Switch to Adjacent Tab

**What goes wrong:** Closing a tab leaves the user on a blank or random tab.

**Prevention:** On close, switch to the next tab if available, otherwise the previous tab. Follow KiCad and browser conventions.

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| Canvas foundation | Zoom not centered on cursor | Implement zoomAtPoint with before/after world coordinate adjustment |
| Canvas foundation | Grid rendering performance at high zoom | Adaptive grid: show coarser grid when zoomed out, finer when zoomed in |
| Core editing | Move vs Drag confusion | Implement both from the start. Default to Drag (rubber-band). |
| Core editing | Box selection direction convention unclear | Left-to-right = enclosed only. Right-to-left = intersecting. Document in keybinds help. |
| Wire drawing | Wire routing creates off-grid endpoints | Force all wire vertices to snap to grid. Round, do not truncate. |
| Wire drawing | Orthogonal routing creates extra segments | Collapse collinear wire segments after placement. Remove zero-length segments. |
| Undo/Redo | Redo stack corrupted by partial operations | Clear redo stack on ANY new undoable command. No exceptions. |
| File operations | Save-as dialog needs custom file picker | Reuse FileExplorer.zig pattern. Do not attempt native file dialog (WASM incompatible). |
| Property editing | dvui text entry crashes or corrupts input | Use command bar as primary text input. Properties dialog shows read-only view with "Edit in command bar" hint. |
| Plugin integration | Widget rendering ABI changes break plugins | NEVER modify ParsedWidget format. Add new widget types at the end of the enum only. |
| Both backends | WASM canvas size/DPI differs from native | Test at multiple browser zoom levels. Use dvui's DPI-aware scaling. |

---

## Sources

- Schemify CONCERNS.md -- Documented bugs (redo broken, setProp stub, no unsaved warning, module-level mutable state)
- Schemify CLAUDE.md -- GUI rules (frame z-order, command queue for undoable ops, dvui text instability)
- [KiCad Forum: Moving Components](https://forum.kicad.info/t/moving-components-in-schematic-editor/36095) -- Community confusion about Move vs Drag
- [EasyEDA Canvas Settings](https://docs.easyeda.com/en/Schematic/Canvas-Settings/) -- Grid snap recommendations
- [Altium Schematic Editing Essentials](https://techdocs.altium.com/node/296790) -- Move vs Drag, "Always Drag" option
- [KiCad 10 Release](https://www.kicad.org/blog/2026/03/Version-10.0.0-Released/) -- Junction live updates, hop-over wire crossings
