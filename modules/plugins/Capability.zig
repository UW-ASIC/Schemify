const std = @import("std");

pub const FileScope = enum { project, plugin_data };

pub const Capability = packed struct {
    file_read_project: bool = false,
    file_read_plugin_data: bool = false,
    file_write_plugin_data: bool = false,
    schematic_mutate: bool = false,
    network: bool = false,
    _pad: u3 = 0,
};

pub const MAX_PROCESSES = 8;
pub const MAX_PROCESS_NAME = 64;

pub const AllowedProcesses = struct {
    names: [MAX_PROCESSES][MAX_PROCESS_NAME]u8 = undefined,
    len: u8 = 0,

    pub fn add(self: *AllowedProcesses, name: []const u8) void {
        if (self.len >= MAX_PROCESSES) return;
        const n: usize = @min(name.len, MAX_PROCESS_NAME);
        @memcpy(self.names[self.len][0..n], name[0..n]);
        if (n < MAX_PROCESS_NAME) self.names[self.len][n] = 0;
        self.len += 1;
    }
};

fn nameMatch(buf: [MAX_PROCESS_NAME]u8, name: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, &buf, 0) orelse MAX_PROCESS_NAME;
    return end == name.len and std.mem.eql(u8, buf[0..end], name);
}

pub fn isProcessAllowed(procs: AllowedProcesses, name: []const u8) bool {
    for (procs.names[0..procs.len]) |buf| {
        if (nameMatch(buf, name)) return true;
    }
    return false;
}

fn isUnder(path: []const u8, dir: []const u8) bool {
    return path.len >= dir.len and std.mem.eql(u8, path[0..dir.len], dir) and
        (path.len == dir.len or path[dir.len] == '/');
}

pub fn validateReadPath(cap: Capability, path: []const u8, plugin_data_dir: []const u8, project_dir: []const u8) bool {
    if (cap.file_read_plugin_data and isUnder(path, plugin_data_dir)) return true;
    if (cap.file_read_project and isUnder(path, project_dir)) return true;
    return false;
}

pub fn validateWritePath(cap: Capability, path: []const u8, plugin_data_dir: []const u8) bool {
    return cap.file_write_plugin_data and isUnder(path, plugin_data_dir);
}

test "read path validation" {
    const cap = Capability{ .file_read_project = true, .file_read_plugin_data = true };
    try std.testing.expect(validateReadPath(cap, "/proj/foo.sch", "/data", "/proj"));
    try std.testing.expect(validateReadPath(cap, "/data/state.json", "/data", "/proj"));
    try std.testing.expect(!validateReadPath(cap, "/etc/passwd", "/data", "/proj"));
}

test "write path validation" {
    const cap = Capability{ .file_write_plugin_data = true };
    try std.testing.expect(validateWritePath(cap, "/data/out.json", "/data"));
    try std.testing.expect(!validateWritePath(cap, "/proj/evil.sch", "/data"));
}

test "process allow list" {
    var procs = AllowedProcesses{};
    procs.add("git");
    try std.testing.expect(isProcessAllowed(procs, "git"));
    try std.testing.expect(!isProcessAllowed(procs, "rm"));
}
