//! Command-mode (vim-style `:`) keyboard handling.
//!
//! Extracted from Input.zig for modularity.

const dvui = @import("dvui");
const st = @import("state");
const AppState = st.AppState;
const actions = @import("../Actions.zig");
const km = @import("KeyMapping.zig");

pub fn handleCommandMode(app: *AppState, code: dvui.enums.Key, shift: bool) bool {
    switch (code) {
        .escape => {
            app.gui.hot.command_mode = false;
            app.status_msg = "Command canceled";
            return true;
        },
        .enter => {
            actions.runVimCommand(app, app.gui.cold.command_buf[0..app.gui.hot.command_len]);
            app.gui.hot.command_mode = false;
            resetCommandBuffer(app);
            return true;
        },
        .backspace => {
            if (app.gui.hot.command_len > 0) {
                app.gui.hot.command_len -= 1;
                app.gui.cold.command_buf[app.gui.hot.command_len] = 0;
            }
            return true;
        },
        else => {
            const ch = km.keyToChar(code, shift);
            if (ch == 0 or app.gui.hot.command_len >= app.gui.cold.command_buf.len - 1) return false;
            app.gui.cold.command_buf[app.gui.hot.command_len] = ch;
            app.gui.hot.command_len += 1;
            return true;
        },
    }
}

fn resetCommandBuffer(app: *AppState) void {
    app.gui.hot.command_len = 0;
    @memset(&app.gui.cold.command_buf, 0);
}