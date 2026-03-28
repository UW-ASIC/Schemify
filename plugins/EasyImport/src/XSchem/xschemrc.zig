// xschemrc.zig - XSchemRC parser using full Tcl evaluation.
//
// Evaluates the entire xschemrc file through the Tcl evaluator, then reads
// resolved variables to extract library paths, PDK root, start window, and
// netlist directory. This replaces line-by-line pattern matching which fails
// on real-world xschemrc files with nested Tcl constructs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tcl = @import("tcl").Tcl;

/// Result of parsing an xschemrc file. All strings are arena-owned.
pub const RcResult = struct {
    project_dir: []const u8,
    start_window: ?[]const u8,
    lib_paths: []const []const u8,
    netlist_dir: ?[]const u8,
    xschem_sharedir: []const u8,
    user_conf_dir: []const u8,
    pdk_root: ?[]const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *RcResult) void {
        self.arena.deinit();
    }
};

/// Parse an xschemrc file using full Tcl evaluation.
///
/// `backing` is the allocator for the arena and Tcl evaluator internals.
/// `bytes` is the raw content of the xschemrc file.
/// `xschemrc_dir` is the directory containing the xschemrc file.
/// `xschemrc_path` is the absolute path to the xschemrc file itself.
pub fn parseRc(
    backing: Allocator,
    bytes: []const u8,
    xschemrc_dir: []const u8,
    xschemrc_path: []const u8,
) !RcResult {
    var result_arena = std.heap.ArenaAllocator.init(backing);
    errdefer result_arena.deinit();
    const aa = result_arena.allocator();

    // Create Tcl evaluator and set up context
    var tcl = Tcl.init(backing);
    defer tcl.deinit();

    // Set `info script` path so [file dirname [info script]] works
    tcl.setScriptPath(xschemrc_path);

    // Pre-seed standard variables
    try seedDefaults(&tcl, xschemrc_dir);

    // Evaluate the entire xschemrc through the Tcl evaluator.
    // Catch errors from unsupported constructs (proc, switch, etc.)
    // which are DRC helpers that don't affect path resolution.
    _ = tcl.eval(bytes) catch |err| blk: {
        switch (err) {
            error.UnsupportedConstruct => {}, // Expected for proc/switch/etc
            else => {}, // Continue on any Tcl error -- partial evaluation is fine
        }
        break :blk "";
    };

    // Read resolved variables from the Tcl variable table
    const sharedir = tcl.getVar("XSCHEM_SHAREDIR") orelse "/usr/share/xschem";
    const user_conf = tcl.getVar("USER_CONF_DIR") orelse blk: {
        if (std.posix.getenv("HOME")) |home| {
            break :blk try std.fmt.allocPrint(aa, "{s}/.xschem", .{home});
        }
        break :blk "~/.xschem";
    };

    // Extract library paths from XSCHEM_LIBRARY_PATH (colon-separated)
    const lib_paths = try extractLibPaths(
        aa,
        tcl.getVar("XSCHEM_LIBRARY_PATH"),
        xschemrc_dir,
    );

    // Extract start window
    const raw_start = tcl.getVar("XSCHEM_START_WINDOW");
    const start_window: ?[]const u8 = if (raw_start) |s|
        (if (s.len == 0) null else try aa.dupe(u8, s))
    else
        null;

    // Extract netlist directory
    const raw_netlist = tcl.getVar("netlist_dir");
    const netlist_dir: ?[]const u8 = if (raw_netlist) |s|
        (if (s.len == 0) null else try aa.dupe(u8, s))
    else
        null;

    // Extract PDK_ROOT (may have been set/modified by the script)
    const raw_pdk = tcl.getVar("PDK_ROOT");
    const pdk_root: ?[]const u8 = if (raw_pdk) |s|
        (if (s.len == 0) null else try aa.dupe(u8, s))
    else
        null;

    return .{
        .project_dir = try aa.dupe(u8, xschemrc_dir),
        .start_window = start_window,
        .lib_paths = lib_paths,
        .netlist_dir = netlist_dir,
        .xschem_sharedir = try aa.dupe(u8, sharedir),
        .user_conf_dir = try aa.dupe(u8, user_conf),
        .pdk_root = pdk_root,
        .arena = result_arena,
    };
}

