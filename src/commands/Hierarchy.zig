//! Hierarchy command handlers.

const std = @import("std");
const Vfs = @import("utility").Vfs;
const Immediate = @import("command.zig").Immediate;

pub const Error = error{};

pub fn handle(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .descend_schematic => {
            const idx = firstSelectedInst(state) orelse {
                state.setStatus("Select an instance to descend into");
                return;
            };
            const fio = state.active() orelse return;
            const inst = fio.sch.instances.get(idx);
            var buf: [512]u8 = undefined;
            const path = resolveFile(state, fio, inst.symbol, ".chn", &buf) orelse {
                state.setStatus("No schematic found for this symbol");
                return;
            };
            state.hierarchy_stack.append(state.allocator(), .{
                .doc_idx = state.active_idx,
                .instance_idx = idx,
            }) catch { state.setStatusErr("Hierarchy stack full"); return; };
            state.openPath(path) catch {
                _ = state.hierarchy_stack.pop();
                state.setStatusErr("Failed to open schematic");
                return;
            };
            state.setStatus("Descended into schematic");
        },
        .descend_symbol => {
            const idx = firstSelectedInst(state) orelse {
                state.setStatus("Select an instance to descend into");
                return;
            };
            const fio = state.active() orelse return;
            const inst = fio.sch.instances.get(idx);
            var buf: [512]u8 = undefined;
            const path = resolveFile(state, fio, inst.symbol, ".chn_prim", &buf) orelse {
                state.setStatus("No symbol file found");
                return;
            };
            state.hierarchy_stack.append(state.allocator(), .{
                .doc_idx = state.active_idx,
                .instance_idx = idx,
            }) catch { state.setStatusErr("Hierarchy stack full"); return; };
            state.openPath(path) catch {
                _ = state.hierarchy_stack.pop();
                state.setStatusErr("Failed to open symbol");
                return;
            };
            state.setStatus("Descended into symbol");
        },
        .ascend => {
            const entry = state.hierarchy_stack.pop() orelse {
                state.setStatus("Already at top level");
                return;
            };
            if (entry.doc_idx < state.documents.items.len) {
                state.active_idx = @intCast(entry.doc_idx);
                state.selection.clear();
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
        .make_symbol_from_schematic => {
            const fio = state.active() orelse { state.setStatus("No active document"); return; };
            const base_path = switch (fio.origin) {
                .chn_file => |p| p,
                else => { state.setStatus("Save the schematic first"); return; },
            };
            const stem_end = std.mem.lastIndexOf(u8, base_path, ".chn") orelse base_path.len;
            var buf: [512]u8 = undefined;
            const sym_path = std.fmt.bufPrint(&buf, "{s}.chn_prim", .{base_path[0..stem_end]}) catch {
                state.setStatusErr("Path too long"); return;
            };
            fio.saveAsChn(sym_path) catch {
                state.setStatusErr("Failed to create symbol"); return;
            };
            state.setStatus("Created symbol from schematic");
        },
        .make_schematic_from_symbol => {
            const fio = state.active() orelse { state.setStatus("No active document"); return; };
            const base_path = switch (fio.origin) {
                .chn_file => |p| p,
                else => { state.setStatus("Save the document first"); return; },
            };
            const stem_end = std.mem.lastIndexOf(u8, base_path, ".chn") orelse base_path.len;
            var buf: [512]u8 = undefined;
            const sch_path = std.fmt.bufPrint(&buf, "{s}.chn", .{base_path[0..stem_end]}) catch {
                state.setStatusErr("Path too long"); return;
            };
            fio.saveAsChn(sch_path) catch {
                state.setStatusErr("Failed to create schematic"); return;
            };
            state.setStatus("Created schematic from symbol");
        },
        .make_schem_and_sym => {
            const fio = state.active() orelse { state.setStatus("No active document"); return; };
            const base_path = switch (fio.origin) {
                .chn_file => |p| p,
                else => { state.setStatus("Save the document first"); return; },
            };
            const stem_end = std.mem.lastIndexOf(u8, base_path, ".chn") orelse base_path.len;
            var sch_buf: [512]u8 = undefined;
            var sym_buf: [512]u8 = undefined;
            const sch_path = std.fmt.bufPrint(&sch_buf, "{s}.chn", .{base_path[0..stem_end]}) catch {
                state.setStatusErr("Path too long"); return;
            };
            const sym_path = std.fmt.bufPrint(&sym_buf, "{s}.chn_prim", .{base_path[0..stem_end]}) catch {
                state.setStatusErr("Path too long"); return;
            };
            fio.saveAsChn(sch_path) catch {
                state.setStatusErr("Failed to save schematic"); return;
            };
            fio.saveAsChn(sym_path) catch {
                state.setStatusErr("Failed to save symbol"); return;
            };
            state.setStatus("Created schematic and symbol");
        },
        .insert_from_library => state.open_library_browser = true,
        .open_file_explorer  => state.open_file_explorer = !state.open_file_explorer,
        else => unreachable,
    }
}

// ── Private helpers ──────────────────────────────────────────────────────────

fn firstSelectedInst(state: anytype) ?usize {
    const sel = &state.selection.instances;
    if (sel.bit_length == 0) return null;
    var it = sel.iterator(.{});
    return it.next();
}

/// Try to find a file for the given symbol name + extension.
/// Searches: (1) symbol as-is if it already has the extension, (2) relative to
/// the current document's directory, (3) relative to the project directory.
fn resolveFile(state: anytype, fio: anytype, symbol: []const u8, ext: []const u8, buf: *[512]u8) ?[]const u8 {
    // If symbol already has the target extension, try it directly.
    if (std.mem.endsWith(u8, symbol, ext)) {
        if (fileExists(symbol)) return symbol;
    }
    // Directory of the current file.
    const dir: []const u8 = switch (fio.origin) {
        .chn_file => |p| std.fs.path.dirname(p) orelse ".",
        else => ".",
    };
    // Try <dir>/<symbol><ext>
    if (std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ dir, symbol, ext })) |path| {
        if (fileExists(path)) return path;
    } else |_| {}
    // Try <project_dir>/<symbol><ext>
    if (std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ state.project_dir, symbol, ext })) |path| {
        if (fileExists(path)) return path;
    } else |_| {}
    return null;
}

fn fileExists(path: []const u8) bool {
    return Vfs.exists(path);
}
