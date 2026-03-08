//! Renderer — schematic/symbol canvas drawing and input handling.

const std = @import("std");
const dvui = @import("dvui");
const AppState = @import("../state.zig").AppState;
const CT = @import("../state.zig").CT;

// ── Constants ─────────────────────────────────────────────────────────────── //

const GRID_MIN_STEP_PX: f32 = 3.0;
const GRID_MAX_POINTS: f32 = 16000.0;
const GRID_DOT_LARGE: f32 = 1.2;
const GRID_DOT_SMALL: f32 = 0.7;
const GRID_DOT_THRESHOLD: f32 = 20.0;
const ORIGIN_ARM_MIN: f32 = 6.0;
const ORIGIN_ARM_MAX_SCALE: f32 = 12.0;
const WIRE_ENDPOINT_RADIUS: f32 = 2.5;
const WIRE_PREVIEW_DOT_RADIUS: f32 = 4.0;
const WIRE_PREVIEW_ARM: f32 = 8.0;
const INST_HIT_TOLERANCE: f32 = 14.0;
const WIRE_HIT_TOLERANCE: f32 = 10.0;

// ── Theme-derived palette ─────────────────────────────────────────────────────
//
// All renderer colors are computed from dvui.themeGet() each frame so that
// switching themes (including custom .lua themes) instantly affects the canvas.

const Palette = struct {
    canvas_bg: dvui.Color,
    grid_dot: dvui.Color,
    wire: dvui.Color,
    wire_sel: dvui.Color,
    wire_endpoint: dvui.Color,
    inst_body: dvui.Color,
    inst_sel: dvui.Color,
    inst_pin: dvui.Color,
    symbol_line: dvui.Color,
    symbol_pin: dvui.Color,
    wire_preview: dvui.Color,
    origin: dvui.Color,

    pub fn fromTheme(t: dvui.Theme) Palette {
        // Resolve optional colours from Theme.Style
        const focus = t.focus;
        const hl = t.highlight.fill orelse t.focus;
        const ctrl = t.control.fill orelse t.fill;
        const win_bg = t.window.fill orelse t.fill;

        // Blend two colours by weight w ∈ [0,255] towards b
        const blend = struct {
            fn f(a: dvui.Color, b: dvui.Color, w: u8) dvui.Color {
                const fw: u32 = w;
                const fa: u32 = 255 - fw;
                return .{
                    .r = @intCast((a.r * fa + b.r * fw) / 255),
                    .g = @intCast((a.g * fa + b.g * fw) / 255),
                    .b = @intCast((a.b * fa + b.b * fw) / 255),
                    .a = 255,
                };
            }
        }.f;

        // Scale brightness by factor f ∈ [0, 255]
        const scale = struct {
            fn f(c: dvui.Color, fac: u32) dvui.Color {
                return .{
                    .r = @intCast(@min(255, @as(u32, c.r) * fac / 255)),
                    .g = @intCast(@min(255, @as(u32, c.g) * fac / 255)),
                    .b = @intCast(@min(255, @as(u32, c.b) * fac / 255)),
                    .a = c.a,
                };
            }
        }.f;

        // Make an alpha-adjusted copy
        const withAlpha = struct {
            fn f(c: dvui.Color, a: u8) dvui.Color {
                return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
            }
        }.f;

        // Canvas background: slightly darker than window fill
        const canvas_bg = if (t.dark)
            scale(win_bg, 180)
        else
            scale(win_bg, 240);

        // Grid dots: border colour at reduced brightness
        const grid_dot = withAlpha(scale(t.border, if (t.dark) 140 else 170), if (t.dark) 200 else 180);

        // Wires: focus colour (the accent), brightened for dark themes
        const wire = if (t.dark)
            blend(focus, .{ .r = 200, .g = 235, .b = 255, .a = 255 }, 60)
        else
            blend(focus, .{ .r = 0, .g = 40, .b = 100, .a = 255 }, 30);

        // Selected wire/instance: highlight colour tinted orange for dark, darker for light
        const wire_sel = if (t.dark)
            blend(hl, .{ .r = 255, .g = 180, .b = 60, .a = 255 }, 100)
        else
            blend(hl, .{ .r = 180, .g = 80, .b = 0, .a = 255 }, 80);

        // Wire endpoints: focus + green lean
        const wire_endpoint = blend(focus, .{ .r = 60, .g = 255, .b = 140, .a = 255 }, 80);

        // Instance body: control fill tinted toward focus
        const inst_body = blend(ctrl, focus, 80);

        // Instance selected: same as wire_sel
        const inst_sel = wire_sel;

        // Instance pin: text colour tinted yellow
        const inst_pin = blend(t.text, .{ .r = 255, .g = 230, .b = 60, .a = 255 }, 90);

        // Symbol lines: text colour at 85% brightness
        const symbol_line = scale(t.text, 215);

        // Symbol pins: focus + yellow lean
        const symbol_pin = blend(focus, .{ .r = 255, .g = 220, .b = 60, .a = 255 }, 100);

        // Wire preview: highlight colour at 70% alpha
        const wire_preview = withAlpha(blend(hl, .{ .r = 80, .g = 255, .b = 100, .a = 255 }, 80), 180);

        // Origin cross: border colour
        const origin = withAlpha(t.border, if (t.dark) 190 else 170);

        return .{
            .canvas_bg = canvas_bg,
            .grid_dot = grid_dot,
            .wire = wire,
            .wire_sel = wire_sel,
            .wire_endpoint = wire_endpoint,
            .inst_body = inst_body,
            .inst_sel = inst_sel,
            .inst_pin = inst_pin,
            .symbol_line = symbol_line,
            .symbol_pin = symbol_pin,
            .wire_preview = wire_preview,
            .origin = origin,
        };
    }
};

