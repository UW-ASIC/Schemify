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
const tb_overlay = @import("TbOverlay.zig");
const canvas_bar = @import("CanvasBar.zig");

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

    // Testbench overlay input (must run before canvas interaction so button
    // clicks are consumed before the canvas pan/select logic sees them).
    tb_overlay.preInput(app, wd, rs.r);

    // Input handling (uses app.gui.hot.canvas instead of module-level Renderer state).
    const event = interaction.handleInput(&app.gui.hot.canvas, app, wd, vp);

    const ctx = RenderContext{
        .allocator = app.gpa.allocator(),
        .vp = vp,
        .pal = pal,
        .cmd_flags = app.cmd_flags,
    };

    // Clip every draw below to the canvas widget's physical rect. Without
    // this, grid dots, instance geometry, and wire-preview overlays can
    // paint outside the canvas box — e.g. into the toolbar above, when the
    // user pans so that schematic content's projected position falls above
    // rs.r.y. `dvui.clip` intersects with the current clip and returns the
    // previous value, so nested per-renderer clips (WireRenderer,
    // SymbolRenderer.drawSymbol) remain correct.
    const prev_clip = dvui.clip(rs.r);
    defer dvui.clipSet(prev_clip);

    // Z-order rendering.
    if (app.show_grid) grid.draw(&ctx, app.tool.snap_size);
    grid.drawOrigin(&ctx);

    if (app.active_idx < app.documents.items.len) {
        const doc = &app.documents.items[app.active_idx];
        const file_type = symbol_renderer.classifyFile(doc.origin);

        switch (app.gui.hot.view_mode) {
            .schematic => if (file_type != .prim_only) {
                // Rebuild prim cache on first frame after any structural
                // mutation (file load, instance add/remove). Zero string
                // lookups during the render loop.
                if (doc.sch.prim_cache_dirty or doc.sch.prim_cache.len != doc.sch.instances.len) {
                    doc.sch.rebuildPrimCache();
                    doc.sch.rebuildSymData();
                    doc.clearMissingSymbols();
                }
                wire_renderer.draw(&ctx, &doc.sch, &doc.selection);
                symbol_renderer.draw(&ctx, &doc.sch, app, &doc.selection, tb_overlay.isHovered());
                tb_overlay.draw(&ctx, app);
            },
            .symbol => if (file_type != .tb_only) {
                symbol_renderer.drawSymbol(&ctx, &doc.sch);
            },
        }

        // Wire placement preview overlay.
        if (app.gui.hot.view_mode == .schematic) selection_overlay.drawWirePreview(&ctx, app);
    }

    canvas_bar.draw(app);

    return event;
}
