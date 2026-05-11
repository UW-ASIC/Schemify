//! File handlers — save, open, reload, merge, tabs.

const std = @import("std");
const core = @import("core");
const h = @import("helpers.zig");
const Error = h.Error;
const Immediate = h.Immediate;
const Point = h.Point;

pub fn handleFile(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .file_new, .new_tab => {
            var buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, "untitled_{d}.comp", .{state.documents.items.len + 1}) catch "untitled.comp";
            state.newFile(name) catch {
                state.setStatus("Failed to create new tab");
                return;
            };
        },
        .close_tab => {
            if (state.documents.items.len <= 1) { state.setStatus("Cannot close last tab"); return; }
            const idx = state.active_idx;
            state.documents.items[idx].deinit();
            _ = state.documents.orderedRemove(idx);
            if (@as(usize, state.active_idx) >= state.documents.items.len)
                state.active_idx = @intCast(state.documents.items.len - 1);
            if (state.active()) |fd| fd.selection.clear();
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
                state.active_idx = if (state.active_idx == 0)
                    @intCast(state.documents.items.len - 1)
                else
                    state.active_idx - 1;
                state.setStatus("Previous tab");
            }
        },
        .file_open => { state.open_file_explorer = true; state.setStatus("Open file"); },
        .file_save_as => state.setStatus("Save as (use :saveas <path>)"),
        .file_save_all => state.setStatus("Save all"),
        .reopen_closed_tab => {
            if (state.closed_tabs.popLast()) |path| {
                state.openPath(path) catch { state.setStatus("Reopen failed"); return; };
                state.allocator().free(path);
                state.setStatus("Reopened tab");
            } else state.setStatus("No closed tabs");
        },
        .file_save => {
            const fio = state.active() orelse { state.setStatus("No active document"); return; };
            const path = switch (fio.origin) {
                .chn_file => |p| p,
                else => { state.setStatus("Save as (use :saveas <path>)"); return; },
            };
            state.saveActiveTo(path) catch {
                state.setStatus("Save failed");
                return;
            };
            state.setStatus("Saved");
        },
        .reload_from_disk => {
            const fio = state.active() orelse return;
            const reload_path: ?[]const u8 = switch (fio.origin) {
                .chn_file => |p| p,
                .buffer, .unsaved => null,
            };
            if (reload_path) |p| {
                state.openPath(p) catch {
                    state.setStatus("Reload failed");
                };
            } else state.setStatus("No disk path to reload from");
        },
        .merge_file => {
            if (state.active() == null) { state.setStatus("No active document"); return; }
            state.open_file_explorer = true;
            state.setStatus("Select file to merge");
        },
        else => {},
    }
}

