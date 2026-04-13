//! Right-click context menu for instances, wires, and canvas.
//!
//! Renders a compact dvui `floatingMenu` (popup) anchored at the cursor.
//! dvui handles outside-click dismissal via the focus chain — we mirror
//! that into `app.gui.cold.ctx_menu.open` by tracking the menu's subwindow id
//! across frames.

const dvui = @import("dvui");
const st = @import("state");
const command = @import("commands");
const actions = @import("../Actions.zig");

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

// ── Internal state ────────────────────────────────────────────────────────── //

/// Subwindow id of the floating menu, captured the frame after it opens.
/// `null` until the first draw completes. Used to detect outside-click
/// dismissal: if the menu is `open` but the focused subwindow id no longer
/// matches, dvui's focus chain has moved away and the menu should close.
var menu_subwindow_id: ?dvui.Id = null;

// ── Public API ────────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    if (!app.gui.cold.ctx_menu.open) {
        menu_subwindow_id = null;
        return;
    }

    // Anchor at the cursor in natural-pixel space (floatingMenu's units).
    const inv_scale = 1.0 / dvui.windowNaturalScale();
    const anchor: dvui.Point.Natural = .{
        .x = app.gui.cold.ctx_menu.pixel_x * inv_scale,
        .y = app.gui.cold.ctx_menu.pixel_y * inv_scale,
    };
    const from = dvui.Rect.Natural.fromPoint(anchor);

    var fm = dvui.floatingMenu(@src(), .{ .from = from }, .{});
    defer fm.deinit();

    const this_id = fm.data().id;

    // Detect outside-click dismissal: once we've recorded our subwindow id
    // (set the frame after the menu first opens so dvui has had a chance to
    // focus it), a focus change away means dvui closed us via its own focus
    // chain — mirror that into our open flag.
    if (menu_subwindow_id) |our_id| {
        if (dvui.focusedSubwindowId() != our_id) {
            app.gui.cold.ctx_menu.open = false;
            menu_subwindow_id = null;
            return; // defer fm.deinit() still runs and closes the chain
        }
    }

    // Cache our subwindow id so the next frame can detect outside-click.
    menu_subwindow_id = this_id;

    if (app.gui.cold.ctx_menu.inst_idx >= 0) {
        drawItems(app, fm, instance_items);
    } else if (app.gui.cold.ctx_menu.wire_idx >= 0) {
        drawItems(app, fm, wire_items);
    } else {
        drawItems(app, fm, canvas_items);
    }
}

// ── Private helpers ───────────────────────────────────────────────────────── //

fn drawItems(app: *AppState, fm: *dvui.FloatingMenuWidget, items: []const MenuItem) void {
    for (items, 0..) |item, i| {
        if (dvui.menuItemLabel(@src(), item.label, .{}, .{
            .id_extra = i,
            .expand = .horizontal,
        }) != null) {
            actions.enqueue(app, item.cmd, item.status);
            fm.close();
            app.gui.cold.ctx_menu.open = false;
            menu_subwindow_id = null;
        }
    }
}
