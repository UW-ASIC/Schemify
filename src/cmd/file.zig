//! File and tab management command handlers.

const std = @import("std");
const state_mod = @import("../state.zig");
const AppState = state_mod.AppState;
const cmd = @import("../command.zig");
const Command = cmd.Command;

pub fn handle(c: Command, state: *AppState) !void {
    switch (c) {
        .new_tab => {
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "untitled_{d}", .{state.schematics.items.len + 1}) catch "untitled";
            state.newFile(name) catch |err| {
                state.setStatusErr("Failed to create new tab");
                state.log.err("CMD", "new tab failed: {}", .{err});
            };
        },
        .close_tab => {
            if (state.schematics.items.len <= 1) {
                state.setStatus("Cannot close last tab");
                return;
            }
            const alloc = state.allocator();
            const idx = state.active_idx;
            const fio = state.schematics.items[idx];
            fio.deinit();
            alloc.destroy(fio);
            _ = state.schematics.orderedRemove(idx);
            if (state.active_idx >= state.schematics.items.len) {
                state.active_idx = state.schematics.items.len - 1;
            }
            state.selection.clear();
            state.setStatus("Tab closed");
        },
        .next_tab => {
            if (state.schematics.items.len > 0) {
                state.active_idx = (state.active_idx + 1) % state.schematics.items.len;
                state.setStatus("Next tab");
            }
        },
        .prev_tab => {
            if (state.schematics.items.len > 0) {
                state.active_idx = if (state.active_idx == 0)
                    state.schematics.items.len - 1
                else
                    state.active_idx - 1;
                state.setStatus("Previous tab");
            }
        },
        .reopen_last_closed => state.setStatus("Reopen last closed (stub)"),
        .save_as_dialog => state.setStatus("Save as (use :saveas <path>)"),
        .save_as_symbol_dialog => state.setStatus("Save as symbol (stub)"),
        .reload_from_disk => {
            const fio = state.active() orelse return;
            const reload_path: ?[]const u8 = switch (fio.origin) {
                .chn_file, .chn_sym_file => |p| p,
                .buffer, .unsaved => null,
            };
            if (reload_path) |p| {
                state.openPath(p) catch |err| {
                    state.setStatusErr("Reload failed");
                    state.log.err("CMD", "reload failed: {}", .{err});
                };
            } else {
                state.setStatus("No disk path to reload from");
            }
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
        .place_text => {
            state.tool.active = .text;
            state.setStatus("Place text (stub)");
        },
        .load_schematic => |p| try state.openPath(p.path),
        .save_schematic => |p| try state.saveActiveTo(p.path),
        else => unreachable,
    }
}
