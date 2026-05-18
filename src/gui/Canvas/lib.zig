//! Canvas module — orchestrates sub-renderers in z-order.
//!
//! Z-order:
//!   Grid -> Wires -> Junctions -> Symbols -> Labels -> Selection -> Rubber-band -> Crosshair

const dvui = @import("dvui");
const st = @import("state");
const core = @import("schematic");
const theme = @import("theme_config");

const types = @import("types.zig");
const render = @import("render.zig");
const symbols = @import("symbols.zig");
const wires = @import("wires.zig");
const overlays = @import("overlays.zig");
const interaction = @import("interaction.zig");

const AppState = st.AppState;
const RenderContext = types.RenderContext;
const RenderViewport = types.RenderViewport;
const CanvasEvent = types.CanvasEvent;
const Palette = types.Palette;

pub fn draw(app: *AppState) CanvasEvent {
    const pal = Palette.fromDvui(dvui.themeGet());

    var canvas = dvui.box(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = pal.canvas_bg,
    });
    defer canvas.deinit();

    const wd = canvas.data();
    const rs = wd.contentRectScale();
    const vp = RenderViewport{
        .cx = rs.r.x + rs.r.w / 2.0,
        .cy = rs.r.y + rs.r.h / 2.0,
        .scale = (if (app.active()) |d| d.view.zoom else 1.0) * rs.s,
        .rs_s = rs.s,
        .pan = if (app.active()) |d| d.view.pan else .{ 0, 0 },
        .bounds = rs.r,
    };

    // Overlay input (before canvas interaction).
    overlays.autoGenPreInput(app, wd, rs.r);
    overlays.tbPreInput(app, wd, rs.r);

    // Input handling.
    const event = interaction.handleInput(&app.gui.hot.canvas, app, wd, vp);

    // Dispatch hover events to plugins.
    dispatchPluginHover(app);

    const ctx = RenderContext{
        .allocator = app.gpa.allocator(),
        .vp = vp,
        .pal = pal,
        .cmd_flags = app.cmd_flags,
        .canvas_styles = theme.active_config.resolved.canvas,
        .animation = theme.active_config.animation,
    };

    // Clip to canvas widget.
    const prev_clip = dvui.clip(rs.r);
    defer dvui.clipSet(prev_clip);

    // Z-order rendering.
    if (app.show_grid) render.drawGrid(&ctx, app.tool.snap_size);
    render.drawOrigin(&ctx);

    if (app.active_idx < app.documents.items.len) {
        const doc = &app.documents.items[app.active_idx];
        const file_type = symbols.classifyFile(doc.origin);

        switch (app.gui.hot.view_mode) {
            .schematic => if (file_type != .prim_only) {
                if (doc.sch.prim_cache_dirty or doc.sch.prim_cache.len != doc.sch.instances.len) {
                    doc.sch.rebuildPrimCache(doc.alloc);
                    doc.sch.rebuildSymData(doc.alloc);
                    doc.clearMissingSymbols();
                }
                if (doc.conn.dirty) {
                    doc.conn.resolve(doc.alloc, &doc.sch.instances, &doc.sch.wires, doc.sch.sym_data.items, &doc.sch.strings);
                }
                wires.draw(&ctx, &doc.sch, &doc.selection);
                symbols.draw(&ctx, &doc.sch, app, &doc.selection, overlays.tbIsHovered(app));
                overlays.drawGhostOverlay(&ctx, app);
                overlays.autoGenDraw(&ctx, app);
                overlays.tbDraw(&ctx, app);
            },
            .symbol => if (file_type != .tb_only) {
                symbols.drawSymbol(&ctx, &doc.sch);
            },
            .doc => {},
        }

        if (app.gui.hot.view_mode == .schematic) {
            overlays.drawWirePreview(&ctx, app);
            overlays.drawPlacementGhost(&ctx, app);
            overlays.drawDrawingToolPreview(&ctx, app);
        }
        overlays.drawRubberBand(&ctx, app);
    }

    // Crosshair: full-width/height lines through cursor when enabled.
    if (app.cmd_flags.crosshair) drawCrosshair(&ctx, app);

    renderPluginTooltip(app);

    return event;
}

/// Draw a full-canvas crosshair through the current cursor position.
fn drawCrosshair(ctx: *const RenderContext, app: *const AppState) void {
    const cs = &app.gui.hot.canvas;
    const cursor = cs.cursor_world;
    const vp = ctx.vp;
    const p = render.w2p(cursor, vp);

    // Clamp to canvas bounds for sanity, but draw edge-to-edge.
    const bounds = vp.bounds;
    const crosshair_col = types.Color{ .r = ctx.pal.origin.r, .g = ctx.pal.origin.g, .b = ctx.pal.origin.b, .a = 120 };
    const thickness: f32 = 1.0;

    // Horizontal line (full width)
    render.strokeLine(bounds.x, p[1], bounds.x + bounds.w, p[1], thickness, crosshair_col);
    // Vertical line (full height)
    render.strokeLine(p[0], bounds.y, p[0], bounds.y + bounds.h, thickness, crosshair_col);
}

/// Hit-test cursor and send hover event to subscribed plugins.
fn dispatchPluginHover(app: *AppState) void {
    const host = app.plugin_runtime orelse return;
    const world = app.gui.hot.canvas.cursor_world;

    var element_type: u8 = 0;
    var element_idx: i32 = -1;
    var element_name: []const u8 = "";

    if (app.active()) |doc| {
        const sch = &doc.sch;
        if (interaction.hitTestInstance(sch, world)) |idx| {
            element_type = 1;
            element_idx = @intCast(idx);
            if (idx < sch.instances.len) element_name = sch.str(sch.instances.items(.name)[idx]);
        } else if (interaction.hitTestWire(sch, world)) |idx| {
            element_type = 2;
            element_idx = @intCast(idx);
        }
    }

    host.hover(world[0], world[1], element_type, element_idx, element_name);
}

/// Render tooltip from plugin host if active.
fn renderPluginTooltip(app: *AppState) void {
    const host = app.plugin_runtime orelse return;
    const text = host.getTooltip();
    if (text.len == 0) return;
    dvui.tooltip(@src(), .{ .active_rect = .{} }, "{s}", .{text}, .{});
}
