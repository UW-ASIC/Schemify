//! renderer/Wires — wire collection pass and wire-preview overlay.

const c  = @import("common.zig");
const tc = @import("theme_config");

/// Collect wires into `buckets` for the schematic view.
pub fn collect(
    app:     *c.AppState,
    pal:     c.Palette,
    sch:     *c.CT.Schematic,
    vp:      c.Viewport,
    buckets: *c.Buckets,
) void {
    const ww_mult    = tc.getWireWidth();
    const wire_w     = @max(1.2, 1.8 * vp.scale) * ww_mult;
    const wire_w_sel = @max(1.8, 2.8 * vp.scale) * ww_mult;

    for (sch.wires.items, 0..) |wire, i| {
        const selected = i < app.selection.wires.bit_length and app.selection.wires.isSet(i);
        const a = c.w2p(wire.start, vp);
        const b = c.w2p(wire.end,   vp);

        if (selected) {
            c.push(buckets, .selection, .{ .line = .{ .a = a, .b = b, .color = pal.wire_sel,  .width = wire_w_sel } });
        } else {
            c.push(buckets, .wires,     .{ .line = .{ .a = a, .b = b, .color = pal.wire,      .width = wire_w } });
        }
        c.push(buckets, .wire_endpoints, .{ .dot = .{ .p = a, .radius = c.wire_endpoint_radius, .color = pal.wire_endpoint } });
        c.push(buckets, .wire_endpoints, .{ .dot = .{ .p = b, .radius = c.wire_endpoint_radius, .color = pal.wire_endpoint } });
    }
}

/// Draw the in-progress wire-placement preview overlay.
pub fn drawPreview(app: *c.AppState, pal: c.Palette, vp: c.Viewport) void {
    const ws    = app.tool.wire_start orelse return;
    const start = c.w2p(ws, vp);

    c.strokeDot(start, c.wire_preview_dot_radius, pal.wire_preview);
    c.strokeLine(start[0] - c.wire_preview_arm, start[1], start[0] + c.wire_preview_arm, start[1], 1.5, pal.wire_preview);
    c.strokeLine(start[0], start[1] - c.wire_preview_arm, start[0], start[1] + c.wire_preview_arm, 1.5, pal.wire_preview);
}
