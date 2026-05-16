const std = @import("std");

// ── Simulation result types (previously in sim_types.zig) ────────────────────

pub const Severity = enum(u8) { info, warning, @"error", fatal };

pub const SimError = struct {
    line: u32 = 0,
    severity: Severity = .@"error",
    message: []const u8 = &.{},
};

pub const Waveform = struct {
    name: []const u8 = &.{},
    x_data: []const f64 = &.{},
    y_data: []const f64 = &.{},
    y_imag: []const f64 = &.{},
    x_unit: []const u8 = &.{},
    y_unit: []const u8 = &.{},

    pub fn len(self: *const Waveform) usize {
        return self.x_data.len;
    }

    pub fn isComplex(self: *const Waveform) bool {
        return self.y_imag.len > 0;
    }
};

pub const SimStatus = enum(u8) {
    success,
    convergence_error,
    syntax_error,
    timeout,
    backend_not_found,
    pyspice_not_found,
    python_not_found,
    unknown_error,
};

pub const OpPoint = struct {
    name: []const u8 = &.{},
    value: f64 = 0.0,
    unit: []const u8 = &.{},
};

pub const SimResult = struct {
    status: SimStatus = .unknown_error,
    analysis_type: []const u8 = &.{},
    backend: []const u8 = &.{},
    waveforms: []const Waveform = &.{},
    measurements: []const Measurement = &.{},
    node_names: []const []const u8 = &.{},
    op_values: []const OpPoint = &.{},
    errors: []const SimError = &.{},
    raw_output: []const u8 = &.{},
    raw_spice: []const u8 = &.{},

    pub fn isSuccess(self: *const SimResult) bool {
        return self.status == .success;
    }

    pub fn waveformByName(self: *const SimResult, name: []const u8) ?*const Waveform {
        for (self.waveforms) |*w| {
            if (std.mem.eql(u8, w.name, name)) return w;
        }
        return null;
    }
};

// ── Waveform Arithmetic ──────────────────────────────────────────────────────

/// Compute magnitude in dB from complex waveform data.
/// Returns a new waveform with y_data = 20*log10(|H|).
pub fn magnitudeDb(arena: std.mem.Allocator, wf: *const Waveform) !Waveform {
    if (wf.y_data.len == 0) return Waveform{ .name = wf.name };

    const n = wf.y_data.len;
    const mag = try arena.alloc(f64, n);

    if (wf.isComplex()) {
        for (0..n) |i| {
            const re = wf.y_data[i];
            const im = if (i < wf.y_imag.len) wf.y_imag[i] else 0.0;
            const abs_val = @sqrt(re * re + im * im);
            mag[i] = 20.0 * @log10(@max(abs_val, 1e-300));
        }
    } else {
        for (0..n) |i| {
            mag[i] = 20.0 * @log10(@max(@abs(wf.y_data[i]), 1e-300));
        }
    }

    return Waveform{
        .name = wf.name,
        .x_data = wf.x_data,
        .y_data = mag,
        .x_unit = wf.x_unit,
        .y_unit = "dB",
    };
}

/// Compute phase in degrees from complex waveform data.
/// Returns a new waveform with y_data = atan2(imag, real) * 180/pi.
pub fn phaseDeg(arena: std.mem.Allocator, wf: *const Waveform) !Waveform {
    if (!wf.isComplex()) return Waveform{ .name = wf.name };

    const n = wf.y_data.len;
    const phase = try arena.alloc(f64, n);

    for (0..n) |i| {
        const re = wf.y_data[i];
        const im = if (i < wf.y_imag.len) wf.y_imag[i] else 0.0;
        phase[i] = std.math.atan2(im, re) * (180.0 / std.math.pi);
    }

    return Waveform{
        .name = wf.name,
        .x_data = wf.x_data,
        .y_data = phase,
        .x_unit = wf.x_unit,
        .y_unit = "deg",
    };
}

// ── Measurements ─────────────────────────────────────────────────────────────

