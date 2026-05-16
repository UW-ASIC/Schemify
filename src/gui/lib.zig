const std = @import("std");
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
const interaction = @import("Canvas/interaction.zig");
const CanvasEvent = @import("Canvas/types.zig").CanvasEvent;

const chat_panel = @import("chat_panel.zig");
const doc_view = @import("doc_view.zig");

// Panels & browsers
const welcome = @import("welcome.zig");
const plugin_panels = @import("PluginPanels.zig");
const marketplace = @import("Panels/marketplace.zig");
pub const file_explorer = @import("Panels/file_explorer.zig");
const library = @import("Panels/library.zig");
const context_menu = @import("Panels/context_menu.zig");
const startup_download = @import("Panels/startup_download.zig");

// File-scope buffer for placement name (avoids dangling slice from stack-local Placement copy)
var place_name_buf: [32]u8 = undefined;

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
        chat_panel.draw(app);
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

// ── Canvas event dispatch ────────────────────────────────────────────────────

// ── Drawing tool click handlers ──────────────────────────────────────────────

fn handleLineClick(app: *AppState, pt: [2]i32) void {
    const draw = &app.tool.draw;
    if (draw.first_point) |fp| {
        actions.enqueue(app, .{ .undoable = .{ .add_line = .{
            .x0 = fp[0], .y0 = fp[1], .x1 = pt[0], .y1 = pt[1],
        } } }, "Line placed");
        draw.first_point = null;
    } else {
        draw.first_point = pt;
        app.status_msg = "Line: click end point";
    }
}

fn handleRectClick(app: *AppState, pt: [2]i32) void {
    const draw = &app.tool.draw;
    if (draw.first_point) |fp| {
        actions.enqueue(app, .{ .undoable = .{ .add_rect = .{
            .x0 = fp[0], .y0 = fp[1], .x1 = pt[0], .y1 = pt[1],
        } } }, "Rect placed");
        draw.first_point = null;
    } else {
        draw.first_point = pt;
        app.status_msg = "Rect: click opposite corner";
    }
}

fn handleCircleClick(app: *AppState, pt: [2]i32) void {
    const draw = &app.tool.draw;
    if (draw.first_point) |fp| {
        const dx: f64 = @floatFromInt(pt[0] - fp[0]);
        const dy: f64 = @floatFromInt(pt[1] - fp[1]);
        const radius: i32 = @intFromFloat(@round(@sqrt(dx * dx + dy * dy)));
        if (radius > 0) {
            actions.enqueue(app, .{ .undoable = .{ .add_circle = .{
                .cx = fp[0], .cy = fp[1], .radius = radius,
            } } }, "Circle placed");
        }
        draw.first_point = null;
    } else {
        draw.first_point = pt;
        app.status_msg = "Circle: click edge point";
    }
}

fn handleArcClick(app: *AppState, pt: [2]i32) void {
    const draw = &app.tool.draw;
    switch (draw.arc_step) {
        .center => {
            draw.first_point = pt;
            draw.arc_step = .radius_start;
            app.status_msg = "Arc: click start point on circumference";
        },
        .radius_start => {
            draw.arc_second = pt;
            draw.arc_step = .sweep;
            app.status_msg = "Arc: click end point for sweep";
        },
        .sweep => {
            const center = draw.first_point orelse return;
            const start_pt = draw.arc_second orelse return;
            const dx1: f64 = @floatFromInt(start_pt[0] - center[0]);
            const dy1: f64 = @floatFromInt(start_pt[1] - center[1]);
            const radius: i32 = @intFromFloat(@round(@sqrt(dx1 * dx1 + dy1 * dy1)));
            const start_angle: i16 = @intFromFloat(@round(std.math.atan2(
                -@as(f64, @floatFromInt(start_pt[1] - center[1])),
                @as(f64, @floatFromInt(start_pt[0] - center[0])),
            ) * 180.0 / std.math.pi));
            const dx2: f64 = @floatFromInt(pt[0] - center[0]);
            const dy2: f64 = @floatFromInt(pt[1] - center[1]);
            const end_angle: i16 = @intFromFloat(@round(std.math.atan2(-dy2, dx2) * 180.0 / std.math.pi));
            var sweep: i16 = end_angle - start_angle;
            if (sweep <= 0) sweep += 360;
            if (radius > 0) {
                actions.enqueue(app, .{ .undoable = .{ .add_arc = .{
                    .cx = center[0], .cy = center[1], .radius = radius,
                    .start_angle = start_angle, .sweep_angle = sweep,
                } } }, "Arc placed");
            }
            draw.first_point = null;
            draw.arc_second = null;
            draw.arc_step = .center;
        },
    }
}

