//! Right-click context menu for instances, wires, and canvas.

const std = @import("std");
const dvui = @import("dvui");
const AppState = @import("../state.zig").AppState;
const actions = @import("actions.zig");

// ── Local state ───────────────────────────────────────────────────────────── //

pub const State = struct {
    open: bool = false,
    inst_idx: i32 = -1,
    wire_idx: i32 = -1,
};

pub var state: State = .{};

// TODO: renderer sets state.open/inst_idx/wire_idx

// ── Public API ────────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    if (!state.open) return;

    var fw = dvui.floatingWindow(@src(), .{}, .{ .min_size_content = .{ .w = 180, .h = 160 } });
    defer fw.deinit();

    if (state.inst_idx >= 0) {
        dvui.labelNoFmt(@src(), "Instance", .{}, .{ .style = .highlight });
        if (dvui.button(@src(), "Properties [Q]", .{}, .{})) {
            actions.enqueue(app, .{ .edit_properties = {} }, "Edit properties");
            state.open = false;
        }
        if (dvui.button(@src(), "Delete [Del]", .{}, .{ .id_extra = 1 })) {
            actions.enqueue(app, .{ .delete_selected = {} }, "Delete");
            state.open = false;
        }
        if (dvui.button(@src(), "Rotate CW [R]", .{}, .{ .id_extra = 2 })) {
            actions.enqueue(app, .{ .rotate_cw = {} }, "Rotate CW");
            state.open = false;
        }
        if (dvui.button(@src(), "Flip H [X]", .{}, .{ .id_extra = 3 })) {
            actions.enqueue(app, .{ .flip_horizontal = {} }, "Flip H");
            state.open = false;
        }
        if (dvui.button(@src(), "Move [M]", .{}, .{ .id_extra = 4 })) {
            actions.enqueue(app, .{ .move_interactive = {} }, "Move");
            state.open = false;
        }
        if (dvui.button(@src(), "Descend [E]", .{}, .{ .id_extra = 5 })) {
            actions.enqueue(app, .{ .descend_schematic = {} }, "Descend");
            state.open = false;
        }
    } else if (state.wire_idx >= 0) {
        dvui.labelNoFmt(@src(), "Wire", .{}, .{ .style = .highlight });
        if (dvui.button(@src(), "Delete [Del]", .{}, .{})) {
            actions.enqueue(app, .{ .delete_selected = {} }, "Delete");
            state.open = false;
        }
        if (dvui.button(@src(), "Select Connected", .{}, .{ .id_extra = 1 })) {
            actions.enqueue(app, .{ .select_connected = {} }, "Select connected");
            state.open = false;
        }
    } else {
        dvui.labelNoFmt(@src(), "Canvas", .{}, .{ .style = .highlight });
        if (dvui.button(@src(), "Paste [Ctrl+V]", .{}, .{})) {
            actions.enqueue(app, .{ .clipboard_paste = {} }, "Paste");
            state.open = false;
        }
        if (dvui.button(@src(), "Insert from Library", .{}, .{ .id_extra = 1 })) {
            actions.enqueue(app, .{ .insert_from_library = {} }, "Insert from library");
            state.open = false;
        }
    }

    _ = dvui.separator(@src(), .{ .id_extra = 99 });
    if (dvui.button(@src(), "Cancel", .{}, .{ .id_extra = 99 })) {
        state.open = false;
    }
}
