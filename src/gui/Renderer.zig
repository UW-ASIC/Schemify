const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme_config");
const st = @import("state");
const core = @import("core");

const Palette = theme.Palette;
const Schemify = core.Schemify;
const DeviceKind = core.DeviceKind;
const primitives = core.primitives;

// ===========================================================================
// Renderer
// ===========================================================================

const Point = [2]i32;
const Vec2 = @Vector(2, f32);
const Color = dvui.Color;

pub const Viewport = struct {
    cx: f32,
    cy: f32,
    scale: f32,
    pan: [2]f32,
    bounds: dvui.Rect.Physical,
};

pub const CanvasEvent = union(enum) {
    none,
    click: Point,
    double_click: Point,
    right_click: struct { pixel: Vec2, world: Point },
};

pub const Renderer = struct {
    zoom: f32 = 1.0,
    pan: [2]f32 = .{ 0, 0 },
    snap_size: f32 = 10.0,
    show_grid: bool = true,
    wire_start: ?Point = null,

    // Internal input state — caller doesn't touch these.
    dragging: bool = false,
    drag_last: Vec2 = .{ 0, 0 },
    space_held: bool = false,
    last_click_time: f64 = 0,
    last_click_pos: Vec2 = .{ 0, 0 },

    pub fn draw(self: *Renderer, app: *st.AppState) CanvasEvent {
        const pal = Palette.fromDvui(dvui.themeGet());

        var canvas = dvui.box(@src(), .{}, .{
            .expand = .both,
            .background = true,
            .color_fill = pal.canvas_bg,
        });
        defer canvas.deinit();

        const wd = canvas.data();
        const rs = wd.contentRectScale();
        const vp = Viewport{
            .cx = rs.r.x + rs.r.w / 2.0,
            .cy = rs.r.y + rs.r.h / 2.0,
            .scale = self.zoom * rs.s,
            .pan = self.pan,
            .bounds = rs.r,
        };

        const event = self.handleInput(wd, vp);

        if (self.show_grid) drawGrid(vp, pal, self.snap_size);
        drawOrigin(vp, pal);

        // Dispatch based on view mode and active document
        if (app.active_idx < app.documents.items.len) {
            const doc = &app.documents.items[app.active_idx];
            const file_type = classifyFile(doc.origin);

            switch (app.gui.view_mode) {
                .schematic => if (file_type != .prim_only) drawSchematic(&doc.sch, app, vp, pal),
                .symbol => if (file_type != .tb_only) {
                    drawSchematic(&doc.sch, app, vp, pal);
                },
            }

            // Wire placement preview overlay
            drawWirePreview(app, vp, pal);
        }

        return event;
    }

    fn handleInput(self: *Renderer, wd: *dvui.WidgetData, vp: Viewport) CanvasEvent {
        var result: CanvasEvent = .none;

        for (dvui.events()) |*ev| {
            if (ev.handled or !dvui.eventMatchSimple(ev, wd)) continue;

            switch (ev.evt) {
                .key => |ke| {
                    if (ke.code == .space) {
                        self.space_held = (ke.action != .up);
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
                                    if (self.space_held) {
                                        self.dragging = true;
                                        self.drag_last = mp;
                                    } else {
                                        result = self.handleClick(mp, vp);
                                    }
                                },
                                .middle => {
                                    ev.handled = true;
                                    self.dragging = true;
                                    self.drag_last = mp;
                                },
                                .right => {
                                    ev.handled = true;
                                    result = .{ .right_click = .{
                                        .pixel = mp,
                                        .world = p2w(mp, vp, self.snap_size),
                                    } };
                                },
                                else => {},
                            }
                        },
                        .release => {
                            if (me.button == .middle or me.button == .left) {
                                if (self.dragging) {
                                    self.dragging = false;
                                    ev.handled = true;
                                }
                            }
                        },
                        .motion => {
                            if (self.dragging) {
                                ev.handled = true;
                                const cur: Vec2 = .{ me.p.x, me.p.y };
                                const delta = cur - self.drag_last;
                                const inv_s: Vec2 = @splat(1.0 / vp.scale);
                                const pan_delta = delta * inv_s;
                                self.pan[0] -= pan_delta[0];
                                self.pan[1] -= pan_delta[1];
                                self.drag_last = cur;
                            }
                        },
                        .wheel_y => |dy| {
                            ev.handled = true;
                            const cursor: Vec2 = .{ me.p.x, me.p.y };
                            const world_before = p2w_raw(cursor, vp);

                            const factor: f32 = if (dy > 0) 1.25 else (1.0 / 1.25);
                            self.zoom = std.math.clamp(self.zoom * factor, 0.01, 50.0);

                            const new_vp = Viewport{
                                .cx = vp.cx,
                                .cy = vp.cy,
                                .scale = vp.scale * factor,
                                .pan = self.pan,
                                .bounds = vp.bounds,
                            };
                            const world_after = p2w_raw(cursor, new_vp);

                            self.pan[0] += world_before[0] - world_after[0];
                            self.pan[1] += world_before[1] - world_after[1];
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        return result;
    }

    fn handleClick(self: *Renderer, mp: Vec2, vp: Viewport) CanvasEvent {
        const now: f64 = @as(f64, @floatFromInt(dvui.frameTimeNS())) / 1_000_000_000.0;
        const dt = now - self.last_click_time;
        const dp = mp - self.last_click_pos;
        const dist = @sqrt(dp[0] * dp[0] + dp[1] * dp[1]);

        const world_pt = p2w(mp, vp, self.snap_size);

        if (dt < 0.4 and dist < 10.0) {
            self.last_click_time = 0;
            return .{ .double_click = world_pt };
        }

        self.last_click_time = now;
        self.last_click_pos = mp;
        return .{ .click = world_pt };
    }
};

// ===========================================================================
// File Classification
// ===========================================================================

const FileType = enum { full, prim_only, tb_only };

fn classifyFile(origin: st.Origin) FileType {
    return switch (origin) {
        .chn_file => |path| {
            if (std.mem.endsWith(u8, path, ".chn_prim")) return .prim_only;
            if (std.mem.endsWith(u8, path, ".chn_testbench") or std.mem.endsWith(u8, path, ".chn_tb")) return .tb_only;
            return .full;
        },
        else => .full,
    };
}

// ===========================================================================
// Schematic Drawing
// ===========================================================================

fn drawSchematic(sch: *const Schemify, app: *st.AppState, vp: Viewport, pal: Palette) void {
    // Clip drawing to canvas viewport
    const prev_clip = dvui.clip(.{ .x = vp.bounds.x, .y = vp.bounds.y, .w = vp.bounds.w, .h = vp.bounds.h });
    defer dvui.clipSet(prev_clip);

    const wire_w: f32 = @max(1.2, 1.8 * vp.scale) * theme.getWireWidth();
    const wire_w_sel: f32 = @max(1.8, 2.8 * vp.scale) * theme.getWireWidth();

    // ── Wires ────────────────────────────────────────────────────────────── //
    if (sch.wires.len > 0) {
        const wx0 = sch.wires.items(.x0);
        const wy0 = sch.wires.items(.y0);
        const wx1 = sch.wires.items(.x1);
        const wy1 = sch.wires.items(.y1);

        for (0..sch.wires.len) |i| {
            const selected = i < app.selection.wires.bit_length and app.selection.wires.isSet(i);
            const a = w2p(.{ wx0[i], wy0[i] }, vp);
            const b = w2p(.{ wx1[i], wy1[i] }, vp);
            const col = if (selected) pal.wire_sel else pal.wire;
            const w = if (selected) wire_w_sel else wire_w;
            strokeLine(a[0], a[1], b[0], b[1], w, col);

            // Endpoint dots
            strokeDot(a, wire_endpoint_radius, pal.wire_endpoint);
            strokeDot(b, wire_endpoint_radius, pal.wire_endpoint);
        }
    }

    // ── Geometry: Lines ──────────────────────────────────────────────────── //
    if (sch.lines.len > 0) {
        const lx0 = sch.lines.items(.x0);
        const ly0 = sch.lines.items(.y0);
        const lx1 = sch.lines.items(.x1);
        const ly1 = sch.lines.items(.y1);
        for (0..sch.lines.len) |i| {
            const a = w2p(.{ lx0[i], ly0[i] }, vp);
            const b = w2p(.{ lx1[i], ly1[i] }, vp);
            strokeLine(a[0], a[1], b[0], b[1], 1.0, pal.symbol_line);
        }
    }

    // ── Geometry: Rects ─────────────────────────────────────────────────── //
    if (sch.rects.len > 0) {
        const rx0 = sch.rects.items(.x0);
        const ry0 = sch.rects.items(.y0);
        const rx1 = sch.rects.items(.x1);
        const ry1 = sch.rects.items(.y1);
        for (0..sch.rects.len) |i| {
            const tl = w2p(.{ rx0[i], ry0[i] }, vp);
            const br = w2p(.{ rx1[i], ry1[i] }, vp);
            strokeRectOutline(tl, br, 1.0, pal.symbol_line);
        }
    }

    // ── Geometry: Circles ───────────────────────────────────────────────── //
    if (sch.circles.len > 0) {
        const ccx = sch.circles.items(.cx);
        const ccy = sch.circles.items(.cy);
        const crad = sch.circles.items(.radius);
        for (0..sch.circles.len) |i| {
            const center = w2p(.{ ccx[i], ccy[i] }, vp);
            const r: f32 = @as(f32, @floatFromInt(crad[i])) * vp.scale;
            strokeCircle(center, r, 1.0, pal.symbol_line);
        }
    }

    // ── Geometry: Arcs ──────────────────────────────────────────────────── //
    if (sch.arcs.len > 0) {
        const acx = sch.arcs.items(.cx);
        const acy = sch.arcs.items(.cy);
        const arad = sch.arcs.items(.radius);
        const astart = sch.arcs.items(.start_angle);
        const asweep = sch.arcs.items(.sweep_angle);
        for (0..sch.arcs.len) |i| {
            const center = w2p(.{ acx[i], acy[i] }, vp);
            const r: f32 = @as(f32, @floatFromInt(arad[i])) * vp.scale;
            strokeArc(center, r, astart[i], asweep[i], 1.0, pal.symbol_line);
        }
    }

    // ── Instances ────────────────────────────────────────────────────────── //
    if (sch.instances.len > 0) {
        const ix = sch.instances.items(.x);
        const iy = sch.instances.items(.y);
        const irot = sch.instances.items(.rot);
        const iflip = sch.instances.items(.flip);
        const ikind = sch.instances.items(.kind);
        const iname = sch.instances.items(.name);
        const isymbol = sch.instances.items(.symbol);

        for (0..sch.instances.len) |i| {
            const selected = i < app.selection.instances.bit_length and app.selection.instances.isSet(i);
            const color = if (selected) pal.inst_sel else pal.symbol_line;
            const origin = w2p(.{ ix[i], iy[i] }, vp);
            const rot = irot[i];
            const flip = iflip[i];
            const kind = ikind[i];

            const prim = lookupPrim(isymbol[i], kind);

            if (prim) |entry| {
                drawPrimEntry(entry, origin, rot, flip, vp, color);
            } else {
                // Fallback: generic box for unknown devices
                drawGenericBox(origin, rot, flip, vp, color);
            }

            // Pin marker cross at instance origin
            const pin_arm: f32 = @max(2.0, 3.0 * @min(vp.scale, 2.0));
            const pin_color = if (selected) pal.wire_sel else pal.inst_pin;
            strokeLine(origin[0] - pin_arm, origin[1], origin[0] + pin_arm, origin[1], 0.8, pin_color);
            strokeLine(origin[0], origin[1] - pin_arm, origin[0], origin[1] + pin_arm, 0.8, pin_color);

            // Instance name label
            if (vp.scale >= 0.3 and iname[i].len > 0) {
                drawLabel(iname[i], origin[0] + 25.0 * vp.scale, origin[1] - 20.0 * vp.scale, pal.inst_pin, vp, i);
            }
        }
    }

    // ── Net labels on wires ──────────────────────────────────────────────── //
    if (vp.scale >= 0.4 and sch.wires.len > 0) {
        const wx0 = sch.wires.items(.x0);
        const wy0 = sch.wires.items(.y0);
        const wx1 = sch.wires.items(.x1);
        const wy1 = sch.wires.items(.y1);
        const wnn = sch.wires.items(.net_name);

        for (0..sch.wires.len) |i| {
            const net = wnn[i] orelse continue;
            if (net.len == 0) continue;

            const a = w2p(.{ wx0[i], wy0[i] }, vp);
            const b = w2p(.{ wx1[i], wy1[i] }, vp);
            const mid_x = (a[0] + b[0]) * 0.5;
            const mid_y = (a[1] + b[1]) * 0.5;

            drawLabel(net, mid_x - 40.0, mid_y - 16.0, theme.withAlpha(pal.wire, 180), vp, sch.instances.len + i);

            // Zero-length wires (net label markers) get a white dot
            if (wx0[i] == wx1[i] and wy0[i] == wy1[i]) {
                const radius: f32 = @max(3.0, 5.0 * @min(vp.scale, 2.0));
                strokeDot(a, radius, Color{ .r = 255, .g = 255, .b = 255, .a = 255 });
            }
        }
    }

    // ── Texts ────────────────────────────────────────────────────────────── //
    if (vp.scale >= 0.3 and sch.texts.len > 0) {
        const tcontent = sch.texts.items(.content);
        const tx = sch.texts.items(.x);
        const ty = sch.texts.items(.y);
        for (0..sch.texts.len) |i| {
            if (tcontent[i].len == 0) continue;
            const p = w2p(.{ tx[i], ty[i] }, vp);
            drawLabel(tcontent[i], p[0], p[1], pal.symbol_line, vp, sch.instances.len + sch.wires.len + i);
        }
    }
}

// ===========================================================================
// Symbol View Drawing
// ===========================================================================

fn drawSymbolView(sym: *const Schemify, vp: Viewport, pal: Palette) void {
    const prev_clip = dvui.clip(.{ .x = vp.bounds.x, .y = vp.bounds.y, .w = vp.bounds.w, .h = vp.bounds.h });
    defer dvui.clipSet(prev_clip);

    // ── Lines ────────────────────────────────────────────────────────────── //
    if (sym.lines.len > 0) {
        const lx0 = sym.lines.items(.x0);
        const ly0 = sym.lines.items(.y0);
        const lx1 = sym.lines.items(.x1);
        const ly1 = sym.lines.items(.y1);
        for (0..sym.lines.len) |i| {
            const a = w2p(.{ lx0[i], ly0[i] }, vp);
            const b = w2p(.{ lx1[i], ly1[i] }, vp);
            strokeLine(a[0], a[1], b[0], b[1], 1.4, pal.symbol_line);
        }
    }

    // ── Rects ────────────────────────────────────────────────────────────── //
    if (sym.rects.len > 0) {
        const rx0 = sym.rects.items(.x0);
        const ry0 = sym.rects.items(.y0);
        const rx1 = sym.rects.items(.x1);
        const ry1 = sym.rects.items(.y1);
        for (0..sym.rects.len) |i| {
            const tl = w2p(.{ rx0[i], ry0[i] }, vp);
            const br = w2p(.{ rx1[i], ry1[i] }, vp);
            strokeRectOutline(tl, br, 1.4, pal.symbol_line);
        }
    }

    // ── Circles ──────────────────────────────────────────────────────────── //
    if (sym.circles.len > 0) {
        const ccx = sym.circles.items(.cx);
        const ccy = sym.circles.items(.cy);
        const crad = sym.circles.items(.radius);
        for (0..sym.circles.len) |i| {
            const center = w2p(.{ ccx[i], ccy[i] }, vp);
            const r: f32 = @as(f32, @floatFromInt(crad[i])) * vp.scale;
            strokeCircle(center, r, 1.4, pal.symbol_line);
        }
    }

    // ── Arcs ─────────────────────────────────────────────────────────────── //
    if (sym.arcs.len > 0) {
        const acx = sym.arcs.items(.cx);
        const acy = sym.arcs.items(.cy);
        const arad = sym.arcs.items(.radius);
        const astart = sym.arcs.items(.start_angle);
        const asweep = sym.arcs.items(.sweep_angle);
        for (0..sym.arcs.len) |i| {
            const center = w2p(.{ acx[i], acy[i] }, vp);
            const r: f32 = @as(f32, @floatFromInt(arad[i])) * vp.scale;
            strokeArc(center, r, astart[i], asweep[i], 1.4, pal.symbol_line);
        }
    }

    // ── Pins (cross + dot + label) ──────────────────────────────────────── //
    if (sym.pins.len > 0) {
        const px = sym.pins.items(.x);
        const py = sym.pins.items(.y);
        const pname = sym.pins.items(.name);
        const pin_arm: f32 = @max(3.5, 5.0 * @min(vp.scale, 2.0));

        for (0..sym.pins.len) |i| {
            const p = w2p(.{ px[i], py[i] }, vp);
            // Cross
            strokeLine(p[0] - pin_arm, p[1], p[0] + pin_arm, p[1], 2.0, pal.symbol_pin);
            strokeLine(p[0], p[1] - pin_arm, p[0], p[1] + pin_arm, 2.0, pal.symbol_pin);
            // Dot
            strokeDot(p, 3.0, pal.symbol_pin);
            // Pin name label
            if (vp.scale >= 0.4 and pname[i].len > 0) {
                drawLabel(pname[i], p[0] + 8.0, p[1] - 14.0, pal.symbol_pin, vp, i);
            }
        }
    }

    // ── Texts ────────────────────────────────────────────────────────────── //
    if (vp.scale >= 0.3 and sym.texts.len > 0) {
        const tcontent = sym.texts.items(.content);
        const tx = sym.texts.items(.x);
        const ty = sym.texts.items(.y);
        for (0..sym.texts.len) |i| {
            if (tcontent[i].len == 0) continue;
            const p = w2p(.{ tx[i], ty[i] }, vp);
            drawLabel(tcontent[i], p[0], p[1], pal.symbol_line, vp, sym.pins.len + i);
        }
    }
}

// ===========================================================================
// Wire Preview Overlay
// ===========================================================================

fn drawWirePreview(app: *st.AppState, vp: Viewport, pal: Palette) void {
    const ws = app.tool.wire_start orelse return;
    const start = w2p(ws, vp);
    strokeDot(start, wire_preview_dot_radius, pal.wire_preview);
    strokeLine(start[0] - wire_preview_arm, start[1], start[0] + wire_preview_arm, start[1], 1.5, pal.wire_preview);
    strokeLine(start[0], start[1] - wire_preview_arm, start[0], start[1] + wire_preview_arm, 1.5, pal.wire_preview);
}

// ===========================================================================
// Primitives-Based Symbol Lookup
// ===========================================================================

/// Look up a PrimEntry for the given symbol/kind, trying kind-based lookup
/// first, then symbol name resolution. Returns null only for kinds that
/// have no .chn_prim file (e.g. annotation, title, etc.), in which case
/// the caller draws a generic fallback box.
fn lookupPrim(symbol_name: []const u8, kind: DeviceKind) ?*const primitives.PrimEntry {
    // 1. Try kind-to-name mapping (covers all DeviceKind variants including
    //    aliases like nmos4_depl -> nmos4, sqwsource -> vsource, etc.)
    const kind_name = kindToName(kind);
    if (kind_name) |name| {
        if (primitives.findByNameRuntime(name)) |entry| return entry;
    }

    // 2. Fall back to symbol name (strip path prefix and .sym suffix)
    var base = symbol_name;
    if (std.mem.startsWith(u8, base, "devices/"))
        base = base["devices/".len..];
    if (std.mem.endsWith(u8, base, ".sym"))
        base = base[0 .. base.len - ".sym".len];

    // Try direct lookup
    if (primitives.findByNameRuntime(base)) |entry| return entry;

    // Try symbol name aliases
    const alias_map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "nmos", "nmos4" },
        .{ "pmos", "pmos4" },
        .{ "resistors", "resistor" },
        .{ "capacitors", "capacitor" },
        .{ "inductors", "inductor" },
        .{ "diodes", "diode" },
        .{ "ipin", "input_pin" },
        .{ "opin", "output_pin" },
        .{ "iopin", "inout_pin" },
        .{ "vsource_arith", "vsource" },
        .{ "parax_cap", "capacitor" },
    });
    if (alias_map.get(base)) |alias_name| {
        if (primitives.findByNameRuntime(alias_name)) |entry| return entry;
    }

    // Try DeviceKind.fromStr on the symbol name
    const name_kind = DeviceKind.fromStr(base);
    if (name_kind != .unknown) {
        const nk = kindToName(name_kind);
        if (nk) |n| {
            if (primitives.findByNameRuntime(n)) |entry| return entry;
        }
    }

    return null;
}

