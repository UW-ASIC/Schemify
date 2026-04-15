//! Input handling — keyboard dispatch for normal mode, command mode, and file explorer.
//!
//! Extracted from lib.zig so the frame orchestrator stays focused on layout.
//! Space-bar handling lives here as it's cross-cutting input normalization.
//! Mode handlers live in Input/ subdirectory.

const dvui = @import("dvui");
const st = @import("state");
const AppState = st.AppState;

const normal = @import("Input/NormalMode.zig");
const command = @import("Input/CommandMode.zig");
const file_explorer = @import("Input/FileExplorerMode.zig");

// ── Public API ────────────────────────────────────────────────────────── //

pub fn handleInput(app: *AppState) void {
    for (dvui.events()) |*ev| {
        if (ev.handled) continue;
        switch (ev.evt) {
            .key => |k| {
                if (k.code == .space and !app.gui.hot.command_mode and !app.open_file_explorer) {
                    const cs = &app.gui.hot.canvas;
                    switch (k.action) {
                        .down => {
                            cs.space_held = true;
                            cs.space_drag_happened = false;
                        },
                        .up => {
                            cs.space_held = false;
                            if (!cs.space_drag_happened) {
                                cs.pan_mode = .grab;
                            }
                            cs.space_drag_happened = false;
                        },
                        else => {},
                    }
                    ev.handled = true;
                    continue;
                }
                if (k.action == .up) continue;
                if (app.open_file_explorer) {
                    if (file_explorer.handleFileExplorerInput(app, k.code, k.mod.shift())) {
                        ev.handled = true;
                        continue;
                    }
                }
                if (app.gui.hot.command_mode) {
                    if (command.handleCommandMode(app, k.code, k.mod.shift())) ev.handled = true;
                } else {
                    if (normal.handleNormalMode(app, k.code, k.mod.control(), k.mod.shift(), k.mod.alt()))
                        ev.handled = true;
                }
            },
            else => {},
        }
    }
}