//! Volare wrapper — detect and invoke the Volare PDK manager.
//!
//! Detection priority:
//!   1. local         — bundled dep at ~/.config/Schemify/PDKLoader/dep/volare/
//!   2. cli           — `volare` binary in PATH
//!   3. python_module — `python3 -m volare`

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How the Volare executable was found.
pub const Kind = enum { none, local, cli, python_module };

/// Build the path to the bundled volare __main__.py into `buf`.
/// Returns a slice into `buf`, or null if `home` is empty or buf is too small.
pub fn localMainPath(home: []const u8, buf: []u8) ?[]const u8 {
    if (home.len == 0) return null;
    return std.fmt.bufPrint(
        buf,
        "{s}/.config/Schemify/PDKLoader/dep/volare/volare/__main__.py",
        .{home},
    ) catch null;
}

/// Probe the environment for volare. `home` is used to locate the bundled dep.
pub fn detect(alloc: Allocator, home: []const u8) Kind {
    var buf: [512]u8 = undefined;
    if (localMainPath(home, &buf)) |main_py|
        if (runOk(alloc, &.{ "python3", main_py, "--version" })) return .local;
    if (runOk(alloc, &.{ "volare", "--version" })) return .cli;
    if (runOk(alloc, &.{ "python3", "-m", "volare", "--version" })) return .python_module;
    return .none;
}

/// Fetch a PDK family. `local_main` is the path to volare's __main__.py (used
/// when kind == .local); ignored for .cli / .python_module.
/// Pass null or "" for `version` to fetch the latest available release.
pub fn fetchPdk(
    alloc: Allocator,
    kind: Kind,
    local_main: []const u8,
    pdk: []const u8,
    version: ?[]const u8,
) bool {
    if (kind == .none) return false;
    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(alloc);
    appendPrefix(&argv, alloc, kind, local_main) catch return false;
    argv.appendSlice(alloc, &.{ "fetch", "--pdk", pdk }) catch return false;
    if (version) |v| {
        if (v.len > 0 and !std.mem.eql(u8, v, "latest"))
            argv.append(alloc, v) catch return false;
    }
    var child = std.process.Child.init(argv.items, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return term == .Exited and term.Exited == 0;
}

/// Query available versions for `pdk` from `volare ls --pdk <pdk>`.
/// Writes version token strings into `out` (each slot [80]u8) and their lengths
/// into `out_lens`. Returns the count of entries written (≤ out.len).
pub fn listVersions(
    alloc: Allocator,
    kind: Kind,
    local_main: []const u8,
    pdk: []const u8,
    out: [][80]u8,
    out_lens: []u8,
) u8 {
    if (kind == .none or out.len == 0) return 0;
    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(alloc);
    appendPrefix(&argv, alloc, kind, local_main) catch return 0;
    argv.appendSlice(alloc, &.{ "ls", "--pdk", pdk }) catch return 0;

    const res = std.process.Child.run(.{
        .allocator        = alloc,
        .argv             = argv.items,
        .max_output_bytes = 32768,
    }) catch return 0;
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);

    var count: u8 = 0;
    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    while (lines.next()) |raw| {
        if (count >= out.len) break;
        // Strip whitespace, leading dashes and asterisks (volare uses these as
        // list markers and "currently installed" markers).
        const line = std.mem.trim(u8, raw, " \t\r-*");
        if (line.len == 0) continue;
        // Version tokens start with a digit, e.g. "1.0.496-0-gc0ad4f2".
        // Anything else (header, parenthetical) is skipped.
        const end = std.mem.indexOfAny(u8, line, " \t(") orelse line.len;
        const tok = line[0..end];
        if (tok.len == 0 or !std.ascii.isDigit(tok[0])) continue;
        const n: u8 = @intCast(@min(tok.len, 79));
        @memcpy(out[count][0..n], tok[0..n]);
        out[count][n] = 0;
        out_lens[count] = n;
        count += 1;
    }
    return count;
}

/// Check whether `<home>/.volare/<pdk>` exists; writes path into `buf` and
/// returns a slice, or null when the PDK has not been installed yet.
pub fn pdkRoot(home: []const u8, pdk: []const u8, buf: []u8) ?[]const u8 {
    if (home.len == 0) return null;
    const path = std.fmt.bufPrint(buf, "{s}/.volare/{s}", .{ home, pdk }) catch return null;
    std.fs.cwd().access(path, .{}) catch return null;
    return path;
}

// ── internals ─────────────────────────────────────────────────────────────── //

fn appendPrefix(argv: *std.ArrayListUnmanaged([]const u8), alloc: Allocator, kind: Kind, local_main: []const u8) !void {
    switch (kind) {
        .local         => try argv.appendSlice(alloc, &.{ "python3", local_main }),
        .cli           => try argv.append(alloc, "volare"),
        .python_module => try argv.appendSlice(alloc, &.{ "python3", "-m", "volare" }),
        .none          => unreachable,
    }
}

fn runOk(alloc: Allocator, argv: []const []const u8) bool {
    const res = std.process.Child.run(.{
        .allocator        = alloc,
        .argv             = argv,
        .max_output_bytes = 512,
    }) catch return false;
    alloc.free(res.stdout);
    alloc.free(res.stderr);
    return res.term == .Exited and res.term.Exited == 0;
}
