//! Keybinds help window and keybind dispatch logic.

const std = @import("std");
const dvui = @import("dvui");
const AppState = @import("../state.zig").AppState;
const actions = @import("actions.zig");

// ── Local state ───────────────────────────────────────────────────────────── //

pub const State = struct {
    open: bool = false,
};

pub var state: State = .{};

// ── Keybind types ─────────────────────────────────────────────────────────── //

pub const KeybindAction = union(enum) {
    queue: struct { cmd: @import("../command.zig").Command, msg: []const u8 },
    gui: actions.GuiCommand,
};

pub const Keybind = struct {
    key: dvui.enums.Key,
    ctrl: bool,
    shift: bool,
    alt: bool,
    action: KeybindAction,
};

pub const static_keybinds = [_]Keybind{
    // File
    .{ .key = .n, .ctrl = true, .shift = false, .alt = false, .action = .{ .gui = .file_new } },
    .{ .key = .o, .ctrl = true, .shift = false, .alt = false, .action = .{ .gui = .file_open } },
    .{ .key = .s, .ctrl = true, .shift = false, .alt = false, .action = .{ .gui = .file_save } },
    .{ .key = .s, .ctrl = true, .shift = true, .alt = false, .action = .{ .gui = .file_save_as } },
    .{ .key = .s, .ctrl = false, .shift = false, .alt = true, .action = .{ .gui = .file_reload } },
    .{ .key = .l, .ctrl = true, .shift = false, .alt = false, .action = .{ .gui = .file_view_logs } },
    .{ .key = .n, .ctrl = true, .shift = true, .alt = false, .action = .{ .gui = .file_start_process } },
    .{ .key = .q, .ctrl = true, .shift = false, .alt = false, .action = .{ .gui = .file_exit } },
    // Tab management
    .{ .key = .t, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .new_tab = {} }, .msg = "New tab" } } },
    .{ .key = .w, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .close_tab = {} }, .msg = "Close tab" } } },
    .{ .key = .t, .ctrl = true, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .reopen_last_closed = {} }, .msg = "Reopen last closed" } } },
    // Simulation
    .{ .key = .f5, .ctrl = false, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .run_sim = .{ .sim = .ngspice } }, .msg = "Queued simulation" } } },
    .{ .key = .f6, .ctrl = false, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .plugins_refresh = {} }, .msg = "Queued plugin refresh signal" } } },
    // Zoom
    .{ .key = .equal, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .zoom_in = {} }, .msg = "Zoom in" } } },
    .{ .key = .minus, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .zoom_out = {} }, .msg = "Zoom out" } } },
    .{ .key = .zero, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .zoom_reset = {} }, .msg = "Zoom reset" } } },
    .{ .key = .f, .ctrl = true, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .zoom_fit_selected = {} }, .msg = "Zoom fit selected" } } },
    // Undo/Redo
    .{ .key = .z, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .undo = {} }, .msg = "Undo" } } },
    .{ .key = .y, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .redo = {} }, .msg = "Redo" } } },
    // Selection
    .{ .key = .a, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .select_all = {} }, .msg = "Select all" } } },
    .{ .key = .a, .ctrl = true, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .select_none = {} }, .msg = "Select none" } } },
    .{ .key = .f, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .find_select_dialog = {} }, .msg = "Find/select" } } },
    // Edit
    .{ .key = .c, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .clipboard_copy = {} }, .msg = "Copied" } } },
    .{ .key = .x, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .clipboard_cut = {} }, .msg = "Cut" } } },
    .{ .key = .v, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .clipboard_paste = {} }, .msg = "Pasted" } } },
    // Net highlight
    .{ .key = .k, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .unhighlight_selected_nets = {} }, .msg = "Unhighlighting nets" } } },
    .{ .key = .k, .ctrl = false, .shift = false, .alt = true, .action = .{ .queue = .{ .cmd = .{ .select_attached_nets = {} }, .msg = "Selecting nets" } } },
    // Move/stretch
    .{ .key = .m, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .move_interactive_stretch = {} }, .msg = "Move stretch mode" } } },
    .{ .key = .u, .ctrl = false, .shift = false, .alt = true, .action = .{ .queue = .{ .cmd = .{ .align_to_grid = {} }, .msg = "Aligned to grid" } } },
    // Snap
    .{ .key = .g, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .snap_halve = {} }, .msg = "Snap halved" } } },
    // Hierarchy
    .{ .key = .e, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .ascend = {} }, .msg = "Ascend" } } },
    .{ .key = .l, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .make_schematic_from_symbol = {} }, .msg = "Make schematic from symbol" } } },
    .{ .key = .h, .ctrl = true, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .make_schem_and_sym = {} }, .msg = "Make both" } } },
    // Netlisting
    .{ .key = .n, .ctrl = false, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .netlist_top_only = {} }, .msg = "Top netlist" } } },
    // View toggles
    .{ .key = .b, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .toggle_text_in_symbols = {} }, .msg = "Toggle text in symbols" } } },
    .{ .key = .b, .ctrl = false, .shift = false, .alt = true, .action = .{ .queue = .{ .cmd = .{ .toggle_symbol_details = {} }, .msg = "Toggle symbol details" } } },
    .{ .key = .x, .ctrl = false, .shift = false, .alt = true, .action = .{ .queue = .{ .cmd = .{ .toggle_crosshair = {} }, .msg = "Toggle crosshair" } } },
    // Wires
    .{ .key = .w, .ctrl = false, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .start_wire_snap = {} }, .msg = "Wire snap mode" } } },
    .{ .key = .l, .ctrl = false, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .toggle_orthogonal_routing = {} }, .msg = "Toggle ortho routing" } } },
    // Export
    .{ .key = .p, .ctrl = true, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .export_pdf = {} }, .msg = "Export PDF (stub)" } } },
    // Query props
    .{ .key = .q, .ctrl = true, .shift = true, .alt = false, .action = .{ .queue = .{ .cmd = .{ .view_properties = {} }, .msg = "View properties" } } },
    // Symbol pins
    .{ .key = .p, .ctrl = true, .shift = false, .alt = false, .action = .{ .queue = .{ .cmd = .{ .make_symbol_from_schematic = {} }, .msg = "Make symbol" } } },
};