// ── Pan drag state ────────────────────────────────────────────────────────────

var pan_dragging: bool = false;
var pan_last: dvui.Point.Physical = .{ .x = 0, .y = 0 };

/// Draw the main schematic/symbol canvas with grid, objects, and overlays.
pub fn draw(app: *AppState) void {
    const pal = Palette.fromTheme(dvui.themeGet());

    var canvas = dvui.box(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = pal.canvas_bg,
    });
    defer canvas.deinit();

    const wd = canvas.data();
    const rs = wd.contentRectScale();
    const viewport = Viewport{
        .cx = rs.r.x + rs.r.w / 2.0,
        .cy = rs.r.y + rs.r.h / 2.0,
        .scale = app.view.zoom * rs.s,
        .pan = app.view.pan,
        .bounds = rs.r,
    };

    if (app.gui.view_mode == .waveform) {
        drawWaveform(app, pal, viewport);
        return;
    }

    handleCanvasInput(app, wd, viewport);
    drawGrid(app, pal, viewport);
    drawOriginCross(pal, viewport);

    if (app.active()) |fio| {
        switch (app.gui.view_mode) {
            .schematic => drawSchematic(app, pal, fio.schematic(), viewport),
            .symbol => if (fio.symbol()) |sym| drawSymbol(pal, sym, viewport),
            .waveform => {}, // handled above
        }
    }

    drawWirePreview(app, pal, viewport);
    drawInfoOverlay(app, viewport);
}

// ── Viewport ──────────────────────────────────────────────────────────────────

const Viewport = struct {
    cx: f32,
    cy: f32,
    scale: f32,
    pan: [2]f32,
    bounds: dvui.Rect.Physical,
};

// ── Waveform viewer ───────────────────────────────────────────────────────────

