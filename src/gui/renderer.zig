//! Renderer — schematic/symbol canvas drawing and input handling.

const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
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
const LABEL_ZOOM_THRESHOLD: f32 = 0.3;

// ── Theme-derived palette ─────────────────────────────────────────────────────

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
    drag_rect: dvui.Color,
    crosshair: dvui.Color,
    net_label: dvui.Color,

    pub fn fromTheme(t: dvui.Theme) Palette {
        const focus = t.focus;
        const hl = t.highlight.fill orelse t.focus;
        const ctrl = t.control.fill orelse t.fill;
        const win_bg = t.window.fill orelse t.fill;

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

        const withAlpha = struct {
            fn f(c: dvui.Color, a: u8) dvui.Color {
                return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
            }
        }.f;

        const canvas_bg = if (t.dark) scale(win_bg, 180) else scale(win_bg, 240);
        const grid_dot = withAlpha(scale(t.border, if (t.dark) 140 else 170), if (t.dark) 200 else 180);
        const wire = if (t.dark)
            blend(focus, .{ .r = 200, .g = 235, .b = 255, .a = 255 }, 60)
        else
            blend(focus, .{ .r = 0, .g = 40, .b = 100, .a = 255 }, 30);
        const wire_sel = if (t.dark)
            blend(hl, .{ .r = 255, .g = 180, .b = 60, .a = 255 }, 100)
        else
            blend(hl, .{ .r = 180, .g = 80, .b = 0, .a = 255 }, 80);
        const wire_endpoint = blend(focus, .{ .r = 60, .g = 255, .b = 140, .a = 255 }, 80);
        const inst_body = blend(ctrl, focus, 80);
        const inst_sel = wire_sel;
        const inst_pin = blend(t.text, .{ .r = 255, .g = 230, .b = 60, .a = 255 }, 90);
        const symbol_line = scale(t.text, 215);
        const symbol_pin = blend(focus, .{ .r = 255, .g = 220, .b = 60, .a = 255 }, 100);
        const wire_preview = withAlpha(blend(hl, .{ .r = 80, .g = 255, .b = 100, .a = 255 }, 80), 180);
        const origin = withAlpha(t.border, if (t.dark) 190 else 170);
        const drag_rect = withAlpha(hl, 80);
        const crosshair = withAlpha(t.border, 120);
        const net_label = blend(focus, .{ .r = 80, .g = 220, .b = 160, .a = 255 }, 80);

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
            .drag_rect = drag_rect,
            .crosshair = crosshair,
            .net_label = net_label,
        };
    }
};

// ── Module-local state ────────────────────────────────────────────────────────

pub const State = struct {
    pan_dragging:       bool                                     = false,
    pan_last:           dvui.Point.Physical                      = .{ .x = 0, .y = 0 },
    drag_start:         ?dvui.Point.Physical                     = null,
    drag_current:       dvui.Point.Physical                      = .{ .x = 0, .y = 0 },
    move_anchor:        ?CT.Point                                = null,
    cursor_pos:         dvui.Point.Physical                      = .{ .x = 0, .y = 0 },
    symbol_cache:       std.StringHashMapUnmanaged(CT.Symbol)    = .{},
    symbol_cache_arena: ?std.heap.ArenaAllocator                 = null,
};

pub var state: State = .{};

