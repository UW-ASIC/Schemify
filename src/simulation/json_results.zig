const std = @import("std");
const results = @import("results.zig");

/// Parse JSON stdout from a Python testbench script into a SimResult.
/// All returned data is allocated from `alloc`. Caller owns the memory.
/// Use an ArenaAllocator for easy bulk-free.
pub fn parseSimResultJson(alloc: std.mem.Allocator, json_text: []const u8) !results.SimResult {
    if (json_text.len == 0) return results.SimResult{ .status = .unknown_error };

    const tree = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch
        return results.SimResult{ .status = .unknown_error, .raw_output = json_text };
    // NOTE: tree is NOT deferred — caller owns all memory through the allocator.
    // Use an ArenaAllocator and reset/deinit it when the SimResult is no longer needed.

    const root = tree.value;
    if (root != .object) return results.SimResult{ .status = .unknown_error, .raw_output = json_text };

    var result = results.SimResult{};

    // Status
    if (root.object.get("status")) |s| {
        if (s == .string) {
            result.status = if (std.mem.eql(u8, s.string, "success")) .success else .unknown_error;
        }
    }

    // Analysis type
    if (root.object.get("analysis_type")) |s| {
        if (s == .string) result.analysis_type = s.string;
    }

    // Raw SPICE
    if (root.object.get("raw_spice")) |s| {
        if (s == .string) result.raw_spice = s.string;
    }

    // Waveforms
    if (root.object.get("waveforms")) |wf_arr| {
        if (wf_arr == .array) {
            var waveforms: std.ArrayListUnmanaged(results.Waveform) = .{};
            for (wf_arr.array.items) |wf_val| {
                if (wf_val != .object) continue;
                var wf = results.Waveform{};
                if (wf_val.object.get("name")) |n| {
                    if (n == .string) wf.name = n.string;
                }
                if (wf_val.object.get("x_unit")) |u| {
                    if (u == .string) wf.x_unit = u.string;
                }
                if (wf_val.object.get("y_unit")) |u| {
                    if (u == .string) wf.y_unit = u.string;
                }
                if (wf_val.object.get("x_data")) |xd| {
                    wf.x_data = parseF64Array(alloc, xd) catch &.{};
                }
                if (wf_val.object.get("y_data")) |yd| {
                    wf.y_data = parseF64Array(alloc, yd) catch &.{};
                }
                if (wf_val.object.get("y_imag")) |yi| {
                    wf.y_imag = parseF64Array(alloc, yi) catch &.{};
                }
                waveforms.append(alloc, wf) catch continue;
            }
            result.waveforms = waveforms.toOwnedSlice(alloc) catch &.{};
        }
    }

    // Operating point values
    if (root.object.get("op_values")) |op_arr| {
        if (op_arr == .array) {
            var ops: std.ArrayListUnmanaged(results.OpPoint) = .{};
            for (op_arr.array.items) |op_val| {
                if (op_val != .object) continue;
                var op = results.OpPoint{};
                if (op_val.object.get("name")) |n| {
                    if (n == .string) op.name = n.string;
                }
                if (op_val.object.get("unit")) |u| {
                    if (u == .string) op.unit = u.string;
                }
                if (op_val.object.get("value")) |v| {
                    op.value = jsonToF64(v);
                }
                ops.append(alloc, op) catch continue;
            }
            result.op_values = ops.toOwnedSlice(alloc) catch &.{};
        }
    }

    // Measurements
    if (root.object.get("measurements")) |m_arr| {
        if (m_arr == .array) {
            var measurements: std.ArrayListUnmanaged(results.Measurement) = .{};
            for (m_arr.array.items) |m_val| {
                if (m_val != .object) continue;
                var m = results.Measurement{};
                if (m_val.object.get("name")) |n| {
                    if (n == .string) m.name = n.string;
                }
                if (m_val.object.get("unit")) |u| {
                    if (u == .string) m.unit = u.string;
                }
                if (m_val.object.get("value")) |v| {
                    m.value = jsonToF64(v);
                    m.valid = true;
                }
                measurements.append(alloc, m) catch continue;
            }
            result.measurements = measurements.toOwnedSlice(alloc) catch &.{};
        }
    }

    // Errors
    if (root.object.get("errors")) |e_arr| {
        if (e_arr == .array) {
            var errs: std.ArrayListUnmanaged(results.SimError) = .{};
            for (e_arr.array.items) |e_val| {
                if (e_val != .object) continue;
                var err = results.SimError{};
                if (e_val.object.get("message")) |msg| {
                    if (msg == .string) err.message = msg.string;
                }
                if (e_val.object.get("severity")) |sev| {
                    if (sev == .string) {
                        err.severity = if (std.mem.eql(u8, sev.string, "warning")) .warning else if (std.mem.eql(u8, sev.string, "info")) .info else .@"error";
                    }
                }
                errs.append(alloc, err) catch continue;
            }
            result.errors = errs.toOwnedSlice(alloc) catch &.{};
        }
    }

    return result;
}

fn jsonToF64(v: std.json.Value) f64 {
    return switch (v) {
        .float => v.float,
        .integer => @as(f64, @floatFromInt(v.integer)),
        else => 0.0,
    };
}

fn parseF64Array(alloc: std.mem.Allocator, val: std.json.Value) ![]const f64 {
    if (val != .array) return &.{};
    const arr = try alloc.alloc(f64, val.array.items.len);
    for (val.array.items, 0..) |item, i| {
        arr[i] = jsonToF64(item);
    }
    return arr;
}

// ── Tests ────────────────────────────────────────────────────────────────────
// Tests use ArenaAllocator — parseSimResultJson intentionally leaks into the
// caller's allocator (designed for arena usage). Arena.deinit() frees everything.

test "parseSimResultJson: success with waveforms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const json =
        \\{
        \\  "status": "success",
        \\  "analysis_type": "ac",
        \\  "waveforms": [
        \\    { "name": "v(out)", "x_data": [1.0, 10.0], "y_data": [0.5, 0.3], "x_unit": "Hz", "y_unit": "V" }
        \\  ],
        \\  "measurements": [
        \\    { "name": "f_3dB", "value": 1000000.0, "unit": "Hz" }
        \\  ]
        \\}
    ;
    const result = try parseSimResultJson(alloc, json);
    try std.testing.expectEqual(results.SimStatus.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), result.waveforms.len);
    try std.testing.expectEqualStrings("v(out)", result.waveforms[0].name);
    try std.testing.expectEqual(@as(usize, 1), result.measurements.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1e6), result.measurements[0].value, 1.0);
}

test "parseSimResultJson: error result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const json =
        \\{
        \\  "status": "error",
        \\  "errors": [
        \\    { "severity": "error", "message": "convergence failed" }
        \\  ]
        \\}
    ;
    const result = try parseSimResultJson(alloc, json);
    try std.testing.expectEqual(results.SimStatus.unknown_error, result.status);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expectEqualStrings("convergence failed", result.errors[0].message);
}

test "parseSimResultJson: empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseSimResultJson(arena.allocator(), "");
    try std.testing.expectEqual(results.SimStatus.unknown_error, result.status);
}

test "parseSimResultJson: integer coercion in values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const json =
        \\{
        \\  "status": "success",
        \\  "op_values": [
        \\    { "name": "V(out)", "value": 2, "unit": "V" }
        \\  ]
        \\}
    ;
    const result = try parseSimResultJson(alloc, json);
    try std.testing.expectEqual(results.SimStatus.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), result.op_values.len);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.op_values[0].value, 0.01);
}
