//! Input handling — keyboard dispatch for normal mode, command mode, and file explorer.
//!
//! Extracted from lib.zig so the frame orchestrator stays focused on layout.

const dvui = @import("dvui");
const st = @import("state");
const AppState = st.AppState;
const actions = @import("Actions.zig");
const keybinds = @import("Keybinds.zig");
const file_explorer = @import("FileExplorer.zig");
const plugin_panels = @import("PluginPanels.zig");

// ── Public API ────────────────────────────────────────────────────────────── //

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
                    if (handleFileExplorerInput(app, k.code, k.mod.shift())) {
                        ev.handled = true;
                        continue;
                    }
                }
                if (app.gui.hot.command_mode) {
                    if (handleCommandMode(app, k.code, k.mod.shift())) ev.handled = true;
                } else {
                    if (handleNormalMode(app, k.code, k.mod.control(), k.mod.shift(), k.mod.alt()))
                        ev.handled = true;
                }
            },
            else => {},
        }
    }
}

// ── FileExplorer modal input ──────────────────────────────────────────────── //

fn handleFileExplorerInput(app: *AppState, code: dvui.enums.Key, shift: bool) bool {
    return switch (code) {
        .escape => file_explorer.onKeyEscape(app),
        .backspace => file_explorer.onKeyBackspace(app),
        else => blk: {
            const ch = keyToChar(code, shift);
            if (ch == 0) break :blk false;
            break :blk file_explorer.onKeyChar(app, ch);
        },
    };
}

// ── Command mode ──────────────────────────────────────────────────────────── //

fn handleCommandMode(app: *AppState, code: dvui.enums.Key, shift: bool) bool {
    switch (code) {
        .escape => {
            app.gui.hot.command_mode = false;
            app.status_msg = "Command canceled";
            return true;
        },
        .enter => {
            actions.runVimCommand(app, app.gui.cold.command_buf[0..app.gui.hot.command_len]);
            app.gui.hot.command_mode = false;
            resetCommandBuffer(app);
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
            const ch = keyToChar(code, shift);
            if (ch == 0 or app.gui.hot.command_len >= app.gui.cold.command_buf.len - 1) return false;
            app.gui.cold.command_buf[app.gui.hot.command_len] = ch;
            app.gui.hot.command_len += 1;
            return true;
        },
    }
}

// ── Normal mode ───────────────────────────────────────────────────────────── //

fn handleNormalMode(app: *AppState, code: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) bool {
    if (dispatchPluginKeybind(app, code, ctrl, shift, alt)) return true;

    const plain = !ctrl and !shift and !alt;
    if (plain and plugin_panels.handlePlainKeyToggle(app, keyToChar(code, false))) return true;

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
            if (app.active()) |d| d.view.pan[1] -= 50;
            return true;
        },
        .down => {
            if (app.active()) |d| d.view.pan[1] += 50;
            return true;
        },
        .left => {
            if (app.active()) |d| d.view.pan[0] -= 50;
            return true;
        },
        .right => {
            if (app.active()) |d| d.view.pan[0] += 50;
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
    const key_char = keyToChar(code, false);
    if (key_char == 0) return false;
    const mods = packMods(ctrl, shift, alt);
    for (app.gui.cold.plugin_keybinds.items) |kb| {
        if (key_char == kb.key and mods == kb.mods) {
            const alloc = app.gpa.allocator();
            app.queue.push(alloc, .{ .immediate = .{ .plugin_command = .{ .tag = kb.cmd_tag, .payload = null } } }) catch {};
            return true;
        }
    }
    return false;
}

fn resetCommandBuffer(app: *AppState) void {
    app.gui.hot.command_len = 0;
    @memset(&app.gui.cold.command_buf, 0);
}

fn packMods(ctrl: bool, shift: bool, alt: bool) u8 {
    return (@as(u8, @intFromBool(ctrl)) << 0) |
        (@as(u8, @intFromBool(shift)) << 1) |
        (@as(u8, @intFromBool(alt)) << 2);
}

fn dispatchStaticKeybind(app: *AppState, code: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) bool {
    const kb = keybinds.lookup(code, ctrl, shift, alt) orelse return false;
    switch (kb.action) {
        .queue => |q| actions.enqueue(app, q.cmd, q.msg),
        .gui => |g| actions.runGuiCommand(app, g),
    }
    return true;
}

// ── Key to char lookup table ─────────────────────────────────────────────── //

pub fn keyToChar(code: dvui.enums.Key, shift: bool) u8 {
    const key_int = @intFromEnum(code);
    if (key_int >= key_char_table.len) return 0;
    const entry = key_char_table[key_int];
    if (entry[0] == 0) return 0;
    return if (shift) entry[1] else entry[0];
}

const key_char_table = blk: {
    const Key = dvui.enums.Key;
    const max_key = max: {
        var m: comptime_int = 0;
        for (@typeInfo(Key).@"enum".fields) |fld| if (fld.value > m) {
            m = fld.value;
        };
        break :max m;
    };
    var table: [max_key + 1][2]u8 = .{.{ 0, 0 }} ** (max_key + 1);

    const mappings = .{
        .{ Key.a, 'a', 'A' },             .{ Key.b, 'b', 'B' },
        .{ Key.c, 'c', 'C' },             .{ Key.d, 'd', 'D' },
        .{ Key.e, 'e', 'E' },             .{ Key.f, 'f', 'F' },
        .{ Key.g, 'g', 'G' },             .{ Key.h, 'h', 'H' },
        .{ Key.i, 'i', 'I' },             .{ Key.j, 'j', 'J' },
        .{ Key.k, 'k', 'K' },             .{ Key.l, 'l', 'L' },
        .{ Key.m, 'm', 'M' },             .{ Key.n, 'n', 'N' },
        .{ Key.o, 'o', 'O' },             .{ Key.p, 'p', 'P' },
        .{ Key.q, 'q', 'Q' },             .{ Key.r, 'r', 'R' },
        .{ Key.s, 's', 'S' },             .{ Key.t, 't', 'T' },
        .{ Key.u, 'u', 'U' },             .{ Key.v, 'v', 'V' },
        .{ Key.w, 'w', 'W' },             .{ Key.x, 'x', 'X' },
        .{ Key.y, 'y', 'Y' },             .{ Key.z, 'z', 'Z' },
        .{ Key.zero, '0', ')' },          .{ Key.one, '1', '!' },
        .{ Key.two, '2', '@' },           .{ Key.three, '3', '#' },
        .{ Key.four, '4', '$' },          .{ Key.five, '5', '%' },
        .{ Key.six, '6', '^' },           .{ Key.seven, '7', '&' },
        .{ Key.eight, '8', '*' },         .{ Key.nine, '9', '(' },
        .{ Key.grave, '`', '~' },         .{ Key.minus, '-', '_' },
        .{ Key.equal, '=', '+' },         .{ Key.left_bracket, '[', '{' },
        .{ Key.right_bracket, ']', '}' }, .{ Key.backslash, '\\', '|' },
        .{ Key.semicolon, ';', ':' },     .{ Key.apostrophe, '\'', '"' },
        .{ Key.comma, ',', '<' },         .{ Key.period, '.', '>' },
        .{ Key.slash, '/', '?' },         .{ Key.space, ' ', ' ' },
    };

    for (mappings) |m| table[@intFromEnum(m[0])] = .{ m[1], m[2] };

    break :blk table;
};