fn getSymbolCacheAllocator() std.mem.Allocator {
    if (state.symbol_cache_arena == null) {
        state.symbol_cache_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
    return state.symbol_cache_arena.?.allocator();
}

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

    // Phase 5B: track canvas size for zoom-fit
    app.canvas_w = rs.r.w / rs.s;
    app.canvas_h = rs.r.h / rs.s;

    const viewport = Viewport{
        .cx = rs.r.x + rs.r.w / 2.0,
        .cy = rs.r.y + rs.r.h / 2.0,
        .scale = app.view.zoom * rs.s,
        .pan = app.view.pan,
        .bounds = rs.r,
    };

    handleCanvasInput(app, wd, viewport);
    drawGrid(app, pal, viewport);
    drawOriginCross(pal, viewport);

    if (app.active()) |fio| {
        // Enforce view_mode based on file type — .chn_sym is symbol-only,
        // .chn_tb is schematic-only; only plain .chn allows free switching.
        const locked_mode: ?@import("../state.zig").GuiViewMode = switch (fio.fileType()) {
            .chn_sym => .symbol,
            .chn_tb  => .schematic,
            else     => null,
        };
        const effective_mode = locked_mode orelse app.gui.view_mode;

        switch (effective_mode) {
            .schematic => drawSchematic(app, pal, fio.schematic(), viewport),
            .symbol    => if (fio.symbol()) |sym| drawSymbol(pal, sym, viewport),
        }
    }

    drawWirePreview(app, pal, viewport);

    // Phase 5F: drag-select rectangle
    if (state.drag_start) |ds| {
        const x0 = @min(ds.x, state.drag_current.x);
        const y0 = @min(ds.y, state.drag_current.y);
        const x1 = @max(ds.x, state.drag_current.x);
        const y1 = @max(ds.y, state.drag_current.y);
        dvui.Path.stroke(.{
            .points = &.{
                .{ .x = x0, .y = y0 },
                .{ .x = x1, .y = y0 },
                .{ .x = x1, .y = y1 },
                .{ .x = x0, .y = y1 },
                .{ .x = x0, .y = y0 },
            },
        }, .{ .thickness = 1.2, .color = pal.drag_rect });
    }

    // Phase 5J: crosshair
    if (app.cmd_flags.crosshair) {
        const mx = state.cursor_pos.x;
        const my = state.cursor_pos.y;
        dvui.Path.stroke(.{
            .points = &.{ .{ .x = vp_bounds_x(viewport), .y = my }, .{ .x = vp_bounds_x(viewport) + vp_bounds_w(viewport), .y = my } },
        }, .{ .thickness = 1.0, .color = pal.crosshair });
        dvui.Path.stroke(.{
            .points = &.{ .{ .x = mx, .y = vp_bounds_y(viewport) }, .{ .x = mx, .y = vp_bounds_y(viewport) + vp_bounds_h(viewport) } },
        }, .{ .thickness = 1.0, .color = pal.crosshair });
    }

    drawInfoOverlay(app, viewport);
}

fn vp_bounds_x(vp: Viewport) f32 { return vp.bounds.x; }
fn vp_bounds_y(vp: Viewport) f32 { return vp.bounds.y; }
fn vp_bounds_w(vp: Viewport) f32 { return vp.bounds.w; }
fn vp_bounds_h(vp: Viewport) f32 { return vp.bounds.h; }

// ── Viewport ──────────────────────────────────────────────────────────────────

const Viewport = struct {
    cx: f32,
    cy: f32,
    scale: f32,
    pan: [2]f32,
    bounds: dvui.Rect.Physical,
};

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
        const highlighted = i < app.highlighted_nets.bit_length and app.highlighted_nets.isSet(i);
        const col = if (selected) pal.wire_sel else if (highlighted) pal.net_label else pal.wire;
        const lw = if (selected) wire_w_sel else wire_w;

        const a = w2p(wire.start, vp);
        const b = w2p(wire.end, vp);
        dvui.Path.stroke(.{
            .points = &.{ a, b },
        }, .{ .thickness = lw, .color = col });

        drawDot(a, WIRE_ENDPOINT_RADIUS, pal.wire_endpoint);
        drawDot(b, WIRE_ENDPOINT_RADIUS, pal.wire_endpoint);

        // Phase 5D: net label at wire midpoint
        if (wire.net_name) |net| {
            if (net.len > 0 and vp.scale > LABEL_ZOOM_THRESHOLD) {
                if (app.cmd_flags.show_netlist or net.len > 0) {
                    const mid_x = (a.x + b.x) / 2.0;
                    const mid_y = (a.y + b.y) / 2.0;
                    const net_w = @as(f32, @floatFromInt(net.len)) * 7.0 + 4.0;
                    drawDot(.{ .x = mid_x, .y = mid_y }, 2.0, pal.net_label);
                    dvui.labelNoFmt(@src(), net, .{}, .{
                        .rect = .{ .x = mid_x - net_w / 2.0, .y = mid_y - 16.0, .w = net_w, .h = 14.0 },
                        .color_text = pal.net_label,
                        .gravity_x = 0.5,
                        .id_extra = i *% 257 +% 0xBEEF,
                    });
                }
            }
        }
    }
}

