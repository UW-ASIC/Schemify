const std = @import("std");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32;

pub fn handleOptimize(state: anytype) void {
    if (is_wasm) { state.setStatus("Optimizer not available in browser"); return; }
    _ = state.active() orelse { state.setStatus("No active document"); return; };

    state.gui.cold.optimizer_dialog.is_open = true;
    state.setStatus("Optimize Sizing");
}