fn handlePolygonClick(app: *AppState, pt: [2]i32) void {
    const draw = &app.tool.draw;
    if (draw.polygon_len < draw.polygon_points.len) {
        draw.polygon_points[draw.polygon_len] = pt;
        draw.polygon_len += 1;
        app.status_msg = "Polygon: click next vertex (double-click or right-click to close)";
    } else {
        app.status_msg = "Polygon: max vertices reached, closing";
        closePolygon(app);
    }
}

fn closePolygon(app: *AppState) void {
    const draw = &app.tool.draw;
    const n = draw.polygon_len;
    if (n < 2) {
        draw.polygon_len = 0;
        app.status_msg = "Polygon cancelled (need at least 2 points)";
        return;
    }
    // Emit each edge as a line segment, including closing edge back to first vertex.
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        const next = if (i + 1 < n) i + 1 else 0;
        actions.enqueue(app, .{ .undoable = .{ .add_line = .{
            .x0 = draw.polygon_points[i][0], .y0 = draw.polygon_points[i][1],
            .x1 = draw.polygon_points[next][0], .y1 = draw.polygon_points[next][1],
        } } }, "Polygon edge");
    }
    draw.polygon_len = 0;
    app.status_msg = "Polygon placed";
}

fn handleTextClick(app: *AppState, pt: [2]i32) void {
    const draw = &app.tool.draw;
    draw.text_pos = pt;
    draw.text_input_active = true;
    draw.text_len = 0;
    @memset(&draw.text_buf, 0);
    app.status_msg = "Text: type text, press Enter to place";
}

/// Returns true if a drawing-tool in-progress operation was cancelled.
fn cancelDrawingTool(app: *AppState) bool {
    const draw = &app.tool.draw;
    switch (app.tool.active) {
        .line, .rect, .circle => {
            if (draw.first_point != null) {
                draw.first_point = null;
                app.status_msg = "Cancelled";
                return true;
            }
        },
        .arc => {
            if (draw.first_point != null) {
                draw.first_point = null;
                draw.arc_second = null;
                draw.arc_step = .center;
                app.status_msg = "Arc cancelled";
                return true;
            }
        },
        .polygon => {
            if (draw.polygon_len > 0) {
                closePolygon(app);
                return true;
            }
        },
        .text => {
            if (draw.text_input_active) {
                draw.text_input_active = false;
                draw.text_pos = null;
                draw.text_len = 0;
                app.status_msg = "Text cancelled";
                return true;
            }
        },
        else => {},
    }
    return false;
}

