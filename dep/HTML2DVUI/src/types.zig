/// Shared types for html2dvui rendering pipeline.
/// These are the fundamental primitives used to communicate draw commands
/// from the HTML/CSS layout engine to the dvui rendering layer.

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.w and
            py >= self.y and py <= self.y + self.h;
    }

    pub fn intersects(self: Rect, other: Rect) bool {
        return !(self.x + self.w < other.x or
            other.x + other.w < self.x or
            self.y + self.h < other.y or
            other.y + other.h < self.y);
    }
};

pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub fn fromU32(rgba: u32) Color {
        return .{
            .r = @truncate(rgba >> 24),
            .g = @truncate(rgba >> 16),
            .b = @truncate(rgba >> 8),
            .a = @truncate(rgba),
        };
    }

    pub fn toU32(self: Color) u32 {
        return @as(u32, self.r) << 24 |
            @as(u32, self.g) << 16 |
            @as(u32, self.b) << 8 |
            @as(u32, self.a);
    }

    pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
};

pub const FontHandle = struct {
    monospace: bool = false,
    size: f32 = 14.0,
    bold: bool = false,
    italic: bool = false,
};

pub const DrawCommand = union(enum) {
    text: TextCmd,
    rect_fill: RectFillCmd,
    rect_stroke: RectStrokeCmd,
    image: ImageCmd,
    clip: Rect,
    clip_end: void,

    pub const TextCmd = struct {
        x: f32,
        y: f32,
        content: []const u8,
        color: Color,
        font: FontHandle,
    };

    pub const RectFillCmd = struct {
        rect: Rect,
        color: Color,
    };

    pub const RectStrokeCmd = struct {
        rect: Rect,
        color: Color,
        width: f32,
    };

    pub const ImageCmd = struct {
        rect: Rect,
        data: []const u8,
    };
};