fn drawInstances(app: *AppState, pal: Palette, sch: *CT.Schematic, vp: Viewport) void {
    for (sch.instances.items, 0..) |inst, i| {
        const selected = i < app.selection.instances.bit_length and app.selection.instances.isSet(i);
        drawInstance(app, pal, inst, selected, vp);
    }
}

fn drawInstance(app: *AppState, pal: Palette, inst: CT.Instance, selected: bool, vp: Viewport) void {
    const p = w2p(inst.pos, vp);
    const col_body = if (selected) pal.inst_sel else pal.inst_body;
    const col_pin = if (selected) pal.wire_sel else pal.inst_pin;

    // Phase 5E: try to load and draw real symbol geometry
    if (lookupOrLoadSymbol(inst.symbol)) |sym| {
        // Draw symbol shapes transformed by instance rotation/flip
        for (sym.shapes.items) |shape| {
            switch (shape.tag) {
                .line => {
                    const s = shape.data.line;
                    const a = w2pXform(s.start, inst.pos, inst.xform, vp);
                    const b = w2pXform(s.end, inst.pos, inst.xform, vp);
                    dvui.Path.stroke(.{
                        .points = &.{ a, b },
                    }, .{ .thickness = 1.4, .color = if (selected) pal.inst_sel else pal.symbol_line });
                },
                .rect => {
                    const r = shape.data.rect;
                    const lo = w2pXform(r.min, inst.pos, inst.xform, vp);
                    const hi = w2pXform(r.max, inst.pos, inst.xform, vp);
                    // Need all four corners since rotation may swap them
                    const c0 = w2pXform(.{ .x = r.min.x, .y = r.min.y }, inst.pos, inst.xform, vp);
                    const c1 = w2pXform(.{ .x = r.max.x, .y = r.min.y }, inst.pos, inst.xform, vp);
                    const c2 = w2pXform(.{ .x = r.max.x, .y = r.max.y }, inst.pos, inst.xform, vp);
                    const c3 = w2pXform(.{ .x = r.min.x, .y = r.max.y }, inst.pos, inst.xform, vp);
                    _ = lo;
                    _ = hi;
                    dvui.Path.stroke(.{
                        .points = &.{ c0, c1, c2, c3, c0 },
                    }, .{ .thickness = 1.4, .color = if (selected) pal.inst_sel else pal.symbol_line });
                },
                else => {},
            }
        }
        // Draw pin stubs
        for (sym.pins.items) |pin| {
            const pp = w2pXform(pin.pos, inst.pos, inst.xform, vp);
            const arm: f32 = @max(3.5, 5.0 * @min(vp.scale, 2.0));
            dvui.Path.stroke(.{
                .points = &.{ .{ .x = pp.x - arm, .y = pp.y }, .{ .x = pp.x + arm, .y = pp.y } },
            }, .{ .thickness = 2.0, .color = if (selected) pal.wire_sel else pal.symbol_pin });
            dvui.Path.stroke(.{
                .points = &.{ .{ .x = pp.x, .y = pp.y - arm }, .{ .x = pp.x, .y = pp.y + arm } },
            }, .{ .thickness = 2.0, .color = if (selected) pal.wire_sel else pal.symbol_pin });
            drawDot(pp, 3.0, if (selected) pal.wire_sel else pal.symbol_pin);
        }
    } else {
        // Fallback: placeholder box
        const box_half: f32 = @max(4.0, 6.0 * @min(vp.scale, 2.0));
        const lw: f32 = if (selected) 1.8 else 1.2;
        dvui.Path.stroke(.{
            .points = &.{
                .{ .x = p.x - box_half, .y = p.y - box_half },
                .{ .x = p.x + box_half, .y = p.y - box_half },
                .{ .x = p.x + box_half, .y = p.y + box_half },
                .{ .x = p.x - box_half, .y = p.y + box_half },
                .{ .x = p.x - box_half, .y = p.y - box_half },
            },
        }, .{ .thickness = lw, .color = col_body });

        const pin_arm: f32 = @max(3.0, 4.0 * @min(vp.scale, 2.0));
        dvui.Path.stroke(.{
            .points = &.{ .{ .x = p.x - pin_arm, .y = p.y }, .{ .x = p.x + pin_arm, .y = p.y } },
        }, .{ .thickness = 1.0, .color = col_pin });
        dvui.Path.stroke(.{
            .points = &.{ .{ .x = p.x, .y = p.y - pin_arm }, .{ .x = p.x, .y = p.y + pin_arm } },
        }, .{ .thickness = 1.0, .color = col_pin });
    }

    // Phase 5C: instance labels when zoom is sufficient
    if (vp.scale > LABEL_ZOOM_THRESHOLD) {
        const box_half_label: f32 = @max(4.0, 6.0 * @min(vp.scale, 2.0));

        // Refdes label (e.g. "R1") above the instance
        const refdes_w = @as(f32, @floatFromInt(inst.name.len)) * 7.0 + 4.0;
        const refdes_x = p.x - refdes_w / 2.0;
        const refdes_y = p.y - box_half_label - 16.0;
        dvui.labelNoFmt(@src(), inst.name, .{}, .{
            .rect = .{ .x = refdes_x, .y = refdes_y, .w = refdes_w, .h = 14.0 },
            .color_text = col_body,
            .gravity_x = 0.5,
            .id_extra = @as(usize, @bitCast(@as(isize, inst.pos.x))) *% 65537 +% @as(usize, @bitCast(@as(isize, inst.pos.y))),
        });

        if (app.cmd_flags.text_in_symbols) {
            // Symbol basename (e.g. "resistor") below the instance
            const sym_name = std.fs.path.stem(inst.symbol);
            const sym_w = @as(f32, @floatFromInt(sym_name.len)) * 7.0 + 4.0;
            const sym_x = p.x - sym_w / 2.0;
            const sym_y = p.y + box_half_label + 2.0;
            dvui.labelNoFmt(@src(), sym_name, .{}, .{
                .rect = .{ .x = sym_x, .y = sym_y, .w = sym_w, .h = 14.0 },
                .color_text = col_pin,
                .gravity_x = 0.5,
                .id_extra = @as(usize, @bitCast(@as(isize, inst.pos.x))) *% 131071 +% @as(usize, @bitCast(@as(isize, inst.pos.y))),
            });
        }
    }
}