// ── Public API ────────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    _ = app;
    if (!state.open) return;

    var fw = dvui.floatingWindow(@src(), .{}, .{ .min_size_content = .{ .w = 500, .h = 400 } });
    defer fw.deinit();

    dvui.labelNoFmt(@src(), "Keyboard Shortcuts", .{}, .{ .style = .highlight });

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    for (static_keybinds, 0..) |kb, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i });
        defer row.deinit();

        var key_buf: [32]u8 = undefined;
        const ctrl_str: []const u8 = if (kb.ctrl) "Ctrl+" else "";
        const shift_str: []const u8 = if (kb.shift) "Shift+" else "";
        const alt_str: []const u8 = if (kb.alt) "Alt+" else "";
        const key_str = std.fmt.bufPrint(&key_buf, "{s}{s}{s}{s}", .{ ctrl_str, shift_str, alt_str, @tagName(kb.key) }) catch "?";
        dvui.labelNoFmt(@src(), key_str, .{}, .{ .min_size_content = .{ .w = 150 }, .id_extra = i });

        var action_buf: [64]u8 = undefined;
        const action_str: []const u8 = switch (kb.action) {
            .queue => |q| q.msg,
            .gui => |g| @tagName(g),
        };
        const action_text = std.fmt.bufPrint(&action_buf, "{s}", .{action_str}) catch "?";
        dvui.labelNoFmt(@src(), action_text, .{}, .{ .expand = .horizontal, .id_extra = i + 1000 });
    }

    if (dvui.button(@src(), "Close [Esc]", .{}, .{})) {
        state.open = false;
    }
}

