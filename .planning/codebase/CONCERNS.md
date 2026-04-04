# Codebase Concerns

**Analysis Date:** 2026-04-04

## Tech Debt

**Redo not implemented:**
- Issue: Undo history stores only inverse commands; forward commands are discarded. Redo always returns `null`.
- Files: `src/commands/Undo.zig` (lines 62-63, 82-86)
- Impact: Users cannot redo after undoing. Every undo is permanent until the document is reloaded. This is a significant UX gap for a schematic editor where experimental edits are common.
- Fix approach: Extend `History` to store both the forward `Undoable` command and its `CommandInverse` as a pair. On undo, push the forward command onto a redo stack. On redo, pop from the redo stack, re-execute, and push a new inverse. Clear the redo stack whenever a new undoable command is executed.

**Property mutation is a stub:**
- Issue: `Document.setProp()` ignores all arguments (`_ = self; _ = idx; _ = key; _ = val;`). The PropsDialog "Apply" button prints "Properties applied (stub)".
- Files: `src/state/Document.zig` (lines 97-103), `src/gui/Dialogs/PropsDialog.zig` (lines 52, 70-71)
- Impact: Instance properties cannot be edited at all through the GUI or command system. The undo system pushes `.none` for set_prop inverses, so even if implemented later, old undo entries will be broken.
- Fix approach: Implement `setProp` to mutate the instance's property map in `core.Schemify`. Wire the PropsDialog to iterate instance properties and dispatch `set_prop` undoable commands through the queue.

**FindDialog is non-functional:**
- Issue: No text entry (blocked by dvui text entry API instability), no query execution, no result list, "Select All Matches" is a no-op.
- Files: `src/gui/Dialogs/FindDialog.zig` (lines 33, 49, 59)
- Impact: Users cannot search for instances or nets by name. The dialog opens but does nothing useful.
- Fix approach: Once dvui text entry stabilises, wire query_buf to a text input widget. Implement a search function that iterates `sch.instances` matching by name/symbol, populate `result_count`, render a result list, and select matching instances on "Select All Matches".

**Marketplace install is a stub:**
- Issue: The "Install" button sets `mkt.install_status = .fetching` but never actually downloads or installs anything. Search text entry is also blocked by dvui.
- Files: `src/gui/Marketplace.zig` (lines 79, 181)
- Impact: Plugin marketplace is purely visual; users cannot discover or install plugins through it.
- Fix approach: Implement background HTTP fetch (or WASM fetch) to download plugin archives, then delegate to `src/plugins/installer.zig` for extraction and placement.

**Save-As and Merge dialogs are CLI-only:**
- Issue: `save_as_dialog` and `merge_file_dialog` commands print status messages telling the user to use CLI `:saveas` / `:merge` commands. No native file picker.
- Files: `src/commands/File.zig` (lines 77-78, 123-126)
- Impact: GUI-only users cannot save to a new path or merge schematics without knowing vim-style commands.
- Fix approach: Integrate a file picker dialog (could reuse `FileExplorer.zig` pattern) and wire it to `saveActiveTo` / merge logic.

**Move stretch and insert modes are no-ops:**
- Issue: `move_interactive_stretch` and `move_interactive_insert` fall through to plain move mode with different status messages. Rubber-band wire tracking and auto-insert are not implemented.
- Files: `src/commands/Edit.zig` (lines 43-51)
- Impact: Moving components always disconnects wires. This is a critical usability gap for schematic editing.
- Fix approach: Implement stretch mode by finding wires connected to selected instances (endpoint matching) and updating their endpoints during move. Insert mode additionally requires splitting wires and inserting new segments.

**Select connected ignores junction detection:**
- Issue: `stop_at_junctions` parameter is accepted but ignored (`_ = stop_at_junctions`). BFS expansion runs for at most 8 rounds regardless.
- Files: `src/commands/Selection.zig` (lines 79-81)
- Impact: `select_connected_stop_junctions` behaves identically to `select_connected`. Users cannot isolate a net segment bounded by junctions.
- Fix approach: Implement junction detection (count wire endpoints sharing a coordinate; 3+ = junction) and stop BFS at junction nodes when the flag is set.

**Screenshot area selection not implemented:**
- Issue: `screenshot_area` falls through to full-schematic PNG export. There is no rubber-band area selection UI.
- Files: `src/commands/View.zig` (lines 74-78)
- Impact: Minor -- users can still export the full schematic. Region-specific export is a nice-to-have.
- Fix approach: Add a tool mode for rectangular selection that captures screen coordinates, then clip the SVG viewBox before conversion.

