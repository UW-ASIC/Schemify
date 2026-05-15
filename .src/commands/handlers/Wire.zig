//! Wire mode command handlers.

const types = @import("../types.zig");
const Immediate = types.Immediate;

pub fn handleStartWire(state: anytype) void {
    state.tool.wire_start = null;
    state.tool.active = .wire;
    state.setStatus("Wire mode — click to start");
}

pub fn handleEscapeMode(state: anytype) void {
    state.tool.wire_start = null;
    state.tool.active = .select;
    if (state.active()) |fio| fio.selection.clear();
    state.setStatus("Ready");
}

pub fn handleToolSwitch(imm: Immediate, state: anytype) void {
    switch (imm) {
        .tool_select => { state.tool.active = .select; state.setStatus("Select"); },
        .tool_move => { state.tool.active = .move; state.setStatus("Move"); },
        .tool_pan => { state.tool.active = .pan; state.setStatus("Pan"); },
        .tool_line => { state.tool.active = .line; state.setStatus("Line"); },
        .tool_rect => { state.tool.active = .rect; state.setStatus("Rect"); },
        .tool_polygon => { state.tool.active = .polygon; state.setStatus("Polygon"); },
        .tool_arc => { state.tool.active = .arc; state.setStatus("Arc"); },
        .tool_circle => { state.tool.active = .circle; state.setStatus("Circle"); },
        .tool_text => { state.tool.active = .text; state.setStatus("Text"); },
        else => {},
    }
}
