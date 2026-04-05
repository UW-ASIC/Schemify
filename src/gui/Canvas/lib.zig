//! Canvas module -- orchestrates sub-renderers in z-order.
//!
//! Z-order (per D-02):
//!   Grid -> Wires -> Junctions -> Symbols -> Labels -> Selection -> Rubber-band -> Crosshair

const dvui = @import("dvui");
const st = @import("state");
const theme = @import("theme_config");

const types = @import("types.zig");
const grid = @import("Grid.zig");
const symbol_renderer = @import("SymbolRenderer.zig");
const wire_renderer = @import("WireRenderer.zig");
const selection_overlay = @import("SelectionOverlay.zig");
const interaction = @import("Interaction.zig");

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
        .scale = app.view.zoom * rs.s,
        .pan = app.view.pan,
        .bounds = rs.r,
    };

    // Input handling (uses app.gui.canvas instead of module-level Renderer state).
    const event = interaction.handleInput(&app.gui.canvas, app, wd, vp);

    const ctx = RenderContext{
        .allocator = app.gpa.allocator(),
        .vp = vp,
        .pal = pal,
        .cmd_flags = app.cmd_flags,
    };

    // Z-order rendering.
    if (app.show_grid) grid.draw(&ctx, app.tool.snap_size);
    grid.drawOrigin(&ctx);

    if (app.active_idx < app.documents.items.len) {
        const doc = &app.documents.items[app.active_idx];
        const file_type = symbol_renderer.classifyFile(doc.origin);

        switch (app.gui.view_mode) {
            .schematic => if (file_type != .prim_only) {
                wire_renderer.draw(&ctx, &doc.sch, &app.selection);
                symbol_renderer.draw(&ctx, &doc.sch, app, &app.selection);
            },
            .symbol => if (file_type != .tb_only) {
                symbol_renderer.drawSymbol(&ctx, &doc.sch);
            },
        }

        // Wire placement preview overlay.
        if (app.gui.view_mode == .schematic) selection_overlay.drawWirePreview(&ctx, app);
    }

    return event;
}
