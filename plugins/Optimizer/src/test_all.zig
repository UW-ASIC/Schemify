// Pull in tests from all helper modules (no PluginIF dependency)
const std = @import("std");
test {
    _ = @import("config.zig");
    _ = @import("lhc.zig");
    _ = @import("log_buf.zig");
    _ = @import("sim_result.zig");
}
