//! Minimal custom test runner that prints ✓/✗ for each test (CLI tick marks).
//! Usage: zig build test_cosim (or test, test_core, test_library)
const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;

    for (builtin.test_functions) |t| {
        std.testing.allocator_instance = .{};
        defer {
            if (std.testing.allocator_instance.deinit() == .leak) {
                leak += 1;
            }
        }

        t.func() catch |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                std.debug.print("⊘ {s}\n", .{t.name});
                continue;
            },
            else => {
                fail += 1;
                std.debug.print("✗ {s} ({s})\n", .{ t.name, @errorName(err) });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
                continue;
            },
        };

        pass += 1;
        std.debug.print("✓ {s}\n", .{t.name});
    }

    std.debug.print("\n{d} passed", .{pass});
    if (fail > 0) std.debug.print(", {d} failed", .{fail});
    if (skip > 0) std.debug.print(", {d} skipped", .{skip});
    if (leak > 0) std.debug.print(", {d} leaked", .{leak});
    std.debug.print("\n", .{});

    if (fail > 0 or leak > 0) {
        std.process.exit(1);
    }
}