/// Measurement result for a single scalar extraction.
pub const Measurement = struct {
    name: []const u8 = &.{},
    value: f64 = 0.0,
    unit: []const u8 = &.{},
    valid: bool = false,
};

/// Find the -3dB bandwidth from an AC magnitude response (in dB).
/// Assumes x_data is frequency, y_data is magnitude in dB.
/// Returns the frequency where magnitude drops 3dB below DC gain.
pub fn bandwidth3dB(wf: *const Waveform) Measurement {
    if (wf.y_data.len < 2) return .{ .name = "f_3dB", .unit = "Hz" };

    const dc_gain = wf.y_data[0];
    const threshold = dc_gain - 3.0;

    // Find first crossing below threshold
    for (1..wf.y_data.len) |i| {
        if (wf.y_data[i] < threshold) {
            // Linear interpolation between i-1 and i
            const y0 = wf.y_data[i - 1];
            const y1 = wf.y_data[i];
            const x0 = wf.x_data[i - 1];
            const x1 = wf.x_data[i];
            const t = if (y1 != y0) (threshold - y0) / (y1 - y0) else 0.5;
            const freq = x0 + t * (x1 - x0);
            return .{ .name = "f_3dB", .value = freq, .unit = "Hz", .valid = true };
        }
    }

    return .{ .name = "f_3dB", .unit = "Hz" };
}

/// Find the unity-gain frequency (0dB crossing) from a magnitude response.
pub fn unityGainFreq(wf: *const Waveform) Measurement {
    if (wf.y_data.len < 2) return .{ .name = "f_ugb", .unit = "Hz" };

    for (1..wf.y_data.len) |i| {
        if (wf.y_data[i] <= 0.0 and wf.y_data[i - 1] > 0.0) {
            const y0 = wf.y_data[i - 1];
            const y1 = wf.y_data[i];
            const x0 = wf.x_data[i - 1];
            const x1 = wf.x_data[i];
            const t = if (y0 != y1) (0.0 - y0) / (y1 - y0) else 0.5;
            const freq = x0 + t * (x1 - x0);
            return .{ .name = "f_ugb", .value = freq, .unit = "Hz", .valid = true };
        }
    }

    return .{ .name = "f_ugb", .unit = "Hz" };
}

/// Find the phase margin from gain/phase data.
/// Phase margin = 180 + phase at unity-gain frequency.
pub fn phaseMargin(gain_wf: *const Waveform, phase_wf: *const Waveform) Measurement {
    const ugb = unityGainFreq(gain_wf);
    if (!ugb.valid) return .{ .name = "PM", .unit = "deg" };

    // Find phase at the unity-gain frequency via interpolation
    const phase_at_ugb = interpolateAt(phase_wf, ugb.value);
    return .{
        .name = "PM",
        .value = 180.0 + phase_at_ugb,
        .unit = "deg",
        .valid = true,
    };
}

/// Compute the DC gain from the first point of a magnitude response.
pub fn dcGain(wf: *const Waveform) Measurement {
    if (wf.y_data.len == 0) return .{ .name = "A_dc", .unit = "dB" };
    return .{ .name = "A_dc", .value = wf.y_data[0], .unit = "dB", .valid = true };
}

/// Compute slew rate from a transient step response.
/// Finds the maximum |dy/dx| in the waveform.
pub fn slewRate(wf: *const Waveform) Measurement {
    if (wf.y_data.len < 2 or wf.x_data.len < 2)
        return .{ .name = "SR", .unit = "V/s" };

    var max_slope: f64 = 0.0;
    for (1..wf.y_data.len) |i| {
        const dt = wf.x_data[i] - wf.x_data[i - 1];
        if (dt <= 0.0) continue;
        const slope = @abs(wf.y_data[i] - wf.y_data[i - 1]) / dt;
        if (slope > max_slope) max_slope = slope;
    }

    return .{
        .name = "SR",
        .value = max_slope,
        .unit = "V/s",
        .valid = max_slope > 0.0,
    };
}