## Known Bugs

**Rename duplicate refdes calls stub setProp:**
- Symptoms: `renameDupRefdes` calls `fio.setProp()` which is a no-op, so duplicate reference designators are detected and "renamed" but nothing actually changes.
- Files: `src/commands/Selection.zig` (lines 133-151), `src/state/Document.zig` (lines 97-103)
- Trigger: Select all, then run `rename_dup_refdes` command.
- Workaround: None -- must rename manually.

**Duplicate undo does not track wires:**
- Symptoms: `duplicate_selected` only duplicates instances (not wires), but undo uses `DeleteLastN` which trims instances from the end. If wires were part of the selection, they are silently dropped.
- Files: `src/commands/Edit.zig` (lines 134-148)
- Trigger: Select instances and wires, then duplicate. Only instances are duplicated.
- Workaround: Duplicate instances and wires separately, or manually add wires after duplicating.

**CommandQueue.pop uses orderedRemove(0) -- O(n) per dequeue:**
- Symptoms: Every frame drains the queue with `pop()` which calls `orderedRemove(0)`, shifting all remaining elements. With max_capacity=64 this is tolerable but architecturally wrong.
- Files: `src/commands/CommandQueue.zig` (lines 22-25)
- Trigger: Queue multiple commands in one frame (e.g., rapid key presses).
- Workaround: Not needed at current scale; replace with a ring buffer if the cap increases.

## Security Considerations

**Plugin filesystem access is unrestricted:**
- Risk: Plugins can read and write arbitrary files via `file_read_request` and `file_write` messages. There is no sandboxing, path validation, or allowlist.
- Files: `src/plugins/runtime.zig` (lines 327-347)
- Current mitigation: Plugin command whitelist (`allowed_plugin_commands` at line 669) restricts which app commands plugins can push, but filesystem operations have no restrictions.
- Recommendations: Add path validation to restrict plugin file access to the project directory and the plugin's own config directory. Reject absolute paths outside these roots. Add a user-consent prompt for first-time file access from a new plugin.

**Plugin command whitelist is too narrow but bypass-prone:**
- Risk: The `isCommandAllowed` whitelist (15 entries) blocks destructive commands, but `push_command` dispatches through the generic plugin_command immediate path. A malicious plugin could craft payloads that exploit the string-based tag dispatch.
- Files: `src/plugins/runtime.zig` (lines 359-375, 669-681)
- Current mitigation: Whitelist comparison using `std.mem.eql`.
- Recommendations: Ensure the whitelist is exhaustive for all safe commands. Consider capability-based access where plugins declare required permissions at load time.

**Hardcoded /tmp paths for SPICE simulation:**
- Risk: Predictable filenames in `/tmp` enable symlink attacks (TOCTOU). An attacker could place a symlink at `/tmp/{name}.sp` pointing to a sensitive file before the write.
- Files: `src/state/Document.zig` (lines 79-80), `src/commands/Sim.zig` (line 23), `src/core/Synthesis.zig` (line 80), `src/core/SpiceIF.zig` (line 948)
- Current mitigation: None.
- Recommendations: Use `std.fs.tmpDir()` or `mkstemp`-equivalent to generate unique temporary paths. Alternatively, write to a subdirectory under the project directory.

**std.posix.getenv used in cli.zig:**
- Risk: Violates the project lint rule ("No `std.fs.*` or `std.posix.getenv` outside `utility/` and `cli/`"). The cli.zig usage is technically within the allowed zone, but `HOME` is trusted without validation.
- Files: `src/cli.zig` (line 76)
- Current mitigation: Allowed by the lint rule exception for `cli/`.
- Recommendations: Validate that the HOME path is a real directory before joining paths with it.

## Performance Bottlenecks

**selectConnected is O(n^2) per BFS round:**
- Problem: For each selected wire, the algorithm iterates all wires to find shared endpoints. With 8 rounds maximum, worst case is O(8 * n^2) where n is the wire count.
- Files: `src/commands/Selection.zig` (lines 86-110)
- Cause: No spatial index or adjacency list for wire connectivity. Every round does a full pairwise comparison.
- Improvement path: Build an endpoint-to-wire-index map (hash map keyed by `Point`) before BFS. Each round then expands in O(selected_wires * avg_connections_per_endpoint) instead of O(n^2).

