//! Input handling — keyboard dispatch for normal, command, and file explorer modes.
//! Space-bar pan handling is cross-cutting and lives here.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const AppState = st.AppState;
const actions = @import("../actions.zig");
const keybinds = @import("keybinds.zig");
const km = @import("key_mapping.zig");
const plugins = @import("plugins");
const PluginHost = plugins.PluginHost.PluginHost;
const plugin_panels = @import("../PluginPanels.zig");
const file_explorer = @import("../Panels/file_explorer.zig");

// ── Public API ───────────────────────────────────────────────────────────────

pub fn handleInput(app: *AppState) void {
    for (dvui.events()) |*ev| {
        if (ev.handled) continue;
        switch (ev.evt) {
            .key => |k| {
                // Space-bar pan mode (cross-cutting)
                if (k.code == .space and !app.gui.hot.command_mode and !app.open_file_explorer) {
                    const cs = &app.gui.hot.canvas;
                    switch (k.action) {
                        .down => { cs.space_held = true; cs.space_drag_happened = false; },
                        .up => { cs.space_held = false; if (!cs.space_drag_happened) cs.pan_mode = .grab; cs.space_drag_happened = false; },
                        else => {},
                    }
                    ev.handled = true;
                    continue;
                }

                // Plugin key dispatch
                if (dispatchPluginKey(app, k.code, k.mod.control(), k.mod.shift(), k.mod.alt(), k.action)) {
                    ev.handled = true;
                    continue;
                }

                if (k.action == .up) continue;

                // File explorer mode
                if (app.open_file_explorer) {
                    if (handleFileExplorer(app, k.code, k.mod.shift())) { ev.handled = true; continue; }
                }

                // Command mode vs normal mode
                if (app.gui.hot.command_mode) {
                    if (handleCommand(app, k.code, k.mod.shift())) ev.handled = true;
                } else {
                    if (handleNormal(app, k.code, k.mod.control(), k.mod.shift(), k.mod.alt())) ev.handled = true;
                }
            },
            else => {},
        }
    }
}

// ── Normal mode ──────────────────────────────────────────────────────────────

fn handleNormal(app: *AppState, code: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) bool {
    // Plugin keybinds
    if (dispatchPluginKeybind(app, code, ctrl, shift, alt)) return true;

    const plain = !ctrl and !shift and !alt;
    if (plain and plugin_panels.handlePlainKeyToggle(app, km.keyToChar(code, false))) return true;

    // Static keybinds
    if (keybinds.lookup(code, ctrl, shift, alt)) |kb| {
        switch (kb.action) {
            .queue => |q| actions.enqueue(app, q.cmd, q.msg),
            .gui => |gg| actions.runGuiCommand(app, gg),
        }
        return true;
    }

    // Enter command mode with ':'
    if (code == .semicolon and shift and !ctrl and !alt) {
        app.gui.hot.command_mode = true;
        app.gui.hot.command_len = 0;
        @memset(&app.gui.cold.command_buf, 0);
        app.status_msg = "Command mode";
        return true;
    }

    // Grid toggle
    if (code == .g and plain) {
        app.show_grid = !app.show_grid;
        app.status_msg = if (app.show_grid) "Grid on" else "Grid off";
        return true;
    }

    // Arrow keys: nudge selection or pan
    if (plain) switch (code) {
        .up, .down, .left, .right => {
            const has_sel = if (app.active()) |d| !d.selection.isEmpty() else false;
            if (has_sel) {
                const cmd: @import("commands").Undoable = switch (code) {
                    .up => .nudge_up, .down => .nudge_down,
                    .left => .nudge_left, .right => .nudge_right,
                    else => unreachable,
                };
                actions.enqueue(app, .{ .undoable = cmd }, switch (code) {
                    .up => "Nudge up", .down => "Nudge down",
                    .left => "Nudge left", .right => "Nudge right",
                    else => unreachable,
                });
            } else if (app.active()) |d| {
                switch (code) {
                    .up => d.view.pan[1] -= 50,
                    .down => d.view.pan[1] += 50,
                    .left => d.view.pan[0] -= 50,
                    .right => d.view.pan[0] += 50,
                    else => {},
                }
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

// ── Command mode ─────────────────────────────────────────────────────────────

fn handleCommand(app: *AppState, code: dvui.enums.Key, shift: bool) bool {
    switch (code) {
        .escape => { app.gui.hot.command_mode = false; app.status_msg = "Command canceled"; return true; },
        .enter => {
            actions.runVimCommand(app, app.gui.cold.command_buf[0..app.gui.hot.command_len]);
            app.gui.hot.command_mode = false;
            app.gui.hot.command_len = 0;
            @memset(&app.gui.cold.command_buf, 0);
            return true;
        },
        .backspace => {
            if (app.gui.hot.command_len > 0) {
                app.gui.hot.command_len -= 1;
                app.gui.cold.command_buf[app.gui.hot.command_len] = 0;
            }
            return true;
        },
        else => {
            const ch = km.keyToChar(code, shift);
            if (ch == 0 or app.gui.hot.command_len >= app.gui.cold.command_buf.len - 1) return false;
            app.gui.cold.command_buf[app.gui.hot.command_len] = ch;
            app.gui.hot.command_len += 1;
            return true;
        },
    }
}

// ── File explorer mode ───────────────────────────────────────────────────────

fn handleFileExplorer(app: *AppState, code: dvui.enums.Key, shift: bool) bool {
    return switch (code) {
        .escape => file_explorer.onKeyEscape(app),
        .backspace => file_explorer.onKeyBackspace(app),
        else => blk: {
            const ch = km.keyToChar(code, shift);
            break :blk if (ch == 0) false else file_explorer.onKeyChar(app, ch);
        },
    };
}

// ── Plugin dispatch ──────────────────────────────────────────────────────────

fn dispatchPluginKey(app: *AppState, code: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool, action: anytype) bool {
    const host = app.plugin_host orelse return false;
    const ch = km.keyToChar(code, shift);
    if (ch == 0) return false;
    const mods = km.packMods(ctrl, shift, alt);
    const act: u8 = switch (action) { .down => 0, .up => 1, .repeat => 2 };
    return host.dispatchKeyEvent(ch, mods, act);
}

fn dispatchPluginKeybind(app: *AppState, code: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) bool {
    const ch = km.keyToChar(code, false);
    if (ch == 0) return false;
    const mods = km.packMods(ctrl, shift, alt);
    for (app.gui.cold.plugin_keybinds.items) |kb| {
        if (ch == kb.key and mods == kb.mods) {
            const alloc = app.gpa.allocator();
            app.queue.push(alloc, .{ .immediate = .{ .plugin_command = .{ .tag = kb.cmd_tag, .payload = null } } }) catch {};
            return true;
        }
    }
    return false;
}