fn drawWaveform(app: *AppState, pal: Palette, vp: Viewport) void {
    const cx = vp.bounds.x;
    const cy = vp.bounds.y;
    const bw = vp.bounds.w;
    const bh = vp.bounds.h;

    // Title area
    const title_h: f32 = 30.0;
    const label_bytes = app.waveform_label[0..app.waveform_label_len];
    _ = label_bytes; // used in text below

    // Draw title background strip
    dvui.Path.stroke(.{
        .points = &.{
            .{ .x = cx, .y = cy + title_h },
            .{ .x = cx + bw, .y = cy + title_h },
        },
    }, .{ .thickness = 1.0, .color = pal.wire });

    // Plot area margins
    const mx: f32 = 40.0;
    const my: f32 = title_h + 20.0;
    const pw: f32 = bw - mx * 2.0;
    const ph: f32 = bh - my - 20.0;

    if (app.waveform_len == 0) {
        // No data: draw a centered placeholder line
        dvui.Path.stroke(.{
            .points = &.{
                .{ .x = cx + bw * 0.2, .y = cy + bh / 2.0 },
                .{ .x = cx + bw * 0.8, .y = cy + bh / 2.0 },
            },
        }, .{ .thickness = 1.0, .color = pal.grid_dot });
        return;
    }

    const n = app.waveform_len;

    // Find min/max for scaling
    var vmin: f32 = app.waveform_data[0];
    var vmax: f32 = app.waveform_data[0];
    for (app.waveform_data[0..n]) |v| {
        if (v < vmin) vmin = v;
        if (v > vmax) vmax = v;
    }
    const vrange = if (vmax - vmin < 1e-9) 1.0 else vmax - vmin;

    // Draw waveform as connected line segments
    const nf: f32 = @floatFromInt(n);
    const nsteps: f32 = if (n > 1) nf - 1.0 else 1.0;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const i0: f32 = @floatFromInt(i - 1);
        const i1: f32 = @floatFromInt(i);
        const x0 = cx + mx + (i0 / nsteps) * pw;
        const y0 = cy + my + ph - ((app.waveform_data[i - 1] - vmin) / vrange) * ph;
        const x1 = cx + mx + (i1 / nsteps) * pw;
        const y1 = cy + my + ph - ((app.waveform_data[i] - vmin) / vrange) * ph;
        dvui.Path.stroke(.{
            .points = &.{
                .{ .x = x0, .y = y0 },
                .{ .x = x1, .y = y1 },
            },
        }, .{ .thickness = 1.5, .color = pal.wire });
    }

    // Draw axes
    dvui.Path.stroke(.{
        .points = &.{
            .{ .x = cx + mx, .y = cy + my },
            .{ .x = cx + mx, .y = cy + my + ph },
            .{ .x = cx + mx + pw, .y = cy + my + ph },
        },
    }, .{ .thickness = 1.0, .color = pal.origin });
}

// ── Grid ──────────────────────────────────────────────────────────────────────

fn drawGrid(app: *AppState, pal: Palette, vp: Viewport) void {
    if (!app.show_grid) return;

    const snap = app.tool.snap_size;
    const step = snap * vp.scale;
    if (step < GRID_MIN_STEP_PX) return;

    const ox = @mod(vp.cx - vp.pan[0] * vp.scale, step);
    const oy = @mod(vp.cy - vp.pan[1] * vp.scale, step);

    const cols_f = @max(1.0, @floor(vp.bounds.w / step) + 2.0);
    const rows_f = @max(1.0, @floor(vp.bounds.h / step) + 2.0);
    const total_points = cols_f * rows_f;
    const max_points: f32 = GRID_MAX_POINTS;
    const stride = if (total_points <= max_points) 1.0 else @ceil(@sqrt(total_points / max_points));
    const draw_step = step * stride;

    const dot_r: f32 = if (step > GRID_DOT_THRESHOLD) GRID_DOT_LARGE else GRID_DOT_SMALL;

    var x: f32 = vp.bounds.x + ox;
    while (x < vp.bounds.x + vp.bounds.w) : (x += draw_step) {
        var y: f32 = vp.bounds.y + oy;
        while (y < vp.bounds.y + vp.bounds.h) : (y += draw_step) {
            dvui.Path.stroke(.{
                .points = &.{
                    .{ .x = x - dot_r, .y = y },
                    .{ .x = x + dot_r, .y = y },
                },
            }, .{ .thickness = dot_r * 2.0, .color = pal.grid_dot });
        }
    }
}

fn drawOriginCross(pal: Palette, vp: Viewport) void {
    const ox = vp.cx - vp.pan[0] * vp.scale;
    const oy = vp.cy - vp.pan[1] * vp.scale;
    const arm: f32 = @max(ORIGIN_ARM_MIN, ORIGIN_ARM_MAX_SCALE * @min(vp.scale, 1.0));

    if (ox < vp.bounds.x or ox > vp.bounds.x + vp.bounds.w) return;
    if (oy < vp.bounds.y or oy > vp.bounds.y + vp.bounds.h) return;

    dvui.Path.stroke(.{
        .points = &.{ .{ .x = ox - arm, .y = oy }, .{ .x = ox + arm, .y = oy } },
    }, .{ .thickness = 1.0, .color = pal.origin });
    dvui.Path.stroke(.{
        .points = &.{ .{ .x = ox, .y = oy - arm }, .{ .x = ox, .y = oy + arm } },
    }, .{ .thickness = 1.0, .color = pal.origin });
}

