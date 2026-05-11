//! Wire mode handlers — start wire, escape, insert primitive, set layer,
//! interactive copy, rubber-band move, and wire operations (break, join, cut).

const std = @import("std");
const h = @import("helpers.zig");
const types = h.types;
const Immediate = h.Immediate;
const selInst = h.selInst;
const selWire = h.selWire;

pub fn handleStartWire(state: anytype) void {
    state.tool.wire_start = null;
    state.tool.active = .wire;
    state.setStatus("Wire mode \xe2\x80\x94 click to start");
}

pub fn handleRubberBandMove(state: anytype) void {
    state.tool.active = .move;
    state.setStatus("Rubber-band move");
}

pub fn handleEscapeMode(state: anytype) void {
    state.tool.wire_start = null;
    state.tool.active = .select;
    if (state.active()) |fio| fio.selection.clear();
    state.setStatus("Ready");
}

pub fn handleInsertPrimitive(kind: types.PrimitiveKind, state: anytype) void {
    const fio = state.active() orelse return;
    const pos = state.gui.hot.canvas.cursor_world;
    const kind_name = kind.kindName();
    const pfx = kind.prefix();

    // Count existing instances with same prefix to generate unique name
    var counter: u32 = 1;
    const names = fio.sch.instances.items(.name);
    for (0..fio.sch.instances.len) |i| {
        if (names[i].len > 0 and names[i][0] == pfx) counter += 1;
    }

    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{c}{d}", .{ pfx, counter }) catch "X1";

    _ = fio.sch.addInstance(fio.alloc, name, kind_name, pos[0], pos[1]) catch {
        state.setStatus("Failed to insert primitive");
        return;
    };
    fio.dirty = true;
    state.setStatus("Inserted primitive");
}

pub fn handleSetLayer(layer: u4, state: anytype) void {
    state.cmd_flags.current_layer = layer;
    var buf: [16]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Layer {d}", .{layer}) catch "Layer set";
    state.setStatusBuf(msg);
}

pub fn handleInteractiveCopy(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const sa = fio.alloc;
    const before_len = sch.instances.len;
    var copied: usize = 0;
    for (0..before_len) |i| {
        if (!selInst(fio, i)) continue;
        const copy = sch.instances.get(i);
        sch.instances.append(sa, copy) catch continue;
        copied += 1;
    }
    if (copied == 0) { state.setStatus("Nothing selected to copy"); return; }
    // Clear old selection, select only the new copies
    fio.selection.clear();
    fio.selection.ensureCapacity(sa, sch.instances.len, sch.wires.len, false) catch {};
    for (before_len..sch.instances.len) |i| {
        fio.selection.instances.set(i);
    }
    fio.dirty = true;
    // Enter move mode so the copies follow the cursor
    state.tool.active = .move;
    state.setStatus("Copy mode \xe2\x80\x94 click to place");
}

// -- Wire operations: break, join, cut ----------------------------------------

pub fn handleWireOps(imm: Immediate, state: anytype) void {
    switch (imm) {
        .break_wires_at_junctions => breakWiresAtJunctions(state),
        .join_collinear_wires => joinCollinearWires(state),
        .cut_wire_at_cursor => cutWireAtCursor(state),
        .autotrim_wires => {
            breakWiresAtJunctions(state);
            joinCollinearWires(state);
            state.setStatus("Wires auto-trimmed");
        },
        else => {},
    }
}

/// Test whether point (px,py) lies strictly interior to the axis-aligned
/// or diagonal segment (x0,y0)-(x1,y1). Uses integer cross-product for
/// collinearity and bounding-box for containment -- zero floating point.
fn pointOnSegment(px: i32, py: i32, x0: i32, y0: i32, x1: i32, y1: i32) bool {
    const cross = @as(i64, px - x0) * @as(i64, y1 - y0) - @as(i64, py - y0) * @as(i64, x1 - x0);
    if (cross != 0) return false;
    return px >= @min(x0, x1) and px <= @max(x0, x1) and
        py >= @min(y0, y1) and py <= @max(y0, y1);
}

