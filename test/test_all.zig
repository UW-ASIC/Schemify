// test/test_all.zig — Aggregate test entry point.
//
// Imports all test files so `zig build test` discovers every test in one pass.
// Uses test_runner.zig (configured in build.zig) for verbose output + leak detection.

comptime {
    _ = @import("test_pyspice_import.zig");
}
