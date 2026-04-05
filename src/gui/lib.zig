//! GUI shell — toolbar, tabbar, renderer, command bar, dialogs, overlays.
//!
//! Frame layout order:
//!   toolbar -> tabbar -> { left_sidebar | { renderer / bottom_bar } | right_sidebar }
//!   -> command_bar -> overlays -> file_explorer -> library_browser
//!   -> context_menu -> keybinds_dlg -> find_dlg -> props_dlg -> marketplace

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");

const AppState = st.AppState;

// ── Sub-module imports ──────────────────────────────────────────────────── //

const actions = @import("Actions.zig");
const keybinds = @import("Keybinds.zig");
const RendererMod = @import("Renderer.zig");
const Renderer = RendererMod.Renderer;
const CanvasEvent = RendererMod.CanvasEvent;

// Bars
const toolbar = @import("Bars/ToolBar.zig");
const tabbar = @import("Bars/TabBar.zig");
const command_bar = @import("Bars/CommandBar.zig");

// Panels & browsers
const plugin_panels = @import("PluginPanels.zig");
const marketplace = @import("Marketplace.zig");
const file_explorer = @import("FileExplorer.zig");
const library_browser = @import("LibraryBrowser.zig");

// Dialogs
const context_menu = @import("ContextMenu.zig");
const keybinds_dlg = @import("Dialogs/KeybindsDialog.zig");
const find_dlg = @import("Dialogs/FindDialog.zig");
const props_dlg = @import("Dialogs/PropsDialog.zig");

// ── Module-level state ─────────────────────────────────────────────────── //

var renderer_state: Renderer = .{};

// ── Public API ─────────────────────────────────────────────────────────── //

/// Render a single GUI frame: input handling, layout, and all sub-panels.
pub fn frame(app: *AppState) !void {
    handleInput(app);

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer outer.deinit();

    toolbar.draw(app);
    tabbar.draw(app);
    {
        var middle = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer middle.deinit();
        plugin_panels.drawSidebar(app, .left_sidebar);
        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer col.deinit();
            const canvas_ev = renderer_state.draw(app);
            handleCanvasEvent(app, canvas_ev);
            plugin_panels.drawBottomBar(app);
        }
        plugin_panels.drawSidebar(app, .right_sidebar);
    }
    command_bar.draw(app);
    plugin_panels.drawOverlays(app);
    file_explorer.draw(app);
    library_browser.draw(app);
    context_menu.draw(app);

    // Sync keybinds dialog open state from gui flag.
    app.gui.keybinds_dialog.open = app.gui.keybinds_dialog.open or app.gui.keybinds_open;
    app.gui.keybinds_open = false;
    keybinds_dlg.draw(app);

    find_dlg.draw(app);
    props_dlg.draw(app);
    marketplace.draw(app);
}

// ── Canvas event dispatch ─────────────────────────────────────────────────── //

fn handleCanvasEvent(app: *AppState, ev: CanvasEvent) void {
    switch (ev) {
        .none => {},
        .click => |pt| {
            switch (app.tool.active) {
                .wire => {
                    if (app.tool.wire_start) |ws| {
                        // Second click: place the wire segment.
                        actions.enqueue(app, .{ .undoable = .{ .add_wire = .{
                            .start = ws,
                            .end = pt,
                        } } }, "Wire placed");
                        // Chain: next wire starts from this endpoint.
                        app.tool.wire_start = pt;
                    } else {
                        // First click: set the starting point.
                        app.tool.wire_start = pt;
                        app.status_msg = "Wire start set — click to place endpoint";
                    }
                },
                .select => {
                    // Point-based hit testing: find nearest instance.
                    const doc = app.active() orelse return;
                    const sch = &doc.sch;
                    var best_idx: ?usize = null;
                    var best_dist: i64 = 400; // 20-unit click radius squared
                    for (0..sch.instances.len) |i| {
                        const ix = sch.instances.items(.x)[i];
                        const iy = sch.instances.items(.y)[i];
                        const dx = @as(i64, pt[0]) - @as(i64, ix);
                        const dy = @as(i64, pt[1]) - @as(i64, iy);
                        const d2 = dx * dx + dy * dy;
                        if (d2 < best_dist) {
                            best_dist = d2;
                            best_idx = i;
                        }
                    }
                    if (best_idx) |idx| {
                        app.selection.clear();
                        const a = app.allocator();
                        app.selection.instances.resize(a, sch.instances.len, false) catch return;
                        app.selection.instances.set(idx);
                        app.status_msg = "Selected instance";
                    } else {
                        app.selection.clear();
                        app.status_msg = "Ready";
                    }
                },
                else => {},
            }
        },
        .double_click => |_| {
            actions.enqueue(app, .{ .immediate = .edit_properties }, "Edit properties");
        },
        .right_click => |rc| {
            _ = rc;
            app.gui.ctx_menu.open = true;
        },
    }
}

// ── Input handling ────────────────────────────────────────────────────────── //

fn handleInput(app: *AppState) void {
    for (dvui.events()) |*ev| {
        if (ev.handled) continue;
        switch (ev.evt) {
            .key => |k| {
                // Spacebar hold/release for pan mode.
                if (k.code == .space and !app.gui.command_mode) {
                    renderer_state.space_held = (k.action != .up);
                    if (k.action == .up) renderer_state.dragging = false;
                    ev.handled = true;
                    continue;
                }
                if (k.action == .up) continue;
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
            resetCommandBuffer(app);
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
    // Plugin keybinds.
    if (dispatchPluginKeybind(app, code, ctrl, shift, alt)) return true;

    // Plain-key plugin panel toggles.
    const plain = !ctrl and !shift and !alt;
    if (plain and plugin_panels.handlePlainKeyToggle(app, keyToChar(code, false))) return true;

    // Static keybind table.
    if (dispatchStaticKeybind(app, code, ctrl, shift, alt)) return true;

    // Colon → enter command mode.
    if (code == .semicolon and shift and !ctrl and !alt) {
        app.gui.command_mode = true;
        resetCommandBuffer(app);
        app.status_msg = "Command mode";
        return true;
    }

    // Grid toggle.
    if (code == .g and plain) {
        app.show_grid = !app.show_grid;
        app.status_msg = if (app.show_grid) "Grid on" else "Grid off";
        return true;
    }

    // Arrow keys → pan.
    if (plain) switch (code) {
        .up => {
            app.view.pan[1] -= 50;
            return true;
        },
        .down => {
            app.view.pan[1] += 50;
            return true;
        },
        .left => {
            app.view.pan[0] -= 50;
            return true;
        },
        .right => {
            app.view.pan[0] += 50;
            return true;
        },
        else => {},
    };

    // Escape.
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
    for (app.gui.plugin_keybinds.items) |kb| {
        if (key_char == kb.key and mods == kb.mods) {
            const alloc = app.gpa.allocator();
            app.queue.push(alloc, .{ .immediate = .{ .plugin_command = .{ .tag = kb.cmd_tag, .payload = null } } }) catch {};
            return true;
        }
    }
    return false;
}

fn resetCommandBuffer(app: *AppState) void {
    app.gui.command_len = 0;
    @memset(&app.gui.command_buf, 0);
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

fn keyToChar(code: dvui.enums.Key, shift: bool) u8 {
    const key_int = @intFromEnum(code);
    if (key_int >= key_char_table.len) return 0;
    const entry = key_char_table[key_int];
    if (entry[0] == 0) return 0;
    return if (shift) entry[1] else entry[0];
}

/// Comptime lookup table: key_char_table[key_enum_int] = .{ unshifted, shifted }.
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
