const std = @import("std");

pub const MAX_PATH = 1024;
pub const MAX_MODELS = 8;
pub const MAX_PLOTS = 24;

pub const ModelKind = enum(u8) {
    unknown,
    mosfet,
    bjt,

    pub fn label(self: ModelKind) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .mosfet => "mosfet",
            .bjt => "bjt",
        };
    }
};

pub const RunStatus = enum(u8) {
    idle,
    running,
    done,
    err,
};

pub const State = struct {
    selected_model_path: [MAX_PATH]u8 = [_]u8{0} ** MAX_PATH,
    selected_model_len: u16 = 0,
    selected_model_kind: ModelKind = .unknown,

    recent_models: [MAX_MODELS][MAX_PATH]u8 = [_][MAX_PATH]u8{[_]u8{0} ** MAX_PATH} ** MAX_MODELS,
    recent_model_lens: [MAX_MODELS]u16 = [_]u16{0} ** MAX_MODELS,
    recent_count: u8 = 0,
    dropdown_open: bool = false,

    status: RunStatus = .idle,
    status_msg: [256]u8 = [_]u8{0} ** 256,
    status_len: u16 = 0,
    error_buf: [512]u8 = [_]u8{0} ** 512,
    error_len: u16 = 0,

    plots: [MAX_PLOTS][MAX_PATH]u8 = [_][MAX_PATH]u8{[_]u8{0} ** MAX_PATH} ** MAX_PLOTS,
    plot_lens: [MAX_PLOTS]u16 = [_]u16{0} ** MAX_PLOTS,
    plot_count: u8 = 0,

    pub fn selectedPath(self: *const State) []const u8 {
        return self.selected_model_path[0..self.selected_model_len];
    }

    pub fn statusText(self: *const State) []const u8 {
        return self.status_msg[0..self.status_len];
    }

    pub fn errorText(self: *const State) []const u8 {
        return self.error_buf[0..self.error_len];
    }

    pub fn setSelectedModel(self: *State, path: []const u8, kind: ModelKind) void {
        const n = @min(path.len, MAX_PATH - 1);
        @memcpy(self.selected_model_path[0..n], path[0..n]);
        self.selected_model_len = @intCast(n);
        self.selected_model_kind = kind;
    }

    pub fn addRecentModel(self: *State, path: []const u8) void {
        var existing_idx: ?usize = null;
        for (0..self.recent_count) |idx| {
            const cur = self.recent_models[idx][0..self.recent_model_lens[idx]];
            if (std.mem.eql(u8, cur, path)) {
                existing_idx = idx;
                break;
            }
        }

        if (existing_idx) |idx| {
            if (idx != 0) {
                const tmp = self.recent_models[idx];
                const tmp_len = self.recent_model_lens[idx];
                var i = idx;
                while (i > 0) : (i -= 1) {
                    self.recent_models[i] = self.recent_models[i - 1];
                    self.recent_model_lens[i] = self.recent_model_lens[i - 1];
                }
                self.recent_models[0] = tmp;
                self.recent_model_lens[0] = tmp_len;
            }
            return;
        }

        if (self.recent_count < MAX_MODELS) {
            self.recent_count += 1;
        }
        var j: usize = self.recent_count - 1;
        while (j > 0) : (j -= 1) {
            self.recent_models[j] = self.recent_models[j - 1];
            self.recent_model_lens[j] = self.recent_model_lens[j - 1];
        }

        const n = @min(path.len, MAX_PATH - 1);
        @memcpy(self.recent_models[0][0..n], path[0..n]);
        self.recent_model_lens[0] = @intCast(n);
    }

    pub fn clearPlots(self: *State) void {
        self.plot_count = 0;
    }

    pub fn addPlot(self: *State, path: []const u8) void {
        if (self.plot_count >= MAX_PLOTS) return;
        const idx = self.plot_count;
        const n = @min(path.len, MAX_PATH - 1);
        @memcpy(self.plots[idx][0..n], path[0..n]);
        self.plot_lens[idx] = @intCast(n);
        self.plot_count += 1;
    }

    pub fn setStatus(self: *State, msg: []const u8) void {
        const n = @min(msg.len, self.status_msg.len - 1);
        @memcpy(self.status_msg[0..n], msg[0..n]);
        self.status_len = @intCast(n);
    }

    pub fn setError(self: *State, msg: []const u8) void {
        const n = @min(msg.len, self.error_buf.len - 1);
        @memcpy(self.error_buf[0..n], msg[0..n]);
        self.error_len = @intCast(n);
        self.status = .err;
    }

    pub fn clearError(self: *State) void {
        self.error_len = 0;
    }

    pub fn resetRun(self: *State) void {
        self.status = .idle;
        self.status_len = 0;
        self.error_len = 0;
        self.clearPlots();
    }

    pub fn resetAll(self: *State) void {
        self.selected_model_len = 0;
        self.selected_model_kind = .unknown;
        self.dropdown_open = false;
        self.resetRun();
    }
};

pub var g: State = .{};