// ── Schematic ─────────────────────────────────────────────────────────────────

fn drawSchematic(app: *AppState, pal: Palette, sch: *CT.Schematic, vp: Viewport) void {
    drawWires(app, pal, sch, vp);
    drawInstances(app, pal, sch, vp);
}

fn drawWires(app: *AppState, pal: Palette, sch: *CT.Schematic, vp: Viewport) void {
    const wire_w = @max(1.2, 1.8 * vp.scale);
    const wire_w_sel = @max(1.8, 2.8 * vp.scale);

    for (sch.wires.items, 0..) |wire, i| {
        const selected = i < app.selection.wires.bit_length and app.selection.wires.isSet(i);
        const col = if (selected) pal.wire_sel else pal.wire;
        const lw = if (selected) wire_w_sel else wire_w;

        const a = w2p(wire.start, vp);
        const b = w2p(wire.end, vp);
        dvui.Path.stroke(.{
            .points = &.{ a, b },
        }, .{ .thickness = lw, .color = col });

        // Draw endpoint dots for wires
        drawDot(a, WIRE_ENDPOINT_RADIUS, pal.wire_endpoint);
        drawDot(b, WIRE_ENDPOINT_RADIUS, pal.wire_endpoint);
    }
}

fn drawInstances(app: *AppState, pal: Palette, sch: *CT.Schematic, vp: Viewport) void {
    for (sch.instances.items, 0..) |inst, i| {
        const selected = i < app.selection.instances.bit_length and app.selection.instances.isSet(i);
        drawInstance(pal, inst, selected, vp);
    }
}

fn drawInstance(pal: Palette, inst: CT.Instance, selected: bool, vp: Viewport) void {
    const p = w2p(inst.pos, vp);
    const col_body = if (selected) pal.inst_sel else pal.inst_body;
    const col_pin = if (selected) pal.wire_sel else pal.inst_pin;

    const box_half: f32 = @max(4.0, 6.0 * @min(vp.scale, 2.0));
    const lw: f32 = if (selected) 1.8 else 1.2;

    // Component bounding box
    dvui.Path.stroke(.{
        .points = &.{
            .{ .x = p.x - box_half, .y = p.y - box_half },
            .{ .x = p.x + box_half, .y = p.y - box_half },
            .{ .x = p.x + box_half, .y = p.y + box_half },
            .{ .x = p.x - box_half, .y = p.y + box_half },
            .{ .x = p.x - box_half, .y = p.y - box_half },
        },
    }, .{ .thickness = lw, .color = col_body });

    // Pin indicator (small cross at origin)
    const pin_arm: f32 = @max(3.0, 4.0 * @min(vp.scale, 2.0));
    dvui.Path.stroke(.{
        .points = &.{ .{ .x = p.x - pin_arm, .y = p.y }, .{ .x = p.x + pin_arm, .y = p.y } },
    }, .{ .thickness = 1.0, .color = col_pin });
    dvui.Path.stroke(.{
        .points = &.{ .{ .x = p.x, .y = p.y - pin_arm }, .{ .x = p.x, .y = p.y + pin_arm } },
    }, .{ .thickness = 1.0, .color = col_pin });
}

// ── Symbol view ───────────────────────────────────────────────────────────────

fn drawSymbol(pal: Palette, sym: *CT.Symbol, vp: Viewport) void {
    for (sym.shapes.items) |shape| {
        switch (shape.tag) {
            .line => {
                dvui.Path.stroke(.{
                    .points = &.{ w2p(shape.data.line.start, vp), w2p(shape.data.line.end, vp) },
                }, .{ .thickness = 1.4, .color = pal.symbol_line });
            },
            .rect => {
                const lo = w2p(shape.data.rect.min, vp);
                const hi = w2p(shape.data.rect.max, vp);
                dvui.Path.stroke(.{
                    .points = &.{
                        .{ .x = lo.x, .y = lo.y },
                        .{ .x = hi.x, .y = lo.y },
                        .{ .x = hi.x, .y = hi.y },
                        .{ .x = lo.x, .y = hi.y },
                        .{ .x = lo.x, .y = lo.y },
                    },
                }, .{ .thickness = 1.4, .color = pal.symbol_line });
            },
            else => {},
        }
    }

    for (sym.pins.items) |pin| {
        const p = w2p(pin.pos, vp);
        const arm: f32 = @max(3.5, 5.0 * @min(vp.scale, 2.0));
        dvui.Path.stroke(.{
            .points = &.{ .{ .x = p.x - arm, .y = p.y }, .{ .x = p.x + arm, .y = p.y } },
        }, .{ .thickness = 2.0, .color = pal.symbol_pin });
        dvui.Path.stroke(.{
            .points = &.{ .{ .x = p.x, .y = p.y - arm }, .{ .x = p.x, .y = p.y + arm } },
        }, .{ .thickness = 2.0, .color = pal.symbol_pin });
        drawDot(p, 3.0, pal.symbol_pin);
    }
}

