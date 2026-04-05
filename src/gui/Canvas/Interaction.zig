//! Mouse/keyboard dvui events -> CanvasEvent.
//! Replaces the old Renderer struct's handleInput method.
//! State lives in app.gui.canvas (CanvasState) instead of a module-level var.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");

const types = @import("types.zig");
const vp_mod = @import("Viewport.zig");

const Vec2 = types.Vec2;
const CanvasEvent = types.CanvasEvent;
const RenderViewport = types.RenderViewport;
const CanvasState = st.CanvasState;

/// Process dvui events for the canvas widget and return a CanvasEvent.
pub fn handleInput(cs: *CanvasState, app: *st.AppState, wd: *dvui.WidgetData, vp: RenderViewport) CanvasEvent {
    var result: CanvasEvent = .none;
    const snap = app.tool.snap_size;

    for (dvui.events()) |*ev| {
        if (ev.handled or !dvui.eventMatchSimple(ev, wd)) continue;

        switch (ev.evt) {
            .key => |ke| {
                if (ke.code == .space) {
                    cs.space_held = (ke.action != .up);
                    ev.handled = true;
                }
            },
            .mouse => |me| {
                switch (me.action) {
                    .press => {
                        const mp: Vec2 = .{ me.p.x, me.p.y };
                        switch (me.button) {
                            .left => {
                                ev.handled = true;
                                if (cs.space_held) {
                                    cs.dragging = true;
                                    cs.drag_last = .{ mp[0], mp[1] };
                                } else {
                                    result = handleClick(cs, mp, vp, snap);
                                }
                            },
                            .middle => {
                                ev.handled = true;
                                cs.dragging = true;
                                cs.drag_last = .{ mp[0], mp[1] };
                            },
                            .right => {
                                ev.handled = true;
                                result = .{ .right_click = .{
                                    .pixel = mp,
                                    .world = vp_mod.p2w(mp, vp, snap),
                                } };
                            },
                            else => {},
                        }
                    },
                    .release => {
                        if (me.button == .middle or me.button == .left) {
                            if (cs.dragging) {
                                cs.dragging = false;
                                ev.handled = true;
                            }
                        }
                    },
                    .motion => {
                        if (cs.dragging) {
                            ev.handled = true;
                            const cur: Vec2 = .{ me.p.x, me.p.y };
                            const drag_last_vec: Vec2 = .{ cs.drag_last[0], cs.drag_last[1] };
                            const delta = cur - drag_last_vec;
                            const inv_s: Vec2 = @splat(1.0 / vp.scale);
                            const pan_delta = delta * inv_s;
                            app.view.pan[0] -= pan_delta[0];
                            app.view.pan[1] -= pan_delta[1];
                            cs.drag_last = .{ cur[0], cur[1] };
                        }
                    },
                    .wheel_y => |dy| {
                        ev.handled = true;
                        const cursor: Vec2 = .{ me.p.x, me.p.y };
                        const world_before = vp_mod.p2w_raw(cursor, vp);

                        const factor: f32 = if (dy > 0) 1.25 else (1.0 / 1.25);
                        app.view.zoom = std.math.clamp(app.view.zoom * factor, 0.01, 50.0);

                        const new_vp = RenderViewport{
                            .cx = vp.cx,
                            .cy = vp.cy,
                            .scale = vp.scale * factor,
                            .pan = app.view.pan,
                            .bounds = vp.bounds,
                        };
                        const world_after = vp_mod.p2w_raw(cursor, new_vp);

                        app.view.pan[0] += world_before[0] - world_after[0];
                        app.view.pan[1] += world_before[1] - world_after[1];
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    return result;
}

fn handleClick(cs: *CanvasState, mp: Vec2, vp: RenderViewport, snap: f32) CanvasEvent {
    const now: f64 = @as(f64, @floatFromInt(dvui.frameTimeNS())) / 1_000_000_000.0;
    const dt = now - cs.last_click_time;
    const last_pos: Vec2 = .{ cs.last_click_pos[0], cs.last_click_pos[1] };
    const dp = mp - last_pos;
    const dist = @sqrt(dp[0] * dp[0] + dp[1] * dp[1]);

    const world_pt = vp_mod.p2w(mp, vp, snap);

    if (dt < 0.4 and dist < 10.0) {
        cs.last_click_time = 0;
        return .{ .double_click = world_pt };
    }

    cs.last_click_time = now;
    cs.last_click_pos = .{ mp[0], mp[1] };
    return .{ .click = world_pt };
}