**page_allocator used in hot paths:**
- Problem: `std.heap.page_allocator` is used directly in several places instead of the application's GPA. Page allocator requests whole pages from the OS (typically 4 KiB minimum), causing excessive memory waste and syscall overhead.
- Files:
  - `src/gui/Renderer.zig` (line 39) -- subcircuit symbol cache arena
  - `src/gui/FileExplorer.zig` (line 38) -- global allocator for file browser
  - `src/commands/View.zig` (line 213) -- SVG export buffer
  - `src/gui/Theme.zig` (line 163) -- theme JSON parsing
  - `src/core/Netlist.zig` (lines 440-441) -- netlist emission buffer
  - `src/core/Devices.zig` (line 191) -- device table fallback
- Cause: These modules don't receive the application allocator. They use page_allocator as a "works everywhere" fallback.
- Improvement path: Thread the application's `std.mem.Allocator` through to these callsites. For the Renderer's subcircuit cache, accept an allocator parameter in the init function. For one-shot operations (SVG export), use the AppState allocator passed via the state parameter.

**Subcircuit symbol cache never evicts:**
- Problem: `subckt_cache` in Renderer.zig grows indefinitely. The backing `subckt_arena_state` arena is never freed or reset. Loading many subcircuit-heavy schematics will steadily consume memory.
- Files: `src/gui/Renderer.zig` (lines 34-35)
- Cause: No eviction policy or cache size limit.
- Improvement path: Add a cache size limit (e.g., 256 entries). Implement LRU eviction or clear the cache on document switch. Reset the arena when the cache is cleared.

**History eviction uses orderedRemove(0):**
- Problem: When undo history reaches `max_depth` (64), `orderedRemove(0)` shifts all 63 remaining entries. This is O(n) per push.
- Files: `src/commands/Undo.zig` (line 54)
- Cause: Uses ArrayList instead of a ring buffer.
- Improvement path: Replace with a fixed-size ring buffer (like `ClosedTabs` in `src/state/types.zig`) to make eviction O(1). The comment acknowledges this: "orderedRemove is acceptable here -- undo is infrequent."

## Fragile Areas

**Plugin ABI binary wire format:**
- Files: `src/plugins/types.zig`, `src/plugins/runtime.zig`, `src/plugins/Framework.zig`, `src/plugins/Reader.zig`, `src/plugins/Writer.zig`
- Why fragile: The wire protocol (`[u8 tag][u16 payload_sz LE][payload bytes]`) has no versioned framing, no checksums, and no length-prefix on the overall message batch. A single off-by-one in payload size calculation corrupts all subsequent messages in the batch. The tag enum must stay in sync across host, native plugins, and WASM plugins.
- Safe modification: Always add new tags at the end of the enum. Never reorder or remove existing tags. Add integration tests that round-trip messages through Reader/Writer. Bump `ABI_VERSION` on any wire-format change.
- Test coverage: `src/plugins/lib.zig` has Reader/Writer round-trip tests (lines 76-113), but no tests for the runtime's `iterOutMsgs` or `dispatchOutMsgs`.

**Renderer.zig (1152 LOC) -- single largest GUI file:**
- Files: `src/gui/Renderer.zig`
- Why fragile: Handles canvas rendering, viewport transforms, subcircuit symbol resolution and caching, device primitive drawing, wire rendering, selection overlay, grid drawing, and mouse interaction -- all in one file. The subcircuit cache uses module-level mutable state with `page_allocator`.
- Safe modification: Changes to rendering should be tested visually on both native and web backends. The subcircuit cache is stateful -- be careful with concurrent document switching.
- Test coverage: Zero unit tests. The Renderer has no test block at all. All testing is manual/visual.

**core/Schemify.zig (1169 LOC) -- net resolution logic:**
- Files: `src/core/Schemify.zig`
- Why fragile: The `resolveNets` function (approximately lines 250-530) performs a multi-pass algorithm: pin-to-wire mapping, union-find merging, label resolution, auto-naming, and connection list building. It uses many `catch {}` error swallows (30+ occurrences) which silently drop allocation failures or data inconsistencies.
- Safe modification: Any change to net resolution should be verified against complex schematics with buses, hierarchical references, and label connectivity. Add assertions or logging for the `catch {}` paths.
- Test coverage: One structural test (`test "struct size"` at line 1167). No behavioral tests for net resolution, reading, or writing.

