const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Subprocess = struct {
    child: std.process.Child,
    stdin_pipe: std.fs.File,
    stdout_pipe: std.fs.File,
    stderr_pipe: std.fs.File,
    alive: bool,
    partial_pos: usize = 0,

    pub fn spawn(alloc: Allocator, argv: []const []const u8, cwd: ?[]const u8) !Subprocess {
        var child = std.process.Child.init(argv, alloc);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        if (cwd) |d| child.cwd = d;

        try child.spawn();

        const stdout = child.stdout.?;

        // Set O_NONBLOCK on stdout so readLine never blocks the GUI tick.
        const fd = stdout.handle;
        var fl_flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch 0;
        fl_flags |= 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
        _ = std.posix.fcntl(fd, std.posix.F.SETFL, fl_flags) catch {};

        return .{
            .child = child,
            .stdin_pipe = child.stdin.?,
            .stdout_pipe = stdout,
            .stderr_pipe = child.stderr.?,
            .alive = true,
        };
    }

    pub fn kill(self: *Subprocess) void {
        if (!self.alive) return;
        _ = self.child.kill() catch {};
        self.alive = false;
    }

    pub fn isAlive(self: *Subprocess) bool {
        if (!self.alive) return false;
        // Signal 0 probes process existence without sending a real signal.
        std.posix.kill(self.child.id, 0) catch {
            self.alive = false;
            return false;
        };
        return true;
    }

    pub fn writeAll(self: *Subprocess, data: []const u8) !void {
        try self.stdin_pipe.writeAll(data);
    }

    pub fn writeLine(self: *Subprocess, line: []const u8) !void {
        try self.stdin_pipe.writeAll(line);
        try self.stdin_pipe.writeAll("\n");
    }

    /// Read one newline-delimited line from stdout (non-blocking).
    ///
    /// Returns the line content (without trailing newline), or `null` if no
    /// complete line is available yet. Partial data is kept in `buf` across
    /// calls via `self.partial_pos`.
    ///
    /// Caller must pass the same buffer for consecutive calls on the same
    /// subprocess instance.
    pub fn readLine(self: *Subprocess, buf: []u8) !?[]const u8 {
        var pos = self.partial_pos;
        while (pos < buf.len) {
            var one: [1]u8 = undefined;
            const n = self.stdout_pipe.read(&one) catch |err| {
                if (err == error.WouldBlock) {
                    // No data available right now.
                    self.partial_pos = pos;
                    return null;
                }
                return err;
            };
            if (n == 0) {
                // EOF
                if (pos == 0) {
                    self.partial_pos = 0;
                    return null;
                }
                const line = buf[0..pos];
                self.partial_pos = 0;
                return line;
            }
            if (one[0] == '\n') {
                const line = buf[0..pos];
                self.partial_pos = 0;
                return line;
            }
            buf[pos] = one[0];
            pos += 1;
        }
        // Buffer full -- return what we have.
        self.partial_pos = 0;
        return buf[0..pos];
    }

    pub fn deinit(self: *Subprocess) void {
        self.kill();
        self.stdin_pipe.close();
        self.stdout_pipe.close();
        self.stderr_pipe.close();
    }
};

// -- Tests --------------------------------------------------------------------

test "spawn echo and read output" {
    var proc = try Subprocess.spawn(std.testing.allocator, &.{ "echo", "hello" }, null);
    defer proc.deinit();

    var buf: [256]u8 = undefined;

    // Non-blocking read may need a few attempts until echo output arrives.
    var line: ?[]const u8 = null;
    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        line = try proc.readLine(&buf);
        if (line != null) break;
        std.Thread.sleep(1_000_000); // 1ms
    }
    try std.testing.expect(line != null);
    try std.testing.expectEqualStrings("hello", line.?);
}

test "writeLine sends data to child stdin" {
    // Use cat which echoes stdin to stdout.
    var proc = try Subprocess.spawn(std.testing.allocator, &.{"cat"}, null);
    defer proc.deinit();

    try proc.writeLine("test line");
    // Close stdin so cat flushes and exits.
    proc.stdin_pipe.close();
    // Reopen as a no-op to avoid double-close in deinit.
    proc.stdin_pipe = proc.stdout_pipe;

    var buf: [256]u8 = undefined;

    // Non-blocking read may need a few attempts.
    var line: ?[]const u8 = null;
    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        line = try proc.readLine(&buf);
        if (line != null) break;
        std.Thread.sleep(1_000_000); // 1ms
    }
    try std.testing.expect(line != null);
    try std.testing.expectEqualStrings("test line", line.?);
}

test "readLine returns null when no data available" {
    // Spawn sleep so we have a process with no stdout output.
    var proc = try Subprocess.spawn(std.testing.allocator, &.{ "sleep", "10" }, null);
    defer proc.deinit();

    var buf: [256]u8 = undefined;
    const result = try proc.readLine(&buf);
    try std.testing.expect(result == null);
    // Partial position should stay at 0 (nothing read).
    try std.testing.expectEqual(@as(usize, 0), proc.partial_pos);
}