/// Try to merge two collinear, overlapping/touching segments.
/// On success, wire `i` is extended to cover both and returns true (caller
/// should mark `j` for deletion). Only handles axis-aligned (H/V) wires.
fn tryMergeCollinear(x0s: []i32, y0s: []i32, x1s: []i32, y1s: []i32, i: usize, j: usize) bool {
    // Both horizontal (same Y)
    if (y0s[i] == y1s[i] and y0s[j] == y1s[j] and y0s[i] == y0s[j]) {
        const imin = @min(x0s[i], x1s[i]);
        const imax = @max(x0s[i], x1s[i]);
        const jmin = @min(x0s[j], x1s[j]);
        const jmax = @max(x0s[j], x1s[j]);
        if (jmin <= imax and jmax >= imin) {
            x0s[i] = @min(imin, jmin);
            x1s[i] = @max(imax, jmax);
            return true;
        }
    }
    // Both vertical (same X)
    if (x0s[i] == x1s[i] and x0s[j] == x1s[j] and x0s[i] == x0s[j]) {
        const imin = @min(y0s[i], y1s[i]);
        const imax = @max(y0s[i], y1s[i]);
        const jmin = @min(y0s[j], y1s[j]);
        const jmax = @max(y0s[j], y1s[j]);
        if (jmin <= imax and jmax >= imin) {
            y0s[i] = @min(imin, jmin);
            y1s[i] = @max(imax, jmax);
            return true;
        }
    }
    return false;
}

/// Scan all wire endpoints and instance pin positions to find junction
/// points, then split any wire that passes through a junction at its
/// interior. Stack-allocated buffers, zero heap allocations beyond
/// existing wire SoA appends.
fn breakWiresAtJunctions(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const a = fio.alloc;

    // Collect junction points into stack-allocated buffers.
    const MAX_JUNCTIONS = 4096;
    var jx: [MAX_JUNCTIONS]i32 = undefined;
    var jy: [MAX_JUNCTIONS]i32 = undefined;
    var jcount: usize = 0;

    // Wire endpoints
    const x0s = sch.wires.items(.x0);
    const y0s = sch.wires.items(.y0);
    const x1s = sch.wires.items(.x1);
    const y1s = sch.wires.items(.y1);
    for (0..sch.wires.len) |i| {
        if (jcount + 2 > MAX_JUNCTIONS) break;
        jx[jcount] = x0s[i];
        jy[jcount] = y0s[i];
        jcount += 1;
        jx[jcount] = x1s[i];
        jy[jcount] = y1s[i];
        jcount += 1;
    }

    // Instance pin positions (from prim cache)
    for (0..sch.instances.len) |i| {
        if (i >= sch.prim_cache.len) continue;
        const entry = sch.prim_cache[i] orelse continue;
        const ix = sch.instances.items(.x)[i];
        const iy = sch.instances.items(.y)[i];
        for (entry.pin_positions) |pin| {
            if (jcount >= MAX_JUNCTIONS) break;
            jx[jcount] = ix + pin.x;
            jy[jcount] = iy + pin.y;
            jcount += 1;
        }
    }

    // For each wire, check if any junction point lies strictly interior.
    // Only process wires that existed before this pass (ignore appended splits).
    var splits: usize = 0;
    var wi: usize = 0;
    const initial_len = sch.wires.len;
    while (wi < initial_len) : (wi += 1) {
        const wx0 = x0s[wi];
        const wy0 = y0s[wi];
        const wx1 = x1s[wi];
        const wy1 = y1s[wi];

        for (0..jcount) |ji| {
            const px = jx[ji];
            const py = jy[ji];
            // Skip if junction coincides with this wire's endpoints.
            if ((px == wx0 and py == wy0) or (px == wx1 and py == wy1)) continue;
            // Check if point lies on the segment interior.
            if (pointOnSegment(px, py, wx0, wy0, wx1, wy1)) {
                // Split: shorten original to (start -> junction), append (junction -> end).
                x1s[wi] = px;
                y1s[wi] = py;
                const net = sch.wires.items(.net_name)[wi];
                const bus = sch.wires.items(.bus)[wi];
                sch.wires.append(a, .{
                    .x0 = px, .y0 = py, .x1 = wx1, .y1 = wy1,
                    .net_name = net, .bus = bus,
                }) catch {};
                splits += 1;
                break; // One split per wire per pass.
            }
        }
    }
    if (splits > 0) {
        fio.dirty = true;
        state.setStatus("Broke wires at junctions");
    } else state.setStatus("No junctions found");
}

