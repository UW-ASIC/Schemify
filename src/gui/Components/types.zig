//! Shared types for reusable GUI components.

const dvui = @import("dvui");

/// Standard padding preset for themed components.
pub const PaddingPreset = enum {
    compact,
    normal,
    spacious,

    pub fn values(self: PaddingPreset) dvui.Padding {
        return switch (self) {
            .compact => .{ .x = 4, .y = 2, .w = 4, .h = 2 },
            .normal => .{ .x = 8, .y = 5, .w = 8, .h = 5 },
            .spacious => .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        };
    }
};
