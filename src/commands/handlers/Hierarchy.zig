//! Hierarchy command handlers.

const std = @import("std");
const Vfs = @import("utility").Vfs;
const Immediate = @import("../utils/command.zig").Immediate;

pub const Error = error{};

pub fn handle(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .descend_schematic => descendInto(state, ".chn",      "schematic"),
        .descend_symbol    => descendInto(state, ".chn_prim", "symbol"),

        .ascend => {
            const entry = state.hierarchy_stack.pop() orelse {
                state.setStatus("Already at top level");
                return;
            };
            if (entry.doc_idx < state.documents.items.len) {
                state.active_idx = @intCast(entry.doc_idx);
                if (state.active()) |fd| fd.selection.clear();
                state.setStatus("Ascended to parent");
            } else {
                state.setStatus("Parent document no longer open");
            }
        },

        .edit_in_new_tab => {
            const idx = firstSelectedInst(state) orelse {
                state.setStatus("Select an instance first");
                return;
            };
            const fio = state.active() orelse return;
            const inst = fio.sch.instances.get(idx);
            var buf: [512]u8 = undefined;
            const path = resolveFile(state, fio, inst.symbol, ".chn", &buf) orelse
                resolveFile(state, fio, inst.symbol, ".chn_prim", &buf) orelse {
                state.setStatus("No file found for this symbol");
                return;
            };
            state.openPath(path) catch {
                state.setStatusErr("Failed to open in new tab");
                return;
            };
            state.setStatus("Opened in new tab");
        },

        .make_symbol_from_schematic  => saveVariant(state, &.{".chn_prim"}, "Created symbol from schematic"),
        .make_schematic_from_symbol  => saveVariant(state, &.{".chn"},       "Created schematic from symbol"),
        .make_schem_and_sym          => saveVariant(state, &.{ ".chn", ".chn_prim" }, "Created schematic and symbol"),

        .insert_from_library => state.open_library_browser = true,
        .open_file_explorer  => state.open_file_explorer = !state.open_file_explorer,
        else => unreachable,
    }
}

// ── Private helpers ──────────────────────────────────────────────────────────

fn firstSelectedInst(state: anytype) ?usize {
    const sel_doc = state.active() orelse return null;
    const sel = &sel_doc.selection.instances;
    if (sel.bit_length == 0) return null;
    var it = sel.iterator(.{});
    return it.next();
}

/// Descend into a selected instance's schematic or symbol file.
fn descendInto(state: anytype, comptime ext: []const u8, comptime kind: []const u8) void {
    const idx = firstSelectedInst(state) orelse {
        state.setStatus("Select an instance to descend into");
        return;
    };
    const fio = state.active() orelse return;
    const inst = fio.sch.instances.get(idx);
    var buf: [512]u8 = undefined;
    const path = resolveFile(state, fio, inst.symbol, ext, &buf) orelse {
        state.setStatus("No " ++ kind ++ " found for this symbol");
        return;
    };
    state.hierarchy_stack.append(state.allocator(), .{
        .doc_idx = state.active_idx,
        .instance_idx = idx,
    }) catch { state.setStatusErr("Hierarchy stack full"); return; };
    state.openPath(path) catch {
        _ = state.hierarchy_stack.pop();
        state.setStatusErr("Failed to open " ++ kind);
        return;
    };
    state.setStatus("Descended into " ++ kind);
}

/// Save the active document under one or more derived extensions.
fn saveVariant(state: anytype, comptime exts: []const []const u8, comptime ok_msg: []const u8) void {
    const fio = state.active() orelse { state.setStatus("No active document"); return; };
    const base_path = switch (fio.origin) {
        .chn_file => |p| p,
        else => { state.setStatus("Save the document first"); return; },
    };
    const stem_end = std.mem.lastIndexOf(u8, base_path, ".chn") orelse base_path.len;
    inline for (exts) |ext| {
        var buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}{s}", .{ base_path[0..stem_end], ext }) catch {
            state.setStatusErr("Path too long"); return;
        };
        fio.saveAsChn(path) catch {
            state.setStatusErr("Failed to save " ++ ext); return;
        };
    }
    state.setStatus(ok_msg);
}

/// Try to find a file for the given symbol name + extension.
fn resolveFile(state: anytype, fio: anytype, symbol: []const u8, ext: []const u8, buf: *[512]u8) ?[]const u8 {
    if (std.mem.endsWith(u8, symbol, ext)) {
        if (Vfs.exists(symbol)) return symbol;
    }
    const dir: []const u8 = switch (fio.origin) {
        .chn_file => |p| std.fs.path.dirname(p) orelse ".",
        else => ".",
    };
    if (std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ dir, symbol, ext })) |path| {
        if (Vfs.exists(path)) return path;
    } else |_| {}
    if (std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ state.project_dir, symbol, ext })) |path| {
        if (Vfs.exists(path)) return path;
    } else |_| {}
    return null;
}
