//! Keybind data and types — no drawing, no dvui dependency beyond key enum.
//!
//! Owns the static keybind table and the O(log n) binary-search lookup.
//! All single-key and modifier+key bindings live here.

const std = @import("std");
const dvui = @import("dvui");
const command = @import("commands");
const actions = @import("Actions.zig");

// ── Types ─────────────────────────────────────────────────────────────────── //

/// Discriminated union: either enqueue a command or run a GUI command directly.
pub const KeybindAction = union(enum) {
    queue: struct { cmd: command.Command, msg: []const u8 },
    gui: actions.GuiCommand,
};

pub const Keybind = struct {
    key: dvui.enums.Key,
    ctrl: bool,
    shift: bool,
    alt: bool,
    action: KeybindAction,
};

// ── Comptime helpers ───────────────────────────────────────────────────────── //

fn imm(comptime tag: command.Immediate) command.Command {
    return .{ .immediate = tag };
}
fn und(comptime tag: command.Undoable) command.Command {
    return .{ .undoable = tag };
}

fn sortKey(kb: Keybind) u32 {
    return (@as(u32, @intFromEnum(kb.key)) << 3) |
        (@as(u32, @intFromBool(kb.ctrl)) << 2) |
        (@as(u32, @intFromBool(kb.shift)) << 1) |
        (@as(u32, @intFromBool(kb.alt)) << 0);
}

fn sortKeyRaw(key: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) u32 {
    return (@as(u32, @intFromEnum(key)) << 3) |
        (@as(u32, @intFromBool(ctrl)) << 2) |
        (@as(u32, @intFromBool(shift)) << 1) |
        (@as(u32, @intFromBool(alt)) << 0);
}

const f = false;
const t = true;

// ── Static keybind table (sorted by sortKey for O(log n) lookup) ──────────── //