/// Look up a symbol in the cache, or parse the .chn_sym file on cache miss.
/// Returns null if the file cannot be read or parsed.
fn lookupOrLoadSymbol(sym_path: []const u8) ?*CT.Symbol {
    // Only handle .chn_sym files
    if (!std.mem.endsWith(u8, sym_path, ".chn_sym")) return null;

    if (state.symbol_cache.getPtr(sym_path)) |cached| return cached;

    // Cache miss — try to read and parse the .chn_sym file
    const cache_alloc = getSymbolCacheAllocator();

    const data = std.fs.cwd().readFileAlloc(cache_alloc, sym_path, 1024 * 1024 * 2) catch return null;
    defer cache_alloc.free(data);

    var parsed = core.Schemify.readFile(data, cache_alloc, null);
    defer parsed.deinit();

    // Convert Schemify DOD format → CT.Symbol
    var sym: CT.Symbol = .{};

    // Convert lines → Shape.line
    const line_slice = parsed.lines.slice();
    for (0..parsed.lines.len) |i| {
        sym.shapes.append(cache_alloc, .{
            .tag = .line,
            .data = .{ .line = .{
                .start = .{ .x = line_slice.items(.x0)[i], .y = line_slice.items(.y0)[i] },
                .end = .{ .x = line_slice.items(.x1)[i], .y = line_slice.items(.y1)[i] },
            } },
        }) catch continue;
    }

    // Convert rects → Shape.rect
    const rect_slice = parsed.rects.slice();
    for (0..parsed.rects.len) |i| {
        sym.shapes.append(cache_alloc, .{
            .tag = .rect,
            .data = .{ .rect = .{
                .min = .{ .x = rect_slice.items(.x0)[i], .y = rect_slice.items(.y0)[i] },
                .max = .{ .x = rect_slice.items(.x1)[i], .y = rect_slice.items(.y1)[i] },
            } },
        }) catch continue;
    }

    // Convert pins → SymbolPin
    const pin_slice = parsed.pins.slice();
    for (0..parsed.pins.len) |i| {
        sym.pins.append(cache_alloc, .{
            .pos = .{ .x = pin_slice.items(.x)[i], .y = pin_slice.items(.y)[i] },
        }) catch continue;
    }

    // Dupe the key for the cache
    const key = cache_alloc.dupe(u8, sym_path) catch return null;
    state.symbol_cache.put(cache_alloc, key, sym) catch return null;

    return state.symbol_cache.getPtr(sym_path);
}

