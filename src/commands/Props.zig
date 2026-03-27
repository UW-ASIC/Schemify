//! Properties command handlers.

const Immediate = @import("command.zig").Immediate;

pub const Error = error{};

pub fn handle(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .edit_properties => {
            // TODO: open PropsDialog for the first selected instance.
            // Needs: PropsDialog GUI component wired into gui layer,
            // reading props from state.active().sch.instances[sel].props.
            state.setStatus("Edit properties (not yet wired to dialog)");
        },
        .view_properties => {
            // TODO: open read-only PropsDialog for the first selected instance.
            state.setStatus("View properties (not yet wired to dialog)");
        },
        .edit_schematic_metadata => {
            // TODO: open dialog/prompt for schematic-level metadata (name, author, etc.).
            // Currently only reachable via CLI `:rename`.
            state.setStatus("Edit metadata (use CLI :rename)");
        },
        else => unreachable,
    }
}