pub const static_keybinds = blk: {
    const table = [_]Keybind{
        // File
        .{ .key = .n, .ctrl = t, .shift = f, .alt = f, .action = .{ .gui = .file_new } },
        .{ .key = .o, .ctrl = t, .shift = f, .alt = f, .action = .{ .gui = .file_open } },
        .{ .key = .s, .ctrl = t, .shift = f, .alt = f, .action = .{ .gui = .file_save } },
        .{ .key = .s, .ctrl = t, .shift = t, .alt = f, .action = .{ .gui = .file_save_as } },
        .{ .key = .s, .ctrl = f, .shift = f, .alt = t, .action = .{ .gui = .file_reload } },
        .{ .key = .l, .ctrl = t, .shift = f, .alt = f, .action = .{ .gui = .file_view_logs } },
        .{ .key = .n, .ctrl = t, .shift = t, .alt = f, .action = .{ .gui = .file_start_process } },
        .{ .key = .q, .ctrl = t, .shift = f, .alt = f, .action = .{ .gui = .file_exit } },
        // Tab management
        .{ .key = .t, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.new_tab), .msg = "New tab" } } },
        .{ .key = .w, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.close_tab), .msg = "Close tab" } } },
        .{ .key = .t, .ctrl = t, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.reopen_last_closed), .msg = "Reopen last closed" } } },
        .{ .key = .left, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.prev_tab), .msg = "Previous tab" } } },
        .{ .key = .right, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.next_tab), .msg = "Next tab" } } },
        // Simulation
        .{ .key = .f5, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = und(.{ .run_sim = .{ .sim = .ngspice } }), .msg = "Queued simulation" } } },
        .{ .key = .f6, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.plugins_refresh), .msg = "Queued plugin refresh" } } },
        // Zoom
        .{ .key = .equal, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.zoom_in), .msg = "Zoom in" } } },
        .{ .key = .minus, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.zoom_out), .msg = "Zoom out" } } },
        .{ .key = .zero, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.zoom_reset), .msg = "Zoom reset" } } },
        .{ .key = .f, .ctrl = t, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.zoom_fit_selected), .msg = "Zoom fit selected" } } },
        // Undo / Redo
        .{ .key = .z, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.undo), .msg = "Undo" } } },
        .{ .key = .y, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.redo), .msg = "Redo" } } },
        // Selection
        .{ .key = .a, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.select_all), .msg = "Select all" } } },
        .{ .key = .a, .ctrl = t, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.select_none), .msg = "Select none" } } },
        .{ .key = .f, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.find_select_dialog), .msg = "Find/select" } } },
        // Clipboard
        .{ .key = .c, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.clipboard_copy), .msg = "Copied" } } },
        .{ .key = .x, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.clipboard_cut), .msg = "Cut" } } },
        .{ .key = .v, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.clipboard_paste), .msg = "Pasted" } } },
        // Net highlight
        .{ .key = .k, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.unhighlight_selected_nets), .msg = "Unhighlighting nets" } } },
        .{ .key = .k, .ctrl = f, .shift = f, .alt = t, .action = .{ .queue = .{ .cmd = imm(.select_attached_nets), .msg = "Selecting nets" } } },
        // Plain single-key bindings
        .{ .key = .a, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.make_symbol_from_schematic), .msg = "Making symbol" } } },
        .{ .key = .c, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.copy_selected), .msg = "Copy mode" } } },
        .{ .key = .d, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = und(.duplicate_selected), .msg = "Queued duplicate" } } },
        .{ .key = .e, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.descend_schematic), .msg = "Descend" } } },
        .{ .key = .e, .ctrl = f, .shift = f, .alt = t, .action = .{ .queue = .{ .cmd = imm(.edit_in_new_tab), .msg = "Edit in new tab" } } },
        .{ .key = .e, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.ascend), .msg = "Ascend" } } },
        .{ .key = .e, .ctrl = t, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.open_file_explorer), .msg = "File explorer" } } },
        .{ .key = .f, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.zoom_fit), .msg = "Zoom fit" } } },
        .{ .key = .i, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.descend_symbol), .msg = "Descend symbol" } } },
        .{ .key = .k, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.highlight_selected_nets), .msg = "Highlighting nets" } } },
        .{ .key = .k, .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.unhighlight_all), .msg = "Unhighlighting all" } } },
        .{ .key = .l, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.start_line), .msg = "Line draw mode" } } },
        .{ .key = .l, .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.toggle_orthogonal_routing), .msg = "Toggle ortho routing" } } },
        .{ .key = .m, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.move_interactive), .msg = "Move mode" } } },
        .{ .key = .n, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.netlist_hierarchical), .msg = "Generating netlist" } } },
        .{ .key = .n, .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.netlist_top_only), .msg = "Top netlist" } } },
        .{ .key = .o, .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.toggle_colorscheme), .msg = "Toggle colorscheme" } } },
        .{ .key = .p, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.start_polygon), .msg = "Polygon draw mode" } } },
        .{ .key = .p, .ctrl = t, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.export_pdf), .msg = "Export PDF" } } },
        .{ .key = .q, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.edit_properties), .msg = "Edit properties" } } },
        .{ .key = .r, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = und(.rotate_cw), .msg = "Queued rotate CW" } } },
        .{ .key = .r, .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = und(.rotate_ccw), .msg = "Queued rotate CCW" } } },
        .{ .key = .s, .ctrl = f, .shift = f, .alt = f, .action = .{ .gui = .view_schematic } },
        .{ .key = .t, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.place_text), .msg = "Place text" } } },
        .{ .key = .v, .ctrl = f, .shift = t, .alt = f, .action = .{ .gui = .view_symbol } },
        .{ .key = .w, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.start_wire), .msg = "Wire mode" } } },
        .{ .key = .w, .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.start_wire_snap), .msg = "Wire mode (snap)" } } },
        .{ .key = .x, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = und(.flip_horizontal), .msg = "Queued flip horizontal" } } },
        .{ .key = .x, .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = und(.flip_vertical), .msg = "Queued flip vertical" } } },
        .{ .key = .z, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.zoom_fit), .msg = "Zoom fit" } } },
        .{ .key = .g, .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.snap_double), .msg = "Snap doubled" } } },
        .{ .key = .g, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.snap_halve), .msg = "Snap halved" } } },
        .{ .key = .insert, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.insert_from_library), .msg = "Opening library" } } },
        .{ .key = .backslash, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.toggle_fullscreen), .msg = "Toggle fullscreen" } } },
        .{ .key = .delete, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = und(.delete_selected), .msg = "Queued delete" } } },
        .{ .key = .backspace, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.ascend), .msg = "Ascend" } } },
    };

    @setEvalBranchQuota(10000);
    const lessThan = struct {
        fn f_(_: void, a: Keybind, b: Keybind) bool {
            return sortKey(a) < sortKey(b);
        }
    }.f_;
    var sorted = table;
    std.sort.insertion(Keybind, &sorted, {}, lessThan);

    break :blk sorted;
};

// ── O(log n) lookup ───────────────────────────────────────────────────────── //

pub fn lookup(key: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) ?*const Keybind {
    const needle = sortKeyRaw(key, ctrl, shift, alt);
    const idx = std.sort.binarySearch(Keybind, &static_keybinds, needle, struct {
        fn order(k: u32, entry: Keybind) std.math.Order {
            return std.math.order(k, sortKey(entry));
        }
    }.order) orelse return null;
    return &static_keybinds[idx];
}
