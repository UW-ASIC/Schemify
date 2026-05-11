//! GUI shell — frame orchestrator.
//! Draws the full frame each tick: bars, main area, overlays, dialogs.
//!
//! Frame layout:
//!   toolbar -> tabbar -> { left_sidebar | { canvas / bottom_bar } | right_sidebar }
//!   -> command_bar -> overlays -> file_explorer -> library -> context_menu -> dialogs -> marketplace

const dvui = @import("dvui");
const st = @import("state");
const AppState = st.AppState;

// Sub-modules
pub const actions = @import("actions.zig");
pub const theme = @import("theme_config");
const input = @import("Input/lib.zig");
const bars = @import("bars.zig");
const dialogs = @import("dialogs.zig");
const canvas = @import("Canvas/lib.zig");
const interaction = @import("Canvas/interaction.zig");
const CanvasEvent = @import("Canvas/types.zig").CanvasEvent;

// Panels & browsers
const welcome = @import("welcome.zig");
const plugin_panels = @import("PluginPanels.zig");
const marketplace = @import("Panels/marketplace.zig");
pub const file_explorer = @import("Panels/file_explorer.zig");
const library = @import("Panels/library.zig");
const context_menu = @import("Panels/context_menu.zig");

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
            const canvas_ev = canvas.draw(app);
            handleCanvasEvent(app, canvas_ev);
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
    marketplace.draw(app);
}

// ── Canvas event dispatch ────────────────────────────────────────────────────

fn handleCanvasEvent(app: *AppState, ev: CanvasEvent) void {
    switch (ev) {
        .none => {},
        .click => |pt| {
            switch (app.tool.active) {
                .wire => {
                    if (app.tool.wire_start) |ws| {
                        const dx: u64 = @abs(@as(i64, pt[0]) - ws[0]);
                        const dy: u64 = @abs(@as(i64, pt[1]) - ws[1]);
                        const end: @import("Canvas/types.zig").Point = if (dx >= dy) .{ pt[0], ws[1] } else .{ ws[0], pt[1] };
                        actions.enqueue(app, .{ .undoable = .{ .add_wire = .{ .x0 = ws[0], .y0 = ws[1], .x1 = end[0], .y1 = end[1] } } }, "Wire placed");
                        app.tool.wire_start = end;
                    } else {
                        app.tool.wire_start = pt;
                        app.status_msg = "Wire start set";
                    }
                },
                .select => {
                    const doc = app.active() orelse return;
                    const a = app.allocator();
                    if (interaction.hitTestInstance(&doc.sch, pt)) |idx| {
                        const already = doc.selection.instances.bit_length > idx and doc.selection.instances.isSet(idx);
                        if (!already) {
                            doc.selection.clear();
                            doc.selection.instances.resize(a, doc.sch.instances.len, false) catch return;
                            doc.selection.instances.set(idx);
                            app.status_msg = "Selected instance";
                        }
                    } else if (interaction.hitTestWire(&doc.sch, pt)) |idx| {
                        const already = doc.selection.wires.bit_length > idx and doc.selection.wires.isSet(idx);
                        if (!already) {
                            doc.selection.clear();
                            doc.selection.wires.resize(a, doc.sch.wires.len, false) catch return;
                            doc.selection.wires.set(idx);
                            app.status_msg = "Selected wire";
                        }
                    } else {
                        doc.selection.clear();
                        app.status_msg = "Ready";
                    }
                },
                else => {},
            }
        },
        .double_click => |_| actions.enqueue(app, .{ .immediate = .edit_properties }, "Edit properties"),
        .right_click => |rc| {
            app.gui.cold.ctx_menu.pixel_x = rc.pixel[0];
            app.gui.cold.ctx_menu.pixel_y = rc.pixel[1];
            app.gui.cold.ctx_menu.inst_idx = rc.inst_idx;
            app.gui.cold.ctx_menu.wire_idx = rc.wire_idx;
            app.gui.cold.ctx_menu.open = true;
            if (rc.inst_idx >= 0) {
                const doc = app.active() orelse return;
                const a = app.allocator();
                doc.selection.ensureCapacity(a, doc.sch.instances.len, doc.sch.wires.len, false) catch return;
                doc.selection.clear();
                doc.selection.instances.set(@intCast(rc.inst_idx));
            }
        },
        .rubber_band_complete => |rb| {
            const doc = app.active() orelse return;
            const a = app.allocator();
            doc.selection.ensureCapacity(a, doc.sch.instances.len, doc.sch.wires.len, false) catch return;
            doc.selection.clear();
            const xs = doc.sch.instances.items(.x);
            const ys = doc.sch.instances.items(.y);
            var count: usize = 0;
            for (0..doc.sch.instances.len) |i| {
                if (xs[i] >= rb.min[0] and xs[i] <= rb.max[0] and ys[i] >= rb.min[1] and ys[i] <= rb.max[1]) {
                    doc.selection.instances.set(i);
                    count += 1;
                }
            }
            const x0s = doc.sch.wires.items(.x0);
            const y0s = doc.sch.wires.items(.y0);
            const x1s = doc.sch.wires.items(.x1);
            const y1s = doc.sch.wires.items(.y1);
            for (0..doc.sch.wires.len) |i| {
                if (@min(x0s[i], x1s[i]) >= rb.min[0] and @max(x0s[i], x1s[i]) <= rb.max[0] and
                    @min(y0s[i], y1s[i]) >= rb.min[1] and @max(y0s[i], y1s[i]) <= rb.max[1])
                    doc.selection.wires.set(i);
            }
            app.status_msg = if (count > 0) "Selected instances" else "Ready";
        },
    }
}