/// Apply rotation/flip transform to a local-coordinate point, offset by instance position,
/// then convert to physical screen coordinates.
fn w2pXform(local: CT.Point, origin: CT.Point, xform: CT.Transform, vp: Viewport) dvui.Point.Physical {
    var lx: i32 = local.x;
    const ly: i32 = local.y;

    // Apply flip (horizontal mirror) first
    if (xform.flip) {
        lx = -lx;
    }

    // Apply rotation (CW quarter-turns)
    var rx: i32 = lx;
    var ry: i32 = ly;
    switch (xform.rot) {
        0 => {},                          // identity
        1 => { rx = -ly; ry = lx; },     // 90 CW
        2 => { rx = -lx; ry = -ly; },    // 180
        3 => { rx = ly; ry = -lx; },     // 270 CW
    }

    return w2p(.{ .x = origin.x + rx, .y = origin.y + ry }, vp);
}

// ── Move ghost (Phase 5G) ─────────────────────────────────────────────────────

fn drawMoveGhost(app: *AppState, pal: Palette, sch: *CT.Schematic, vp: Viewport) void {
    const anchor = state.move_anchor orelse return;
    const cur_w = p2w(state.cursor_pos, vp, app.tool.snap_size);
    const dx = cur_w.x - anchor.x;
    const dy = cur_w.y - anchor.y;

    const ghost_col = dvui.Color{ .r = pal.inst_sel.r, .g = pal.inst_sel.g, .b = pal.inst_sel.b, .a = 120 };

    for (sch.instances.items, 0..) |inst, i| {
        if (i >= app.selection.instances.bit_length or !app.selection.instances.isSet(i)) continue;
        const gp = w2p(.{ .x = inst.pos.x + dx, .y = inst.pos.y + dy }, vp);
        const half: f32 = @max(4.0, 6.0 * @min(vp.scale, 2.0));
        dvui.Path.stroke(.{
            .points = &.{
                .{ .x = gp.x - half, .y = gp.y - half },
                .{ .x = gp.x + half, .y = gp.y - half },
                .{ .x = gp.x + half, .y = gp.y + half },
                .{ .x = gp.x - half, .y = gp.y + half },
                .{ .x = gp.x - half, .y = gp.y - half },
            },
        }, .{ .thickness = 1.2, .color = ghost_col });
    }
    for (sch.wires.items, 0..) |wire, i| {
        if (i >= app.selection.wires.bit_length or !app.selection.wires.isSet(i)) continue;
        const ga = w2p(.{ .x = wire.start.x + dx, .y = wire.start.y + dy }, vp);
        const gb = w2p(.{ .x = wire.end.x + dx, .y = wire.end.y + dy }, vp);
        dvui.Path.stroke(.{ .points = &.{ ga, gb } }, .{ .thickness = 1.5, .color = ghost_col });
    }
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

    // Draw rubber-band line to cursor when in wire mode
    if (app.tool.active == .wire) {
        dvui.Path.stroke(.{
            .points = &.{ start, state.cursor_pos },
        }, .{ .thickness = 1.2, .color = pal.wire_preview });
    }
}

// ── Info overlay (Phase 5K) ───────────────────────────────────────────────────

