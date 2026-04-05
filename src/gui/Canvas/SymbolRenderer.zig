//! Instance/subcircuit rendering and symbol view drawing.
//! Includes SubcktCache (module-level), primitive lookup, and all instance drawing.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme_config");
const st = @import("state");
const core = @import("core");
const utility = @import("utility");
const Vfs = utility.Vfs;

const types = @import("types.zig");
const vp_mod = @import("Viewport.zig");
const h = @import("draw_helpers.zig");

const Schemify = core.Schemify;
const DeviceKind = core.DeviceKind;
const primitives = core.primitives;
const Allocator = std.mem.Allocator;
const Vec2 = types.Vec2;
const Color = types.Color;
const RenderViewport = types.RenderViewport;
const RenderContext = types.RenderContext;

// ===========================================================================
// Subcircuit Symbol Cache
// ===========================================================================

const SubcktPin = struct {
    name: []const u8,
    dir: core.PinDir,
    x: i16,
    y: i16,
};

const SubcktSymbol = struct {
    pins: []SubcktPin,
    box_w: i16,
    box_h: i16,
};

const SubcktCache = std.StringHashMapUnmanaged(SubcktSymbol);
var subckt_cache: SubcktCache = .{};
var subckt_arena_state: ?std.heap.ArenaAllocator = null;