/// Map a DeviceKind enum variant to the kind_name used in .chn_prim files.
/// Returns null for kinds that have no .chn_prim file (fallback box needed).
fn kindToName(kind: DeviceKind) ?[]const u8 {
    return switch (kind) {
        // 3-terminal MOSFETs have their own .chn_prim — check before isNmos/isPmos
        .nmos3 => "nmos3",
        .pmos3 => "pmos3",
        // 4-terminal and variant NMOS/PMOS all share nmos4/pmos4 drawing
        .nmos4, .nmos4_depl, .nmos_sub, .nmoshv4, .rnmos4 => "nmos4",
        .pmos4, .pmos_sub, .pmoshv4 => "pmos4",
        .resistor, .var_resistor => "resistor",
        .resistor3 => "resistor3",
        .capacitor => "capacitor",
        .inductor => "inductor",
        .diode => "diode",
        .zener => "zener",
        .vsource, .sqwsource => "vsource",
        .isource => "isource",
        .ammeter => "ammeter",
        .behavioral => "behavioral",
        .npn => "npn",
        .pnp => "pnp",
        .njfet => "njfet",
        .pjfet => "pjfet",
        .mesfet => "njfet",
        .vcvs => "vcvs",
        .vccs => "vccs",
        .ccvs => "ccvs",
        .cccs => "cccs",
        .vswitch => "vswitch",
        .iswitch => "iswitch",
        .tline, .tline_lossy => "tline",
        .coupling => "coupling",
        .gnd => "gnd",
        .vdd => "vdd",
        .lab_pin => "lab_pin",
        .input_pin => "input_pin",
        .output_pin => "output_pin",
        .inout_pin => "inout_pin",
        .probe, .probe_diff => "probe",
        // Kinds without .chn_prim files — fallback to generic box
        .annotation, .title, .param, .code, .graph, .launcher,
        .rgb_led, .hdl, .noconn, .subckt, .digital_instance, .generic,
        => null,
        .unknown => null,
    };
}

