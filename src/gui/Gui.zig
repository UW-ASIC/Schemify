//! GUI shell — toolbar, tabbar, renderer, command bar.
//!
//! Frame layout order:
//!   toolbar -> tabbar -> { left_sidebar | { renderer / bottom_bar } | right_sidebar }
//!   -> command_bar -> overlays -> marketplace

const dvui       = @import("dvui");
const AppState   = @import("state").AppState;
const Runtime    = @import("runtime").Runtime;
const actions    = @import("Actions.zig");
const keybinds   = @import("Keybinds.zig");
const toolbar    = @import("Toolbar.zig");
const tabbar     = @import("Tabbar.zig");
const renderer_mod = @import("Renderer.zig");

var renderer_state: renderer_mod.Renderer = .{};
const command_bar    = @import("CommandBar.zig");
const plugin_panels  = @import("PluginPanels.zig");
const marketplace    = @import("Marketplace.zig");

/// Render a single GUI frame: input handling, layout, and all sub-panels.
pub fn frame(app: *AppState, rt: *Runtime) !void {
    handleInput(app);

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer outer.deinit();

    toolbar.draw(app);
    tabbar.draw(app);
    {
        var middle = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer middle.deinit();
        plugin_panels.drawSidebar(app, rt, .left_sidebar);
        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer col.deinit();
            renderer_state.draw(app);
            plugin_panels.drawBottomBar(app, rt);
        }
        plugin_panels.drawSidebar(app, rt, .right_sidebar);
    }
    command_bar.draw(app);
    plugin_panels.drawOverlays(app, rt);
    marketplace.draw(app);
}

// ── Input handling ────────────────────────────────────────────────────────── //

fn handleInput(app: *AppState) void {
    for (dvui.events()) |*ev| {
        if (ev.handled) continue;
        switch (ev.evt) {
            .mouse => |m| switch (m.action) {
                .wheel_y => |dy| {
                    if (dy > 0) actions.enqueue(app, .{ .immediate = .zoom_in  }, "Zoom in")
                    else if (dy < 0) actions.enqueue(app, .{ .immediate = .zoom_out }, "Zoom out");
                    ev.handled = true;
                },
                else => {},
            },
            .key => |k| {
                if (k.action != .down and k.action != .repeat) continue;
                if (app.gui.command_mode) {
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

// ── Command mode ──────────────────────────────────────────────────────────── //

fn handleCommandMode(app: *AppState, code: dvui.enums.Key, shift: bool) bool {
    switch (code) {
        .escape => {
            app.gui.command_mode = false;
            app.status_msg = "Command canceled";
            return true;
        },
        .enter => {
            actions.runVimCommand(app, app.gui.command_buf[0..app.gui.command_len]);
            app.gui.command_mode = false;
            app.gui.command_len  = 0;
            @memset(&app.gui.command_buf, 0);
            return true;
        },
        .backspace => {
            if (app.gui.command_len > 0) {
                app.gui.command_len -= 1;
                app.gui.command_buf[app.gui.command_len] = 0;
            }
            return true;
        },
        else => {
            const ch = keyToChar(code, shift);
            if (ch == 0 or app.gui.command_len >= app.gui.command_buf.len - 1) return false;
            app.gui.command_buf[app.gui.command_len] = ch;
            app.gui.command_len += 1;
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
        app.gui.command_mode = true;
        app.gui.command_len  = 0;
        @memset(&app.gui.command_buf, 0);
        app.status_msg = "Command mode";
        return true;
    }

    if (code == .g and plain) {
        app.show_grid  = !app.show_grid;
        app.status_msg = if (app.show_grid) "Grid on" else "Grid off";
        return true;
    }

    // Arrow pan goes direct — no pan_* tags in Immediate.
    if (plain) switch (code) {
        .up    => { app.view.panBy(0, -50);  return true; },
        .down  => { app.view.panBy(0,  50);  return true; },
        .left  => { app.view.panBy(-50, 0);  return true; },
        .right => { app.view.panBy(50,  0);  return true; },
        else   => {},
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
    const mods = (@as(u8, @intFromBool(ctrl))  << 0) |
                 (@as(u8, @intFromBool(shift))  << 1) |
                 (@as(u8, @intFromBool(alt))    << 2);
    for (app.gui.plugin_keybinds.items) |kb| {
        if (key_char == kb.key and mods == kb.mods) {
            app.queue.push(app.allocator(), .{ .immediate = .{ .plugin_command = .{ .tag = kb.cmd_tag, .payload = null } } }) catch {};
            return true;
        }
    }
    return false;
}

fn dispatchStaticKeybind(app: *AppState, code: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) bool {
    const kb = keybinds.lookup(code, ctrl, shift, alt) orelse return false;
    switch (kb.action) {
        .queue => |q| actions.enqueue(app, q.cmd, q.msg),
        .gui   => |g| actions.runGuiCommand(app, g),
    }
    return true;
}

// ── Key → char lookup table ───────────────────────────────────────────────── //

fn keyToChar(code: dvui.enums.Key, shift: bool) u8 {
    const key_int = @intFromEnum(code);
    if (key_int >= key_char_table.len) return 0;
    const entry = key_char_table[key_int];
    if (entry[0] == 0) return 0;
    return if (shift) entry[1] else entry[0];
}

/// Comptime lookup table: key_char_table[key_enum_int] = .{ unshifted, shifted }.
/// Zero entries mean the key has no printable character mapping.
const key_char_table = blk: {
    const Key = dvui.enums.Key;
    const max_key = max: {
        var m: comptime_int = 0;
        for (@typeInfo(Key).@"enum".fields) |fld| if (fld.value > m) { m = fld.value; };
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
        .{ Key.zero, '0', ')' },           .{ Key.one, '1', '!' },
        .{ Key.two, '2', '@' },            .{ Key.three, '3', '#' },
        .{ Key.four, '4', '$' },           .{ Key.five, '5', '%' },
        .{ Key.six, '6', '^' },            .{ Key.seven, '7', '&' },
        .{ Key.eight, '8', '*' },          .{ Key.nine, '9', '(' },
        .{ Key.grave, '`', '~' },          .{ Key.minus, '-', '_' },
        .{ Key.equal, '=', '+' },          .{ Key.left_bracket, '[', '{' },
        .{ Key.right_bracket, ']', '}' },  .{ Key.backslash, '\\', '|' },
        .{ Key.semicolon, ';', ':' },      .{ Key.apostrophe, '\'', '"' },
        .{ Key.comma, ',', '<' },          .{ Key.period, '.', '>' },
        .{ Key.slash, '/', '?' },          .{ Key.space, ' ', ' ' },
    };

    for (mappings) |m| table[@intFromEnum(m[0])] = .{ m[1], m[2] };

    break :blk table;
};
