//! Project Config.toml parser
//!
//! Reads Config.toml from a project directory and parses into ProjectConfig.
//!
//! Paths support glob patterns (e.g. `"examples/*"`) which are expanded
//! recursively at parse time, filtering by file extension per key:
//!   - `chn`      → `.chn`
//!   - `chn_tb`   → `.chn_tb`
//!   - `chn_prim` → `.chn_prim`
//!
//! Expected Config.toml structure:
//! ```toml
//! name = "My Project"
//! [paths]
//! chn = ["examples/*"]
//! chn_tb = ["examples/*"]
//! chn_prim = ["src/core/devices/*.chn_prim"]
//! [simulation]
//! spice_include_paths = ["/pdk/spice"]
//! [plugins]
//! enabled = ["myplugin"]
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Vfs = @import("utility").Vfs;

/// Named error set for TOML parsing failures.
pub const ParseError = error{
    InvalidFormat,
    OutOfMemory,
};

pub const ProjectConfig = struct {
    name: []const u8 = "Untitled",
    paths: Paths = .{},
    pdk: ?[]const u8 = null,
    simulation: ?SimulationOptions = null,
    plugins: ?PluginOptions = null,
    plugin_specs: []const PluginSpec = &.{},
    arena: std.heap.ArenaAllocator,

    pub const Paths = struct {
        chn: []const []const u8 = &.{},
        chn_tb: []const []const u8 = &.{},
        chn_prim: []const []const u8 = &.{},
    };

    pub const SimulationOptions = struct {
        spice_include_paths: []const []const u8 = &.{},
    };

    pub const PluginOptions = struct {
        enabled: []const []const u8 = &.{},
        disabled: []const []const u8 = &.{},
    };

    /// Flattened, per-plugin record built from the `[plugins]` section.
    /// Plugins in `disabled` override those in `enabled`.
    pub const PluginSpec = struct {
        name: []const u8,
        enabled: bool,
        url: []const u8 = "",
        lazy: bool = false,
    };

    pub fn init(alloc: Allocator) ProjectConfig {
        return .{ .arena = std.heap.ArenaAllocator.init(alloc) };
    }

    pub fn deinit(self: *ProjectConfig) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Parse Config.toml from project directory. Returns default config if file missing.
    ///
    /// Uses Vfs so this works on both native (std.fs) and WASM (host.vfs_* imports).
    /// Glob patterns in path arrays (e.g. `"examples/*"`) are expanded recursively.
    pub fn parseFromPath(alloc: Allocator, project_dir: []const u8) !ProjectConfig {
        var config = ProjectConfig.init(alloc);
        errdefer config.deinit();

        const path = try std.fs.path.join(alloc, &.{ project_dir, "Config.toml" });
        defer alloc.free(path);

        const content = Vfs.readAlloc(alloc, path) catch |err| {
            if (err == error.FileNotFound) return config;
            return err;
        };
        defer alloc.free(content);

        try parseInto(&config, content);
        expandPathGlobs(&config, project_dir);
        buildPluginSpecs(&config);
        return config;
    }

    pub fn parseFromString(alloc: Allocator, content: []const u8) ParseError!ProjectConfig {
        var config = ProjectConfig.init(alloc);
        errdefer config.deinit();
        try parseInto(&config, content);
        buildPluginSpecs(&config);
        return config;
    }

    /// Parse from an arbitrary file path (used for user-level plugins.toml).
    pub fn parseFromFile(alloc: Allocator, path: []const u8) !ProjectConfig {
        var config = ProjectConfig.init(alloc);
        errdefer config.deinit();
        const content = Vfs.readAlloc(alloc, path) catch |err| {
            if (err == error.FileNotFound) return config;
            return err;
        };
        defer alloc.free(content);
        try parseInto(&config, content);
        buildPluginSpecs(&config);
        return config;
    }

    /// First schematic to open: .chn -> .chn_tb
    pub fn firstSchematicPath(self: *const ProjectConfig) ?[]const u8 {
        if (self.paths.chn.len > 0) return self.paths.chn[0];
        if (self.paths.chn_tb.len > 0) return self.paths.chn_tb[0];
        return null;
    }

    /// Return all resolved .chn, .chn_tb and .chn_prim file paths (for the
    /// file viewer). Caller must free the returned slice (but not the
    /// strings, which are arena-owned).
    pub fn allFiles(self: *const ProjectConfig, alloc: Allocator) []const []const u8 {
        var list: std.ArrayListUnmanaged([]const u8) = .{};
        for (self.paths.chn) |p| list.append(alloc, p) catch {};
        for (self.paths.chn_tb) |p| list.append(alloc, p) catch {};
        for (self.paths.chn_prim) |p| list.append(alloc, p) catch {};
        return list.toOwnedSlice(alloc) catch &.{};
    }
};

