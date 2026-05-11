//! Hierarchy navigation handlers — descend, ascend, edit in new tab,
//! make symbol/schematic from each other.

const std = @import("std");
const core = @import("core");
const h = @import("helpers.zig");
const Immediate = h.Immediate;
const resolveSymbolFile = h.resolveSymbolFile;
const pathExists = h.pathExists;

pub fn handleHierarchy(imm: Immediate, state: anytype) void {
    switch (imm) {
        .descend_schematic => descendInto(state, ".chn", "schematic"),
        .descend_symbol => descendInto(state, ".chn_prim", "symbol"),
        .ascend => {
            const entry = state.hierarchy_stack.pop() orelse {
                state.setStatus("Already at top level");
                return;
            };
            if (entry.doc_idx < state.documents.items.len) {
                state.active_idx = @intCast(entry.doc_idx);
                if (state.active()) |fd| fd.selection.clear();
                state.setStatus("Ascended to parent");
            } else state.setStatus("Parent document no longer open");
        },
        .edit_in_new_tab => {
            const idx = firstSelectedInst(state) orelse {
                state.setStatus("Select an instance first");
                return;
            };
            const fio = state.active() orelse return;
            const inst = fio.sch.instances.get(idx);
            var buf: [512]u8 = undefined;
            const path = resolveSymbolFile(state, fio, inst.symbol, ".chn", &buf) orelse
                resolveSymbolFile(state, fio, inst.symbol, ".chn_prim", &buf) orelse {
                state.setStatus("No file found for this symbol");
                return;
            };
            state.openPath(path) catch { state.setStatus("Failed to open in new tab"); return; };
            state.setStatus("Opened in new tab");
        },
        .insert_from_library => { state.open_library_browser = true; },
        .open_file_explorer => { state.open_file_explorer = !state.open_file_explorer; },
        .make_symbol_from_schematic => makeSymbolFromSchematic(state),
        .make_schematic_from_symbol => makeSchematicFromSymbol(state),
        else => {},
    }
}

fn firstSelectedInst(state: anytype) ?usize {
    const fio = state.active() orelse return null;
    if (fio.selection.instances.bit_length == 0) return null;
    var it = fio.selection.instances.iterator(.{});
    return it.next();
}

fn descendInto(state: anytype, comptime ext: []const u8, comptime kind: []const u8) void {
    const idx = firstSelectedInst(state) orelse {
        state.setStatus("Select an instance to descend into");
        return;
    };
    const fio = state.active() orelse return;
    const inst = fio.sch.instances.get(idx);
    var buf: [512]u8 = undefined;
    const path = resolveSymbolFile(state, fio, inst.symbol, ext, &buf) orelse {
        state.setStatus("No " ++ kind ++ " found for this symbol");
        return;
    };
    state.hierarchy_stack.append(state.allocator(), .{
        .doc_idx = state.active_idx,
        .instance_idx = idx,
    }) catch { state.setStatus("Hierarchy stack full"); return; };
    state.openPath(path) catch {
        _ = state.hierarchy_stack.pop();
        state.setStatus("Failed to open " ++ kind);
        return;
    };
    state.setStatus("Descended into " ++ kind);
}

