//! Properties command handlers.

const Immediate = @import("command.zig").Immediate;

pub const Error = error{};

pub fn handle(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .edit_properties         => state.setStatus("Edit properties (stub)"),
        .view_properties         => state.setStatus("View properties (stub)"),
        .edit_schematic_metadata => state.setStatus("(stub — use CLI :rename)"),
        else => unreachable,
    }
}
