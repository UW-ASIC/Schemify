//! Thin action bar below the canvas — SPICE code button.

const dvui = @import("dvui");
const HTML = dvui.HTML;
const st = @import("state");
const actions = @import("../actions.zig");
const AppState = st.AppState;

var g_app: *AppState = undefined;

const Bar = HTML.parse(
    \\<nav style="display: flex; height: 24px; align-items: center; background: #181a22; padding: 0 8px; gap: 4px;">
    \\  <style>
    \\    button { padding: 0 10px; height: 20px; background: #282a34; color: #dce0e8; font-size: 11px; border-radius: 3px; }
    \\    button:hover { background: #32343e; }
    \\  </style>
    \\  <button data-action="spice-code">SPICE Code</button>
    \\</nav>
);

fn doSpiceCode() void {
    actions.enqueue(g_app, .{ .immediate = .open_spice_code_dialog }, "Opening SPICE code editor");
}

pub fn draw(app: *AppState) void {
    g_app = app;
    var cbs = Bar.Callbacks{};
    Bar.callbacksOn(&cbs, "spice-code", doSpiceCode);
    Bar.renderDvui(.{ .callbacks = &cbs });
}