fn expandPathGlobs(config: *ProjectConfig, project_dir: []const u8) void {
    const arena = config.arena.allocator();
    config.paths.chn = expandGlobs(arena, project_dir, config.paths.chn, ".chn");
    config.paths.chn_tb = expandGlobs(arena, project_dir, config.paths.chn_tb, ".chn_tb");
    config.paths.chn_prim = expandGlobs(arena, project_dir, config.paths.chn_prim, ".chn_prim");
}

// ---------------------------------------------------------------------------
// Glob expansion
// ---------------------------------------------------------------------------

/// Expand glob patterns in a path array. Patterns containing `*` are treated
/// as directory prefixes: the `*` and everything after it is stripped, and the
/// resulting directory is walked recursively for files matching `ext`.
/// Non-glob entries are passed through unchanged.
fn expandGlobs(
    alloc: Allocator,
    project_dir: []const u8,
    raw_paths: []const []const u8,
    ext: []const u8,
) []const []const u8 {
    if (comptime @import("builtin").target.cpu.arch == .wasm32) return raw_paths;

    var result: std.ArrayListUnmanaged([]const u8) = .{};
    for (raw_paths) |p| {
        if (std.mem.indexOfScalar(u8, p, '*')) |star| {
            // Directory prefix is everything before the `*` (and any trailing `/`).
            const dir_part = if (star > 0 and p[star - 1] == '/')
                p[0 .. star - 1]
            else
                p[0..star];

            const abs_dir = if (dir_part.len == 0)
                alloc.dupe(u8, project_dir) catch continue
            else if (std.fs.path.isAbsolute(dir_part))
                alloc.dupe(u8, dir_part) catch continue
            else
                std.fs.path.join(alloc, &.{ project_dir, dir_part }) catch continue;
            defer alloc.free(abs_dir);

            walkDirForExt(alloc, abs_dir, dir_part, ext, &result);
        } else {
            result.append(alloc, p) catch {};
        }
    }
    return result.toOwnedSlice(alloc) catch raw_paths;
}

/// Recursively walk `abs_dir`, collecting files that end with `ext`.
/// Stored paths use `rel_prefix` so they remain relative to the project root.
fn walkDirForExt(
    alloc: Allocator,
    abs_dir: []const u8,
    rel_prefix: []const u8,
    ext: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) void {
    const listing = Vfs.listDir(alloc, abs_dir) catch return;
    defer listing.deinit(alloc);

    for (listing.entries) |name| {
        const sub_abs = std.fs.path.join(alloc, &.{ abs_dir, name }) catch continue;

        // Recurse into subdirectories.
        if (Vfs.isDir(sub_abs)) {
            defer alloc.free(sub_abs);
            const sub_rel = std.fs.path.join(alloc, &.{ rel_prefix, name }) catch continue;
            defer alloc.free(sub_rel);
            walkDirForExt(alloc, sub_abs, sub_rel, ext, out);
            continue;
        }
        alloc.free(sub_abs);

        if (!matchesExt(name, ext)) continue;
        const rel_path = std.fs.path.join(alloc, &.{ rel_prefix, name }) catch continue;
        out.append(alloc, rel_path) catch {
            alloc.free(rel_path);
        };
    }
}

fn matchesExt(name: []const u8, ext: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ext)) return false;
    if (!std.mem.eql(u8, ext, ".chn")) return true;
    return !std.mem.endsWith(u8, name, ".chn_tb") and !std.mem.endsWith(u8, name, ".chn_prim");
}

// ---------------------------------------------------------------------------
// Private parser helpers
// ---------------------------------------------------------------------------

const Section = enum { root, paths, simulation, plugins };