/// Dispatch a key event against the static keybind table.
pub fn dispatchStatic(app: *AppState, code: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) bool {
    for (static_keybinds) |kb| {
        if (kb.key != code or kb.ctrl != ctrl or kb.shift != shift or kb.alt != alt) continue;
        switch (kb.action) {
            .queue => |q| actions.enqueue(app, q.cmd, q.msg),
            .gui => |g| actions.runGuiCommand(app, g),
        }
        return true;
    }
    return false;
}

/// Dispatch a key event against plugin-registered keybinds.
pub fn dispatchPlugin(app: *AppState, code: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) bool {
    const key_char = keyToChar(code, false);
    if (key_char == 0) return false;
    const mods = encodeMods(ctrl, shift, alt);
    for (app.gui.plugin_keybinds.items) |kb| {
        if (key_char == kb.key and mods == kb.mods) {
            app.queue.push(.{ .plugin_command = .{ .tag = kb.cmd_tag, .payload = null } }) catch {};
            return true;
        }
    }
    return false;
}

/// Convert a dvui key code to an ASCII character.
pub fn keyToChar(code: dvui.enums.Key, shift: bool) u8 {
    return switch (code) {
        .a => if (shift) 'A' else 'a',
        .b => if (shift) 'B' else 'b',
        .c => if (shift) 'C' else 'c',
        .d => if (shift) 'D' else 'd',
        .e => if (shift) 'E' else 'e',
        .f => if (shift) 'F' else 'f',
        .g => if (shift) 'G' else 'g',
        .h => if (shift) 'H' else 'h',
        .i => if (shift) 'I' else 'i',
        .j => if (shift) 'J' else 'j',
        .k => if (shift) 'K' else 'k',
        .l => if (shift) 'L' else 'l',
        .m => if (shift) 'M' else 'm',
        .n => if (shift) 'N' else 'n',
        .o => if (shift) 'O' else 'o',
        .p => if (shift) 'P' else 'p',
        .q => if (shift) 'Q' else 'q',
        .r => if (shift) 'R' else 'r',
        .s => if (shift) 'S' else 's',
        .t => if (shift) 'T' else 't',
        .u => if (shift) 'U' else 'u',
        .v => if (shift) 'V' else 'v',
        .w => if (shift) 'W' else 'w',
        .x => if (shift) 'X' else 'x',
        .y => if (shift) 'Y' else 'y',
        .z => if (shift) 'Z' else 'z',
        .zero => if (shift) ')' else '0',
        .one => if (shift) '!' else '1',
        .two => if (shift) '@' else '2',
        .three => if (shift) '#' else '3',
        .four => if (shift) '$' else '4',
        .five => if (shift) '%' else '5',
        .six => if (shift) '^' else '6',
        .seven => if (shift) '&' else '7',
        .eight => if (shift) '*' else '8',
        .nine => if (shift) '(' else '9',
        .grave => if (shift) '~' else '`',
        .minus => if (shift) '_' else '-',
        .equal => if (shift) '+' else '=',
        .left_bracket => if (shift) '{' else '[',
        .right_bracket => if (shift) '}' else ']',
        .backslash => if (shift) '|' else '\\',
        .semicolon => if (shift) ':' else ';',
        .apostrophe => if (shift) '"' else '\'',
        .comma => if (shift) '<' else ',',
        .period => if (shift) '>' else '.',
        .slash => if (shift) '?' else '/',
        .space => ' ',
        else => 0,
    };
}

/// Encode modifier flags into a single byte matching PluginKeybind.mods layout.
fn encodeMods(ctrl: bool, shift: bool, alt: bool) u8 {
    var m: u8 = 0;
    if (ctrl) m |= 0x01;
    if (shift) m |= 0x02;
    if (alt) m |= 0x04;
    return m;
}