/// Compute settling time to within `tolerance` of final value.
pub fn settlingTime(wf: *const Waveform, tolerance: f64) Measurement {
    if (wf.y_data.len < 2)
        return .{ .name = "t_settle", .unit = "s" };

    const final_val = wf.y_data[wf.y_data.len - 1];
    const band = @abs(final_val) * tolerance;

    // Walk backward to find last point outside settling band
    var settle_idx: usize = wf.y_data.len - 1;
    while (settle_idx > 0) : (settle_idx -= 1) {
        if (@abs(wf.y_data[settle_idx] - final_val) > band) {
            settle_idx += 1;
            break;
        }
    }

    if (settle_idx >= wf.x_data.len) settle_idx = wf.x_data.len - 1;
    return .{
        .name = "t_settle",
        .value = wf.x_data[settle_idx] - wf.x_data[0],
        .unit = "s",
        .valid = true,
    };
}

/// Find min/max values in a waveform.
pub fn minMax(wf: *const Waveform) struct { min: f64, max: f64, min_x: f64, max_x: f64 } {
    if (wf.y_data.len == 0)
        return .{ .min = 0.0, .max = 0.0, .min_x = 0.0, .max_x = 0.0 };

    var min_val: f64 = wf.y_data[0];
    var max_val: f64 = wf.y_data[0];
    var min_idx: usize = 0;
    var max_idx: usize = 0;

    for (wf.y_data, 0..) |y, i| {
        if (y < min_val) {
            min_val = y;
            min_idx = i;
        }
        if (y > max_val) {
            max_val = y;
            max_idx = i;
        }
    }

    return .{
        .min = min_val,
        .max = max_val,
        .min_x = if (min_idx < wf.x_data.len) wf.x_data[min_idx] else 0.0,
        .max_x = if (max_idx < wf.x_data.len) wf.x_data[max_idx] else 0.0,
    };
}

// ── Multi-sweep aggregation ──────────────────────────────────────────────────

/// Extract measurements from a complete AC simulation result.
/// Returns gain, bandwidth, phase margin, unity-gain frequency.
pub fn extractAcMetrics(
    arena: std.mem.Allocator,
    result: *const SimResult,
    output_node: []const u8,
) ![4]Measurement {
    var metrics: [4]Measurement = .{
        .{ .name = "A_dc", .unit = "dB" },
        .{ .name = "f_3dB", .unit = "Hz" },
        .{ .name = "PM", .unit = "deg" },
        .{ .name = "f_ugb", .unit = "Hz" },
    };

    // Find the output waveform
    const wf = result.waveformByName(output_node) orelse return metrics;

    // Compute magnitude in dB
    const mag_wf = try magnitudeDb(arena, wf);

    metrics[0] = dcGain(&mag_wf);
    metrics[1] = bandwidth3dB(&mag_wf);
    metrics[3] = unityGainFreq(&mag_wf);

    // Compute phase if complex data available
    if (wf.isComplex()) {
        const phase_wf = try phaseDeg(arena, wf);
        metrics[2] = phaseMargin(&mag_wf, &phase_wf);
    }

    return metrics;
}

// ── Utilities ────────────────────────────────────────────────────────────────

/// Linear interpolation of y-value at a given x position.
fn interpolateAt(wf: *const Waveform, x: f64) f64 {
    if (wf.x_data.len == 0) return 0.0;
    if (wf.x_data.len == 1) return wf.y_data[0];

    // Find bracketing indices
    for (1..wf.x_data.len) |i| {
        if (wf.x_data[i] >= x) {
            const x0 = wf.x_data[i - 1];
            const x1 = wf.x_data[i];
            const y0 = wf.y_data[i - 1];
            const y1 = wf.y_data[i];
            const t = if (x1 != x0) (x - x0) / (x1 - x0) else 0.0;
            return y0 + t * (y1 - y0);
        }
    }

    // x is beyond data range; return last value
    return wf.y_data[wf.y_data.len - 1];
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "magnitudeDb: basic computation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const x = [_]f64{ 1.0, 10.0, 100.0, 1000.0 };
    const y_re = [_]f64{ 10.0, 7.07, 1.0, 0.1 };
    const y_im = [_]f64{ 0.0, 7.07, 0.0, 0.0 };

    const wf = Waveform{
        .name = "v(out)",
        .x_data = &x,
        .y_data = &y_re,
        .y_imag = &y_im,
        .x_unit = "Hz",
        .y_unit = "V",
    };

    const result = try magnitudeDb(arena, &wf);
    // First point: |10 + 0j| = 10 -> 20*log10(10) = 20 dB
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), result.y_data[0], 0.01);
    try std.testing.expectEqualStrings("dB", result.y_unit);
}

