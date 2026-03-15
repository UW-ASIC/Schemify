//! File and tab management command handlers.

const std = @import("std");
const cmd = @import("command.zig");
const Immediate     = cmd.Immediate;
const LoadSchematic = cmd.LoadSchematic;
const SaveSchematic = cmd.SaveSchematic;

pub const Error = error{
    OutOfMemory, FileNotFound, AccessDenied, Unexpected,
    InvalidFormat, NoActiveDocument, NotSupported,
    // std.fs write errors:
    AntivirusInterference, BadPathName, BrokenPipe, ConnectionResetByPeer,
    DeviceBusy, DiskQuota, FileBusy, FileLocksNotSupported, FileTooBig,
    InputOutput, InvalidArgument, InvalidUtf8, InvalidWtf8, IsDir,
    LockViolation, MessageTooBig, NameTooLong, NetworkNotFound, NoDevice,
    NoSpaceLeft, NotDir, NotOpenForWriting, OperationAborted,
    PathAlreadyExists, PermissionDenied, PipeBusy, ProcessFdQuotaExceeded,
    ProcessNotFound, SharingViolation, SymLinkLoop, SystemFdQuotaExceeded,
    SystemResources, WouldBlock,
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
        .reopen_last_closed    => state.setStatus("Reopen last closed (stub)"),
        .save_as_dialog        => state.setStatus("Save as (use :saveas <path>)"),
        .save_as_symbol_dialog => state.setStatus("Save as symbol (stub)"),
        .reload_from_disk => {
            const fio = state.active() orelse return;
            const reload_path: ?[]const u8 = switch (fio.origin) {
                .chn_file    => |p|  p,
                .xschem_files => |xf| xf.sch,
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
            const sch = fio.schematic();
            sch.wires.clearRetainingCapacity();
            sch.instances.clearRetainingCapacity();
            state.selection.clear();
            fio.dirty = true;
            state.setStatus("Schematic cleared");
        },
        .merge_file_dialog => state.setStatus("Merge file (stub — use :merge <path>)"),
        .place_text => { state.tool.active = .text; state.setStatus("Place text (stub)"); },
        else => unreachable,
    }
}

pub fn handleLoad(p: LoadSchematic, state: anytype) Error!void {
    try state.openPath(p.path);
}

pub fn handleSave(p: SaveSchematic, state: anytype) Error!void {
    try state.saveActiveTo(p.path);
}