fn drawInfoOverlay(app: *AppState, vp: Viewport) void {
    // Draw tool badge + cursor coords + zoom + snap in bottom-right corner
    const tool_col: dvui.Color = switch (app.tool.active) {
        .select => .{ .r = 100, .g = 120, .b = 200, .a = 200 },
        .wire => .{ .r = 80, .g = 200, .b = 100, .a = 200 },
        .move => .{ .r = 200, .g = 170, .b = 80, .a = 200 },
        .pan => .{ .r = 120, .g = 200, .b = 210, .a = 200 },
        .line, .rect, .polygon, .arc, .circle, .text => .{ .r = 210, .g = 110, .b = 170, .a = 200 },
    };

    // Cursor world position
    const snap: f32 = switch (app.tool.active) {
        .wire, .line, .rect, .polygon, .arc, .circle, .text, .move => app.tool.snap_size,
        .select, .pan => 1.0,
    };
    const world = p2w(state.cursor_pos, vp, snap);

    // Overlay dimensions
    const overlay_w: f32 = 220.0;
    const overlay_h: f32 = 56.0;
    const margin: f32 = 6.0;
    const ox = vp.bounds.x + vp.bounds.w - overlay_w - margin;
    const oy = vp.bounds.y + vp.bounds.h - overlay_h - margin;

    // Background bar with tool colour
    const bar_h: f32 = 16.0;
    dvui.Path.stroke(.{
        .points = &.{
            .{ .x = ox, .y = oy },
            .{ .x = ox + overlay_w, .y = oy },
            .{ .x = ox + overlay_w, .y = oy + bar_h },
            .{ .x = ox, .y = oy + bar_h },
            .{ .x = ox, .y = oy },
        },
    }, .{ .thickness = bar_h, .color = tool_col });

    // Tool name badge
    dvui.labelNoFmt(@src(), app.tool.label(), .{}, .{
        .rect = .{ .x = ox + 4.0, .y = oy, .w = overlay_w - 8.0, .h = bar_h },
        .color_text = .{ .r = 255, .g = 255, .b = 255, .a = 240 },
        .id_extra = 0xF001,
    });

    // Cursor world coords: (x, y)
    var coord_buf: [48]u8 = undefined;
    const coord_text = std.fmt.bufPrint(&coord_buf, "({d}, {d})", .{ world.x, world.y }) catch "(??,??)";
    dvui.labelNoFmt(@src(), coord_text, .{}, .{
        .rect = .{ .x = ox + 4.0, .y = oy + bar_h + 2.0, .w = overlay_w - 8.0, .h = 14.0 },
        .id_extra = 0xF002,
    });

    // Zoom % and snap size
    var info_buf: [48]u8 = undefined;
    const zoom_pct: i32 = @intFromFloat(@round(app.view.zoom * 100.0));
    const snap_int: i32 = @intFromFloat(app.tool.snap_size);
    const info_text = std.fmt.bufPrint(&info_buf, "Zoom: {d}%  Snap: {d}", .{ zoom_pct, snap_int }) catch "Zoom: ?";
    dvui.labelNoFmt(@src(), info_text, .{}, .{
        .rect = .{ .x = ox + 4.0, .y = oy + bar_h + 16.0, .w = overlay_w - 8.0, .h = 14.0 },
        .id_extra = 0xF003,
    });
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
                    .right => {
                        // Phase 5I: right-click context menu
                        e.handled = true;
                        const inst_idx = nearestInstance(sch, me.p, vp, INST_HIT_TOLERANCE);
                        const wire_idx = nearestWire(sch, me.p, vp, WIRE_HIT_TOLERANCE);
                        const ctx = @import("context_menu.zig");
                        ctx.state.inst_idx = if (inst_idx) |idx| @intCast(idx) else -1;
                        ctx.state.wire_idx = if (wire_idx) |idx| @intCast(idx) else -1;
                        ctx.state.open = true;
                    },
                    .middle => {
                        e.handled = true;
                        state.pan_dragging = true;
                        state.pan_last = me.p;
                    },
                    else => {},
                }
            },
            .release => {
                if (me.button == .middle) {
                    state.pan_dragging = false;
                    e.handled = true;
                }
                if (me.button == .left) {
                    // Phase 5F: complete drag-select
                    if (state.drag_start) |ds| {
                        e.handled = true;
                        completeDragSelect(app, sch, ds, me.p, vp);
                        state.drag_start = null;
                    }
                    // Phase 5G: complete interactive move
                    if (state.move_anchor != null and app.tool.active == .move) {
                        e.handled = true;
                        completeMoveInteractive(app, sch, me.p, vp);
                        state.move_anchor = null;
                    }
                }
            },
            .motion => {
                state.cursor_pos = me.p;
                if (state.pan_dragging) {
                    e.handled = true;
                    const dx = me.p.x - state.pan_last.x;
                    const dy = me.p.y - state.pan_last.y;
                    app.view.pan[0] -= dx / vp.scale;
                    app.view.pan[1] -= dy / vp.scale;
                    state.pan_last = me.p;
                }
                if (state.drag_start != null) {
                    e.handled = true;
                    state.drag_current = me.p;
                }
            },
            else => {},
        }
    }

    // Draw move ghost if move tool is active with anchor
    if (state.move_anchor != null and app.tool.active == .move) {
        drawMoveGhost(app, Palette.fromTheme(dvui.themeGet()), sch, vp);
    }
}

