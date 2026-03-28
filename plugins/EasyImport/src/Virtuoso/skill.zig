pub const Evaluator = struct {
    pub fn init() Evaluator {
        return .{};
    }

    pub fn deinit(self: *Evaluator) void {
        self.* = undefined;
    }
};
