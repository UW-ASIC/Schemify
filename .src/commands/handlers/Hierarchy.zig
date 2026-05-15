//! Hierarchy command handlers — descend, ascend, symbol/schematic generation.

const std = @import("std");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32;
const types = @import("../types.zig");
const Immediate = types.Immediate;

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
    if (is_wasm) { state.setStatus("Not available in browser"); return; }
    const fio = state.active() orelse { state.setStatus("No active document"); return; };
    const sch = &fio.sch;

    const base_path: []const u8 = switch (fio.origin) {
        .chn_file => |p| p,
        else => { state.setStatus("Save the schematic first"); return; },
    };
    var path_buf: [512]u8 = undefined;
    const prim_path = std.fmt.bufPrint(&path_buf, "{s}_prim", .{base_path}) catch {
        state.setStatus("Path too long");
        return;
    };

    const ikind = sch.instances.items(.kind);
    const iname = sch.instances.items(.name);
    const ixx = sch.instances.items(.x);
    const iyy = sch.instances.items(.y);

    var pin_count: usize = 0;
    for (0..sch.instances.len) |i| if (ikind[i].isLabel()) { pin_count += 1; };
    if (pin_count == 0) { state.setStatus("No I/O pins found in schematic"); return; }

    const alloc = state.allocator();
    var buf_list: std.ArrayListUnmanaged(u8) = .{};
    defer buf_list.deinit(alloc);
    const w = buf_list.writer(alloc);

    const stem = std.fs.path.stem(base_path);

    w.writeAll("chn_prim 1\n\nSYMBOL ") catch { state.setStatus("Out of memory"); return; };
    w.writeAll(stem) catch return;
    w.writeByte('\n') catch return;
    w.writeAll("  desc: Auto-generated symbol\n") catch return;

    var lo_x: i32 = std.math.maxInt(i32);
    var lo_y: i32 = std.math.maxInt(i32);
    var hi_x: i32 = std.math.minInt(i32);
    var hi_y: i32 = std.math.minInt(i32);
    for (0..sch.instances.len) |i| {
        if (!ikind[i].isLabel()) continue;
        lo_x = @min(lo_x, ixx[i]);
        lo_y = @min(lo_y, iyy[i]);
        hi_x = @max(hi_x, ixx[i]);
        hi_y = @max(hi_y, iyy[i]);
    }
    lo_x -= 40; lo_y -= 40; hi_x += 40; hi_y += 40;

    w.writeAll("  pins:\n") catch return;
    for (0..sch.instances.len) |i| {
        if (!ikind[i].isLabel()) continue;
        const dir_str: []const u8 = switch (ikind[i]) {
            .input_pin => "in",
            .output_pin => "out",
            .inout_pin => "inout",
            .lab_pin => "inout",
            else => "inout",
        };
        w.print("    {s}  {s}  x={d}  y={d}\n", .{ iname[i], dir_str, ixx[i], iyy[i] }) catch return;
    }

    w.print("  drawing:\n    rect {d} {d} {d} {d}\n", .{ lo_x, lo_y, hi_x, hi_y }) catch return;

    @import("utility").platform.fs.cwd().writeFile(.{ .sub_path = prim_path, .data = buf_list.items }) catch {
        state.setStatus("Failed to write symbol file");
        return;
    };
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Symbol created: {s}", .{prim_path}) catch "Symbol created";
    state.setStatusBuf(msg);
}

fn makeSchematicFromSymbol(state: anytype) void {
    if (is_wasm) { state.setStatus("Not available in browser"); return; }
    const fio = state.active() orelse { state.setStatus("No active document"); return; };
    const sch = &fio.sch;

    if (sch.pins.len == 0) { state.setStatus("No pins defined in this symbol"); return; }

    const base_path: []const u8 = switch (fio.origin) {
        .chn_file => |p| p,
        else => { state.setStatus("Save the symbol first"); return; },
    };
    var path_buf: [512]u8 = undefined;
    const sch_path = if (std.mem.endsWith(u8, base_path, ".chn_prim"))
        std.fmt.bufPrint(&path_buf, "{s}.chn", .{base_path[0 .. base_path.len - "_prim".len]}) catch {
            state.setStatus("Path too long");
            return;
        }
    else
        std.fmt.bufPrint(&path_buf, "{s}_impl.chn", .{base_path[0 .. base_path.len - ".chn".len]}) catch {
            state.setStatus("Path too long");
            return;
        };

    if (pathExists(sch_path)) {
        state.setStatus("Schematic file already exists");
        return;
    }

    const alloc = state.allocator();
    var buf_list: std.ArrayListUnmanaged(u8) = .{};
    defer buf_list.deinit(alloc);
    const w = buf_list.writer(alloc);

    const stem_val = std.fs.path.stem(base_path);
    w.writeAll("chn 1\n\nSYMBOL ") catch { state.setStatus("Out of memory"); return; };
    w.writeAll(stem_val) catch return;
    w.writeByte('\n') catch return;

    const pn = sch.pins.items(.name);
    const pd = sch.pins.items(.dir);
    const px = sch.pins.items(.x);
    const py = sch.pins.items(.y);
    if (sch.pins.len > 0) {
        w.writeAll("  pins:\n") catch return;
        for (0..sch.pins.len) |i| {
            const dir_str: []const u8 = switch (pd[i]) {
                .input => "in", .output => "out", .inout => "inout",
                .power => "inout", .ground => "inout",
            };
            w.print("    {s}  {s}  x={d}  y={d}\n", .{ pn[i], dir_str, px[i], py[i] }) catch return;
        }
    }

    w.writeAll("\nSCHEMATIC\n  instances:\n") catch return;
    for (0..sch.pins.len) |i| {
        const kind_str: []const u8 = switch (pd[i]) {
            .input => "ipin", .output => "opin", .inout => "iopin",
            .power => "ipin", .ground => "ipin",
        };
        w.print("    {s}  {s}  x={d}  y={d}\n", .{
            pn[i], kind_str, px[i], py[i],
        }) catch return;
    }

    @import("utility").platform.fs.cwd().writeFile(.{ .sub_path = sch_path, .data = buf_list.items }) catch {
        state.setStatus("Failed to write schematic file");
        return;
    };

    state.openPath(sch_path) catch {
        state.setStatus("Schematic created but failed to open");
        return;
    };
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Schematic created: {s}", .{sch_path}) catch "Schematic created";
    state.setStatusBuf(msg);
}

fn pathExists(path: []const u8) bool {
    @import("utility").platform.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn resolveSymbolFile(state: anytype, fio: anytype, symbol: []const u8, ext: []const u8, buf: *[512]u8) ?[]const u8 {
    if (std.mem.endsWith(u8, symbol, ext)) {
        if (pathExists(symbol)) return symbol;
    }
    const dir: []const u8 = switch (fio.origin) {
        .chn_file => |p| std.fs.path.dirname(p) orelse ".",
        else => ".",
    };
    if (std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ dir, symbol, ext })) |path| {
        if (pathExists(path)) return path;
    } else |_| {}
    if (std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ state.project_dir, symbol, ext })) |path| {
        if (pathExists(path)) return path;
    } else |_| {}
    return null;
}