**core/Reader.zig (1259 LOC) -- .chn file parser:**
- Files: `src/core/Reader.zig`
- Why fragile: Parses the XSchem-compatible .chn format with extensive `catch {}` error swallowing (40+ occurrences). Malformed input silently produces incomplete schematics rather than reporting errors. The parser handles multiple sub-formats (XSchem, KiCad-like, digital inline blocks) in a single function.
- Safe modification: Add regression test files for each supported format variant. Replace `catch {}` with `catch continue` where appropriate and add a parse-error accumulator.
- Test coverage: No unit tests in the file.

**Module-level mutable state in GUI dialogs:**
- Files: `src/gui/Dialogs/FindDialog.zig` (lines 19-23), `src/gui/Dialogs/PropsDialog.zig` (lines 11-14), `src/gui/FileExplorer.zig` (lines 40-46), `src/gui/LibraryBrowser.zig` (lines 28-29), `src/gui/Marketplace.zig` (line 34), `src/gui/Renderer.zig` (lines 34-35)
- Why fragile: Module-level `var` declarations are effectively global mutable state. They persist across frames and document switches. If a dialog is open when the active document changes, the stale `inst_idx` or `selected_file` could reference invalid indices.
- Safe modification: Always bounds-check module-level indices against current document state before use. Consider moving dialog state into `GuiState` so it resets with document switches.
- Test coverage: No tests for any dialog module.

## Scaling Limits

**History max_depth = 64:**
- Current capacity: 64 undo steps.
- Limit: Complex editing sessions exhaust the undo history quickly. Heavy users of rotate/nudge commands can burn through 64 steps in minutes.
- Scaling path: Increase `max_depth` and switch to a ring buffer. Consider command coalescing (e.g., merging consecutive nudge commands into a single move).

**CommandQueue max_capacity = 64:**
- Current capacity: 64 pending commands per frame.
- Limit: Unlikely to be hit in normal use, but automated testing or plugin command floods could trigger `error.Full`.
- Scaling path: Increase capacity or use a dynamically-growing ring buffer.

**EventBuffer MAX_EVENTS (plugin runtime):**
- Current capacity: Defined in `src/plugins/types.zig` (likely 64 or 128).
- Limit: Rapid GUI interaction (many slider drags in one frame) silently drops events beyond the cap.
- Scaling path: Make the event buffer dynamically-growing, or increase the cap and add a warning log when events are dropped.

**Fixed-size path buffers (512 bytes):**
- Current capacity: Many path operations use `[512]u8` stack buffers.
- Limit: Deeply nested project directories or long home directory paths will cause silent truncation or `bufPrint` failures.
- Files: `src/state/Document.zig` (lines 77-78), `src/commands/File.zig` (line 89), `src/commands/Hierarchy.zig` (lines 75, 101), `src/commands/Netlist.zig` (line 78), `src/gui/Renderer.zig` (line 50), `src/plugins/runtime.zig` (lines 383, 390, 394, 407)
- Scaling path: Use `std.fmt.allocPrint` with the GPA for paths that could exceed 512 bytes, or increase buffer sizes to 4096 (matching the plugin runtime buffers).

## Dependencies at Risk

**dvui text entry instability:**
- Risk: dvui's text entry widget API is explicitly noted as "not yet stable" in CLAUDE.md. Multiple GUI features (FindDialog, Marketplace search, PropsDialog editing) are blocked waiting for this.
- Impact: Three major GUI features are non-functional stubs.
- Migration plan: Monitor dvui upstream for text entry stabilisation. When ready, wire `query_buf` / `search_buf` to `dvui.textInput()` or equivalent. Consider a temporary workaround using the existing command-bar text input for search queries.

**rsvg-convert for PNG/PDF export:**
- Risk: Export to PNG and PDF requires `rsvg-convert` to be installed on the system. The command is spawned without checking if it exists first.
- Impact: Export silently falls back to SVG-only with a status message if the tool is missing. Users may not understand why PNG/PDF export "doesn't work."
- Files: `src/commands/View.zig` (lines 72-73, 176-179)
- Migration plan: Add a check for `rsvg-convert` availability at startup or first export attempt. Consider bundling a minimal SVG-to-PNG renderer or using raylib's built-in screenshot capability for the native backend.

**ngspice as hardcoded simulator:**
- Risk: `Document.runSpiceSim` hardcodes `"ngspice"` as the simulator binary. No path configuration, no fallback.
- Impact: Simulation fails silently if ngspice is not installed or not on PATH.
- Files: `src/state/Document.zig` (line 85)
- Migration plan: Read the simulator path from `ProjectConfig` (Config.toml). Support Xyce as an alternative (the SpiceIF backend enum already includes `.xyce`).