/// Draw a single PrimEntry's drawing data at the given origin with rotation/flip.
fn drawPrimEntry(entry: *const primitives.PrimEntry, origin: Vec2, rot: u2, flip: bool, vp: Viewport, color: Color) void {
    const s: Vec2 = @splat(vp.scale);

    // Line segments
    for (entry.segs()) |seg| {
        const a = applyRotFlip(@floatFromInt(seg.x0), @floatFromInt(seg.y0), rot, flip);
        const b = applyRotFlip(@floatFromInt(seg.x1), @floatFromInt(seg.y1), rot, flip);
        const pa = origin + Vec2{ a[0], a[1] } * s;
        const pb = origin + Vec2{ b[0], b[1] } * s;
        strokeLine(pa[0], pa[1], pb[0], pb[1], 1.4, color);
    }

    // Circles
    for (entry.drawCircles()) |circ| {
        const c = applyRotFlip(@floatFromInt(circ.cx), @floatFromInt(circ.cy), rot, flip);
        const center = origin + Vec2{ c[0], c[1] } * s;
        const r: f32 = @as(f32, @floatFromInt(circ.r)) * vp.scale;
        strokeCircle(center, r, 1.4, color);
    }

    // Arcs
    for (entry.drawArcs()) |arc| {
        const c = applyRotFlip(@floatFromInt(arc.cx), @floatFromInt(arc.cy), rot, flip);
        const center = origin + Vec2{ c[0], c[1] } * s;
        const r: f32 = @as(f32, @floatFromInt(arc.r)) * vp.scale;
        // Adjust start angle for rotation and flip
        var start_angle: i16 = arc.start;
        const sweep_angle: i16 = arc.sweep;
        if (flip) {
            start_angle = 180 - start_angle - sweep_angle;
        }
        start_angle += @as(i16, @intCast(rot)) * 90;
        strokeArc(center, r, start_angle, sweep_angle, 1.4, color);
    }

    // Rects
    for (entry.drawRects()) |rect| {
        const tl_raw = applyRotFlip(@floatFromInt(rect.x0), @floatFromInt(rect.y0), rot, flip);
        const br_raw = applyRotFlip(@floatFromInt(rect.x1), @floatFromInt(rect.y1), rot, flip);
        const tl = origin + Vec2{ @min(tl_raw[0], br_raw[0]), @min(tl_raw[1], br_raw[1]) } * s;
        const br = origin + Vec2{ @max(tl_raw[0], br_raw[0]), @max(tl_raw[1], br_raw[1]) } * s;
        strokeRectOutline(tl, br, 1.4, color);
    }
}