fn subcktArena() Allocator {
    if (subckt_arena_state == null) {
        subckt_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
    return subckt_arena_state.?.allocator();
}

fn resolveSubcktSymbol(symbol: []const u8, doc_origin: st.Origin, project_dir: []const u8) ?*const SubcktSymbol {
    if (subckt_cache.get(symbol)) |*cached| return cached;

    var path_buf: [512]u8 = undefined;
    const chn_path = resolveSubcktPath(symbol, doc_origin, project_dir, &path_buf) orelse return null;

    const arena = subcktArena();
    const data = Vfs.readAlloc(arena, chn_path) catch return null;
    const parsed = core.Schemify.readFile(data, arena, null);

    var pins: std.ArrayListUnmanaged(SubcktPin) = .{};
    const kinds = parsed.instances.items(.kind);
    const names = parsed.instances.items(.name);
    const xs = parsed.instances.items(.x);
    const ys = parsed.instances.items(.y);
    for (0..parsed.instances.len) |i| {
        const dir: core.PinDir = switch (kinds[i]) {
            .input_pin => .input,
            .output_pin => .output,
            .inout_pin => .inout,
            else => continue,
        };
        pins.append(arena, .{
            .name = arena.dupe(u8, names[i]) catch names[i],
            .dir = dir,
            .x = @intCast(xs[i]),
            .y = @intCast(ys[i]),
        }) catch continue;
    }

    if (pins.items.len == 0) return null;

    var left_count: i16 = 0;
    var right_count: i16 = 0;
    for (pins.items) |p| {
        switch (p.dir) {
            .input, .inout, .power, .ground => left_count += 1,
            .output => right_count += 1,
        }
    }
    const max_side: i16 = @max(left_count, right_count);
    const pin_spacing: i16 = 20;
    const box_h: i16 = @max(40, (max_side + 1) * pin_spacing);
    var max_name_len: usize = 0;
    for (pins.items) |p| {
        if (p.name.len > max_name_len) max_name_len = p.name.len;
    }
    const box_w: i16 = @max(60, @as(i16, @intCast(@min(max_name_len * 8 + 30, 120))));
    const half_w = @divTrunc(box_w, 2);
    const half_h = @divTrunc(box_h, 2);

    var left_idx: i16 = 0;
    var right_idx: i16 = 0;
    for (pins.items) |*p| {
        switch (p.dir) {
            .input, .inout, .power, .ground => {
                p.x = -half_w - 10;
                p.y = -half_h + (left_idx + 1) * pin_spacing;
                left_idx += 1;
            },
            .output => {
                p.x = half_w + 10;
                p.y = -half_h + (right_idx + 1) * pin_spacing;
                right_idx += 1;
            },
        }
    }

    const key = arena.dupe(u8, symbol) catch return null;
    const sym = SubcktSymbol{
        .pins = pins.toOwnedSlice(arena) catch return null,
        .box_w = box_w,
        .box_h = box_h,
    };
    subckt_cache.put(arena, key, sym) catch return null;
    return subckt_cache.getPtr(key);
}

fn resolveSubcktPath(symbol: []const u8, doc_origin: st.Origin, project_dir: []const u8, buf: *[512]u8) ?[]const u8 {
    const base = if (std.mem.endsWith(u8, symbol, ".sym"))
        symbol[0 .. symbol.len - ".sym".len]
    else
        symbol;

    if (std.mem.endsWith(u8, base, ".chn")) {
        if (Vfs.exists(base)) return base;
    }

    const dir: []const u8 = switch (doc_origin) {
        .chn_file => |p| std.fs.path.dirname(p) orelse ".",
        else => ".",
    };

    if (std.fmt.bufPrint(buf, "{s}/{s}.chn", .{ dir, base })) |path| {
        if (Vfs.exists(path)) return path;
    } else |_| {}

    if (std.fmt.bufPrint(buf, "{s}/{s}.chn", .{ project_dir, base })) |path| {
        if (Vfs.exists(path)) return path;
    } else |_| {}

    const stem = std.fs.path.stem(base);
    if (std.fmt.bufPrint(buf, "{s}/{s}.chn", .{ dir, stem })) |path| {
        if (Vfs.exists(path)) return path;
    } else |_| {}

    return null;
}

// ===========================================================================
// Public API
// ===========================================================================

/// Draw all instances in schematic view.
pub fn draw(ctx: *const RenderContext, sch: *const Schemify, app: *st.AppState, sel: *const st.Selection) void {
    const vp = ctx.vp;
    const pal = ctx.pal;

    if (sch.instances.len == 0) return;

    const ix = sch.instances.items(.x);
    const iy = sch.instances.items(.y);
    const irot = sch.instances.items(.rot);
    const iflip = sch.instances.items(.flip);
    const ikind = sch.instances.items(.kind);
    const iname = sch.instances.items(.name);
    const isymbol = sch.instances.items(.symbol);

    const doc_origin: st.Origin = if (app.active_idx < app.documents.items.len)
        app.documents.items[app.active_idx].origin
    else
        .unsaved;

    for (0..sch.instances.len) |i| {
        const selected = i < sel.instances.bit_length and sel.instances.isSet(i);
        const color = if (selected) pal.inst_sel else pal.symbol_line;
        const origin = vp_mod.w2p(.{ ix[i], iy[i] }, vp);
        const rot = irot[i];
        const flip = iflip[i];
        const kind = ikind[i];

        const prim = lookupPrim(isymbol[i], kind);

        if (prim) |entry| {
            drawPrimEntry(entry, origin, rot, flip, vp, color);
        } else if (resolveSubcktSymbol(isymbol[i], doc_origin, app.project_dir)) |subckt| {
            drawSubcktBox(subckt, origin, rot, flip, vp, color);
        } else {
            drawGenericBox(origin, rot, flip, vp, color);
        }

        // Pin marker cross at instance origin.
        const pin_arm: f32 = @max(2.0, 3.0 * @min(vp.scale, 2.0));
        const pin_color = if (selected) pal.wire_sel else pal.inst_pin;
        h.strokeLine(origin[0] - pin_arm, origin[1], origin[0] + pin_arm, origin[1], 0.8, pin_color);
        h.strokeLine(origin[0], origin[1] - pin_arm, origin[0], origin[1] + pin_arm, 0.8, pin_color);

        // Pin connection squares.
        if (prim) |entry| {
            const pin_sq: f32 = @max(2.5, 3.5 * @min(vp.scale, 2.0));
            for (entry.pinPositions()) |pp| {
                const pp_rf = h.applyRotFlip(@floatFromInt(pp.x), @floatFromInt(pp.y), rot, flip);
                const pp_px = origin + Vec2{ pp_rf[0], pp_rf[1] } * @as(Vec2, @splat(vp.scale));
                h.strokeDot(pp_px, pin_sq, pal.wire_endpoint);
            }
        }

        // Instance name label.
        if (vp.scale >= 0.3 and iname[i].len > 0) {
            h.drawLabel(iname[i], origin[0] + 25.0 * vp.scale, origin[1] - 20.0 * vp.scale, pal.inst_pin, vp, i);
        }
    }
}

/// Draw symbol view (geometry, pins, texts).
pub fn drawSymbol(ctx: *const RenderContext, sch: *const Schemify) void {
    const vp = ctx.vp;
    const pal = ctx.pal;

    const prev_clip = dvui.clip(.{ .x = vp.bounds.x, .y = vp.bounds.y, .w = vp.bounds.w, .h = vp.bounds.h });
    defer dvui.clipSet(prev_clip);

    const sym_w: f32 = @max(1.4, 1.8 * vp.scale);
    const has_geometry = sch.lines.len > 0 or sch.rects.len > 0 or sch.circles.len > 0 or sch.arcs.len > 0;

    if (has_geometry) {
        drawSymbolGeometry(sch, vp, sym_w, pal);
    } else if (sch.pins.len > 0) {
        drawAutoSymbolBox(sch, vp, sym_w, pal);
    }

    // Texts.
    if (vp.scale >= 0.3 and sch.texts.len > 0) {
        const tcontent = sch.texts.items(.content);
        const tx = sch.texts.items(.x);
        const ty = sch.texts.items(.y);
        for (0..sch.texts.len) |i| {
            if (tcontent[i].len == 0) continue;
            const p = vp_mod.w2p(.{ tx[i], ty[i] }, vp);
            h.drawLabel(tcontent[i], p[0], p[1], pal.symbol_line, vp, sch.pins.len + i);
        }
    }
}

// ===========================================================================
// File Classification
// ===========================================================================

pub const FileType = enum { full, prim_only, tb_only };

pub fn classifyFile(origin: st.Origin) FileType {
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
// Private helpers
// ===========================================================================

fn drawSubcktBox(sym: *const SubcktSymbol, origin: Vec2, rot: u2, flip: bool, vp: RenderViewport, color: Color) void {
    const s: Vec2 = @splat(vp.scale);
    const sym_w: f32 = @max(1.4, 1.8 * vp.scale);
    const half_w: f32 = @floatFromInt(@divTrunc(sym.box_w, 2));
    const half_h: f32 = @floatFromInt(@divTrunc(sym.box_h, 2));

    const corners = [4][2]f32{
        .{ -half_w, -half_h },
        .{ half_w, -half_h },
        .{ half_w, half_h },
        .{ -half_w, half_h },
    };
    inline for (0..4) |i| {
        const a = h.applyRotFlip(corners[i][0], corners[i][1], rot, flip);
        const b = h.applyRotFlip(corners[(i + 1) % 4][0], corners[(i + 1) % 4][1], rot, flip);
        const pa = origin + Vec2{ a[0], a[1] } * s;
        const pb = origin + Vec2{ b[0], b[1] } * s;
        h.strokeLine(pa[0], pa[1], pb[0], pb[1], sym_w, color);
    }

    for (sym.pins, 0..) |pin, pi| {
        const px: f32 = @floatFromInt(pin.x);
        const py: f32 = @floatFromInt(pin.y);
        const pp = h.applyRotFlip(px, py, rot, flip);
        const pp_px = origin + Vec2{ pp[0], pp[1] } * s;

        const edge_x: f32 = if (px < 0) -half_w else half_w;
        const ep = h.applyRotFlip(edge_x, py, rot, flip);
        const ep_px = origin + Vec2{ ep[0], ep[1] } * s;
        h.strokeLine(ep_px[0], ep_px[1], pp_px[0], pp_px[1], sym_w, color);

        const pin_sq: f32 = @max(2.5, 3.5 * @min(vp.scale, 2.0));
        h.strokeDot(pp_px, pin_sq, color);

        if (vp.scale >= 0.3 and pin.name.len > 0) {
            const label_x = if (px < 0)
                ep_px[0] + 3.0 * vp.scale
            else
                ep_px[0] - @as(f32, @floatFromInt(pin.name.len)) * 6.0 * vp.scale - 3.0 * vp.scale;
            const label_y = ep_px[1] - 8.0 * vp.scale;
            h.drawLabel(pin.name, label_x, label_y, color, vp, 0x8000 + pi);
        }
    }
}

fn drawPrimEntry(entry: *const primitives.PrimEntry, origin: Vec2, rot: u2, flip: bool, vp: RenderViewport, color: Color) void {
    const s: Vec2 = @splat(vp.scale);
    const sym_w: f32 = @max(1.4, 1.8 * vp.scale);

    for (entry.segs()) |seg| {
        const a = h.applyRotFlip(@floatFromInt(seg.x0), @floatFromInt(seg.y0), rot, flip);
        const b = h.applyRotFlip(@floatFromInt(seg.x1), @floatFromInt(seg.y1), rot, flip);
        const pa = origin + Vec2{ a[0], a[1] } * s;
        const pb = origin + Vec2{ b[0], b[1] } * s;
        h.strokeLine(pa[0], pa[1], pb[0], pb[1], sym_w, color);
    }

    for (entry.drawCircles()) |circ| {
        const c = h.applyRotFlip(@floatFromInt(circ.cx), @floatFromInt(circ.cy), rot, flip);
        const center = origin + Vec2{ c[0], c[1] } * s;
        const r: f32 = @as(f32, @floatFromInt(circ.r)) * vp.scale;
        h.strokeCircle(center, r, sym_w, color);
    }

    for (entry.drawArcs()) |arc| {
        const c = h.applyRotFlip(@floatFromInt(arc.cx), @floatFromInt(arc.cy), rot, flip);
        const center = origin + Vec2{ c[0], c[1] } * s;
        const r: f32 = @as(f32, @floatFromInt(arc.r)) * vp.scale;
        var start_angle: i16 = arc.start;
        const sweep_angle: i16 = arc.sweep;
        if (flip) {
            start_angle = 180 - start_angle - sweep_angle;
        }
        start_angle += @as(i16, @intCast(rot)) * 90;
        h.strokeArc(center, r, start_angle, sweep_angle, sym_w, color);
    }

    for (entry.drawRects()) |rect| {
        const tl_raw = h.applyRotFlip(@floatFromInt(rect.x0), @floatFromInt(rect.y0), rot, flip);
        const br_raw = h.applyRotFlip(@floatFromInt(rect.x1), @floatFromInt(rect.y1), rot, flip);
        const tl = origin + Vec2{ @min(tl_raw[0], br_raw[0]), @min(tl_raw[1], br_raw[1]) } * s;
        const br = origin + Vec2{ @max(tl_raw[0], br_raw[0]), @max(tl_raw[1], br_raw[1]) } * s;
        h.strokeRectOutline(tl, br, sym_w, color);
    }
}

fn drawGenericBox(origin: Vec2, rot: u2, flip: bool, vp: RenderViewport, color: Color) void {
    const s: Vec2 = @splat(vp.scale);
    const sym_w: f32 = @max(1.4, 1.8 * vp.scale);
    const corners = [4][2]f32{ .{ -25, -25 }, .{ 25, -25 }, .{ 25, 25 }, .{ -25, 25 } };
    inline for (0..4) |i| {
        const a = h.applyRotFlip(corners[i][0], corners[i][1], rot, flip);
        const b = h.applyRotFlip(corners[(i + 1) % 4][0], corners[(i + 1) % 4][1], rot, flip);
        const pa = origin + Vec2{ a[0], a[1] } * s;
        const pb = origin + Vec2{ b[0], b[1] } * s;
        h.strokeLine(pa[0], pa[1], pb[0], pb[1], sym_w, color);
    }
}

fn drawSymbolGeometry(sch: *const Schemify, vp: RenderViewport, sym_w: f32, pal: types.Palette) void {
    if (sch.lines.len > 0) {
        const lx0 = sch.lines.items(.x0);
        const ly0 = sch.lines.items(.y0);
        const lx1 = sch.lines.items(.x1);
        const ly1 = sch.lines.items(.y1);
        for (0..sch.lines.len) |i| {
            const a = vp_mod.w2p(.{ lx0[i], ly0[i] }, vp);
            const b = vp_mod.w2p(.{ lx1[i], ly1[i] }, vp);
            h.strokeLine(a[0], a[1], b[0], b[1], sym_w, pal.symbol_line);
        }
    }
    if (sch.rects.len > 0) {
        const rx0 = sch.rects.items(.x0);
        const ry0 = sch.rects.items(.y0);
        const rx1 = sch.rects.items(.x1);
        const ry1 = sch.rects.items(.y1);
        for (0..sch.rects.len) |i| {
            const tl = vp_mod.w2p(.{ rx0[i], ry0[i] }, vp);
            const br = vp_mod.w2p(.{ rx1[i], ry1[i] }, vp);
            h.strokeRectOutline(tl, br, sym_w, pal.symbol_line);
        }
    }
    if (sch.circles.len > 0) {
        const ccx = sch.circles.items(.cx);
        const ccy = sch.circles.items(.cy);
        const crad = sch.circles.items(.radius);
        for (0..sch.circles.len) |i| {
            const center = vp_mod.w2p(.{ ccx[i], ccy[i] }, vp);
            const r: f32 = @as(f32, @floatFromInt(crad[i])) * vp.scale;
            h.strokeCircle(center, r, sym_w, pal.symbol_line);
        }
    }
    if (sch.arcs.len > 0) {
        const acx = sch.arcs.items(.cx);
        const acy = sch.arcs.items(.cy);
        const arad = sch.arcs.items(.radius);
        const astart = sch.arcs.items(.start_angle);
        const asweep = sch.arcs.items(.sweep_angle);
        for (0..sch.arcs.len) |i| {
            const center = vp_mod.w2p(.{ acx[i], acy[i] }, vp);
            const r: f32 = @as(f32, @floatFromInt(arad[i])) * vp.scale;
            h.strokeArc(center, r, astart[i], asweep[i], sym_w, pal.symbol_line);
        }
    }
    if (sch.pins.len > 0) {
        const px = sch.pins.items(.x);
        const py = sch.pins.items(.y);
        const pname = sch.pins.items(.name);
        const pin_arm: f32 = @max(3.0, 4.0 * @min(vp.scale, 2.0));
        for (0..sch.pins.len) |i| {
            const p = vp_mod.w2p(.{ px[i], py[i] }, vp);
            h.strokeLine(p[0] - pin_arm, p[1], p[0] + pin_arm, p[1], 1.0, pal.inst_pin);
            h.strokeLine(p[0], p[1] - pin_arm, p[0], p[1] + pin_arm, 1.0, pal.inst_pin);
            h.strokeDot(p, pin_arm * 0.6, pal.wire_endpoint);
            if (vp.scale >= 0.3 and pname[i].len > 0) {
                h.drawLabel(pname[i], p[0] + 8.0 * vp.scale, p[1] - 14.0 * vp.scale, pal.inst_pin, vp, i);
            }
        }
    }
}

fn drawAutoSymbolBox(sch: *const Schemify, vp: RenderViewport, sym_w: f32, pal: types.Palette) void {
    const dirs = sch.pins.items(.dir);
    const px = sch.pins.items(.x);
    const py = sch.pins.items(.y);
    const pname = sch.pins.items(.name);

    var left_count: i32 = 0;
    var right_count: i32 = 0;
    for (0..sch.pins.len) |i| {
        switch (dirs[i]) {
            .input, .power, .ground => left_count += 1,
            .output => right_count += 1,
            .inout => {
                if (left_count <= right_count) left_count += 1 else right_count += 1;
            },
        }
    }
    const max_pins: i32 = @max(@max(left_count, right_count), 1);

    const pin_spacing: i32 = 20;
    const stub_len: i32 = 10;
    const name_width: i32 = @as(i32, @intCast(sch.name.len)) * 8;
    const box_w: i32 = @max(120, name_width + 40);
    const box_h: i32 = (max_pins + 1) * pin_spacing;

    const tl = vp_mod.w2p(.{ 0, 0 }, vp);
    const tr = vp_mod.w2p(.{ box_w, 0 }, vp);
    const br = vp_mod.w2p(.{ box_w, box_h }, vp);
    const bl = vp_mod.w2p(.{ 0, box_h }, vp);
    h.strokeLine(tl[0], tl[1], tr[0], tr[1], sym_w, pal.symbol_line);
    h.strokeLine(tr[0], tr[1], br[0], br[1], sym_w, pal.symbol_line);
    h.strokeLine(br[0], br[1], bl[0], bl[1], sym_w, pal.symbol_line);
    h.strokeLine(bl[0], bl[1], tl[0], tl[1], sym_w, pal.symbol_line);

    if (vp.scale >= 0.2) {
        const cx = vp_mod.w2p(.{ @divTrunc(box_w, 2), @divTrunc(box_h, 2) }, vp);
        h.drawLabel(sch.name, cx[0] - 40.0, cx[1] - 8.0, pal.symbol_line, vp, 50000);
    }

    var li: i32 = 0;
    var ri: i32 = 0;
    const pin_arm: f32 = @max(3.0, 4.0 * @min(vp.scale, 2.0));

    for (0..sch.pins.len) |i| {
        const is_left = switch (dirs[i]) {
            .input, .power, .ground => true,
            .output => false,
            .inout => blk: {
                if (px[i] != 0 or py[i] != 0) {
                    break :blk px[i] <= @divTrunc(box_w, 2);
                }
                break :blk li <= ri;
            },
        };

        const slot: i32 = if (is_left) blk: {
            li += 1;
            break :blk li;
        } else blk: {
            ri += 1;
            break :blk ri;
        };
        const pin_y: i32 = slot * pin_spacing;

        if (is_left) {
            const stub_start = vp_mod.w2p(.{ -stub_len, pin_y }, vp);
            const stub_end = vp_mod.w2p(.{ 0, pin_y }, vp);
            h.strokeLine(stub_start[0], stub_start[1], stub_end[0], stub_end[1], sym_w, pal.symbol_line);
            h.strokeDot(stub_start, pin_arm * 0.6, pal.wire_endpoint);
            if (vp.scale >= 0.3 and pname[i].len > 0) {
                h.drawLabel(pname[i], stub_end[0] + 4.0 * vp.scale, stub_end[1] - 12.0 * vp.scale, pal.inst_pin, vp, i);
            }
        } else {
            const stub_start = vp_mod.w2p(.{ box_w, pin_y }, vp);
            const stub_end = vp_mod.w2p(.{ box_w + stub_len, pin_y }, vp);
            h.strokeLine(stub_start[0], stub_start[1], stub_end[0], stub_end[1], sym_w, pal.symbol_line);
            h.strokeDot(stub_end, pin_arm * 0.6, pal.wire_endpoint);
            if (vp.scale >= 0.3 and pname[i].len > 0) {
                h.drawLabel(pname[i], stub_start[0] - 60.0 * vp.scale, stub_start[1] - 12.0 * vp.scale, pal.inst_pin, vp, i);
            }
        }
    }
}

// ===========================================================================
// Primitives Lookup
// ===========================================================================

fn lookupPrim(symbol_name: []const u8, kind: DeviceKind) ?*const primitives.PrimEntry {
    const kind_name = kindToName(kind);
    if (kind_name) |name| {
        if (primitives.findByNameRuntime(name)) |entry| return entry;
    }

    var base = symbol_name;
    if (std.mem.startsWith(u8, base, "devices/"))
        base = base["devices/".len..];
    if (std.mem.endsWith(u8, base, ".sym"))
        base = base[0 .. base.len - ".sym".len];

    if (primitives.findByNameRuntime(base)) |entry| return entry;

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

    const name_kind = DeviceKind.fromStr(base);
    if (name_kind != .unknown) {
        const nk = kindToName(name_kind);
        if (nk) |n| {
            if (primitives.findByNameRuntime(n)) |entry| return entry;
        }
    }

    return null;
}

fn kindToName(kind: DeviceKind) ?[]const u8 {
    return switch (kind) {
        .nmos3 => "nmos3",
        .pmos3 => "pmos3",
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
        .annotation, .title, .param, .code, .graph, .launcher,
        .rgb_led, .hdl, .noconn, .subckt, .digital_instance, .generic,
        => null,
        .unknown => null,
    };
}
