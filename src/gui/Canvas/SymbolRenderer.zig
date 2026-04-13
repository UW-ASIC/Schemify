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
// Subcircuit Symbol Cache (per-document, lifetime owned by Document)
// ===========================================================================

const SubcktSymbol = st.SubcktSymbol;
const SubcktCache  = st.SubcktCache;

fn resolveSubcktSymbol(symbol: []const u8, doc_origin: st.Origin, project_dir: []const u8, doc: *st.Document) ?*const SubcktSymbol {
    // NOTE: use getPtr, not get — get returns ?V by value (a stack temporary);
    // a pointer into that temporary dangled before drawSubcktBox read pin slices.
    if (doc.subckt_cache.getPtr(symbol)) |cached| return cached;

    var path_buf: [512]u8 = undefined;
    const chn_path = resolveSubcktPath(symbol, doc_origin, project_dir, &path_buf) orelse return null;

    const arena = doc.subcktAllocator();
    const data = Vfs.readAlloc(arena, chn_path) catch return null;
    const parsed = core.Schemify.readFile(data, arena, null);

    if (parsed.pins.len == 0) return null;

    const pin_names = parsed.pins.items(.name);
    const pin_dirs = parsed.pins.items(.dir);
    const pin_xs = parsed.pins.items(.x);
    const pin_ys = parsed.pins.items(.y);

    const n = parsed.pins.len;

    var col_x:    std.ArrayListUnmanaged(i16)         = .{};
    var col_y:    std.ArrayListUnmanaged(i16)         = .{};
    var col_dir:  std.ArrayListUnmanaged(core.PinDir) = .{};
    var col_name: std.ArrayListUnmanaged([]const u8)  = .{};

    for (0..n) |i| {
        const name_copy = arena.dupe(u8, pin_names[i]) catch pin_names[i];
        col_x.append(arena, @intCast(pin_xs[i])) catch continue;
        col_y.append(arena, @intCast(pin_ys[i])) catch {
            col_x.items.len -= 1;
            continue;
        };
        col_dir.append(arena, pin_dirs[i]) catch {
            col_x.items.len -= 1;
            col_y.items.len -= 1;
            continue;
        };
        col_name.append(arena, name_copy) catch {
            col_x.items.len -= 1;
            col_y.items.len -= 1;
            col_dir.items.len -= 1;
            continue;
        };
    }

    if (col_x.items.len == 0) return null;

    var left_count: i16 = 0;
    var right_count: i16 = 0;
    for (col_dir.items) |d| {
        switch (d) {
            .input, .inout, .power, .ground => left_count += 1,
            .output => right_count += 1,
        }
    }
    const max_side: i16 = @max(left_count, right_count);
    const pin_spacing: i16 = 20;
    const box_h: i16 = @max(40, (max_side + 1) * pin_spacing);
    var max_name_len: usize = 0;
    for (col_name.items) |nm| {
        if (nm.len > max_name_len) max_name_len = nm.len;
    }
    const box_w: i16 = @max(60, @as(i16, @intCast(@min(max_name_len * 8 + 30, 120))));
    const half_w = @divTrunc(box_w, 2);
    const half_h = @divTrunc(box_h, 2);

    var left_idx: i16 = 0;
    var right_idx: i16 = 0;
    for (col_dir.items, 0..) |d, i| {
        switch (d) {
            .input, .inout, .power, .ground => {
                col_x.items[i] = -half_w - 10;
                col_y.items[i] = -half_h + (left_idx + 1) * pin_spacing;
                left_idx += 1;
            },
            .output => {
                col_x.items[i] = half_w + 10;
                col_y.items[i] = -half_h + (right_idx + 1) * pin_spacing;
                right_idx += 1;
            },
        }
    }

    const key = arena.dupe(u8, symbol) catch return null;
    const sym = SubcktSymbol{
        .pin_x    = col_x.toOwnedSlice(arena)    catch return null,
        .pin_y    = col_y.toOwnedSlice(arena)    catch return null,
        .pin_dir  = col_dir.toOwnedSlice(arena)  catch return null,
        .pin_name = col_name.toOwnedSlice(arena) catch return null,
        .box_w = box_w,
        .box_h = box_h,
    };
    doc.subckt_cache.put(arena, key, sym) catch return null;
    return doc.subckt_cache.getPtr(key);
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
pub fn draw(ctx: *const RenderContext, sch: *const Schemify, app: *st.AppState, sel: *const st.Selection, hide_port_prims: bool) void {
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

    const active_doc = app.active();
    const doc_origin: st.Origin = if (active_doc) |d| d.origin else .unsaved;

    // Single per-pass line batch: every primitive segment, subckt edge,
    // generic-box edge, pin-marker cross, and pin connection square is
    // funnelled through this and submitted as one renderTriangles call at
    // the end of the instance pass. The previous implementation emitted
    // ~8–20 render commands per instance; on a schematic with 100 instances
    // that's ~1500 Path.stroke triangulations per frame, which dominated
    // redraw cost during dialog drags.
    const cw = dvui.currentWindow();
    const lalloc = cw.lifo();
    var batch = h.LineBatch.init(lalloc);
    defer batch.deinit();
    // Reserve an optimistic upper bound: 16 line-equivalents per instance
    // covers typical prim segment + rect + pin square counts.
    batch.ensureLineCapacity(sch.instances.len * 16) catch {};

    var pending_labels: h.LabelList = .{};
    defer pending_labels.deinit(lalloc);

    for (0..sch.instances.len) |i| {
        const selected = i < sel.instances.bit_length and sel.instances.isSet(i);
        const color = if (selected) pal.inst_sel else pal.symbol_line;
        const origin = vp_mod.w2p(.{ ix[i], iy[i] }, vp);
        const rot = irot[i];
        const flip = iflip[i];
        const kind = ikind[i];

        if (hide_port_prims and kind.isPort()) continue;

        // Read from the pre-built prim cache (zero string lookups per frame).
        const prim: ?*const primitives.PrimEntry = if (i < sch.prim_cache.len) sch.prim_cache[i] else null;

        if (prim) |entry| {
            drawPrimEntry(entry, origin, rot, flip, vp, color, &batch);
        } else {
            const subckt = if (active_doc) |doc|
                resolveSubcktSymbol(isymbol[i], doc_origin, app.project_dir, doc)
            else
                null;
            if (subckt) |s| {
                drawSubcktBox(s, origin, rot, flip, vp, color, &batch, &pending_labels, lalloc);
            } else {
                const sd = if (i < sch.sym_data.items.len) sch.sym_data.items[i] else core.SymData{};
                drawGenericBox(origin, rot, flip, vp, color, &batch, sd, &pending_labels, lalloc);
                if (active_doc) |doc| doc.addMissingSymbol(isymbol[i]);
            }
        }

        // Pin marker cross at instance origin.
        const pin_arm: f32 = @max(2.0, 3.0 * @min(vp.scale, 2.0));
        const pin_color = if (selected) pal.wire_sel else pal.inst_pin;
        batch.addLine(origin[0] - pin_arm, origin[1], origin[0] + pin_arm, origin[1], 0.8, pin_color);
        batch.addLine(origin[0], origin[1] - pin_arm, origin[0], origin[1] + pin_arm, 0.8, pin_color);

        // Pin connection squares.
        //
        // For port primitives (input_pin / output_pin / inout_pin / lab_pin)
        // the pin_position is intentionally at (0,0) — the instance origin —
        // because that's where a wire attaches. Drawing the wire_endpoint
        // square on top of the instance origin marker makes the pentagon/
        // hexagon body collapse into what looks like a "white dot"
        // (TODO #6): the 7px filled connection square visually dominates
        // the thin 28px-wide pentagon lines at typical zoom levels, leaving
        // only a single bright blob at the port location. Skip the
        // connection square whenever it would be drawn at the instance
        // origin for a non-electrical primitive; the instance-origin cross
        // already marks the attachment point, so the body stays visible.
        if (prim) |entry| {
            const pin_sq: f32 = @max(2.5, 3.5 * @min(vp.scale, 2.0));
            for (entry.pinPositions()) |pp| {
                if (entry.non_electrical and pp.x == 0 and pp.y == 0) continue;
                const pp_rf = h.applyRotFlip(@floatFromInt(pp.x), @floatFromInt(pp.y), rot, flip);
                const pp_px = origin + Vec2{ pp_rf[0], pp_rf[1] } * @as(Vec2, @splat(vp.scale));
                batch.addDot(pp_px, pin_sq, pal.wire_endpoint);
            }
        }
    }

    // Flush all instance line/dot geometry as one renderTriangles call,
    // then draw text labels on top (renderText has its own batching path).
    batch.flush();
    h.drainLabels(&pending_labels, vp);

    if (vp.scale >= 0.3) {
        for (0..sch.instances.len) |i| {
            if (iname[i].len == 0) continue;
            const origin = vp_mod.w2p(.{ ix[i], iy[i] }, vp);
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

    const sym_w: f32 = @max(0.9, 1.8 * vp.scale);
    const has_geometry = sch.lines.len > 0 or sch.rects.len > 0 or sch.circles.len > 0 or sch.arcs.len > 0;

    const cw = dvui.currentWindow();
    const lalloc = cw.lifo();
    var batch = h.LineBatch.init(lalloc);
    defer batch.deinit();
    var pending_labels: h.LabelList = .{};
    defer pending_labels.deinit(lalloc);

    if (has_geometry) {
        drawSymbolGeometry(sch, vp, sym_w, pal, &batch, &pending_labels, lalloc);
    } else if (sch.pins.len > 0) {
        drawAutoSymbolBox(sch, vp, sym_w, pal, &batch, &pending_labels, lalloc);
    }
    batch.flush();
    h.drainLabels(&pending_labels, vp);

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

/// Draw a direction-appropriate symbol at a pin endpoint `p`.
/// `facing_left` is true when the pin stub extends to the left of the box
/// (input side), false for the right (output side).
///
/// - input  : filled arrowhead pointing INTO the box (→ on left side)
/// - output : filled arrowhead pointing OUT of the box (→ on right side)
/// - inout  : diamond (two back-to-back triangles)
/// - power/ground: small cross (same as before — no directional meaning)
fn drawPinSymbol(batch: *h.LineBatch, p: Vec2, dir: core.PinDir, facing_left: bool, sz: f32, col: Color) void {
    switch (dir) {
        .input => {
            // Arrow pointing right (into box on left side) or left (right side
            // input is unusual but handled symmetrically).
            const dx: f32 = if (facing_left) sz else -sz;
            // Arrowhead: two diagonal lines from tip back to shaft.
            batch.addLine(p[0], p[1], p[0] - dx, p[1] - sz * 0.6, 0.9, col);
            batch.addLine(p[0], p[1], p[0] - dx, p[1] + sz * 0.6, 0.9, col);
        },
        .output => {
            // Arrow pointing away from box: on right side → points right.
            const dx: f32 = if (facing_left) -sz else sz;
            batch.addLine(p[0], p[1], p[0] - dx, p[1] - sz * 0.6, 0.9, col);
            batch.addLine(p[0], p[1], p[0] - dx, p[1] + sz * 0.6, 0.9, col);
        },
        .inout => {
            // Diamond: four lines forming a horizontal diamond shape.
            batch.addLine(p[0] - sz, p[1], p[0], p[1] - sz * 0.6, 0.9, col);
            batch.addLine(p[0], p[1] - sz * 0.6, p[0] + sz, p[1], 0.9, col);
            batch.addLine(p[0] + sz, p[1], p[0], p[1] + sz * 0.6, 0.9, col);
            batch.addLine(p[0], p[1] + sz * 0.6, p[0] - sz, p[1], 0.9, col);
        },
        .power, .ground => {
            // Small cross — power rails have no directional meaning.
            batch.addLine(p[0] - sz * 0.7, p[1], p[0] + sz * 0.7, p[1], 0.9, col);
            batch.addLine(p[0], p[1] - sz * 0.7, p[0], p[1] + sz * 0.7, 0.9, col);
        },
    }
}

fn drawSubcktBox(sym: *const SubcktSymbol, origin: Vec2, rot: u2, flip: bool, vp: RenderViewport, color: Color, batch: *h.LineBatch, labels: *h.LabelList, lalloc: std.mem.Allocator) void {
    const s: Vec2 = @splat(vp.scale);
    const sym_w: f32 = @max(0.9, 1.8 * vp.scale);
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
        batch.addLine(pa[0], pa[1], pb[0], pb[1], sym_w, color);
    }

    // Geometry loop: uses only pin_x, pin_y (SoA — avoids loading name/dir).
    for (sym.pin_x, sym.pin_y, 0..) |px_i, py_i, pi| {
        const px: f32 = @floatFromInt(px_i);
        const py: f32 = @floatFromInt(py_i);
        const pp = h.applyRotFlip(px, py, rot, flip);
        const pp_px = origin + Vec2{ pp[0], pp[1] } * s;

        const edge_x: f32 = if (px < 0) -half_w else half_w;
        const ep = h.applyRotFlip(edge_x, py, rot, flip);
        const ep_px = origin + Vec2{ ep[0], ep[1] } * s;
        batch.addLine(ep_px[0], ep_px[1], pp_px[0], pp_px[1], sym_w, color);

        // Directional pin symbol at the wire endpoint (pp_px).
        const arrow_sz: f32 = @max(3.0, 4.5 * @min(vp.scale, 2.0));
        const dir = sym.pin_dir[pi];
        drawPinSymbol(batch, pp_px, dir, px < 0, arrow_sz, color);
    }

    // Label loop: uses only pin_name (SoA — no geometry fields loaded).
    if (vp.scale >= 0.3) {
        for (sym.pin_x, sym.pin_name, 0..) |px_i, name, pi| {
            if (name.len == 0) continue;
            const px: f32 = @floatFromInt(px_i);
            const py: f32 = @floatFromInt(sym.pin_y[pi]);
            const ep = h.applyRotFlip(if (px < 0) -half_w else half_w, py, rot, flip);
            const ep_px = origin + Vec2{ ep[0], ep[1] } * s;
            // Right-anchored labels (pin on the right edge of the symbol box)
            // need to know the actual rendered width so the label's right
            // edge sits next to the pin endpoint.
            const label_x = if (px < 0)
                ep_px[0] + 3.0 * vp.scale
            else blk: {
                const w = h.measureLabelWidth(name, vp);
                break :blk ep_px[0] - w - 3.0 * vp.scale;
            };
            const label_y = ep_px[1] - 8.0 * vp.scale;
            h.queueLabel(labels, lalloc, name, label_x, label_y, color, 0x8000 + pi);
        }
    }
}

fn drawPrimEntry(entry: *const primitives.PrimEntry, origin: Vec2, rot: u2, flip: bool, vp: RenderViewport, color: Color, batch: *h.LineBatch) void {
    const s: Vec2 = @splat(vp.scale);
    const sym_w: f32 = @max(0.9, 1.8 * vp.scale);

    for (entry.segs()) |seg| {
        const a = h.applyRotFlip(@floatFromInt(seg.x0), @floatFromInt(seg.y0), rot, flip);
        const b = h.applyRotFlip(@floatFromInt(seg.x1), @floatFromInt(seg.y1), rot, flip);
        const pa = origin + Vec2{ a[0], a[1] } * s;
        const pb = origin + Vec2{ b[0], b[1] } * s;
        batch.addLine(pa[0], pa[1], pb[0], pb[1], sym_w, color);
    }

    for (entry.drawRects()) |rect| {
        const tl_raw = h.applyRotFlip(@floatFromInt(rect.x0), @floatFromInt(rect.y0), rot, flip);
        const br_raw = h.applyRotFlip(@floatFromInt(rect.x1), @floatFromInt(rect.y1), rot, flip);
        const tl = origin + Vec2{ @min(tl_raw[0], br_raw[0]), @min(tl_raw[1], br_raw[1]) } * s;
        const br = origin + Vec2{ @max(tl_raw[0], br_raw[0]), @max(tl_raw[1], br_raw[1]) } * s;
        batch.addRectOutline(tl, br, sym_w, color);
    }

    // Circles and arcs still emit their own render commands: each is a
    // ~16–64 point closed path that dvui's Path.stroke already batches into
    // one renderTriangles call per shape, and they're rare enough that
    // adding them to the line quad batch would cost more than it saves.
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
}

fn drawGenericBox(origin: Vec2, rot: u2, flip: bool, vp: RenderViewport, color: Color, batch: *h.LineBatch, sd: core.SymData, labels: *h.LabelList, lalloc: std.mem.Allocator) void {
    const s: Vec2 = @splat(vp.scale);
    const sym_w: f32 = @max(0.9, 1.8 * vp.scale);

    if (sd.pins.len == 0) {
        // No pin data — fall back to featureless 50x50 box.
        const corners = [4][2]f32{ .{ -25, -25 }, .{ 25, -25 }, .{ 25, 25 }, .{ -25, 25 } };
        inline for (0..4) |ci| {
            const a = h.applyRotFlip(corners[ci][0], corners[ci][1], rot, flip);
            const b = h.applyRotFlip(corners[(ci + 1) % 4][0], corners[(ci + 1) % 4][1], rot, flip);
            const pa = origin + Vec2{ a[0], a[1] } * s;
            const pb = origin + Vec2{ b[0], b[1] } * s;
            batch.addLine(pa[0], pa[1], pb[0], pb[1], sym_w, color);
        }
        return;
    }

    // Auto-size box from pin bounding box.
    var min_x: i32 = std.math.maxInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var max_y: i32 = std.math.minInt(i32);
    for (sd.pins) |pin| {
        min_x = @min(min_x, pin.x);
        min_y = @min(min_y, pin.y);
        max_x = @max(max_x, pin.x);
        max_y = @max(max_y, pin.y);
    }
    // Add padding around pin extremes for the box body.
    const pad: i32 = 10;
    const half_w: f32 = @floatFromInt(@max(@divTrunc(max_x - min_x, 2) + pad, 25));
    const half_h: f32 = @floatFromInt(@max(@divTrunc(max_y - min_y, 2) + pad, 25));

    // Draw box outline.
    const box_corners = [4][2]f32{
        .{ -half_w, -half_h },
        .{ half_w, -half_h },
        .{ half_w, half_h },
        .{ -half_w, half_h },
    };
    inline for (0..4) |ci| {
        const a = h.applyRotFlip(box_corners[ci][0], box_corners[ci][1], rot, flip);
        const b = h.applyRotFlip(box_corners[(ci + 1) % 4][0], box_corners[(ci + 1) % 4][1], rot, flip);
        const pa = origin + Vec2{ a[0], a[1] } * s;
        const pb = origin + Vec2{ b[0], b[1] } * s;
        batch.addLine(pa[0], pa[1], pb[0], pb[1], sym_w, color);
    }

    // Draw pin stubs from box edge to pin position.
    for (sd.pins, 0..) |pin, pi| {
        const px: f32 = @floatFromInt(pin.x);
        const py: f32 = @floatFromInt(pin.y);
        const pp = h.applyRotFlip(px, py, rot, flip);
        const pp_px = origin + Vec2{ pp[0], pp[1] } * s;

        // Stub from nearest box edge to pin.
        const edge_x: f32 = if (pin.x < 0) -half_w else half_w;
        const ep = h.applyRotFlip(edge_x, py, rot, flip);
        const ep_px = origin + Vec2{ ep[0], ep[1] } * s;
        batch.addLine(ep_px[0], ep_px[1], pp_px[0], pp_px[1], sym_w, color);

        // Pin label inside box edge.
        if (vp.scale >= 0.3 and pin.name.len > 0) {
            const label_x = if (pin.x < 0)
                ep_px[0] + 3.0 * vp.scale
            else blk: {
                const w = h.measureLabelWidth(pin.name, vp);
                break :blk ep_px[0] - w - 3.0 * vp.scale;
            };
            const label_y = ep_px[1] - 8.0 * vp.scale;
            h.queueLabel(labels, lalloc, pin.name, label_x, label_y, color, 0x9000 + pi);
        }
    }
}

fn drawSymbolGeometry(sch: *const Schemify, vp: RenderViewport, sym_w: f32, pal: types.Palette, batch: *h.LineBatch, labels: *h.LabelList, lalloc: std.mem.Allocator) void {
    if (sch.lines.len > 0) {
        const lx0 = sch.lines.items(.x0);
        const ly0 = sch.lines.items(.y0);
        const lx1 = sch.lines.items(.x1);
        const ly1 = sch.lines.items(.y1);
        for (0..sch.lines.len) |i| {
            const a = vp_mod.w2p(.{ lx0[i], ly0[i] }, vp);
            const b = vp_mod.w2p(.{ lx1[i], ly1[i] }, vp);
            batch.addLine(a[0], a[1], b[0], b[1], sym_w, pal.symbol_line);
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
            batch.addRectOutline(tl, br, sym_w, pal.symbol_line);
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
        const pdirs = sch.pins.items(.dir);
        const pin_arm: f32 = @max(3.0, 4.0 * @min(vp.scale, 2.0));
        for (0..sch.pins.len) |i| {
            const p = vp_mod.w2p(.{ px[i], py[i] }, vp);
            batch.addLine(p[0] - pin_arm, p[1], p[0] + pin_arm, p[1], 1.0, pal.inst_pin);
            batch.addLine(p[0], p[1] - pin_arm, p[0], p[1] + pin_arm, 1.0, pal.inst_pin);
            // Directional symbol: replace plain dot with direction-appropriate shape.
            drawPinSymbol(batch, p, pdirs[i], true, pin_arm * 0.75, pal.wire_endpoint);
            if (vp.scale >= 0.3 and pname[i].len > 0) {
                h.queueLabel(labels, lalloc, pname[i], p[0] + 8.0 * vp.scale, p[1] - 14.0 * vp.scale, pal.inst_pin, i);
            }
        }
    }
}

fn drawAutoSymbolBox(sch: *const Schemify, vp: RenderViewport, sym_w: f32, pal: types.Palette, batch: *h.LineBatch, labels: *h.LabelList, lalloc: std.mem.Allocator) void {
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
    batch.addLine(tl[0], tl[1], tr[0], tr[1], sym_w, pal.symbol_line);
    batch.addLine(tr[0], tr[1], br[0], br[1], sym_w, pal.symbol_line);
    batch.addLine(br[0], br[1], bl[0], bl[1], sym_w, pal.symbol_line);
    batch.addLine(bl[0], bl[1], tl[0], tl[1], sym_w, pal.symbol_line);

    if (vp.scale >= 0.2) {
        const cx = vp_mod.w2p(.{ @divTrunc(box_w, 2), @divTrunc(box_h, 2) }, vp);
        h.queueLabel(labels, lalloc, sch.name, cx[0] - 40.0, cx[1] - 8.0, pal.symbol_line, 50000);
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
            batch.addLine(stub_start[0], stub_start[1], stub_end[0], stub_end[1], sym_w, pal.symbol_line);
            // Directional symbol at wire endpoint (stub_start = external connection point).
            drawPinSymbol(batch, stub_start, dirs[i], true, pin_arm * 0.75, pal.wire_endpoint);
            if (vp.scale >= 0.3 and pname[i].len > 0) {
                h.queueLabel(labels, lalloc, pname[i], stub_end[0] + 4.0 * vp.scale, stub_end[1] - 12.0 * vp.scale, pal.inst_pin, i);
            }
        } else {
            const stub_start = vp_mod.w2p(.{ box_w, pin_y }, vp);
            const stub_end = vp_mod.w2p(.{ box_w + stub_len, pin_y }, vp);
            batch.addLine(stub_start[0], stub_start[1], stub_end[0], stub_end[1], sym_w, pal.symbol_line);
            // Directional symbol at wire endpoint (stub_end = external connection point).
            drawPinSymbol(batch, stub_end, dirs[i], false, pin_arm * 0.75, pal.wire_endpoint);
            if (vp.scale >= 0.3 and pname[i].len > 0) {
                h.queueLabel(labels, lalloc, pname[i], stub_start[0] - 60.0 * vp.scale, stub_start[1] - 12.0 * vp.scale, pal.inst_pin, i);
            }
        }
    }
}

