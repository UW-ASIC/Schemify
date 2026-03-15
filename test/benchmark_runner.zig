//! Custom test runner for per-function benchmarks.
//!
//! Used as the --test-runner for `zig build get_bench`.
//! Each test binary receives BENCH_SOURCE_FILE via the environment.
//!
//! Tests must be named:  "Benchmark <FILE_NAME> <FUNCTION_NAME>"
//!
//! The runner times each matching test (wall-clock ns) and writes one line
//! per benchmark to stdout:
//!
//!   <ns>\t<file>/<fn>: <ns>ns (<μs>.x μs)
//!
//! build.zig collects all lines, sorts highest → lowest, and prints them.

const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const source_file = std.process.getEnvVarOwned(alloc, "BENCH_SOURCE_FILE") catch "unknown";
    defer alloc.free(source_file);
    const stem = std.fs.path.stem(std.fs.path.basename(source_file));

    const stdout = std.io.getStdOut().writer();
    const prefix = "Benchmark ";

    for (builtin.test_functions) |t| {
        if (!std.mem.startsWith(u8, t.name, prefix)) continue;

        // Warm-up run (ignored).
        t.func() catch {};

        const t0 = std.time.nanoTimestamp();
        t.func() catch {};
        const elapsed: u64 = @intCast(std.time.nanoTimestamp() - t0);

        // Strip "Benchmark " prefix for display.
        const display = t.name[prefix.len..];
        const us = @as(f64, @floatFromInt(elapsed)) / 1000.0;

        try stdout.print("{d}\t{s}/{s}: {d}ns ({d:.1} μs)\n", .{
            elapsed, stem, display, elapsed, us,
        });
    }
}
