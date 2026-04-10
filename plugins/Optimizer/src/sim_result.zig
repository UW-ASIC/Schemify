//! Parses flat "key=value\n" text from __sim_result__ file_response.

const std = @import("std");
const config = @import("config.zig");

pub const MAX_MEASURES = config.MAX_OBJECTIVES;
pub const MAX_NAME = config.MAX_NAME;

pub const SimResult = struct {
    valid: bool = false,
    elapsed_ms: u32 = 0,
    measures: [MAX_MEASURES][MAX_NAME]u8 = [_][MAX_NAME]u8{[_]u8{0} ** MAX_NAME} ** MAX_MEASURES,
    measure_lens: [MAX_MEASURES]u8 = [_]u8{0} ** MAX_MEASURES,
    values: [MAX_MEASURES]f32 = [_]f32{0} ** MAX_MEASURES,
    count: usize = 0,

    pub fn measureName(self: *const SimResult, i: usize) []const u8 {
        return self.measures[i][0..self.measure_lens[i]];
    }

    pub fn get(self: *const SimResult, name: []const u8) ?f32 {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.measureName(i), name)) return self.values[i];
        }
        return null;
    }
};

pub fn parse(data: []const u8, out: *SimResult) void {
    out.* = .{};
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "valid")) {
            out.valid = !std.mem.eql(u8, val, "0");
        } else if (std.mem.eql(u8, key, "elapsed_ms")) {
            out.elapsed_ms = std.fmt.parseInt(u32, val, 10) catch 0;
        } else if (out.count < MAX_MEASURES) {
            const n = @min(key.len, MAX_NAME - 1);
            @memcpy(out.measures[out.count][0..n], key[0..n]);
            out.measure_lens[out.count] = @intCast(n);
            out.values[out.count] = @floatCast(std.fmt.parseFloat(f64, val) catch 0.0);
            out.count += 1;
        }
    }
}

test "parse sim result" {
    const data = "gain_dB=42.1\nphase_margin=67.3\npower_W=0.00087\nvalid=1\nelapsed_ms=340\n";
    var result: SimResult = undefined;
    parse(data, &result);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 340), result.elapsed_ms);
    try std.testing.expectEqual(@as(usize, 3), result.count);
    const gain = result.get("gain_dB") orelse return error.TestFailed;
    try std.testing.expectApproxEqAbs(@as(f32, 42.1), gain, 0.01);
}
