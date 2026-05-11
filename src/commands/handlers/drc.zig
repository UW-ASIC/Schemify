//! DRC — Design Rule Checks.

const std = @import("std");
const core = @import("core");
const h = @import("helpers.zig");
const Immediate = h.Immediate;

pub fn handleDRC(imm: Immediate, state: anytype) void {
    switch (imm) {
        .check_duplicate_names => checkDuplicateNames(state),
        .check_dangling_nets => checkDanglingNets(state),
        .check_overlapping_instances => checkOverlappingInstances(state),
        .auto_rename_duplicates => autoRenameDuplicates(state),
        .check_pin_mismatch => checkPinMismatch(state),
        .run_all_checks => {
            checkDuplicateNames(state);
            checkDanglingNets(state);
            checkOverlappingInstances(state);
            checkPinMismatch(state);
        },
        else => {},
    }
}

/// O(n^2) scan for instances sharing the same name.
fn checkDuplicateNames(state: anytype) void {
    const fio = state.active() orelse return;
    const names = fio.sch.instances.items(.name);
    var dupes: u32 = 0;
    // Simple O(n^2) -- fine for typical schematics (<1000 instances)
    for (0..fio.sch.instances.len) |i| {
        if (names[i].len == 0) continue;
        for (i + 1..fio.sch.instances.len) |j| {
            if (std.mem.eql(u8, names[i], names[j])) {
                dupes += 1;
                break; // Count each duplicate name once
            }
        }
    }
    var buf: [64]u8 = undefined;
    if (dupes > 0) {
        const msg = std.fmt.bufPrint(&buf, "DRC: {d} duplicate name(s) found", .{dupes}) catch "DRC: duplicates found";
        state.setStatusBuf(msg);
    } else state.setStatus("DRC: no duplicate names");
}

/// Fix duplicate names by appending a counter suffix.
fn autoRenameDuplicates(state: anytype) void {
    const fio = state.active() orelse return;
    const names = fio.sch.instances.items(.name);
    var fixed: u32 = 0;

    for (0..fio.sch.instances.len) |i| {
        if (names[i].len == 0) continue;
        var is_dup = false;
        for (0..i) |j| {
            if (std.mem.eql(u8, names[i], names[j])) {
                is_dup = true;
                break;
            }
        }
        if (is_dup) {
            // Generate new name: first char of old name + counter
            var name_buf: [32]u8 = undefined;
            const pfx = if (names[i].len > 0) names[i][0] else 'X';
            const counter: u32 = @intCast(fio.sch.instances.len + fixed + 1);
            const new_name = std.fmt.bufPrint(&name_buf, "{c}{d}", .{ pfx, counter }) catch continue;
            // Dupe the name into the arena
            names[i] = fio.alloc.dupe(u8, new_name) catch continue;
            fixed += 1;
        }
    }

    var buf: [64]u8 = undefined;
    if (fixed > 0) {
        fio.dirty = true;
        const msg = std.fmt.bufPrint(&buf, "DRC: renamed {d} duplicate(s)", .{fixed}) catch "DRC: renamed duplicates";
        state.setStatusBuf(msg);
    } else state.setStatus("DRC: no duplicates to fix");
}

/// Find wire endpoints not connected to any other wire endpoint or instance pin.
fn checkDanglingNets(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const x0s = sch.wires.items(.x0);
    const y0s = sch.wires.items(.y0);
    const x1s = sch.wires.items(.x1);
    const y1s = sch.wires.items(.y1);

    var dangling: u32 = 0;

    for (0..sch.wires.len) |i| {
        // Check endpoint 0
        if (!endpointConnected(sch, x0s[i], y0s[i], i)) dangling += 1;
        // Check endpoint 1
        if (!endpointConnected(sch, x1s[i], y1s[i], i)) dangling += 1;
    }

    var buf: [64]u8 = undefined;
    if (dangling > 0) {
        const msg = std.fmt.bufPrint(&buf, "DRC: {d} dangling endpoint(s)", .{dangling}) catch "DRC: dangling nets found";
        state.setStatusBuf(msg);
    } else state.setStatus("DRC: no dangling nets");
}

fn endpointConnected(sch: anytype, px: i32, py: i32, skip_wire: usize) bool {
    // Check against other wire endpoints
    const x0s = sch.wires.items(.x0);
    const y0s = sch.wires.items(.y0);
    const x1s = sch.wires.items(.x1);
    const y1s = sch.wires.items(.y1);
    for (0..sch.wires.len) |j| {
        if (j == skip_wire) continue;
        if ((x0s[j] == px and y0s[j] == py) or (x1s[j] == px and y1s[j] == py)) return true;
    }
    // Check against instance positions (approximate -- no pin data needed for basic check)
    const ixs = sch.instances.items(.x);
    const iys = sch.instances.items(.y);
    for (0..sch.instances.len) |k| {
        if (ixs[k] == px and iys[k] == py) return true;
    }
    // Check against pin positions from prim cache with rotation/flip applied
    const inst_flags = sch.instances.items(.flags);
    for (0..sch.instances.len) |k| {
        if (k >= sch.prim_cache.len) continue;
        const entry = sch.prim_cache[k] orelse continue;
        for (entry.pin_positions) |pin| {
            const wp = core.helpers.applyRotFlip(pin.x, pin.y, inst_flags[k].rot, inst_flags[k].flip, ixs[k], iys[k]);
            if (wp.x == px and wp.y == py) return true;
        }
    }
    return false;
}

/// O(n^2) scan for instances at the exact same position.
fn checkOverlappingInstances(state: anytype) void {
    const fio = state.active() orelse return;
    const xs = fio.sch.instances.items(.x);
    const ys = fio.sch.instances.items(.y);
    var overlaps: u32 = 0;

    for (0..fio.sch.instances.len) |i| {
        for (i + 1..fio.sch.instances.len) |j| {
            if (xs[i] == xs[j] and ys[i] == ys[j]) {
                overlaps += 1;
                break;
            }
        }
    }

    var buf: [64]u8 = undefined;
    if (overlaps > 0) {
        const msg = std.fmt.bufPrint(&buf, "DRC: {d} overlapping instance(s)", .{overlaps}) catch "DRC: overlaps found";
        state.setStatusBuf(msg);
    } else state.setStatus("DRC: no overlapping instances");
}

/// Check for instances where connection count doesn't match symbol pin count.
fn checkPinMismatch(state: anytype) void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    var mismatches: u32 = 0;
    const conn_counts = sch.instances.items(.conn_count);
    for (0..sch.instances.len) |i| {
        if (i >= sch.sym_data.items.len) continue;
        const sd = sch.sym_data.items[i];
        if (sd.pins.len == 0) continue;
        if (conn_counts[i] != sd.pins.len) mismatches += 1;
    }
    var buf: [64]u8 = undefined;
    if (mismatches > 0) {
        const msg = std.fmt.bufPrint(&buf, "DRC: {d} pin mismatch(es)", .{mismatches}) catch "DRC: mismatches found";
        state.setStatusBuf(msg);
    } else state.setStatus("DRC: no pin mismatches");
}
