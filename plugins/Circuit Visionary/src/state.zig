//! CircuitVision shared state — read/written by panel.zig and python_bridge.zig.

const std = @import("std");

pub const Style = enum(u8) {
    auto      = 0,
    handdrawn = 1,
    textbook  = 2,
    datasheet = 3,

    pub fn label(self: Style) [*:0]const u8 {
        return switch (self) {
            .auto      => "Auto",
            .handdrawn => "Hand-drawn",
            .textbook  => "Textbook",
            .datasheet => "Datasheet",
        };
    }

    pub fn pyArg(self: Style) ?[*:0]const u8 {
        return switch (self) {
            .auto      => null,
            .handdrawn => "handdrawn",
            .textbook  => "textbook",
            .datasheet => "datasheet",
        };
    }
};

pub const PipelineStatus = enum(u8) {
    idle,
    running,
    done,
    err,
};

pub const Warning = struct {
    msg_buf: [256]u8 = [_]u8{0} ** 256,
    msg_len: u16 = 0,

    pub fn text(self: *const Warning) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }
};

pub const MAX_WARNINGS = 32;
pub const MAX_PATH     = 1024;

pub const State = struct {
    // Input
    image_path:     [MAX_PATH]u8 = [_]u8{0} ** MAX_PATH,
    image_path_len: u16 = 0,
    selected_style: Style = .auto,

    // Pipeline
    status: PipelineStatus = .idle,

    // Results
    n_components:      u32 = 0,
    n_nets:            u32 = 0,
    overall_confidence: f32 = 0.0,
    detected_style_buf: [32]u8 = [_]u8{0} ** 32,
    detected_style_len: u8 = 0,

    // Warnings
    warnings: [MAX_WARNINGS]Warning = [_]Warning{.{}} ** MAX_WARNINGS,
    warning_count: u8 = 0,

    // Error
    error_buf: [512]u8 = [_]u8{0} ** 512,
    error_len: u16 = 0,

    // Result JSON (heap-allocated by python_bridge, freed on next run or unload)
    result_json: ?[]const u8 = null,

    pub fn imagePath(self: *const State) []const u8 {
        return self.image_path[0..self.image_path_len];
    }

    pub fn setImagePath(self: *State, path: []const u8) void {
        const n = @min(path.len, MAX_PATH);
        @memcpy(self.image_path[0..n], path[0..n]);
        self.image_path_len = @intCast(n);
    }

    pub fn detectedStyle(self: *const State) []const u8 {
        return self.detected_style_buf[0..self.detected_style_len];
    }

    pub fn errorMsg(self: *const State) []const u8 {
        return self.error_buf[0..self.error_len];
    }

    pub fn setError(self: *State, msg: []const u8) void {
        const n = @min(msg.len, self.error_buf.len);
        @memcpy(self.error_buf[0..n], msg[0..n]);
        self.error_len = @intCast(n);
        self.status = .err;
    }

    pub fn reset(self: *State) void {
        self.status = .idle;
        self.n_components = 0;
        self.n_nets = 0;
        self.overall_confidence = 0.0;
        self.detected_style_len = 0;
        self.warning_count = 0;
        self.error_len = 0;
        if (self.result_json) |json| {
            std.heap.page_allocator.free(json);
            self.result_json = null;
        }
    }
};

pub var g: State = .{};