## Missing Critical Features

**No unsaved-changes warning:**
- Problem: Closing a tab or quitting the application does not check `document.dirty`. Unsaved work is silently lost.
- Blocks: Safe document management. Users must manually save before every close/quit.
- Files: `src/commands/File.zig` (lines 38-51) -- close_tab does not check `dirty`

**No multi-select drag (rubber-band selection):**
- Problem: The GUI has single-click selection but no click-and-drag rectangular selection for bulk instance/wire selection.
- Blocks: Efficient editing of complex schematics where select-all is too broad.

**No copy/paste across documents:**
- Problem: The clipboard is part of AppState (shared across tabs), but there is no explicit cross-document paste test or handling for allocator lifetime differences.
- Files: `src/state/AppState.zig` (line 42), `src/commands/Clipboard.zig`

## Test Coverage Gaps

**GUI modules -- zero test coverage:**
- What's not tested: All of `src/gui/` -- Renderer, PluginPanels, FileExplorer, LibraryBrowser, Marketplace, all Dialogs, all Bars, Actions, Keybinds, ContextMenu, Theme (Theme has some tests but other GUI files have none).
- Files: `src/gui/Renderer.zig`, `src/gui/PluginPanels.zig`, `src/gui/FileExplorer.zig`, `src/gui/lib.zig`, `src/gui/Actions.zig`, `src/gui/Bars/ToolBar.zig`, `src/gui/Bars/TabBar.zig`, `src/gui/Bars/CommandBar.zig`
- Risk: Rendering regressions, layout breakage, and interaction bugs go undetected. The Renderer (1152 LOC) is entirely untested.
- Priority: High for Renderer and Actions; Medium for dialogs and bars.

**Command handlers -- no integration tests:**
- What's not tested: `src/commands/Edit.zig`, `src/commands/File.zig`, `src/commands/Selection.zig`, `src/commands/Wire.zig`, `src/commands/Clipboard.zig`, `src/commands/View.zig`, `src/commands/Sim.zig`, `src/commands/Hierarchy.zig`, `src/commands/Netlist.zig`. Only `Undo.zig` has a trivial struct-size test.
- Files: All files in `src/commands/`
- Risk: Command dispatch regressions, undo/redo breakage, selection logic errors. The delete_selected + undo round-trip is not tested.
- Priority: High -- these are the core editing operations.

**core/Schemify.zig -- no behavioral tests:**
- What's not tested: Net resolution, schematic read/write round-trip, wire-to-net mapping, label connectivity, bus expansion.
- Files: `src/core/Schemify.zig` (1169 LOC, only 1 struct-size test)
- Risk: Net resolution bugs produce incorrect netlists. The 30+ `catch {}` swallows in resolveNets could mask data corruption.
- Priority: High -- this is the core data model.

**core/Reader.zig -- no parser tests:**
- What's not tested: .chn file parsing, XSchem format compatibility, property extraction, pin parsing, digital block inline parsing.
- Files: `src/core/Reader.zig` (1259 LOC, 0 tests)
- Risk: Parser regressions break file loading. Malformed files could cause silent data loss.
- Priority: High -- file I/O correctness is critical.

**Plugin runtime -- no host-side tests:**
- What's not tested: `runtime.tick()`, `runtime.loadStartup()`, output message dispatching (`dispatchOutMsgs`), event serialization (`writeEvent`), widget parsing (`parseWidget`).
- Files: `src/plugins/runtime.zig` (681 LOC, 0 tests)
- Risk: Plugin interaction bugs (wrong panel_id routing, dropped events, malformed messages) are hard to debug in production.
- Priority: Medium -- covered partially by the Reader/Writer round-trip tests in `src/plugins/lib.zig`.

**Pervasive silent error swallowing (catch {}):**
- What's not tested: Over 90 `catch {}` occurrences across the codebase silently discard errors, primarily `OutOfMemory`. None of these failure paths are tested.
- Files: Most concentrated in `src/core/Reader.zig` (40+), `src/core/Schemify.zig` (30+), `src/commands/` (scattered)
- Risk: OOM conditions produce silently corrupt data structures rather than surfacing errors. Debugging production issues becomes extremely difficult.
- Priority: Medium -- replace `catch {}` with `catch |err| log.warn(...)` at minimum, or propagate errors where possible.

---

*Concerns audit: 2026-04-04*
