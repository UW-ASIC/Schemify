//! Latin Hypercube Sampling for the Optimizer plugin.
//! Pure functions — no allocator, no I/O.

const std = @import("std");
const config = @import("config.zig");

pub const MAX_PARAMS = config.MAX_PARAMS;
pub const MAX_SAMPLES = 200;

/// Generate n_samples LHC candidates into `grid[0..n_samples]`.
/// Each candidate is a normalized [0,1] vector of length n_params.
pub fn generate(
    n_params: usize,
    n_samples: usize,
    grid: *[MAX_SAMPLES][MAX_PARAMS]f32,
    seed: u64,
) void {
    std.debug.assert(n_params <= MAX_PARAMS);
    std.debug.assert(n_samples <= MAX_SAMPLES);
    if (n_samples == 0 or n_params == 0) return;

    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();

    var perm: [MAX_SAMPLES]usize = undefined;
    for (0..n_samples) |i| perm[i] = i;

    for (0..n_params) |dim| {
        // Fisher-Yates shuffle
        var i: usize = n_samples;
        while (i > 1) {
            i -= 1;
            const j = r.intRangeAtMost(usize, 0, i);
            const tmp = perm[i];
            perm[i] = perm[j];
            perm[j] = tmp;
        }
        for (0..n_samples) |s| {
            const interval = @as(f32, @floatFromInt(perm[s]));
            const jitter = r.float(f32);
            grid[s][dim] = (interval + jitter) / @as(f32, @floatFromInt(n_samples));
        }
    }
}

/// Denormalize a normalized parameter value using a ParamEntry's min/max/step.
pub fn denormalize(p: *const config.ParamEntry, norm: f32) f32 {
    const val = p.min + norm * (p.max - p.min);
    if (p.step > 0) {
        return @round(val / p.step) * p.step;
    }
    return val;
}

test "generate produces values in [0,1]" {
    var grid: [MAX_SAMPLES][MAX_PARAMS]f32 = undefined;
    generate(4, 20, &grid, 42);
    for (0..20) |s| {
        for (0..4) |d| {
            try std.testing.expect(grid[s][d] >= 0.0);
            try std.testing.expect(grid[s][d] <= 1.0);
        }
    }
}

test "each interval covered exactly once per dimension" {
    const N: usize = 10;
    const P: usize = 3;
    var grid: [MAX_SAMPLES][MAX_PARAMS]f32 = undefined;
    generate(P, N, &grid, 7);
    for (0..P) |d| {
        var covered = [_]bool{false} ** N;
        for (0..N) |s| {
            const interval: usize = @intFromFloat(grid[s][d] * @as(f32, @floatFromInt(N)));
            const clamped = @min(interval, N - 1);
            try std.testing.expect(!covered[clamped]);
            covered[clamped] = true;
        }
    }
}

test "denormalize applies step" {
    var p = config.ParamEntry{};
    p.min = 0;
    p.max = 1e-6;
    p.step = 1e-7;
    const val = denormalize(&p, 0.35);
    try std.testing.expect(@mod(val, 1e-7) < 1e-10 or @mod(val, 1e-7) > 1e-7 - 1e-10);
}