/// Draw a generic rectangular box for devices without .chn_prim data.
fn drawGenericBox(origin: Vec2, rot: u2, flip: bool, vp: Viewport, color: Color) void {
    const s: Vec2 = @splat(vp.scale);
    const corners = [_][2]f32{
        .{ -25, -25 }, .{ 25, -25 },
        .{ 25, 25 },   .{ -25, 25 },
    };
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const j = (i + 1) % 4;
        const a = applyRotFlip(corners[i][0], corners[i][1], rot, flip);
        const b = applyRotFlip(corners[j][0], corners[j][1], rot, flip);
        const pa = origin + Vec2{ a[0], a[1] } * s;
        const pb = origin + Vec2{ b[0], b[1] } * s;
        strokeLine(pa[0], pa[1], pb[0], pb[1], 1.4, color);
    }
}

// ===========================================================================
// Transform Helpers
// ===========================================================================

fn applyRotFlip(px: f32, py: f32, rot: u2, flip: bool) [2]f32 {
    const x = if (flip) -px else px;
    const y = py;
    return switch (rot) {
        0 => .{ x, y },
        1 => .{ -y, x },
        2 => .{ -x, -y },
        3 => .{ y, -x },
    };
}

// ===========================================================================
// Helper Functions
// ===========================================================================