fn makeSymbolFromSchematic(state: anytype) void {
    const fio = state.active() orelse { state.setStatus("No active document"); return; };
    const sch = &fio.sch;
    const a = fio.alloc;

    // Collect pin instances from schematic
    const ikind = sch.instances.items(.kind);
    const iname = sch.instances.items(.name);

    var in_pins: [64][]const u8 = undefined;
    var out_pins: [64][]const u8 = undefined;
    var io_pins: [64][]const u8 = undefined;
    var in_count: usize = 0;
    var out_count: usize = 0;
    var io_count: usize = 0;

    for (0..sch.instances.len) |i| {
        switch (ikind[i]) {
            .input_pin => {
                if (in_count < 64) { in_pins[in_count] = iname[i]; in_count += 1; }
            },
            .output_pin => {
                if (out_count < 64) { out_pins[out_count] = iname[i]; out_count += 1; }
            },
            .inout_pin, .lab_pin => {
                if (io_count < 64) { io_pins[io_count] = iname[i]; io_count += 1; }
            },
            else => {},
        }
    }

    const total_pins = in_count + out_count + io_count;
    if (total_pins == 0) { state.setStatus("No I/O pins found in schematic"); return; }

    // Clear existing symbol geometry -- free owned strings first
    for (sch.pins.items(.name)) |n| if (n.len > 0) a.free(@constCast(n));
    sch.pins.len = 0;
    for (sch.texts.items(.content)) |c| if (c.len > 0) a.free(@constCast(c));
    sch.texts.len = 0;
    sch.lines.len = 0;
    sch.rects.len = 0;
    sch.circles.len = 0;
    sch.arcs.len = 0;

    // Calculate box dimensions
    const pin_spacing: i32 = 30;
    const pin_stub: i32 = 20;
    const max_side: i32 = @intCast(@max(in_count, out_count));
    const io_span: i32 = @intCast(io_count);
    const box_h: i32 = @max(max_side, 1) * pin_spacing + pin_spacing;
    const box_w: i32 = @max(@max(io_span, 3) * pin_spacing + pin_spacing, 120);
    const x0: i32 = -@divTrunc(box_w, 2);
    const y0: i32 = -@divTrunc(box_h, 2);
    const x1: i32 = @divTrunc(box_w, 2);
    const y1: i32 = @divTrunc(box_h, 2);

    // Add box rectangle
    sch.rects.append(a, .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .layer = 4 }) catch return;

    // Add input pins (left side)
    for (0..in_count) |pi| {
        const py: i32 = y0 + pin_spacing + @as(i32, @intCast(pi)) * pin_spacing;
        sch.lines.append(a, .{ .x0 = x0 - pin_stub, .y0 = py, .x1 = x0, .y1 = py, .layer = 4 }) catch continue;
        sch.drawPin(a, .{ .name = in_pins[pi], .x = x0 - pin_stub, .y = py, .dir = .input }) catch continue;
    }

    // Add output pins (right side)
    for (0..out_count) |pi| {
        const py: i32 = y0 + pin_spacing + @as(i32, @intCast(pi)) * pin_spacing;
        sch.lines.append(a, .{ .x0 = x1, .y0 = py, .x1 = x1 + pin_stub, .y1 = py, .layer = 4 }) catch continue;
        sch.drawPin(a, .{ .name = out_pins[pi], .x = x1 + pin_stub, .y = py, .dir = .output }) catch continue;
    }

    // Add inout pins (bottom)
    for (0..io_count) |pi| {
        const px: i32 = x0 + pin_spacing + @as(i32, @intCast(pi)) * pin_spacing;
        sch.lines.append(a, .{ .x0 = px, .y0 = y1, .x1 = px, .y1 = y1 + pin_stub, .layer = 4 }) catch continue;
        sch.drawPin(a, .{ .name = io_pins[pi], .x = px, .y = y1 + pin_stub, .dir = .inout }) catch continue;
    }

    // Add cell name label at top
    const cell_name: []const u8 = blk: {
        if (sch.name.len > 0) break :blk sch.name;
        const path = switch (fio.origin) {
            .chn_file => |p| p,
            else => break :blk "untitled",
        };
        const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| path[idx + 1 ..] else path;
        // Strip known extensions
        inline for (.{ ".chn_prim", ".chn_tb", ".chn" }) |ext| {
            if (std.mem.endsWith(u8, base, ext)) break :blk base[0 .. base.len - ext.len];
        }
        break :blk base;
    };
    sch.drawText(a, .{ .content = cell_name, .x = 0, .y = y0 - 10, .layer = 4, .size = 12, .rotation = 0 }) catch {};

    fio.dirty = true;
    state.setStatus("Symbol generated from schematic");
}

fn makeSchematicFromSymbol(state: anytype) void {
    const fio = state.active() orelse { state.setStatus("No active document"); return; };
    const sch = &fio.sch;
    const a = fio.alloc;

    if (sch.pins.len == 0) { state.setStatus("No pins in symbol"); return; }

    const pin_names = sch.pins.items(.name);
    const pin_dirs = sch.pins.items(.dir);

    // Place pin instances in a column layout: inputs left, outputs right, inout center
    const spacing: i32 = 60;
    var in_y: i32 = 0;
    var out_y: i32 = 0;
    var io_y: i32 = 0;

    for (0..sch.pins.len) |i| {
        const kind: core.types.DeviceKind = switch (pin_dirs[i]) {
            .input => .input_pin,
            .output => .output_pin,
            else => .inout_pin,
        };
        const sym_name: []const u8 = switch (kind) {
            .input_pin => "ipin",
            .output_pin => "opin",
            else => "iopin",
        };
        const pos_x: i32 = switch (pin_dirs[i]) {
            .input, .power, .ground => -200,
            .output => 200,
            .inout => 0,
        };
        const pos_y: i32 = switch (pin_dirs[i]) {
            .input, .power, .ground => blk: { const y = in_y; in_y += spacing; break :blk y; },
            .output => blk: { const y = out_y; out_y += spacing; break :blk y; },
            .inout => blk: { const y = io_y; io_y += spacing; break :blk y; },
        };

        _ = sch.addInstanceWithKind(a, pin_names[i], sym_name, pos_x, pos_y, kind) catch continue;
    }

    fio.dirty = true;
    state.setStatus("Pin instances created from symbol");
}
