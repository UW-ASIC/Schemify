//! renderer/root — assembles the public Renderer type from sub-modules.
//!
//! External callers import `renderer.zig` (thin shim) which re-exports this.

const dvui    = @import("dvui");
const c       = @import("common.zig");
const Grid    = @import("Grid.zig");
const Wires   = @import("Wires.zig");
const Symbols = @import("Symbols.zig");
const Input   = @import("Input.zig");

// Re-export the public DrawCmd for callers who need to reference it.
pub const DrawCmd = c.DrawCmd;

/// Main renderer — owns pan-drag state.
pub const Renderer = struct {
    pan: Input.PanState = .{},

    /// Draw the main schematic/symbol canvas with grid, objects, and overlays.
    /// Input events (pan, click, scroll) are consumed inside this call.
    pub fn draw(self: *Renderer, app: *c.AppState) void {
        const pal = c.Palette.fromTheme(dvui.themeGet());

        var canvas = dvui.box(@src(), .{}, .{
            .expand     = .both,
            .background = true,
            .color_fill = pal.canvas_bg,
        });
        defer canvas.deinit();

        const wd = canvas.data();
        const rs = wd.contentRectScale();
        const vp = c.Viewport{
            .cx     = rs.r.x + rs.r.w / 2.0,
            .cy     = rs.r.y + rs.r.h / 2.0,
            .scale  = app.view.zoom * rs.s,
            .pan    = app.view.pan,
            .bounds = rs.r,
        };

        Input.handle(&self.pan, app, wd, vp);
        Grid.draw(app, pal, vp);

        if (app.active()) |fio| {
            switch (app.gui.view_mode) {
                .schematic => drawSchematic(app, pal, fio.schematic(), vp),
                .symbol    => if (fio.symbol()) |sym| drawSymbol(pal, sym, vp),
            }
        }

        Wires.drawPreview(app, pal, vp);
    }
};

// ── Schematic draw pass ───────────────────────────────────────────────────── //

fn drawSchematic(app: *c.AppState, pal: c.Palette, sch: *c.CT.Schematic, vp: c.Viewport) void {
    var buckets = c.emptyBuckets();
    Wires.collect(app, pal, sch, vp, &buckets);
    Symbols.collectInstances(app, pal, sch, vp, &buckets);
    c.flushBuckets(&buckets);
}

// ── Symbol draw pass ──────────────────────────────────────────────────────── //

fn drawSymbol(pal: c.Palette, sym: *c.CT.Symbol, vp: c.Viewport) void {
    var buckets = c.emptyBuckets();
    Symbols.collectSymbol(pal, sym, vp, &buckets);
    c.flushBuckets(&buckets);
}

// ── Size test ─────────────────────────────────────────────────────────────── //

test "Expose struct size for renderer" {
    const print = @import("std").debug.print;
    print("DrawCmd:  {d}B\n", .{@sizeOf(DrawCmd)});
    print("Renderer: {d}B\n", .{@sizeOf(Renderer)});
}
