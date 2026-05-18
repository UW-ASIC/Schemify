//! Wire segment, endpoint, junction, and net-label rendering.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme_config");
const st = @import("state");
const core = @import("schematic");

const types = @import("types.zig");
const h = @import("render.zig");

const Schemify = core.Schemify;
const Color = types.Color;
const RenderContext = types.RenderContext;

pub fn draw(ctx: *const RenderContext, sch: *const Schemify, sel: *const st.Selection) void {
    const vp = ctx.vp;
    const pal = ctx.pal;

    const prev_clip = dvui.clip(.{ .x = vp.bounds.x, .y = vp.bounds.y, .w = vp.bounds.w, .h = vp.bounds.h });
    defer dvui.clipSet(prev_clip);

    const wire_w: f32 = @max(0.8, 1.8 * vp.scale) * ctx.canvas_styles.wire.stroke_width;
    const wire_w_sel: f32 = @max(1.2, 2.8 * vp.scale) * ctx.canvas_styles.wire.stroke_width;

    const cw = dvui.currentWindow();
    var batch = h.LineBatch.init(cw.lifo());
    defer batch.deinit();
    batch.ensureLineCapacity(sch.wires.len + sch.lines.len + sch.rects.len * 4) catch {};

    // Wires
    if (sch.wires.len > 0) {
        const wx0 = sch.wires.items(.x0); const wy0 = sch.wires.items(.y0);
        const wx1 = sch.wires.items(.x1); const wy1 = sch.wires.items(.y1);
        const wbus = sch.wires.items(.bus);
        const wcol = sch.wires.items(.color);
        const wthk = sch.wires.items(.thickness);

        const bus_w: f32 = wire_w * 2.5;
        const bus_w_sel: f32 = wire_w_sel * 2.5;

        // Build point occurrence counts for junction detection.
        const PointCount = std.AutoHashMap(u64, u8);
        var point_counts = PointCount.init(cw.lifo());
        defer point_counts.deinit();
        point_counts.ensureTotalCapacity(@intCast(@min(sch.wires.len * 2, 4096))) catch {};
        for (0..sch.wires.len) |i| {
            const k0 = (@as(u64, @bitCast(@as(i64, wx0[i]))) << 32) | (@as(u64, @as(u32, @bitCast(wy0[i]))));
            const k1 = (@as(u64, @bitCast(@as(i64, wx1[i]))) << 32) | (@as(u64, @as(u32, @bitCast(wy1[i]))));
            const e0 = point_counts.getOrPutAssumeCapacity(k0);
            if (!e0.found_existing) e0.value_ptr.* = 0;
            e0.value_ptr.* +|= 1;
            const e1 = point_counts.getOrPutAssumeCapacity(k1);
            if (!e1.found_existing) e1.value_ptr.* = 0;
            e1.value_ptr.* +|= 1;
        }

        for (0..sch.wires.len) |i| {
            const selected = i < sel.wires.bit_length and sel.wires.isSet(i);
            const is_bus = wbus[i];
            const a = h.w2p(.{ wx0[i], wy0[i] }, vp);
            const b = h.w2p(.{ wx1[i], wy1[i] }, vp);
            const col = if (selected) ctx.canvas_styles.wire.color_selected else if (wcol[i] != 0) Color{
                .r = @truncate(wcol[i] >> 24),
                .g = @truncate(wcol[i] >> 16),
                .b = @truncate(wcol[i] >> 8),
                .a = 255,
            } else if (is_bus) pal.bus else ctx.canvas_styles.wire.color;
            const base_w = if (is_bus) (if (selected) bus_w_sel else bus_w) else (if (selected) wire_w_sel else wire_w);
            const w = if (wthk[i] != 0) base_w * (@as(f32, @floatFromInt(wthk[i])) / 10.0) else base_w;
            batch.addLine(a[0], a[1], b[0], b[1], w, col);

            // Bus slash indicator at midpoint.
            if (is_bus) {
                const mx = (a[0] + b[0]) * 0.5;
                const my = (a[1] + b[1]) * 0.5;
                const slash_len: f32 = @max(4.0, 6.0 * @min(vp.scale, 2.0));
                batch.addLine(mx - slash_len * 0.5, my + slash_len * 0.5, mx + slash_len * 0.5, my - slash_len * 0.5, wire_w, col);
            }
        }

        // Draw junction markers (filled square) where 3+ wire endpoints meet.
        const junction_sz: f32 = @max(2.0, 2.5 * @min(vp.scale, 2.0));
        var pit = point_counts.iterator();
        while (pit.next()) |entry| {
            if (entry.value_ptr.* >= 3) {
                const key = entry.key_ptr.*;
                const wx: i32 = @bitCast(@as(u32, @intCast(key >> 32)));
                const wy: i32 = @bitCast(@as(u32, @truncate(key)));
                const p = h.w2p(.{ wx, wy }, vp);
                batch.addFilledSquare(p, junction_sz, pal.symbol_line);
            }
        }
    }

    // Geometry: Lines
    if (sch.lines.len > 0) {
        const lx0 = sch.lines.items(.x0); const ly0 = sch.lines.items(.y0);
        const lx1 = sch.lines.items(.x1); const ly1 = sch.lines.items(.y1);
        for (0..sch.lines.len) |i| {
            const a = h.w2p(.{ lx0[i], ly0[i] }, vp);
            const b = h.w2p(.{ lx1[i], ly1[i] }, vp);
            batch.addLine(a[0], a[1], b[0], b[1], 1.0, pal.symbol_line);
        }
    }

    // Geometry: Rects
    if (sch.rects.len > 0) {
        const rx0 = sch.rects.items(.x0); const ry0 = sch.rects.items(.y0);
        const rx1 = sch.rects.items(.x1); const ry1 = sch.rects.items(.y1);
        for (0..sch.rects.len) |i| {
            batch.addRectOutline(h.w2p(.{ rx0[i], ry0[i] }, vp), h.w2p(.{ rx1[i], ry1[i] }, vp), 1.0, pal.symbol_line);
        }
    }

    batch.flush();

    // Geometry: Circles
    if (sch.circles.len > 0) {
        const ccx = sch.circles.items(.cx); const ccy = sch.circles.items(.cy); const crad = sch.circles.items(.radius);
        for (0..sch.circles.len) |i| {
            h.strokeCircle(h.w2p(.{ ccx[i], ccy[i] }, vp), @as(f32, @floatFromInt(crad[i])) * vp.scale, 1.0, pal.symbol_line);
        }
    }

    // Geometry: Arcs
    if (sch.arcs.len > 0) {
        const acx = sch.arcs.items(.cx); const acy = sch.arcs.items(.cy);
        const arad = sch.arcs.items(.radius); const astart = sch.arcs.items(.start_angle); const asweep = sch.arcs.items(.sweep_angle);
        for (0..sch.arcs.len) |i| {
            h.strokeArc(h.w2p(.{ acx[i], acy[i] }, vp), @as(f32, @floatFromInt(arad[i])) * vp.scale, astart[i], asweep[i], 1.0, pal.symbol_line);
        }
    }

    // Net labels on wires — only when show_netlist is enabled
    if (ctx.cmd_flags.show_netlist and vp.scale >= 0.3 and sch.wires.len > 0) {
        const wx0 = sch.wires.items(.x0); const wy0 = sch.wires.items(.y0);
        const wx1 = sch.wires.items(.x1); const wy1 = sch.wires.items(.y1);
        const wnn = sch.wires.items(.net_name);
        for (0..sch.wires.len) |i| {
            if (wnn[i].isEmpty()) continue;
            const net = sch.str(wnn[i]);
            if (net.len == 0) continue;
            const a = h.w2p(.{ wx0[i], wy0[i] }, vp);
            const b = h.w2p(.{ wx1[i], wy1[i] }, vp);
            h.drawLabel(net, (a[0] + b[0]) * 0.5 - 40.0, (a[1] + b[1]) * 0.5 - 16.0, theme.withAlpha(pal.inst_pin, 200), vp, sch.instances.len + i);
            // Zero-length wires (net label markers) get a white dot.
            if (wx0[i] == wx1[i] and wy0[i] == wy1[i]) {
                h.strokeDot(a, @max(3.0, 5.0 * @min(vp.scale, 2.0)), Color{ .r = 220, .g = 224, .b = 232, .a = 240 });
            }
        }
    }

    // Texts
    if (vp.scale >= 0.3 and sch.texts.len > 0) {
        const tcontent = sch.texts.items(.content); const tx = sch.texts.items(.x); const ty = sch.texts.items(.y);
        for (0..sch.texts.len) |i| {
            const txt = sch.str(tcontent[i]);
            if (txt.len == 0) continue;
            const p = h.w2p(.{ tx[i], ty[i] }, vp);
            h.drawLabel(txt, p[0], p[1], pal.symbol_line, vp, sch.instances.len + sch.wires.len + i);
        }
    }
}