inline fn strokeLine(x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, col: Color) void {
    dvui.Path.stroke(.{
        .points = &.{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 } },
    }, .{ .thickness = thickness, .color = col });
}

inline fn strokeDot(p: Vec2, radius: f32, col: Color) void {
    dvui.Path.stroke(.{
        .points = &.{
            .{ .x = p[0] - radius, .y = p[1] },
            .{ .x = p[0] + radius, .y = p[1] },
        },
    }, .{ .thickness = radius * 2.0, .color = col });
}

fn strokeRectOutline(tl: Vec2, br: Vec2, thickness: f32, col: Color) void {
    dvui.Path.stroke(.{
        .points = &.{
            .{ .x = tl[0], .y = tl[1] },
            .{ .x = br[0], .y = tl[1] },
            .{ .x = br[0], .y = br[1] },
            .{ .x = tl[0], .y = br[1] },
            .{ .x = tl[0], .y = tl[1] },
        },
    }, .{ .thickness = thickness, .color = col });
}

fn strokeCircle(center: Vec2, radius: f32, thickness: f32, col: Color) void {
    const n_segs: usize = 16;
    var prev: Vec2 = .{ center[0] + radius, center[1] };
    for (1..n_segs + 1) |si| {
        const angle = @as(f32, @floatFromInt(si)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(n_segs)));
        const cur: Vec2 = .{
            center[0] + radius * @cos(angle),
            center[1] - radius * @sin(angle),
        };
        strokeLine(prev[0], prev[1], cur[0], cur[1], thickness, col);
        prev = cur;
    }
}

