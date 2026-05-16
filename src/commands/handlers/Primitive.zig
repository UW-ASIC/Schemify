const std = @import("std");
const types = @import("../types.zig");

pub fn handleInsertPrimitive(kind: types.PrimitiveKind, state: anytype) void {
    _ = state.active() orelse return;
    const kind_name = kind.kindName();
    const Placement = std.meta.Child(@TypeOf(state.tool.placement));
    var pl = Placement{};
    const n = @min(kind_name.len, pl.kind_name.len);
    @memcpy(pl.kind_name[0..n], kind_name[0..n]);
    pl.kind_len = @intCast(n);
    state.tool.placement = pl;
    state.tool.active = .select;
    state.setStatus("Click to place — right-click or Esc to cancel");
}
