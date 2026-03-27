//! Right-click context menu for instances, wires, and canvas.

const dvui = @import("dvui");
const st = @import("state");
const command = @import("commands");
const actions = @import("Actions.zig");

const AppState = st.AppState;

// ── Comptime menu definitions ─────────────────────────────────────────────── //

const MenuItem = struct {
    label: []const u8,
    cmd: command.Command,
    status: []const u8,
};

const instance_items: []const MenuItem = &.{
    .{ .label = "Properties [Q]", .cmd = .{ .immediate = .edit_properties }, .status = "Edit properties" },
    .{ .label = "Delete [Del]", .cmd = .{ .undoable = .delete_selected }, .status = "Delete" },
    .{ .label = "Rotate CW [R]", .cmd = .{ .undoable = .rotate_cw }, .status = "Rotate CW" },
    .{ .label = "Flip H [X]", .cmd = .{ .undoable = .flip_horizontal }, .status = "Flip H" },
    .{ .label = "Move [M]", .cmd = .{ .immediate = .move_interactive }, .status = "Move" },
    .{ .label = "Descend [E]", .cmd = .{ .immediate = .descend_schematic }, .status = "Descend" },
};

const wire_items: []const MenuItem = &.{
    .{ .label = "Delete [Del]", .cmd = .{ .undoable = .delete_selected }, .status = "Delete" },
    .{ .label = "Select Connected", .cmd = .{ .immediate = .select_connected }, .status = "Select connected" },
};

const canvas_items: []const MenuItem = &.{
    .{ .label = "Paste [Ctrl+V]", .cmd = .{ .immediate = .clipboard_paste }, .status = "Paste" },
    .{ .label = "Insert from Library", .cmd = .{ .immediate = .insert_from_library }, .status = "Insert from library" },
};

// ── Public API ────────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    if (!app.gui.ctx_menu.open) return;

    var fw = dvui.floatingWindow(@src(), .{}, .{ .min_size_content = .{ .w = 180, .h = 160 } });
    defer fw.deinit();

    if (app.gui.ctx_menu.inst_idx >= 0) {
        dvui.labelNoFmt(@src(), "Instance", .{}, .{ .style = .highlight });
        drawItems(app, instance_items);
    } else if (app.gui.ctx_menu.wire_idx >= 0) {
        dvui.labelNoFmt(@src(), "Wire", .{}, .{ .style = .highlight });
        drawItems(app, wire_items);
    } else {
        dvui.labelNoFmt(@src(), "Canvas", .{}, .{ .style = .highlight });
        drawItems(app, canvas_items);
    }

    _ = dvui.separator(@src(), .{ .id_extra = 99 });
    if (dvui.button(@src(), "Cancel", .{}, .{ .id_extra = 99 })) {
        app.gui.ctx_menu.open = false;
    }
}

// ── Private helpers ───────────────────────────────────────────────────────── //

fn drawItems(app: *AppState, items: []const MenuItem) void {
    for (items, 0..) |item, i| {
        if (dvui.button(@src(), item.label, .{}, .{ .id_extra = @intCast(i) })) {
            actions.enqueue(app, item.cmd, item.status);
            app.gui.ctx_menu.open = false;
        }
    }
}