fn handleCanvasEvent(app: *AppState, ev: CanvasEvent) void {
    switch (ev) {
        .none => {},
        .click => |pt| {
            // Placement mode: left-click places the component
            if (app.tool.placement) |pl| {
                // Copy name into file-scope buffer — pl is a stack copy
                // whose kindSlice() would dangle after this scope.
                const ks = pl.kindSlice();
                @memcpy(place_name_buf[0..ks.len], ks);
                const name = place_name_buf[0..ks.len];
                actions.enqueue(app, .{ .undoable = .{ .place_device = .{
                    .sym_path = name, .name = name, .x = pt[0], .y = pt[1],
                } } }, "Placed device");
                app.tool.placement = null;
                return;
            }
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
                    } else if (interaction.hitTestShape(&doc.sch, pt)) |sh| {
                        doc.selection.clear();
                        doc.selection.ensureShapeCapacity(a, &doc.sch, false) catch return;
                        const bits = switch (sh.kind) {
                            .line => &doc.selection.lines,
                            .rect => &doc.selection.rects,
                            .circle => &doc.selection.circles,
                            .arc => &doc.selection.arcs,
                            .text => &doc.selection.texts,
                        };
                        bits.set(sh.idx);
                        app.status_msg = "Selected shape";
                    } else {
                        doc.selection.clear();
                        app.status_msg = "Ready";
                    }
                },
                .line => handleLineClick(app, pt),
                .rect => handleRectClick(app, pt),
                .circle => handleCircleClick(app, pt),
                .arc => handleArcClick(app, pt),
                .polygon => handlePolygonClick(app, pt),
                .text => handleTextClick(app, pt),
                else => {},
            }
        },
        .double_click => |pt| {
            if (app.tool.active == .polygon) {
                closePolygon(app);
            } else {
                _ = pt;
                actions.enqueue(app, .{ .immediate = .edit_properties }, "Edit properties");
            }
        },
        .right_click => |rc| {
            // Drawing tool: right-click cancels in-progress operation
            if (cancelDrawingTool(app)) return;
            // Placement mode: right-click cancels
            if (app.tool.placement != null) {
                app.tool.placement = null;
                app.status_msg = "Placement cancelled";
                return;
            }
            // Wire mode: right-click cancels
            if (app.tool.active == .wire and app.tool.wire_start != null) {
                app.tool.wire_start = null;
                app.status_msg = "Wire cancelled";
                return;
            }
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
            const sch = &doc.sch;
            doc.selection.ensureCapacity(a, sch.instances.len, sch.wires.len, false) catch return;
            doc.selection.ensureShapeCapacity(a, sch, false) catch return;
            doc.selection.clear();
            var count: usize = 0;
            // Instances
            const xs = sch.instances.items(.x);
            const ys = sch.instances.items(.y);
            for (0..sch.instances.len) |i| {
                if (xs[i] >= rb.min[0] and xs[i] <= rb.max[0] and ys[i] >= rb.min[1] and ys[i] <= rb.max[1]) {
                    doc.selection.instances.set(i); count += 1;
                }
            }
            // Wires
            for (0..sch.wires.len) |i| {
                if (@min(sch.wires.items(.x0)[i], sch.wires.items(.x1)[i]) >= rb.min[0] and
                    @max(sch.wires.items(.x0)[i], sch.wires.items(.x1)[i]) <= rb.max[0] and
                    @min(sch.wires.items(.y0)[i], sch.wires.items(.y1)[i]) >= rb.min[1] and
                    @max(sch.wires.items(.y0)[i], sch.wires.items(.y1)[i]) <= rb.max[1])
                { doc.selection.wires.set(i); count += 1; }
            }
            // Lines
            for (0..sch.lines.len) |i| {
                if (@min(sch.lines.items(.x0)[i], sch.lines.items(.x1)[i]) >= rb.min[0] and
                    @max(sch.lines.items(.x0)[i], sch.lines.items(.x1)[i]) <= rb.max[0] and
                    @min(sch.lines.items(.y0)[i], sch.lines.items(.y1)[i]) >= rb.min[1] and
                    @max(sch.lines.items(.y0)[i], sch.lines.items(.y1)[i]) <= rb.max[1])
                { doc.selection.lines.set(i); count += 1; }
            }
            // Rects
            for (0..sch.rects.len) |i| {
                if (@min(sch.rects.items(.x0)[i], sch.rects.items(.x1)[i]) >= rb.min[0] and
                    @max(sch.rects.items(.x0)[i], sch.rects.items(.x1)[i]) <= rb.max[0] and
                    @min(sch.rects.items(.y0)[i], sch.rects.items(.y1)[i]) >= rb.min[1] and
                    @max(sch.rects.items(.y0)[i], sch.rects.items(.y1)[i]) <= rb.max[1])
                { doc.selection.rects.set(i); count += 1; }
            }
            // Circles
            for (0..sch.circles.len) |i| {
                const cx = sch.circles.items(.cx)[i]; const cy = sch.circles.items(.cy)[i];
                const r = sch.circles.items(.radius)[i];
                if (cx - r >= rb.min[0] and cx + r <= rb.max[0] and cy - r >= rb.min[1] and cy + r <= rb.max[1])
                { doc.selection.circles.set(i); count += 1; }
            }
            // Arcs
            for (0..sch.arcs.len) |i| {
                const cx = sch.arcs.items(.cx)[i]; const cy = sch.arcs.items(.cy)[i];
                const r = sch.arcs.items(.radius)[i];
                if (cx - r >= rb.min[0] and cx + r <= rb.max[0] and cy - r >= rb.min[1] and cy + r <= rb.max[1])
                { doc.selection.arcs.set(i); count += 1; }
            }
            // Texts
            for (0..sch.texts.len) |i| {
                const tx = sch.texts.items(.x)[i]; const ty = sch.texts.items(.y)[i];
                if (tx >= rb.min[0] and tx <= rb.max[0] and ty >= rb.min[1] and ty <= rb.max[1])
                { doc.selection.texts.set(i); count += 1; }
            }
            app.status_msg = if (count > 0) "Selected" else "Ready";
        },
    }
}