fn strokeArc(center: Vec2, radius: f32, start_angle: i16, sweep_angle: i16, thickness: f32, col: Color) void {
    const start_deg: f32 = @floatFromInt(start_angle);
    const sweep_deg: f32 = @floatFromInt(sweep_angle);
    const n_segs: usize = @max(8, @as(usize, @intFromFloat(@abs(sweep_deg) / 10.0)));
    const start_rad = start_deg * std.math.pi / 180.0;
    const sweep_rad = sweep_deg * std.math.pi / 180.0;

    var prev: Vec2 = .{
        center[0] + radius * @cos(start_rad),
        center[1] - radius * @sin(start_rad),
    };
    for (1..n_segs + 1) |si| {
        const t: f32 = @as(f32, @floatFromInt(si)) / @as(f32, @floatFromInt(n_segs));
        const angle = start_rad + sweep_rad * t;
        const cur: Vec2 = .{
            center[0] + radius * @cos(angle),
            center[1] - radius * @sin(angle),
        };
        strokeLine(prev[0], prev[1], cur[0], cur[1], thickness, col);
        prev = cur;
    }
}

fn drawLabel(text: []const u8, x: f32, y: f32, col: Color, vp: Viewport, id_extra: usize) void {
    const size = @max(10.0, @min(18.0, 12.0 * vp.scale));
    var font = dvui.themeGet().font_body;
    font.size = size;
    const lh = font.size * font.line_height_factor + 8;

    // Clip to viewport bounds
    if (x > vp.bounds.x + vp.bounds.w or x + 300 < vp.bounds.x) return;
    if (y > vp.bounds.y + vp.bounds.h or y + lh < vp.bounds.y) return;

    dvui.labelNoFmt(@src(), text, .{}, .{
        .rect = .{ .x = x, .y = y, .w = 300, .h = lh },
        .color_text = col,
        .font = font,
        .id_extra = id_extra,
    });
}

