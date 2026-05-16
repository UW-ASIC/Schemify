//! Keybind data — static table with O(log n) binary-search lookup.
//! No rendering, no dvui dependency beyond the Key enum.

const std = @import("std");
const dvui = @import("dvui");
const command = @import("commands");
const actions = @import("../actions.zig");

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

fn imm(comptime tag: command.Immediate) command.Command { return .{ .immediate = tag }; }
fn und(comptime tag: command.Undoable) command.Command { return .{ .undoable = tag }; }

fn sortKey(kb: Keybind) u32 {
    return (@as(u32, @intFromEnum(kb.key)) << 3) |
        (@as(u32, @intFromBool(kb.ctrl)) << 2) |
        (@as(u32, @intFromBool(kb.shift)) << 1) |
        @as(u32, @intFromBool(kb.alt));
}

const f = false;
const t = true;

pub const static_keybinds = blk: {
    const table = [_]Keybind{
        // File
        .{ .key = .n, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.file_new), .msg = "New file" } } },
        .{ .key = .o, .ctrl = t, .shift = f, .alt = f, .action = .{ .gui = .file_open } },
        .{ .key = .s, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.file_save), .msg = "Saving..." } } },
        // Tabs
        .{ .key = .t, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.new_tab), .msg = "New tab" } } },
        .{ .key = .w, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.close_tab), .msg = "Close tab" } } },
        .{ .key = .left, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.prev_tab), .msg = "Previous tab" } } },
        .{ .key = .right, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.next_tab), .msg = "Next tab" } } },
        // Simulation
        .{ .key = .f5, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = und(.{ .run_sim = .{} }), .msg = "Queued simulation" } } },
        .{ .key = .f6, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.plugins_refresh), .msg = "Queued plugin refresh" } } },
        // Zoom
        .{ .key = .equal, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.zoom_in), .msg = "Zoom in" } } },
        .{ .key = .minus, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.zoom_out), .msg = "Zoom out" } } },
        .{ .key = .zero, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.zoom_reset), .msg = "Zoom reset" } } },
        // Undo/Redo
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
        .{ .key = .k, .ctrl = t, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.unhighlight_all), .msg = "Unhighlighting" } } },
        // Single-key
        .{ .key = .d, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = und(.duplicate_selected), .msg = "Duplicate" } } },
        .{ .key = .e, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.descend_schematic), .msg = "Descend" } } },
        .{ .key = .e, .ctrl = t, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = imm(.open_file_explorer), .msg = "File explorer" } } },
        .{ .key = .f, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.zoom_fit), .msg = "Zoom fit" } } },
        .{ .key = .k, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.highlight_selected_nets), .msg = "Highlighting nets" } } },
        .{ .key = .m, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.tool_move), .msg = "Move mode" } } },
        .{ .key = .n, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.netlist_hierarchical), .msg = "Generating netlist" } } },
        .{ .key = .q, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.edit_properties), .msg = "Edit properties" } } },
        .{ .key = .r, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = und(.rotate_cw), .msg = "Rotate CW" } } },
        .{ .key = .r, .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = und(.rotate_ccw), .msg = "Rotate CCW" } } },
        .{ .key = .s, .ctrl = f, .shift = f, .alt = f, .action = .{ .gui = .view_schematic } },
        .{ .key = .v, .ctrl = f, .shift = t, .alt = f, .action = .{ .gui = .view_symbol } },
        .{ .key = .w, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.start_wire), .msg = "Wire mode" } } },
        .{ .key = .x, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = und(.flip_horizontal), .msg = "Flip horizontal" } } },
        .{ .key = .x, .ctrl = f, .shift = t, .alt = f, .action = .{ .queue = .{ .cmd = und(.flip_vertical), .msg = "Flip vertical" } } },
        .{ .key = .z, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.zoom_fit), .msg = "Zoom fit" } } },
        .{ .key = .delete, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = und(.delete_selected), .msg = "Delete" } } },
        .{ .key = .backspace, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.ascend), .msg = "Ascend" } } },
        .{ .key = .insert, .ctrl = f, .shift = f, .alt = f, .action = .{ .queue = .{ .cmd = imm(.insert_from_library), .msg = "Library" } } },
    };

    @setEvalBranchQuota(10000);
    const lt = struct { fn lt_(_: void, a: Keybind, b: Keybind) bool { return sortKey(a) < sortKey(b); } }.lt_;
    var sorted = table;
    std.sort.insertion(Keybind, &sorted, {}, lt);
    break :blk sorted;
};

pub fn lookup(key: dvui.enums.Key, ctrl: bool, shift: bool, alt: bool) ?*const Keybind {
    const needle = (@as(u32, @intFromEnum(key)) << 3) |
        (@as(u32, @intFromBool(ctrl)) << 2) |
        (@as(u32, @intFromBool(shift)) << 1) |
        @as(u32, @intFromBool(alt));
    const idx = std.sort.binarySearch(Keybind, &static_keybinds, needle, struct {
        fn order(k: u32, entry: Keybind) std.math.Order { return std.math.order(k, sortKey(entry)); }
    }.order) orelse return null;
    return &static_keybinds[idx];
}
