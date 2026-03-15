const std = @import("std");

fn commandExists(a: std.mem.Allocator, cmd: []const u8) bool {
    const sh_cmd = std.fmt.allocPrint(a, "command -v {s}", .{cmd}) catch return false;
    defer a.free(sh_cmd);

    const res = std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ "sh", "-c", sh_cmd },
    }) catch return false;
    defer a.free(res.stdout);
    defer a.free(res.stderr);

    return switch (res.term) {
        .Exited => |code| code == 0 and std.mem.trim(u8, res.stdout, " \t\r\n").len > 0,
        else => false,
    };
}

/// Hard gate for tests that require xschem.
pub fn requireXschem() !void {
    const a = std.testing.allocator;
    if (!commandExists(a, "xschem")) {
        std.debug.print(
            "preflight failed: xschem was not found on PATH.\n" ++
                "Install xschem and ensure `command -v xschem` succeeds before running these tests.\n",
            .{},
        );
        return error.MissingXschem;
    }
}
