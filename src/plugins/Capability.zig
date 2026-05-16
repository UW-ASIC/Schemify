const std = @import("std");

pub const FileScope = enum { project, plugin_data };

pub const Capability = packed struct {
    file_read_project: bool = false,
    file_read_plugin_data: bool = false,
    file_write_plugin_data: bool = false,
    schematic_mutate: bool = false,
    network: bool = false,
    canvas_draw: bool = false,
    simulate: bool = false,
    _pad: u1 = 0,
};

pub fn fromName(name: []const u8) ?Capability {
    const fields = .{
        .{ "file_read_project", Capability{ .file_read_project = true } },
        .{ "file_read_plugin_data", Capability{ .file_read_plugin_data = true } },
        .{ "file_write_plugin_data", Capability{ .file_write_plugin_data = true } },
        .{ "schematic_mutate", Capability{ .schematic_mutate = true } },
        .{ "network", Capability{ .network = true } },
        .{ "canvas_draw", Capability{ .canvas_draw = true } },
        .{ "simulate", Capability{ .simulate = true } },
    };
    inline for (fields) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

pub fn merge(a: Capability, b: Capability) Capability {
    return @bitCast(@as(u8, @bitCast(a)) | @as(u8, @bitCast(b)));
}

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

test "fromName returns correct single-field Capability" {
    const cap = fromName("file_read_project").?;
    try std.testing.expect(cap.file_read_project);
    try std.testing.expect(!cap.file_read_plugin_data);
    try std.testing.expect(!cap.network);
    try std.testing.expect(!cap.canvas_draw);
    try std.testing.expect(!cap.simulate);

    const draw = fromName("canvas_draw").?;
    try std.testing.expect(draw.canvas_draw);
    try std.testing.expect(!draw.file_read_project);

    const sim = fromName("simulate").?;
    try std.testing.expect(sim.simulate);
    try std.testing.expect(!sim.network);
}

test "fromName returns null for unknown name" {
    try std.testing.expect(fromName("unknown_capability") == null);
    try std.testing.expect(fromName("") == null);
    try std.testing.expect(fromName("FILE_READ_PROJECT") == null);
}

test "merge combines two Capabilities" {
    const a = Capability{ .file_read_project = true, .network = true };
    const b = Capability{ .canvas_draw = true, .simulate = true };
    const merged = merge(a, b);
    try std.testing.expect(merged.file_read_project);
    try std.testing.expect(merged.network);
    try std.testing.expect(merged.canvas_draw);
    try std.testing.expect(merged.simulate);
    try std.testing.expect(!merged.schematic_mutate);

    // Merging with empty is identity
    const empty = Capability{};
    const same = merge(a, empty);
    try std.testing.expect(same.file_read_project);
    try std.testing.expect(same.network);
    try std.testing.expect(!same.canvas_draw);
}
