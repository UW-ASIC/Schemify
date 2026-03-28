pub const Reader = struct {
    pub fn init() Reader {
        return .{};
    }

    pub fn deinit(self: *Reader) void {
        self.* = undefined;
    }
};