/// Pre-seed the Tcl evaluator with standard XSchem variables.
fn seedDefaults(tcl: *Tcl, xschemrc_dir: []const u8) !void {
    const aa = tcl.evaluator.arena.allocator();
    // XSCHEM_SHAREDIR: probe env var, then standard paths, then PATH-based, then fallback
    const sharedir = std.posix.getenv("XSCHEM_SHAREDIR") orelse
        probeShareDir() orelse
        probeShareDirFromBinary(aa) orelse
        "/usr/share/xschem";
    try tcl.setVar("XSCHEM_SHAREDIR", sharedir);

    // USER_CONF_DIR: env var or ~/.xschem
    if (std.posix.getenv("USER_CONF_DIR")) |ucd| {
        try tcl.setVar("USER_CONF_DIR", ucd);
    } else if (std.posix.getenv("HOME")) |home| {
        const path = std.fmt.allocPrint(aa, "{s}/.xschem", .{home}) catch
            return error.OutOfMemory;
        try tcl.setVar("USER_CONF_DIR", path);
    } else {
        try tcl.setVar("USER_CONF_DIR", "~/.xschem");
    }

    // PDK_ROOT: only if env var is set
    if (std.posix.getenv("PDK_ROOT")) |pdk| {
        try tcl.setVar("PDK_ROOT", pdk);
    }

    // Set a project directory variable (used by some xschemrc files)
    _ = xschemrc_dir;
}

/// Probe standard paths for XSCHEM_SHAREDIR.
fn probeShareDir() ?[]const u8 {
    const candidates = [_][]const u8{
        "/usr/share/xschem",
        "/usr/local/share/xschem",
    };
    for (&candidates) |path| {
        std.fs.cwd().access(path, .{}) catch continue;
        return path;
    }
    return null;
}

/// Derive XSCHEM_SHAREDIR from the xschem binary on PATH.
/// Handles NixOS, Homebrew, Guix, and other non-FHS prefixes.
fn probeShareDirFromBinary(aa: Allocator) ?[]const u8 {
    const path_env = std.posix.getenv("PATH") orelse return null;
    var iter = std.mem.splitScalar(u8, path_env, ':');
    while (iter.next()) |dir| {
        if (dir.len == 0) continue;
        const xschem_bin = std.fs.path.join(aa, &.{ dir, "xschem" }) catch return null;
        // Resolve symlinks to get the real binary location
        const real_bin = std.fs.cwd().realpathAlloc(aa, xschem_bin) catch continue;
        // Derive: /prefix/bin/xschem → /prefix/share/xschem
        const bin_dir = std.fs.path.dirname(real_bin) orelse continue;
        const prefix = std.fs.path.dirname(bin_dir) orelse continue;
        const share_dir = std.fs.path.join(aa, &.{ prefix, "share", "xschem" }) catch return null;
        // Verify the device symbols directory exists
        const dev_dir = std.fs.path.join(aa, &.{ share_dir, "xschem_library", "devices" }) catch return null;
        std.fs.cwd().access(dev_dir, .{}) catch continue;
        return share_dir;
    }
    return null;
}

/// Extract library paths from a colon-separated XSCHEM_LIBRARY_PATH string.
/// Splits by ':', filters empty segments, resolves relative paths against
/// `base_dir`, and arena-dupes each path.
fn extractLibPaths(
    aa: Allocator,
    raw: ?[]const u8,
    base_dir: []const u8,
) ![]const []const u8 {
    const val = raw orelse return try aa.alloc([]const u8, 0);
    if (val.len == 0) return try aa.alloc([]const u8, 0);

    var paths: std.ArrayListUnmanaged([]const u8) = .{};

    var iter = std.mem.splitScalar(u8, val, ':');
    while (iter.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t\r\n");
        if (trimmed.len == 0) continue;

        // Resolve relative paths against xschemrc directory
        const resolved = if (!std.fs.path.isAbsolute(trimmed))
            try std.fs.path.join(aa, &.{ base_dir, trimmed })
        else
            try aa.dupe(u8, trimmed);

        try paths.append(aa, resolved);
    }

    return try paths.toOwnedSlice(aa);
}
