//! Project Config.toml parser
//!
//! Reads Config.toml from a project directory and parses into ProjectConfig.
//!
//! Expected Config.toml structure:
//! ```toml
//! name = "My Project"
//! [paths]
//! chn = ["schematic.chn"]
//! chn_tb = ["tb.chn_tb"]
//! [legacy_paths]
//! schematics = ["legacy.sch"]
//! symbols = ["legacy.sym"]
//! [simulation]
//! spice_include_paths = ["/pdk/spice"]
//! [plugins]
//! enabled = ["myplugin"]
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Vfs = @import("core").Vfs;

pub const ProjectConfig = struct {
    name: []const u8 = "Untitled",
    paths: Paths = .{},
    legacy_paths: LegacyPaths = .{},
    pdk: ?[]const u8 = null,
    simulation: ?SimulationOptions = null,
    plugins: ?PluginOptions = null,
    arena: std.heap.ArenaAllocator,

    pub const Paths = struct {
        chn: []const []const u8 = &.{},
        chn_tb: []const []const u8 = &.{},
    };
    pub const LegacyPaths = struct {
        schematics: []const []const u8 = &.{},
        symbols: []const []const u8 = &.{},
    };
    pub const SimulationOptions = struct {
        spice_include_paths: []const []const u8 = &.{},
    };
    pub const PluginOptions = struct {
        enabled: []const []const u8 = &.{},
        disabled: []const []const u8 = &.{},
    };

    pub fn init(alloc: Allocator) ProjectConfig {
        return .{ .arena = std.heap.ArenaAllocator.init(alloc) };
    }

    pub fn deinit(self: *ProjectConfig) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *ProjectConfig) Allocator {
        return self.arena.allocator();
    }

    /// Parse Config.toml from project directory. Returns default config if file missing.
    ///
    /// Uses Vfs so this works on both native (std.fs) and WASM (host.vfs_* imports).
    pub fn parseFromPath(alloc: Allocator, project_dir: []const u8) !ProjectConfig {
        var config = init(alloc);
        errdefer config.deinit();
        const path = try std.fs.path.join(alloc, &.{ project_dir, "Config.toml" });
        defer alloc.free(path);
        const content = Vfs.readAlloc(alloc, path) catch |err| {
            if (err == error.FileNotFound) return config;
            return err;
        };
        defer alloc.free(content);
        try parseInto(&config, content);
        return config;
    }

    pub fn parseFromString(alloc: Allocator, content: []const u8) !ProjectConfig {
        var config = init(alloc);
        errdefer config.deinit();
        try parseInto(&config, content);
        return config;
    }

    /// First schematic to open: .chn → .chn_tb → legacy .sch
    pub fn firstSchematicPath(self: *const ProjectConfig) ?[]const u8 {
        if (self.paths.chn.len > 0) return self.paths.chn[0];
        if (self.paths.chn_tb.len > 0) return self.paths.chn_tb[0];
        if (self.legacy_paths.schematics.len > 0) return self.legacy_paths.schematics[0];
        return null;
    }
};

const Section = enum { root, paths, legacy_paths, simulation, plugins };

fn parseInto(config: *ProjectConfig, content: []const u8) !void {
    const alloc = config.allocator();
    var lines = std.mem.splitScalar(u8, content, '\n');
    var section = Section.root;

    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const sec = std.mem.trim(u8, line[1..end], " \t");
            section = if (std.mem.eql(u8, sec, "paths")) .paths else if (std.mem.eql(u8, sec, "legacy_paths")) .legacy_paths else if (std.mem.eql(u8, sec, "simulation")) .simulation else if (std.mem.eql(u8, sec, "plugins")) .plugins else .root;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        switch (section) {
            .root => {
                if (std.mem.eql(u8, key, "name")) {
                    if (parseStr(alloc, val) catch null) |s| config.name = s;
                } else if (std.mem.eql(u8, key, "pdk")) {
                    config.pdk = parseStr(alloc, val) catch null;
                }
            },
            .paths => {
                if (std.mem.eql(u8, key, "chn"))
                    config.paths.chn = try parseStrArray(alloc, val)
                else if (std.mem.eql(u8, key, "chn_tb"))
                    config.paths.chn_tb = try parseStrArray(alloc, val);
            },
            .legacy_paths => {
                if (std.mem.eql(u8, key, "schematics"))
                    config.legacy_paths.schematics = try parseStrArray(alloc, val)
                else if (std.mem.eql(u8, key, "symbols"))
                    config.legacy_paths.symbols = try parseStrArray(alloc, val);
            },
            .simulation => {
                if (std.mem.eql(u8, key, "spice_include_paths"))
                    config.simulation = .{ .spice_include_paths = try parseStrArray(alloc, val) };
            },
            .plugins => {
                if (config.plugins == null) config.plugins = .{};
                if (std.mem.eql(u8, key, "enabled"))
                    config.plugins.?.enabled = try parseStrArray(alloc, val)
                else if (std.mem.eql(u8, key, "disabled"))
                    config.plugins.?.disabled = try parseStrArray(alloc, val);
            },
        }
    }
}

/// Parse `"value"` → allocate and return inner string, or error.
fn parseStr(alloc: Allocator, val: []const u8) ![]const u8 {
    const v = std.mem.trim(u8, val, " \t");
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"')
        return alloc.dupe(u8, v[1 .. v.len - 1]);
    return error.InvalidFormat;
}

/// Parse `["a", "b", ...]` → allocated slice of strings.
fn parseStrArray(alloc: Allocator, val: []const u8) ![]const []const u8 {
    const v = std.mem.trim(u8, val, " \t");
    if (v.len < 2 or v[0] != '[') return &.{};
    var list: std.ArrayListUnmanaged([]const u8) = .{};
    var i: usize = 1;
    while (i < v.len) : (i += 1) {
        if (v[i] == '"') {
            const end = std.mem.indexOfScalarPos(u8, v, i + 1, '"') orelse break;
            try list.append(alloc, try alloc.dupe(u8, v[i + 1 .. end]));
            i = end;
        }
    }
    return list.toOwnedSlice(alloc);
}

// ============================================================================
// Tests
// ============================================================================

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

test "toml parse legacy paths" {
    var cfg = try ProjectConfig.parseFromString(std.testing.allocator,
        \\[legacy_paths]
        \\schematics = ["inv.sch"]
        \\symbols = ["inv.sym"]
    );
    defer cfg.deinit();
    try std.testing.expectEqualStrings("inv.sch", cfg.legacy_paths.schematics[0]);
    try std.testing.expectEqualStrings("inv.sym", cfg.legacy_paths.symbols[0]);
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