// ===========================================================================
// Coordinate Transforms
// ===========================================================================

pub inline fn w2p(pt: Point, vp: Viewport) Vec2 {
    const world: Vec2 = @floatFromInt(@as(@Vector(2, i32), pt));
    const pan: Vec2 = .{ vp.pan[0], vp.pan[1] };
    const s: Vec2 = @splat(vp.scale);
    const center: Vec2 = .{ vp.cx, vp.cy };
    return center + (world - pan) * s;
}

pub inline fn p2w_raw(pt: Vec2, vp: Viewport) Vec2 {
    const center: Vec2 = .{ vp.cx, vp.cy };
    const s: Vec2 = @splat(vp.scale);
    const pan: Vec2 = .{ vp.pan[0], vp.pan[1] };
    return (pt - center) / s + pan;
}

pub inline fn p2w(pt: Vec2, vp: Viewport, snap: f32) Point {
    const center: Vec2 = .{ vp.cx, vp.cy };
    const s: Vec2 = @splat(vp.scale);
    const pan: Vec2 = .{ vp.pan[0], vp.pan[1] };
    const world = (pt - center) / s + pan;
    const gs: f32 = if (snap > 0) snap else 1.0;
    return .{
        @intFromFloat(@round(world[0] / gs) * gs),
        @intFromFloat(@round(world[1] / gs) * gs),
    };
}