fn handleLeftClick(app: *AppState, sch: *CT.Schematic, mp: dvui.Point.Physical, vp: Viewport) void {
    const snap: f32 = switch (app.tool.active) {
        .wire, .line, .rect, .polygon, .arc, .circle, .text, .move => app.tool.snap_size,
        .select, .pan => 1.0,
    };
    const world_pt = p2w(mp, vp, snap);

    // Wire tool
    if (app.tool.active == .wire) {
        if (app.tool.wire_start) |start| {
            app.queue.push(.{ .add_wire = .{
                .x0 = @floatFromInt(start[0]),
                .y0 = @floatFromInt(start[1]),
                .x1 = @floatFromInt(world_pt.x),
                .y1 = @floatFromInt(world_pt.y),
            } }) catch {};
            app.tool.wire_start = .{ world_pt.x, world_pt.y };
            app.status_msg = "Wire: click next point, Esc to finish";
        } else {
            app.tool.wire_start = .{ world_pt.x, world_pt.y };
            app.status_msg = "Wire started — click to place next point";
        }
        return;
    }

    // Phase 5H: draw tool point accumulation
    switch (app.tool.active) {
        .line => {
            if (app.tool.draw_point_count == 0) {
                app.tool.draw_points[0] = world_pt;
                app.tool.draw_point_count = 1;
                app.status_msg = "Line: click end point";
            } else {
                const start = app.tool.draw_points[0];
                app.queue.push(.{ .add_wire = .{
                    .x0 = @floatFromInt(start.x),
                    .y0 = @floatFromInt(start.y),
                    .x1 = @floatFromInt(world_pt.x),
                    .y1 = @floatFromInt(world_pt.y),
                } }) catch {};
                app.tool.draw_point_count = 0;
                app.status_msg = "Line placed";
            }
            return;
        },
        .rect => {
            if (app.tool.draw_point_count == 0) {
                app.tool.draw_points[0] = world_pt;
                app.tool.draw_point_count = 1;
                app.status_msg = "Rect: click second corner";
            } else {
                // Commit as 4 wires forming a rectangle
                const p0 = app.tool.draw_points[0];
                const p1 = world_pt;
                app.queue.push(.{ .add_wire = .{ .x0 = @floatFromInt(p0.x), .y0 = @floatFromInt(p0.y), .x1 = @floatFromInt(p1.x), .y1 = @floatFromInt(p0.y) } }) catch {};
                app.queue.push(.{ .add_wire = .{ .x0 = @floatFromInt(p1.x), .y0 = @floatFromInt(p0.y), .x1 = @floatFromInt(p1.x), .y1 = @floatFromInt(p1.y) } }) catch {};
                app.queue.push(.{ .add_wire = .{ .x0 = @floatFromInt(p1.x), .y0 = @floatFromInt(p1.y), .x1 = @floatFromInt(p0.x), .y1 = @floatFromInt(p1.y) } }) catch {};
                app.queue.push(.{ .add_wire = .{ .x0 = @floatFromInt(p0.x), .y0 = @floatFromInt(p1.y), .x1 = @floatFromInt(p0.x), .y1 = @floatFromInt(p0.y) } }) catch {};
                app.tool.draw_point_count = 0;
                app.status_msg = "Rect placed";
            }
            return;
        },
        .polygon => {
            const n = app.tool.draw_point_count;
            if (n < 16) {
                app.tool.draw_points[n] = world_pt;
                app.tool.draw_point_count = n + 1;
                app.status_msg = "Polygon: click next vertex, double-click to close";
            }
            return;
        },
        .text => {
            // Mark text anchor point; GUI overlay handles actual text entry
            app.tool.draw_points[0] = world_pt;
            app.tool.draw_point_count = 1;
            app.status_msg = "Text anchor set — type in command bar then :text <msg>";
            return;
        },
        .move => {
            // Phase 5G: start or use move anchor
            if (state.move_anchor == null and !app.selection.isEmpty()) {
                state.move_anchor = world_pt;
                app.status_msg = "Move: click destination";
            }
            return;
        },
        else => {},
    }

    // Select mode: click to select nearest object or start drag
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

    // Start drag-select
    state.drag_start = mp;
    state.drag_current = mp;
    app.tool.wire_start = null;
    app.status_msg = "Ready";
}

