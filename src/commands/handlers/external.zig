//! External editor handlers — edit properties in $EDITOR, edit raw file.

const std = @import("std");
const h = @import("helpers.zig");
const is_wasm = h.is_wasm;

pub fn handleEditPropertiesExternal(state: anytype) void {
    if (is_wasm) { state.setStatus("External editor not available in browser"); return; }

    const fio = state.active() orelse { state.setStatus("No active document"); return; };
    const sch = &fio.sch;

    // Find first selected instance.
    if (fio.selection.instances.bit_length == 0) { state.setStatus("No instance selected"); return; }
    var it = fio.selection.instances.iterator(.{});
    const inst_idx = it.next() orelse { state.setStatus("No instance selected"); return; };
    if (inst_idx >= sch.instances.len) { state.setStatus("Invalid selection"); return; }

    const inst_name = sch.instances.items(.name)[inst_idx];
    const prop_start: usize = sch.instances.items(.prop_start)[inst_idx];
    const prop_count: usize = sch.instances.items(.prop_count)[inst_idx];
    const props = sch.props.items[prop_start..][0..prop_count];

    // Write properties to temp file.
    const tmp_path = "/tmp/schemify_props.txt";
    const tmp_file = std.fs.cwd().createFile(tmp_path, .{}) catch {
        state.setStatus("Failed to create temp file");
        return;
    };

    // Write header comment and key = value lines.
    var write_buf: [8192]u8 = undefined;
    var written: usize = 0;
    const header = std.fmt.bufPrint(write_buf[written..], "# Properties for instance: {s}\n# Edit values below. Lines starting with # are ignored.\n", .{inst_name}) catch {
        tmp_file.close();
        state.setStatus("Instance name too long");
        return;
    };
    written += header.len;

    for (props) |prop| {
        const line = std.fmt.bufPrint(write_buf[written..], "{s} = {s}\n", .{ prop.key, prop.val }) catch {
            tmp_file.close();
            state.setStatus("Properties too large for buffer");
            return;
        };
        written += line.len;
    }

    tmp_file.writeAll(write_buf[0..written]) catch {
        tmp_file.close();
        state.setStatus("Failed to write temp file");
        return;
    };
    tmp_file.close();

    // Get $EDITOR, fall back to vi.
    const editor = std.posix.getenv("EDITOR") orelse "vi";

    // Spawn editor synchronously.
    var child = std.process.Child.init(&.{ editor, tmp_path }, state.allocator());
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.spawn() catch {
        std.fs.cwd().deleteFile(tmp_path) catch {};
        state.setStatus("Failed to launch editor");
        return;
    };
    const term = child.wait() catch {
        std.fs.cwd().deleteFile(tmp_path) catch {};
        state.setStatus("Editor process error");
        return;
    };
    if (term != .Exited or term.Exited != 0) {
        std.fs.cwd().deleteFile(tmp_path) catch {};
        state.setStatus("Editor exited with error");
        return;
    }

    // Read back the temp file.
    const read_file = std.fs.cwd().openFile(tmp_path, .{}) catch {
        state.setStatus("Failed to read temp file");
        return;
    };
    var read_buf: [8192]u8 = undefined;
    const n = read_file.readAll(&read_buf) catch {
        read_file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
        state.setStatus("Failed to read temp file");
        return;
    };
    read_file.close();
    std.fs.cwd().deleteFile(tmp_path) catch {};

    const data = read_buf[0..n];

    // Parse key = value lines and apply changes.
    var changed: u32 = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_pos], " \t");
        const val = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");
        if (key.len == 0) continue;

        // Find matching property and update if changed.
        // Re-read prop pointers each iteration (append may relocate).
        const ps: usize = sch.instances.items(.prop_start)[inst_idx];
        const pc: usize = sch.instances.items(.prop_count)[inst_idx];
        const cur_props = sch.props.items[ps..][0..pc];
        for (cur_props) |*prop| {
            if (std.mem.eql(u8, prop.key, key)) {
                if (!std.mem.eql(u8, prop.val, val)) {
                    prop.val = fio.alloc.dupe(u8, val) catch val;
                    changed += 1;
                }
                break;
            }
        }
    }

    if (changed > 0) {
        fio.dirty = true;
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{d} propert{s} updated", .{
            changed, if (changed == 1) "y" else "ies",
        }) catch "Properties updated";
        state.setStatusBuf(msg);
    } else {
        state.setStatus("No properties changed");
    }
}

pub fn handleEditFileRaw(state: anytype) void {
    if (is_wasm) { state.setStatus("External editor not available in browser"); return; }
    const fio = state.active() orelse { state.setStatus("No active document"); return; };
    const path: []const u8 = switch (fio.origin) {
        .chn_file => |p| p,
        else => { state.setStatus("Save the file first"); return; },
    };
    const editor = std.posix.getenv("EDITOR") orelse "vi";
    var child = std.process.Child.init(&.{ editor, path }, state.allocator());
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.spawn() catch { state.setStatus("Failed to launch editor"); return; };
    const term = child.wait() catch { state.setStatus("Editor process error"); return; };
    if (term != .Exited or term.Exited != 0) { state.setStatus("Editor exited with error"); return; }
    state.setStatus("File edited \xe2\x80\x94 use :reload to apply");
}
