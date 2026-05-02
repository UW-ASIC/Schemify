//! Right-click context menu for instances, wires, and canvas.

const dvui = @import("dvui");
const st = @import("state");
const command = @import("commands");
const actions = @import("../actions.zig");

const AppState = st.AppState;

const MenuItem = struct { label: []const u8, cmd: command.Command, status: []const u8 };

const instance_items: []const MenuItem = &.{
    .{ .label = "Properties [Q]", .cmd = .{ .immediate = .edit_properties }, .status = "Edit properties" },
    .{ .label = "Delete [Del]", .cmd = .{ .undoable = .delete_selected }, .status = "Delete" },
    .{ .label = "Rotate CW [R]", .cmd = .{ .undoable = .rotate_cw }, .status = "Rotate CW" },
    .{ .label = "Flip H [X]", .cmd = .{ .undoable = .flip_horizontal }, .status = "Flip H" },
    .{ .label = "Move [M]", .cmd = .{ .immediate = .tool_move }, .status = "Move" },
    .{ .label = "Descend [E]", .cmd = .{ .immediate = .descend_schematic }, .status = "Descend" },
};

const wire_items: []const MenuItem = &.{
    .{ .label = "Delete [Del]", .cmd = .{ .undoable = .delete_selected }, .status = "Delete" },
    .{ .label = "Select Connected", .cmd = .{ .immediate = .select_all }, .status = "Select connected" },
};

const group_items: []const MenuItem = &.{
    .{ .label = "Edit All Properties", .cmd = .{ .immediate = .edit_properties }, .status = "Edit all properties" },
    .{ .label = "Delete [Del]", .cmd = .{ .undoable = .delete_selected }, .status = "Delete" },
    .{ .label = "Rotate CW [R]", .cmd = .{ .undoable = .rotate_cw }, .status = "Rotate CW (group)" },
    .{ .label = "Flip H [X]", .cmd = .{ .undoable = .flip_horizontal }, .status = "Flip H (group)" },
    .{ .label = "Duplicate", .cmd = .{ .undoable = .duplicate_selected }, .status = "Duplicate" },
};

const canvas_items: []const MenuItem = &.{
    .{ .label = "Paste [Ctrl+V]", .cmd = .{ .immediate = .clipboard_paste }, .status = "Paste" },
    .{ .label = "Insert from Library", .cmd = .{ .immediate = .insert_from_library }, .status = "Insert from library" },
};

var menu_subwindow_id: ?dvui.Id = null;

pub fn draw(app: *AppState) void {
    if (!app.gui.cold.ctx_menu.open) { menu_subwindow_id = null; return; }

    const inv = 1.0 / dvui.windowNaturalScale();
    const anchor: dvui.Point.Natural = .{ .x = app.gui.cold.ctx_menu.pixel_x * inv, .y = app.gui.cold.ctx_menu.pixel_y * inv };

    var fm = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(anchor) }, .{});
    defer fm.deinit();

    if (menu_subwindow_id) |our_id| {
        if (dvui.focusedSubwindowId() != our_id) {
            app.gui.cold.ctx_menu.open = false;
            menu_subwindow_id = null;
            return;
        }
    }
    menu_subwindow_id = fm.data().id;

    const multi = blk: {
        const doc = app.active() orelse break :blk false;
        if (doc.selection.instances.bit_length == 0) break :blk false;
        var it = doc.selection.instances.iterator(.{});
        _ = it.next() orelse break :blk false;
        break :blk it.next() != null;
    };

    const items: []const MenuItem = if (multi and app.gui.cold.ctx_menu.inst_idx >= 0) group_items
        else if (app.gui.cold.ctx_menu.inst_idx >= 0) instance_items
        else if (app.gui.cold.ctx_menu.wire_idx >= 0) wire_items
        else canvas_items;

    for (items, 0..) |item, i| {
        if (dvui.menuItemLabel(@src(), item.label, .{}, .{ .id_extra = i, .expand = .horizontal }) != null) {
            actions.enqueue(app, item.cmd, item.status);
            fm.close();
            app.gui.cold.ctx_menu.open = false;
            menu_subwindow_id = null;
        }
    }
}