// ── Wire preview ──────────────────────────────────────────────────────────────

fn drawWirePreview(app: *AppState, pal: Palette, vp: Viewport) void {
    const ws = app.tool.wire_start orelse return;
    const start = w2p(.{ .x = ws[0], .y = ws[1] }, vp);

    drawDot(start, WIRE_PREVIEW_DOT_RADIUS, pal.wire_preview);
    dvui.Path.stroke(.{
        .points = &.{ .{ .x = start.x - WIRE_PREVIEW_ARM, .y = start.y }, .{ .x = start.x + WIRE_PREVIEW_ARM, .y = start.y } },
    }, .{ .thickness = 1.5, .color = pal.wire_preview });
    dvui.Path.stroke(.{
        .points = &.{ .{ .x = start.x, .y = start.y - WIRE_PREVIEW_ARM }, .{ .x = start.x, .y = start.y + WIRE_PREVIEW_ARM } },
    }, .{ .thickness = 1.5, .color = pal.wire_preview });
}

// ── Info overlay ──────────────────────────────────────────────────────────────

fn drawInfoOverlay(app: *AppState, vp: Viewport) void {
    _ = vp;
    // Draw a small corner indicator showing current tool
    const tool_col: dvui.Color = switch (app.tool.active) {
        .select => .{ .r = 100, .g = 120, .b = 200, .a = 160 },
        .wire => .{ .r = 80, .g = 200, .b = 100, .a = 160 },
        .move => .{ .r = 200, .g = 170, .b = 80, .a = 160 },
        .pan => .{ .r = 120, .g = 200, .b = 210, .a = 160 },
        .line, .rect, .polygon, .arc, .circle, .text => .{ .r = 210, .g = 110, .b = 170, .a = 160 },
    };
    const tool_name = app.tool.label();
    _ = tool_name;
    _ = tool_col;
    // Future: draw tool indicator in bottom-right of canvas
}

// ── Input handling ────────────────────────────────────────────────────────────

fn handleCanvasInput(app: *AppState, wd: *dvui.WidgetData, vp: Viewport) void {
    const fio = app.active() orelse return;
    const sch = fio.schematic();
    ensureSelectionSizes(app, sch);

    for (dvui.events()) |*e| {
        if (e.handled or !dvui.eventMatchSimple(e, wd)) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;

        switch (me.action) {
            .press => {
                switch (me.button) {
                    .left => {
                        e.handled = true;
                        handleLeftClick(app, sch, me.p, vp);
                    },
                    .middle => {
                        e.handled = true;
                        pan_dragging = true;
                        pan_last = me.p;
                    },
                    else => {},
                }
            },
            .release => {
                if (me.button == .middle) {
                    pan_dragging = false;
                    e.handled = true;
                }
            },
            .motion => {
                if (pan_dragging) {
                    e.handled = true;
                    const dx = me.p.x - pan_last.x;
                    const dy = me.p.y - pan_last.y;
                    app.view.pan[0] -= dx / vp.scale;
                    app.view.pan[1] -= dy / vp.scale;
                    pan_last = me.p;
                }
            },
            else => {},
        }
    }
}

