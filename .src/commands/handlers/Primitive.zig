//! Insert primitive command handler.

const std = @import("std");
const types = @import("../types.zig");

pub fn handleInsertPrimitive(kind: types.PrimitiveKind, state: anytype) void {
    const fio = state.active() orelse return;
    const pos = state.gui.hot.canvas.cursor_world;
    const kind_name = kind.kindName();
    const pfx = kind.prefix();

    // Count existing instances with same prefix to generate unique name
    var counter: u32 = 1;
    const names = fio.sch.instances.items(.name);
    for (0..fio.sch.instances.len) |i| {
        if (names[i].len > 0 and names[i][0] == pfx) counter += 1;
    }

    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{c}{d}", .{ pfx, counter }) catch "X1";

    _ = fio.sch.addInstance(fio.alloc, name, kind_name, pos[0], pos[1]) catch {
        state.setStatus("Failed to insert primitive");
        return;
    };
    fio.dirty = true;
    state.setStatus("Inserted primitive");
}
