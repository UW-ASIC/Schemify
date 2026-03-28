//! File and tab management command handlers.

const std = @import("std");
const cmd = @import("command.zig");
const Immediate     = cmd.Immediate;
const LoadSchematic = cmd.LoadSchematic;
const SaveSchematic = cmd.SaveSchematic;

/// Broad error set covering std.fs read/write errors propagated by
/// state.openPath() and state.saveActiveTo().
pub const Error = error{
    OutOfMemory, FileNotFound, AccessDenied, Unexpected,
    InvalidFormat, NoActiveDocument, NotSupported,
    ReadError, WriteError,
    AntivirusInterference, BadPathName, BrokenPipe, Canceled,
    ConnectionResetByPeer, ConnectionTimedOut,
    DeviceBusy, DiskQuota, FileBusy, FileLocksNotSupported, FileTooBig,
    InputOutput, InvalidArgument, InvalidUtf8, InvalidWtf8, IsDir,
    LockViolation, MessageTooBig, NameTooLong, NetworkNotFound, NoDevice,
    NoSpaceLeft, NotDir, NotOpenForReading, NotOpenForWriting, OperationAborted,
    PathAlreadyExists, PermissionDenied, PipeBusy, ProcessFdQuotaExceeded,
    ProcessNotFound, SharingViolation, SocketNotConnected, SymLinkLoop,
    SystemFdQuotaExceeded, SystemResources, WouldBlock,
};

/// Immediate (non-history) file/tab commands.
pub fn handleImmediate(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .new_tab => {
            var buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, "untitled_{d}.comp", .{state.documents.items.len + 1}) catch "untitled.comp";
            state.newFile(name) catch |err| {
                state.setStatusErr("Failed to create new tab");
                state.log.err("CMD", "new tab failed: {}", .{err});
            };
        },
        .close_tab => {
            if (state.documents.items.len <= 1) { state.setStatus("Cannot close last tab"); return; }
            const idx = state.active_idx;
            // Remember path for reopen_last_closed.
            switch (state.documents.items[idx].origin) {
                .chn_file => |p| state.closed_tabs.push(state.allocator(), p),
                else => {},
            }
            state.documents.items[idx].deinit();
            _ = state.documents.orderedRemove(idx);
            if (@as(usize, state.active_idx) >= state.documents.items.len)
                state.active_idx = @intCast(state.documents.items.len - 1);
            state.selection.clear();
            state.setStatus("Tab closed");
        },
        .next_tab => {
            if (state.documents.items.len > 0) {
                state.active_idx = @intCast((@as(usize, state.active_idx) + 1) % state.documents.items.len);
                state.setStatus("Next tab");
            }
        },
        .prev_tab => {
            if (state.documents.items.len > 0) {
                state.active_idx = if (state.active_idx == 0) @intCast(state.documents.items.len - 1) else state.active_idx - 1;
                state.setStatus("Previous tab");
            }
        },
        .reopen_last_closed => {
            const path = state.closed_tabs.popLast() orelse {
                state.setStatus("No recently closed tabs");
                return;
            };
            defer state.allocator().free(path);
            state.openPath(path) catch {
                state.setStatusErr("Failed to reopen file");
                return;
            };
            state.setStatus("Reopened tab");
        },
        .save_as_dialog => {
            // TODO: open a native file-save dialog (or command-bar prompt) and
            // call state.saveActiveTo(chosen_path). Currently CLI-only via :saveas.
            state.setStatus("Save as (use :saveas <path>)");
        },
        .save_as_symbol_dialog => {
            const fio = state.active() orelse { state.setStatus("No active document"); return; };
            const base_path = switch (fio.origin) {
                .chn_file => |p| p,
                else => { state.setStatus("Save the schematic first"); return; },
            };
            // Replace .chn* extension with .chn_prim
            const stem_end = std.mem.lastIndexOf(u8, base_path, ".chn") orelse base_path.len;
            var buf: [512]u8 = undefined;
            const sym_path = std.fmt.bufPrint(&buf, "{s}.chn_prim", .{base_path[0..stem_end]}) catch {
                state.setStatusErr("Path too long");
                return;
            };
            fio.saveAsChn(sym_path) catch {
                state.setStatusErr("Failed to save symbol");
                return;
            };
            state.setStatus("Saved as symbol");
        },
        .reload_from_disk => {
            const fio = state.active() orelse return;
            const reload_path: ?[]const u8 = switch (fio.origin) {
                .chn_file => |p| p,
                .buffer, .unsaved => null,
            };
            if (reload_path) |p| {
                state.openPath(p) catch |err| {
                    state.setStatusErr("Reload failed");
                    state.log.err("CMD", "reload failed: {}", .{err});
                };
            } else state.setStatus("No disk path to reload from");
        },
        .clear_schematic => {
            const fio = state.active() orelse return;
            const sch = &fio.sch;
            sch.wires.clearRetainingCapacity();
            sch.instances.clearRetainingCapacity();
            state.selection.clear();
            fio.dirty = true;
            state.setStatus("Schematic cleared");
        },
        .merge_file_dialog => {
            // TODO: open a file-open dialog, then merge the chosen schematic
            // into the active document (append its instances and wires).
            // Currently CLI-only via :merge.
            state.setStatus("Merge file (use :merge <path>)");
        },
        .place_text => { state.tool.active = .text; state.setStatus("Place text"); },
        else => unreachable,
    }
}

pub fn handleLoad(p: LoadSchematic, state: anytype) Error!void {
    try state.openPath(p.path);
}

pub fn handleSave(p: SaveSchematic, state: anytype) Error!void {
    try state.saveActiveTo(p.path);
}