fn parseInto(config: *ProjectConfig, content: []const u8) ParseError!void {
    const alloc = config.arena.allocator();
    var lines = std.mem.splitScalar(u8, content, '\n');
    var section: Section = .root;

    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const name = std.mem.trim(u8, line[1..end], " \t");
            section = std.meta.stringToEnum(Section, name) orelse .root;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        switch (section) {
            .root => {
                if (std.mem.eql(u8, key, "name")) {
                    config.name = parseStr(alloc, val) catch continue;
                } else if (std.mem.eql(u8, key, "pdk")) {
                    config.pdk = parseStr(alloc, val) catch null;
                }
            },
            .paths => {
                if (std.mem.eql(u8, key, "chn")) {
                    config.paths.chn = try parseStrArray(alloc, val);
                } else if (std.mem.eql(u8, key, "chn_tb")) {
                    config.paths.chn_tb = try parseStrArray(alloc, val);
                } else if (std.mem.eql(u8, key, "chn_prim")) {
                    config.paths.chn_prim = try parseStrArray(alloc, val);
                }
            },
            .simulation => {
                if (std.mem.eql(u8, key, "spice_include_paths")) {
                    config.simulation = .{ .spice_include_paths = try parseStrArray(alloc, val) };
                }
            },
            .plugins => {
                if (config.plugins == null) config.plugins = .{};
                if (std.mem.eql(u8, key, "enabled")) {
                    config.plugins.?.enabled = try parseStrArray(alloc, val);
                } else if (std.mem.eql(u8, key, "disabled")) {
                    config.plugins.?.disabled = try parseStrArray(alloc, val);
                }
            },
        }
    }
}

/// Parse `"value"` into an allocated inner string. `val` must already be trimmed.
fn parseStr(alloc: Allocator, val: []const u8) ParseError![]const u8 {
    if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"')
        return alloc.dupe(u8, val[1 .. val.len - 1]);
    return error.InvalidFormat;
}

/// Parse `["a", "b", ...]` into an allocated slice of strings. `val` must already be trimmed.
fn parseStrArray(alloc: Allocator, val: []const u8) ParseError![]const []const u8 {
    if (val.len < 2 or val[0] != '[') return &.{};
    var list: std.ArrayListUnmanaged([]const u8) = .{};
    var i: usize = 1;
    while (i < val.len) : (i += 1) {
        if (val[i] == '"') {
            const end = std.mem.indexOfScalarPos(u8, val, i + 1, '"') orelse break;
            try list.append(alloc, try alloc.dupe(u8, val[i + 1 .. end]));
            i = end;
        }
    }
    return list.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Plugin spec builder
// ---------------------------------------------------------------------------

/// Flatten the `[plugins]` enabled/disabled string arrays into `plugin_specs`.
/// Entries in `disabled` override entries in `enabled`.
fn buildPluginSpecs(config: *ProjectConfig) void {
    const alloc = config.arena.allocator();
    const opts = config.plugins orelse return;

    var specs: std.ArrayListUnmanaged(ProjectConfig.PluginSpec) = .{};

    for (opts.enabled) |name| {
        const is_disabled = for (opts.disabled) |d| {
            if (std.mem.eql(u8, d, name)) break true;
        } else false;
        specs.append(alloc, .{ .name = name, .enabled = !is_disabled }) catch {};
    }

    // Disabled-only entries (not listed in enabled) are also recorded.
    for (opts.disabled) |name| {
        const already = for (opts.enabled) |e| {
            if (std.mem.eql(u8, e, name)) break true;
        } else false;
        if (!already) specs.append(alloc, .{ .name = name, .enabled = false }) catch {};
    }

    config.plugin_specs = specs.toOwnedSlice(alloc) catch &.{};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "toml parse name" {
    var cfg = try ProjectConfig.parseFromString(std.testing.allocator,
        \\name = "My Inverter"
    );
    defer cfg.deinit();
    try std.testing.expectEqualStrings("My Inverter", cfg.name);
}

test "toml parse paths array" {
    var cfg = try ProjectConfig.parseFromString(std.testing.allocator,
        \\[paths]
        \\chn = ["inv.chn", "buf.chn"]
        \\chn_tb = ["tb.chn_tb"]
    );
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 2), cfg.paths.chn.len);
    try std.testing.expectEqualStrings("inv.chn", cfg.paths.chn[0]);
    try std.testing.expectEqualStrings("buf.chn", cfg.paths.chn[1]);
    try std.testing.expectEqualStrings("tb.chn_tb", cfg.paths.chn_tb[0]);
}

test "toml firstSchematicPath" {
    var cfg = try ProjectConfig.parseFromString(std.testing.allocator,
        \\[paths]
        \\chn = ["top.chn"]
    );
    defer cfg.deinit();
    try std.testing.expectEqualStrings("top.chn", cfg.firstSchematicPath().?);
}

test "toml missing file returns default" {
    var cfg = try ProjectConfig.parseFromPath(std.testing.allocator, "/nonexistent/path");
    defer cfg.deinit();
    try std.testing.expectEqualStrings("Untitled", cfg.name);
}

test "Expose struct size for ProjectConfig" {
    const print = @import("std").debug.print;
    print("ProjectConfig: {d}B\n", .{@sizeOf(ProjectConfig)});
}
