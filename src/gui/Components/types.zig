//! Shared types for reusable GUI components.

const st = @import("state");
const dvui = @import("dvui");

/// Zero-cost cast from *WinRect to *dvui.Rect (identical layout: 4 x f32).
pub inline fn winRectPtr(wr: *st.WinRect) *dvui.Rect {
    return @ptrCast(wr);
}
