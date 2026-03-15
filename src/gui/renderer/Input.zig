//! renderer/Input — canvas mouse-event handling (pan, click, right-click).

const dvui = @import("dvui");
const c    = @import("common.zig");

/// Mutable pan state owned by the Renderer struct.
pub const PanState = struct {
    dragging: bool = false,
    last:     @Vector(2, f32) = .{ 0, 0 },
};

/// Process all mouse events for the canvas widget.
pub fn handle(
    pan:  *PanState,
    app:  *c.AppState,
    wd:   *dvui.WidgetData,
    vp:   c.Viewport,
) void {
    const fio = app.active() orelse return;
    const sch = fio.schematic();

    const alloc = app.allocator();
    app.selection.instances.resize(alloc, sch.instances.items.len, false) catch {};
    app.selection.wires.resize(alloc, sch.wires.items.len, false) catch {};

    for (dvui.events()) |*e| {
        if (e.handled or !dvui.eventMatchSimple(e, wd)) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;

        switch (me.action) {
            .press => switch (me.button) {
                .left => {
                    e.handled = true;
                    handleLeftClick(pan, app, sch, .{ me.p.x, me.p.y }, vp);
                },
                .middle => {
                    e.handled    = true;
                    pan.dragging = true;
                    pan.last     = .{ me.p.x, me.p.y };
                },
                .right => {
                    e.handled = true;
                    const mp: @Vector(2, f32) = .{ me.p.x, me.p.y };
                    app.gui.ctx_menu = .{
                        .open     = true,
                        .inst_idx = if (c.nearestInstance(sch, mp, vp, c.inst_hit_tolerance)) |idx| @intCast(idx) else -1,
                        .wire_idx = if (c.nearestWire(sch, mp, vp, c.wire_hit_tolerance))     |idx| @intCast(idx) else -1,
                    };
                },
                else => {},
            },
            .release => {
                if (me.button == .middle) {
                    pan.dragging = false;
                    e.handled    = true;
                }
            },
            .motion => {
                if (pan.dragging) {
                    e.handled = true;
                    const cur: @Vector(2, f32) = .{ me.p.x, me.p.y };
                    const delta     = cur - pan.last;
                    const inv_s: @Vector(2, f32) = @splat(1.0 / vp.scale);
                    const pan_delta = delta * inv_s;
                    app.view.pan[0] -= pan_delta[0];
                    app.view.pan[1] -= pan_delta[1];
                    pan.last        = cur;
                }
            },
            else => {},
        }
    }
}

// ── Left-click dispatch ───────────────────────────────────────────────────── //

fn handleLeftClick(
    _:   *PanState,
    app: *c.AppState,
    sch: *c.CT.Schematic,
    mp:  @Vector(2, f32),
    vp:  c.Viewport,
) void {
    const world_pt = c.p2w(mp, vp, app.tool.snap_size);

    if (app.tool.active == .wire) {
        if (app.tool.wire_start) |start| {
            app.queue.push(app.allocator(), .{ .undoable = .{ .add_wire = .{
                .start = start,
                .end   = world_pt,
            } } }) catch {};
            app.tool.wire_start = world_pt;
            app.status_msg      = "Wire: click next point, Esc to finish";
        } else {
            app.tool.wire_start = world_pt;
            app.status_msg      = "Wire started — click to place next point";
        }
        return;
    }

    app.selection.clear();
    if (c.nearestInstance(sch, mp, vp, c.inst_hit_tolerance)) |idx| {
        app.selection.instances.set(idx);
        app.status_msg = "Selected instance";
        return;
    }
    if (c.nearestWire(sch, mp, vp, c.wire_hit_tolerance)) |idx| {
        app.selection.wires.set(idx);
        app.status_msg = "Selected wire";
        return;
    }

    app.tool.wire_start = null;
    app.status_msg      = "Ready";
}