// Phase 5F: complete drag-select
fn completeDragSelect(app: *AppState, sch: *CT.Schematic, start: dvui.Point.Physical, end: dvui.Point.Physical, vp: Viewport) void {
    const x0 = @min(start.x, end.x);
    const y0 = @min(start.y, end.y);
    const x1 = @max(start.x, end.x);
    const y1 = @max(start.y, end.y);

    if (x1 - x0 < 3.0 and y1 - y0 < 3.0) return; // too small — treat as click

    const alloc = app.allocator();
    app.selection.clear();

    const wp00 = p2w(.{ .x = x0, .y = y0 }, vp, 1.0);
    const wp11 = p2w(.{ .x = x1, .y = y1 }, vp, 1.0);

    for (sch.instances.items, 0..) |inst, i| {
        if (inst.pos.x >= wp00.x and inst.pos.x <= wp11.x and
            inst.pos.y >= wp00.y and inst.pos.y <= wp11.y)
        {
            app.selection.instances.resize(alloc, i + 1, false) catch continue;
            app.selection.instances.set(i);
        }
    }
    for (sch.wires.items, 0..) |wire, i| {
        const in_rect = wire.start.x >= wp00.x and wire.start.x <= wp11.x and
            wire.start.y >= wp00.y and wire.start.y <= wp11.y and
            wire.end.x >= wp00.x and wire.end.x <= wp11.x and
            wire.end.y >= wp00.y and wire.end.y <= wp11.y;
        if (in_rect) {
            app.selection.wires.resize(alloc, i + 1, false) catch continue;
            app.selection.wires.set(i);
        }
    }
    app.status_msg = "Drag-select complete";
}

// Phase 5G: complete interactive move
fn completeMoveInteractive(app: *AppState, sch: *CT.Schematic, end_px: dvui.Point.Physical, vp: Viewport) void {
    const anchor = state.move_anchor orelse return;
    const end_w = p2w(end_px, vp, app.tool.snap_size);
    const dx = end_w.x - anchor.x;
    const dy = end_w.y - anchor.y;
    if (dx == 0 and dy == 0) return;

    for (sch.instances.items, 0..) |*inst, i| {
        if (i >= app.selection.instances.bit_length or !app.selection.instances.isSet(i)) continue;
        inst.pos.x += dx;
        inst.pos.y += dy;
    }
    for (sch.wires.items, 0..) |*wire, i| {
        if (i >= app.selection.wires.bit_length or !app.selection.wires.isSet(i)) continue;
        wire.start.x += dx;
        wire.start.y += dy;
        wire.end.x += dx;
        wire.end.y += dy;
    }
    if (app.active()) |fio| fio.dirty = true;
    app.tool.active = .select;
    app.status_msg = "Move complete";
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

fn p2w(pt: dvui.Point.Physical, vp: Viewport, snap: f32) CT.Point {
    const raw_x = (pt.x - vp.cx) / vp.scale + vp.pan[0];
    const raw_y = (pt.y - vp.cy) / vp.scale + vp.pan[1];
    return .{
        .x = @intFromFloat(@round(raw_x / snap) * snap),
        .y = @intFromFloat(@round(raw_y / snap) * snap),
    };
}
