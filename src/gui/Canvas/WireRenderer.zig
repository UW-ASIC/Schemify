//! Wire segment, endpoint, junction, and net-label rendering.

const dvui = @import("dvui");
const theme = @import("theme_config");
const st = @import("state");
const core = @import("core");

const types = @import("types.zig");
const vp_mod = @import("Viewport.zig");
const h = @import("draw_helpers.zig");

const Schemify = core.Schemify;
const Color = types.Color;
const RenderContext = types.RenderContext;

/// Draw all wires, endpoints, geometry (lines/rects/circles/arcs), net labels, and texts.
pub fn draw(ctx: *const RenderContext, sch: *const Schemify, sel: *const st.Selection) void {
    const vp = ctx.vp;
    const pal = ctx.pal;

    // Clip drawing to canvas viewport.
    const prev_clip = dvui.clip(.{ .x = vp.bounds.x, .y = vp.bounds.y, .w = vp.bounds.w, .h = vp.bounds.h });
    defer dvui.clipSet(prev_clip);

    const wire_w: f32 = @max(0.8, 1.8 * vp.scale) * theme.getWireWidth();
    const wire_w_sel: f32 = @max(1.2, 2.8 * vp.scale) * theme.getWireWidth();

    // One batch accumulates every wire segment, geometry line, and rect
    // outline, then submits them as a single renderTriangles call. On a
    // schematic with a thousand wires this drops per-frame render commands
    // for the wire pass from ~3000 (wire + 2 endpoints each) down to 2
    // (one batch of line quads + one batch of endpoint quads).
    const cw = dvui.currentWindow();
    var batch = h.LineBatch.init(cw.lifo());
    defer batch.deinit();
    batch.ensureLineCapacity(sch.wires.len + sch.lines.len + sch.rects.len * 4) catch {};

    // -- Wires --
    if (sch.wires.len > 0) {
        const wx0 = sch.wires.items(.x0);
        const wy0 = sch.wires.items(.y0);
        const wx1 = sch.wires.items(.x1);
        const wy1 = sch.wires.items(.y1);

        for (0..sch.wires.len) |i| {
            const selected = i < sel.wires.bit_length and sel.wires.isSet(i);
            const a = vp_mod.w2p(.{ wx0[i], wy0[i] }, vp);
            const b = vp_mod.w2p(.{ wx1[i], wy1[i] }, vp);
            const col = if (selected) pal.wire_sel else pal.wire;
            const w = if (selected) wire_w_sel else wire_w;
            batch.addLine(a[0], a[1], b[0], b[1], w, col);
            batch.addDot(a, types.wire_endpoint_radius, pal.wire_endpoint);
            batch.addDot(b, types.wire_endpoint_radius, pal.wire_endpoint);
        }
    }

    // -- Geometry: Lines --
    if (sch.lines.len > 0) {
        const lx0 = sch.lines.items(.x0);
        const ly0 = sch.lines.items(.y0);
        const lx1 = sch.lines.items(.x1);
        const ly1 = sch.lines.items(.y1);
        for (0..sch.lines.len) |i| {
            const a = vp_mod.w2p(.{ lx0[i], ly0[i] }, vp);
            const b = vp_mod.w2p(.{ lx1[i], ly1[i] }, vp);
            batch.addLine(a[0], a[1], b[0], b[1], 1.0, pal.symbol_line);
        }
    }

    // -- Geometry: Rects --
    if (sch.rects.len > 0) {
        const rx0 = sch.rects.items(.x0);
        const ry0 = sch.rects.items(.y0);
        const rx1 = sch.rects.items(.x1);
        const ry1 = sch.rects.items(.y1);
        for (0..sch.rects.len) |i| {
            const tl = vp_mod.w2p(.{ rx0[i], ry0[i] }, vp);
            const br = vp_mod.w2p(.{ rx1[i], ry1[i] }, vp);
            batch.addRectOutline(tl, br, 1.0, pal.symbol_line);
        }
    }

    // Flush all line/rect geometry as one renderTriangles call. Subsequent
    // draws (endpoints, circles, arcs, labels) are layered on top.
    batch.flush();

    // -- Geometry: Circles --
    if (sch.circles.len > 0) {
        const ccx = sch.circles.items(.cx);
        const ccy = sch.circles.items(.cy);
        const crad = sch.circles.items(.radius);
        for (0..sch.circles.len) |i| {
            const center = vp_mod.w2p(.{ ccx[i], ccy[i] }, vp);
            const r: f32 = @as(f32, @floatFromInt(crad[i])) * vp.scale;
            h.strokeCircle(center, r, 1.0, pal.symbol_line);
        }
    }

    // -- Geometry: Arcs --
    if (sch.arcs.len > 0) {
        const acx = sch.arcs.items(.cx);
        const acy = sch.arcs.items(.cy);
        const arad = sch.arcs.items(.radius);
        const astart = sch.arcs.items(.start_angle);
        const asweep = sch.arcs.items(.sweep_angle);
        for (0..sch.arcs.len) |i| {
            const center = vp_mod.w2p(.{ acx[i], acy[i] }, vp);
            const r: f32 = @as(f32, @floatFromInt(arad[i])) * vp.scale;
            h.strokeArc(center, r, astart[i], asweep[i], 1.0, pal.symbol_line);
        }
    }

    // -- Net labels on wires --
    if (vp.scale >= 0.3 and sch.wires.len > 0) {
        const wx0 = sch.wires.items(.x0);
        const wy0 = sch.wires.items(.y0);
        const wx1 = sch.wires.items(.x1);
        const wy1 = sch.wires.items(.y1);
        const wnn = sch.wires.items(.net_name);

        for (0..sch.wires.len) |i| {
            const net = wnn[i] orelse continue;
            if (net.len == 0) continue;

            const a = vp_mod.w2p(.{ wx0[i], wy0[i] }, vp);
            const b = vp_mod.w2p(.{ wx1[i], wy1[i] }, vp);
            const mid_x = (a[0] + b[0]) * 0.5;
            const mid_y = (a[1] + b[1]) * 0.5;

            h.drawLabel(net, mid_x - 40.0, mid_y - 16.0, theme.withAlpha(pal.inst_pin, 200), vp, sch.instances.len + i);

            // Zero-length wires (net label markers) get a white dot.
            if (wx0[i] == wx1[i] and wy0[i] == wy1[i]) {
                const radius: f32 = @max(3.0, 5.0 * @min(vp.scale, 2.0));
                h.strokeDot(a, radius, Color{ .r = 255, .g = 255, .b = 255, .a = 255 });
            }
        }
    }

    // -- Texts --
    if (vp.scale >= 0.3 and sch.texts.len > 0) {
        const tcontent = sch.texts.items(.content);
        const tx = sch.texts.items(.x);
        const ty = sch.texts.items(.y);
        for (0..sch.texts.len) |i| {
            if (tcontent[i].len == 0) continue;
            const p = vp_mod.w2p(.{ tx[i], ty[i] }, vp);
            h.drawLabel(tcontent[i], p[0], p[1], pal.symbol_line, vp, sch.instances.len + sch.wires.len + i);
        }
    }
}