fn handleLeftClick(app: *AppState, sch: *CT.Schematic, mp: dvui.Point.Physical, vp: Viewport) void {
    const world_pt = p2w(mp, vp);

    // If wire tool is active
    if (app.tool.active == .wire) {
        if (app.tool.wire_start) |start| {
            // Complete the wire
            app.queue.push(.{ .add_wire = .{
                .x0 = @floatFromInt(start[0]),
                .y0 = @floatFromInt(start[1]),
                .x1 = @floatFromInt(world_pt.x),
                .y1 = @floatFromInt(world_pt.y),
            } }) catch {};
            // Continue from current point
            app.tool.wire_start = .{ world_pt.x, world_pt.y };
            app.status_msg = "Wire: click next point, Esc to finish";
        } else {
            app.tool.wire_start = .{ world_pt.x, world_pt.y };
            app.status_msg = "Wire started — click to place next point";
        }
        return;
    }

    // Select mode: click to select nearest object
    const nearest_inst = nearestInstance(sch, mp, vp, INST_HIT_TOLERANCE);
    const nearest_wire = nearestWire(sch, mp, vp, WIRE_HIT_TOLERANCE);

    app.selection.clear();
    if (nearest_inst) |idx| {
        app.selection.instances.set(idx);
        app.status_msg = "Selected instance";
        return;
    }
    if (nearest_wire) |idx| {
        app.selection.wires.set(idx);
        app.status_msg = "Selected wire";
        return;
    }

    app.tool.wire_start = null;
    app.status_msg = "Ready";
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn drawDot(p: dvui.Point.Physical, r: f32, col: dvui.Color) void {
    dvui.Path.stroke(.{
        .points = &.{
            .{ .x = p.x - r, .y = p.y },
            .{ .x = p.x + r, .y = p.y },
        },
    }, .{ .thickness = r * 2.0, .color = col });
}

fn ensureSelectionSizes(app: *AppState, sch: *CT.Schematic) void {
    const alloc = app.allocator();
    app.selection.instances.resize(alloc, sch.instances.items.len, false) catch {};
    app.selection.wires.resize(alloc, sch.wires.items.len, false) catch {};
}

fn nearestInstance(sch: *CT.Schematic, mp: dvui.Point.Physical, vp: Viewport, tol: f32) ?usize {
    var best: ?usize = null;
    var best_d2: f32 = tol * tol;
    for (sch.instances.items, 0..) |inst, i| {
        const p = w2p(inst.pos, vp);
        const dx = p.x - mp.x;
        const dy = p.y - mp.y;
        const d2 = dx * dx + dy * dy;
        if (d2 <= best_d2) {
            best = i;
            best_d2 = d2;
        }
    }
    return best;
}

fn nearestWire(sch: *CT.Schematic, mp: dvui.Point.Physical, vp: Viewport, tol: f32) ?usize {
    var best: ?usize = null;
    var best_d2: f32 = tol * tol;
    for (sch.wires.items, 0..) |w, i| {
        const a = w2p(w.start, vp);
        const b = w2p(w.end, vp);
        const d2 = pointSegmentDistance2(mp, a, b);
        if (d2 <= best_d2) {
            best = i;
            best_d2 = d2;
        }
    }
    return best;
}

fn pointSegmentDistance2(p: dvui.Point.Physical, a: dvui.Point.Physical, b: dvui.Point.Physical) f32 {
    const vx = b.x - a.x;
    const vy = b.y - a.y;
    const wx = p.x - a.x;
    const wy = p.y - a.y;
    const len2 = vx * vx + vy * vy;
    if (len2 <= 0.0001) return wx * wx + wy * wy;
    var t = (wx * vx + wy * vy) / len2;
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    const cx = a.x + t * vx;
    const cy = a.y + t * vy;
    const dx = p.x - cx;
    const dy = p.y - cy;
    return dx * dx + dy * dy;
}

inline fn w2p(pt: CT.Point, vp: Viewport) dvui.Point.Physical {
    return .{
        .x = vp.cx + (@as(f32, @floatFromInt(pt.x)) - vp.pan[0]) * vp.scale,
        .y = vp.cy + (@as(f32, @floatFromInt(pt.y)) - vp.pan[1]) * vp.scale,
    };
}

fn p2w(pt: dvui.Point.Physical, vp: Viewport) CT.Point {
    return .{
        .x = @as(i32, @intFromFloat(@round(((pt.x - vp.cx) / vp.scale) + vp.pan[0]))),
        .y = @as(i32, @intFromFloat(@round(((pt.y - vp.cy) / vp.scale) + vp.pan[1]))),
    };
}
