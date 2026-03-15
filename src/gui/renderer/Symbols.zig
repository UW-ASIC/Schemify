//! renderer/Symbols — instance and symbol-view collection passes.

const c = @import("common.zig");

/// Collect instances into `buckets` for the schematic view.
pub fn collectInstances(
    app:     *c.AppState,
    pal:     c.Palette,
    sch:     *c.CT.Schematic,
    vp:      c.Viewport,
    buckets: *c.Buckets,
) void {
    const box_half: f32 = @max(4.0, 6.0 * @min(vp.scale, 2.0));
    const pin_arm:  f32 = @max(3.0, 4.0 * @min(vp.scale, 2.0));

    for (sch.instances.items, 0..) |inst, i| {
        const selected = i < app.selection.instances.bit_length and app.selection.instances.isSet(i);
        const p    = c.w2p(inst.pos, vp);
        const half: @Vector(2, f32) = @splat(box_half);

        if (selected) {
            c.push(buckets, .selection, .{ .rect_outline = .{ .min = p - half, .max = p + half, .color = pal.inst_sel,  .width = 1.8 } });
            c.push(buckets, .selection, .{ .cross        = .{ .p = p, .arm = pin_arm, .width = 1.0, .color = pal.wire_sel } });
        } else {
            c.push(buckets, .instances, .{ .rect_outline = .{ .min = p - half, .max = p + half, .color = pal.inst_body, .width = 1.2 } });
            c.push(buckets, .instances, .{ .cross        = .{ .p = p, .arm = pin_arm, .width = 1.0, .color = pal.inst_pin } });
        }
    }
}

/// Collect symbol shapes and pins into `buckets` for the symbol-editor view.
pub fn collectSymbol(
    pal:     c.Palette,
    sym:     *c.CT.Symbol,
    vp:      c.Viewport,
    buckets: *c.Buckets,
) void {
    for (sym.shapes.items) |shape| {
        switch (shape) {
            .line => |s| {
                c.push(buckets, .symbol_shapes, .{ .line = .{
                    .a     = c.w2p(s.start, vp),
                    .b     = c.w2p(s.end,   vp),
                    .color = pal.symbol_line,
                    .width = 1.4,
                } });
            },
            .rect => |s| {
                c.push(buckets, .symbol_shapes, .{ .rect_outline = .{
                    .min   = c.w2p(s.min, vp),
                    .max   = c.w2p(s.max, vp),
                    .color = pal.symbol_line,
                    .width = 1.4,
                } });
            },
            else => {},
        }
    }

    const pin_arm: f32 = @max(3.5, 5.0 * @min(vp.scale, 2.0));
    for (sym.pins.items) |pin| {
        const p = c.w2p(pin.pos, vp);
        c.push(buckets, .symbol_pins, .{ .cross = .{ .p = p, .arm = pin_arm, .width = 2.0, .color = pal.symbol_pin } });
        c.push(buckets, .symbol_pins, .{ .dot   = .{ .p = p, .radius = 3.0,               .color = pal.symbol_pin } });
    }
}
