const dvui = @import("dvui");
const st = @import("state");
const AppState = st.AppState;

// Sub-modules
pub const actions = @import("actions.zig");
pub const theme = @import("theme_config");
pub const settings = @import("settings.zig");
const input = @import("Input/lib.zig");
const bars = @import("bars.zig");
const dialogs = @import("dialogs.zig");
const optimizer_window = @import("optimizer_window.zig");
const canvas = @import("Canvas/lib.zig");
const CanvasEvent = @import("Canvas/types.zig").CanvasEvent;

const doc_view = @import("doc_view.zig");

// Panels & browsers
const welcome = @import("welcome.zig");
const plugin_panels = @import("PluginPanels.zig");
const marketplace = @import("Panels/marketplace.zig");
pub const file_explorer = @import("Panels/file_explorer.zig");
const library = @import("Panels/library.zig");
const context_menu = @import("Panels/context_menu.zig");
const startup_download = @import("Panels/startup_download.zig");

// ── Public API ───────────────────────────────────────────────────────────────

pub fn frame(app: *AppState) !void {
    input.handleInput(app);

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer outer.deinit();

    bars.drawToolbar(app);
    bars.drawTabBar(app);
    if (app.documents.items.len == 0) {
        welcome.draw(app, 0, 0, 800, 600);
    } else {
        var middle = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer middle.deinit();
        plugin_panels.drawSidebar(app, .left_sidebar);
        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer col.deinit();
            if (app.gui.hot.view_mode == .doc) {
                doc_view.draw(app);
            } else {
                const canvas_ev = canvas.draw(app);
                handleCanvasEvent(app, canvas_ev);
            }
            plugin_panels.drawBottomBar(app);
        }
        plugin_panels.drawSidebar(app, .right_sidebar);
    }
    bars.drawCommandBar(app);

    // Overlays & panels
    plugin_panels.drawOverlays(app);
    file_explorer.draw(app);
    library.draw(app);
    context_menu.draw(app);
    dialogs.drawAll(app);
    settings.draw(app);
    optimizer_window.drawAll(app);
    marketplace.draw(app);
    startup_download.draw(app);
}

// ── Canvas event → command dispatch ──────────────────────────────────────────

fn handleCanvasEvent(app: *AppState, ev: CanvasEvent) void {
    const a = app.gpa.allocator();
    switch (ev) {
        .none => {},
        .click => |pt| {
            app.queue.push(a, .{ .immediate = .{ .canvas_click = .{ .x = pt[0], .y = pt[1] } } }) catch {};
        },
        .double_click => |pt| {
            app.queue.push(a, .{ .immediate = .{ .canvas_double_click = .{ .x = pt[0], .y = pt[1] } } }) catch {};
        },
        .right_click => |rc| {
            // Context menu still needs pixel coords + hit indices for GUI overlay
            app.gui.cold.ctx_menu.pixel_x = rc.pixel[0];
            app.gui.cold.ctx_menu.pixel_y = rc.pixel[1];
            app.gui.cold.ctx_menu.inst_idx = rc.inst_idx;
            app.gui.cold.ctx_menu.wire_idx = rc.wire_idx;
            app.gui.cold.ctx_menu.open = true;
            if (rc.inst_idx >= 0) {
                if (app.active()) |doc| {
                    doc.selection.ensureCapacity(a, doc.sch.instances.len, doc.sch.wires.len, false) catch {};
                    doc.selection.clear();
                    doc.selection.instances.set(@intCast(rc.inst_idx));
                }
            }
            app.queue.push(a, .{ .immediate = .{ .canvas_right_click = .{ .x = rc.world[0], .y = rc.world[1] } } }) catch {};
        },
        .rubber_band_complete => |rb| {
            app.queue.push(a, .{ .immediate = .{ .select_rect = .{ .x0 = rb.min[0], .y0 = rb.min[1], .x1 = rb.max[0], .y1 = rb.max[1] } } }) catch {};
        },
    }
}