test "phaseDeg: basic computation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const x = [_]f64{ 1.0, 10.0 };
    const y_re = [_]f64{ 1.0, 0.0 };
    const y_im = [_]f64{ 0.0, -1.0 };

    const wf = Waveform{
        .name = "v(out)",
        .x_data = &x,
        .y_data = &y_re,
        .y_imag = &y_im,
    };

    const result = try phaseDeg(arena, &wf);
    // atan2(0, 1) = 0 deg
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.y_data[0], 0.01);
    // atan2(-1, 0) = -90 deg
    try std.testing.expectApproxEqAbs(@as(f64, -90.0), result.y_data[1], 0.01);
}

test "bandwidth3dB: first-order system" {
    // Simulate a first-order low-pass: flat at 20dB, drops to 16.5dB at 1kHz
    const n = 5;
    const x = [n]f64{ 1.0, 10.0, 100.0, 1000.0, 10000.0 };
    const y = [n]f64{ 20.0, 20.0, 19.5, 16.5, 0.0 };

    const wf = Waveform{
        .name = "gain",
        .x_data = &x,
        .y_data = &y,
        .y_unit = "dB",
    };

    const result = bandwidth3dB(&wf);
    try std.testing.expect(result.valid);
    // -3dB = 17.0; crosses between 100Hz (19.5) and 1000Hz (16.5)
    try std.testing.expect(result.value > 100.0);
    try std.testing.expect(result.value < 1000.0);
}

test "slewRate: step response" {
    const x = [_]f64{ 0.0, 1e-6, 2e-6, 3e-6, 4e-6 };
    const y = [_]f64{ 0.0, 0.5, 1.5, 1.8, 1.8 };

    const wf = Waveform{
        .name = "v(out)",
        .x_data = &x,
        .y_data = &y,
    };

    const result = slewRate(&wf);
    try std.testing.expect(result.valid);
    // Max slope is 1.0V / 1us = 1e6 V/s
    try std.testing.expectApproxEqAbs(@as(f64, 1e6), result.value, 1e3);
}

test "settlingTime: basic" {
    const x = [_]f64{ 0.0, 1e-6, 2e-6, 3e-6, 4e-6, 5e-6 };
    const y = [_]f64{ 0.0, 1.5, 1.1, 0.98, 1.01, 1.0 };

    const wf = Waveform{
        .name = "v(out)",
        .x_data = &x,
        .y_data = &y,
    };

    const result = settlingTime(&wf, 0.05); // 5% tolerance
    try std.testing.expect(result.valid);
    // Should settle around 3-4us (where it enters the 5% band of final=1.0)
    try std.testing.expect(result.value >= 2e-6);
    try std.testing.expect(result.value <= 5e-6);
}

test "minMax: basic" {
    const x = [_]f64{ 0.0, 1.0, 2.0, 3.0 };
    const y = [_]f64{ 1.0, 3.5, -0.5, 2.0 };
    const wf = Waveform{ .x_data = &x, .y_data = &y };

    const mm = minMax(&wf);
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), mm.min, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), mm.max, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), mm.min_x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), mm.max_x, 1e-10);
}

test "interpolateAt: within range" {
    const x = [_]f64{ 0.0, 1.0, 2.0, 3.0 };
    const y = [_]f64{ 0.0, 10.0, 20.0, 30.0 };
    const wf = Waveform{ .x_data = &x, .y_data = &y };

    const val = interpolateAt(&wf, 1.5);
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), val, 1e-10);
}
