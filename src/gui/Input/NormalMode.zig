//! Normal-mode keyboard handling.
//!
//! Extracted from Input.zig for modularity.

const dvui = @import("dvui");
const st = @import("state");
const AppState = st.AppState;
const actions = @import("../Actions.zig");
const keybinds = @import("../Keybinds/Keybinds.zig");
const plugin_panels = @import("../PluginPanels.zig");
const km = @import("KeyMapping.zig");

pub fn handleNormalMode(app: *AppState, code: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) bool {
    if (dispatchPluginKeybind(app, code, ctrl, shift, alt)) return true;

    const plain = !ctrl and !shift and !alt;
    if (plain and plugin_panels.handlePlainKeyToggle(app, km.keyToChar(code, false))) return true;

    if (dispatchStaticKeybind(app, code, ctrl, shift, alt)) return true;

    if (code == .semicolon and shift and !ctrl and !alt) {
        app.gui.hot.command_mode = true;
        resetCommandBuffer(app);
        app.status_msg = "Command mode";
        return true;
    }

    if (code == .g and plain) {
        app.show_grid = !app.show_grid;
        app.status_msg = if (app.show_grid) "Grid on" else "Grid off";
        return true;
    }

    if (plain) switch (code) {
        .up => {
            const has_sel = if (app.active()) |d| !d.selection.isEmpty() else false;
            if (has_sel) {
                actions.enqueue(app, .{ .undoable = .nudge_up }, "Nudge up");
            } else {
                if (app.active()) |d| d.view.pan[1] -= 50;
            }
            return true;
        },
        .down => {
            const has_sel = if (app.active()) |d| !d.selection.isEmpty() else false;
            if (has_sel) {
                actions.enqueue(app, .{ .undoable = .nudge_down }, "Nudge down");
            } else {
                if (app.active()) |d| d.view.pan[1] += 50;
            }
            return true;
        },
        .left => {
            const has_sel = if (app.active()) |d| !d.selection.isEmpty() else false;
            if (has_sel) {
                actions.enqueue(app, .{ .undoable = .nudge_left }, "Nudge left");
            } else {
                if (app.active()) |d| d.view.pan[0] -= 50;
            }
            return true;
        },
        .right => {
            const has_sel = if (app.active()) |d| !d.selection.isEmpty() else false;
            if (has_sel) {
                actions.enqueue(app, .{ .undoable = .nudge_right }, "Nudge right");
            } else {
                if (app.active()) |d| d.view.pan[0] += 50;
            }
            return true;
        },
        else => {},
    };

    if (code == .escape and plain) {
        actions.enqueue(app, .{ .immediate = .escape_mode }, "Escape");
        return true;
    }

    return false;
}

fn dispatchPluginKeybind(app: *AppState, code: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) bool {
    const key_char = km.keyToChar(code, false);
    if (key_char == 0) return false;
    const mods = km.packMods(ctrl, shift, alt);
    for (app.gui.cold.plugin_keybinds.items) |kb| {
        if (key_char == kb.key and mods == kb.mods) {
            const alloc = app.gpa.allocator();
            app.queue.push(alloc, .{ .immediate = .{ .plugin_command = .{ .tag = kb.cmd_tag, .payload = null } } }) catch {};
            return true;
        }
    }
    return false;
}

fn dispatchStaticKeybind(app: *AppState, code: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) bool {
    const kb = keybinds.lookup(code, ctrl, shift, alt) orelse return false;
    switch (kb.action) {
        .queue => |q| actions.enqueue(app, q.cmd, q.msg),
        .gui => |g| actions.runGuiCommand(app, g),
    }
    return true;
}

fn resetCommandBuffer(app: *AppState) void {
    app.gui.hot.command_len = 0;
    @memset(&app.gui.cold.command_buf, 0);
}