/// Find pairs of collinear, overlapping/touching wire segments (axis-aligned)
/// and merge them into single segments.
fn joinCollinearWires(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;

    const x0s = sch.wires.items(.x0);
    const y0s = sch.wires.items(.y0);
    const x1s = sch.wires.items(.x1);
    const y1s = sch.wires.items(.y1);

    // Stack-allocated deletion bitset (covers up to 512 wires).
    const MAX_WIRES = 512;
    var to_delete: [MAX_WIRES]bool = [_]bool{false} ** MAX_WIRES;
    var joins: usize = 0;

    var i: usize = 0;
    while (i < sch.wires.len) : (i += 1) {
        if (i >= MAX_WIRES or to_delete[i]) continue;
        var j: usize = i + 1;
        while (j < sch.wires.len) : (j += 1) {
            if (j >= MAX_WIRES or to_delete[j]) continue;
            if (tryMergeCollinear(x0s, y0s, x1s, y1s, i, j)) {
                to_delete[j] = true;
                joins += 1;
            }
        }
    }

    // Remove deleted wires in reverse order to keep indices stable.
    if (joins > 0) {
        var dwi = @min(sch.wires.len, MAX_WIRES);
        while (dwi > 0) {
            dwi -= 1;
            if (to_delete[dwi]) sch.wires.orderedRemove(dwi);
        }
        fio.dirty = true;
        state.setStatus("Joined collinear wires");
    } else state.setStatus("No collinear wires found");
}

/// Split the wire under the cursor into two wires at the snapped cursor
/// position. The cursor point must lie strictly interior to the segment.
fn cutWireAtCursor(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const a = fio.alloc;
    const cursor = state.gui.hot.canvas.cursor_world;
    const snap: i32 = @intFromFloat(state.tool.snap_size);

    // Snap cursor to grid.
    const cx = @divTrunc(cursor[0] + @divTrunc(snap, 2), snap) * snap;
    const cy = @divTrunc(cursor[1] + @divTrunc(snap, 2), snap) * snap;

    const x0s = sch.wires.items(.x0);
    const y0s = sch.wires.items(.y0);
    const x1s = sch.wires.items(.x1);
    const y1s = sch.wires.items(.y1);

    for (0..sch.wires.len) |idx| {
        if (pointOnSegment(cx, cy, x0s[idx], y0s[idx], x1s[idx], y1s[idx])) {
            // Don't cut at endpoints -- nothing to split.
            if ((cx == x0s[idx] and cy == y0s[idx]) or (cx == x1s[idx] and cy == y1s[idx])) continue;
            // Split: shorten original, append the remainder.
            const old_x1 = x1s[idx];
            const old_y1 = y1s[idx];
            x1s[idx] = cx;
            y1s[idx] = cy;
            const net = sch.wires.items(.net_name)[idx];
            const bus = sch.wires.items(.bus)[idx];
            sch.wires.append(a, .{
                .x0 = cx, .y0 = cy, .x1 = old_x1, .y1 = old_y1,
                .net_name = net, .bus = bus,
            }) catch {};
            fio.dirty = true;
            state.setStatus("Wire cut");
            return;
        }
    }
    state.setStatus("No wire at cursor");
}