// ===========================================================================
// Grid Drawing Functions
// ===========================================================================

const grid_min_step_px: f32 = 3.0;
const grid_max_points: f32 = 16_000.0;
const grid_dot_large: f32 = 1.2;
const grid_dot_small: f32 = 0.7;
const grid_dot_threshold: f32 = 20.0;
const origin_arm_min: f32 = 6.0;
const origin_arm_max_scale: f32 = 12.0;
const wire_endpoint_radius: f32 = 2.5;
const wire_preview_dot_radius: f32 = 4.0;
const wire_preview_arm: f32 = 8.0;
pub const inst_hit_tolerance: f32 = 14.0;
pub const wire_hit_tolerance: f32 = 10.0;

fn drawGrid(vp: Viewport, pal: Palette, snap: f32) void {
    const step = snap * vp.scale;
    if (step < grid_min_step_px) return;

    const ox = @mod(vp.cx - vp.pan[0] * vp.scale, step);
    const oy = @mod(vp.cy - vp.pan[1] * vp.scale, step);

    const cols_f = @max(1.0, @floor(vp.bounds.w / step) + 2.0);
    const rows_f = @max(1.0, @floor(vp.bounds.h / step) + 2.0);
    const total = cols_f * rows_f;
    const stride = if (total <= grid_max_points) 1.0 else @ceil(@sqrt(total / grid_max_points));
    const dstep = step * stride;

    const dot_r_base: f32 = if (step > grid_dot_threshold) grid_dot_large else grid_dot_small;
    const dot_r: f32 = dot_r_base * theme.getGridDotSize();

    var x: f32 = vp.bounds.x + ox;
    while (x < vp.bounds.x + vp.bounds.w) : (x += dstep) {
        var y: f32 = vp.bounds.y + oy;
        while (y < vp.bounds.y + vp.bounds.h) : (y += dstep) {
            strokeDot(.{ x, y }, dot_r, pal.grid_dot);
        }
    }
}

fn drawOrigin(vp: Viewport, pal: Palette) void {
    const ox = vp.cx - vp.pan[0] * vp.scale;
    const oy = vp.cy - vp.pan[1] * vp.scale;
    const arm = @max(origin_arm_min, origin_arm_max_scale * @min(vp.scale, 1.0));

    if (ox < vp.bounds.x or ox > vp.bounds.x + vp.bounds.w) return;
    if (oy < vp.bounds.y or oy > vp.bounds.y + vp.bounds.h) return;

    strokeLine(ox - arm, oy, ox + arm, oy, 1.0, pal.origin);
    strokeLine(ox, oy - arm, ox, oy + arm, 1.0, pal.origin);
}
