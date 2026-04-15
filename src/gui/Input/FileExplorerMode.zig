//! File-explorer modal input handling.
//!
//! Extracted from Input.zig for modularity.

const dvui = @import("dvui");
const st = @import("state");
const AppState = st.AppState;
const file_explorer = @import("../Panels/FileExplorer.zig");
const km = @import("KeyMapping.zig");

pub fn handleFileExplorerInput(app: *AppState, code: dvui.enums.Key, shift: bool) bool {
    return switch (code) {
        .escape => file_explorer.onKeyEscape(app),
        .backspace => file_explorer.onKeyBackspace(app),
        else => blk: {
            const ch = km.keyToChar(code, shift);
            if (ch == 0) break :blk false;
            break :blk file_explorer.onKeyChar(app, ch);
        },
    };
}