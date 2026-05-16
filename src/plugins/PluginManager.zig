const std = @import("std");
const utility = @import("utility");

pub const PluginSpec = struct {
    name: []const u8,
    enabled: bool = true,
    lazy: bool = false,
};

pub const PluginInfo = struct {
    name: []const u8,
    command: []const u8,
    build_command: []const u8,
    dir: []const u8,
};

pub const PluginManager = struct {
    names: std.ArrayListUnmanaged([]const u8) = .{},
    paths: std.ArrayListUnmanaged(?[]const u8) = .{},
    lazys: std.ArrayListUnmanaged(bool) = .{},
    commands: std.ArrayListUnmanaged([]const u8) = .{},
    dirs: std.ArrayListUnmanaged([]const u8) = .{},

    pub fn deinit(self: *PluginManager, alloc: std.mem.Allocator) void {
        for (self.names.items) |n| alloc.free(n);
        for (self.paths.items) |p| if (p) |path| alloc.free(path);
        for (self.commands.items) |c| if (c.len > 0) alloc.free(c);
        for (self.dirs.items) |d| if (d.len > 0) alloc.free(d);
        self.names.deinit(alloc);
        self.paths.deinit(alloc);
        self.lazys.deinit(alloc);
        self.commands.deinit(alloc);
        self.dirs.deinit(alloc);
    }

    pub fn hasSpec(self: *const PluginManager, name: []const u8) bool {
        for (self.names.items) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    pub fn resolve(
        self: *PluginManager,
        alloc: std.mem.Allocator,
        specs: []const PluginSpec,
        config_dir: []const u8,
    ) u32 {
        var fail_count: u32 = 0;
        for (specs) |spec| {
            if (!spec.enabled) continue;

            const name_owned = alloc.dupe(u8, spec.name) catch {
                fail_count += 1;
                continue;
            };

            const plugin_dir = std.fmt.allocPrint(alloc, "{s}/{s}", .{ config_dir, spec.name }) catch {
                self.appendEntry(alloc, name_owned, null, spec.lazy, "", "");
                fail_count += 1;
                continue;
            };

            const toml_path = std.fmt.allocPrint(alloc, "{s}/plugin.toml", .{plugin_dir}) catch {
                alloc.free(plugin_dir);
                self.appendEntry(alloc, name_owned, null, spec.lazy, "", "");
                fail_count += 1;
                continue;
            };

            if (fileExists(toml_path)) {
                const cmd = readCommandFromToml(alloc, toml_path);
                const dir_owned = alloc.dupe(u8, plugin_dir) catch "";
                self.appendEntry(alloc, name_owned, toml_path, spec.lazy, cmd, dir_owned);
            } else {
                alloc.free(toml_path);
                self.appendEntry(alloc, name_owned, null, spec.lazy, "", "");
                fail_count += 1;
            }
            alloc.free(plugin_dir);
        }
        return fail_count;
    }

    pub fn autoDiscover(
        self: *PluginManager,
        alloc: std.mem.Allocator,
        config_dir: []const u8,
    ) u32 {
        var found: u32 = 0;
        var dir = utility.platform.fs.cwd().openDir(config_dir, .{ .iterate = true }) catch return 0;
        defer dir.close();

        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (self.hasSpec(entry.name)) continue;

            const plugin_dir = std.fmt.allocPrint(alloc, "{s}/{s}", .{ config_dir, entry.name }) catch continue;
            const toml_path = std.fmt.allocPrint(alloc, "{s}/plugin.toml", .{plugin_dir}) catch {
                alloc.free(plugin_dir);
                continue;
            };

            if (fileExists(toml_path)) {
                const name_owned = alloc.dupe(u8, entry.name) catch {
                    alloc.free(toml_path);
                    alloc.free(plugin_dir);
                    continue;
                };
                const cmd = readCommandFromToml(alloc, toml_path);
                const dir_owned = alloc.dupe(u8, plugin_dir) catch "";
                self.appendEntry(alloc, name_owned, toml_path, false, cmd, dir_owned);
                found += 1;
            } else {
                alloc.free(toml_path);
            }
            alloc.free(plugin_dir);
        }
        return found;
    }

    pub fn buildPlugin(self: *PluginManager, alloc: std.mem.Allocator, name: []const u8) bool {
        _ = self;
        _ = alloc;
        _ = name;
        return false;
    }

    fn appendEntry(self: *PluginManager, alloc: std.mem.Allocator, name: []const u8, path: ?[]const u8, lazy: bool, cmd: []const u8, dir: []const u8) void {
        self.names.append(alloc, name) catch {
            alloc.free(name);
            if (path) |p| alloc.free(p);
            if (cmd.len > 0) alloc.free(cmd);
            if (dir.len > 0) alloc.free(dir);
            return;
        };
        self.paths.append(alloc, path) catch {
            if (path) |p| alloc.free(p);
            return;
        };
        self.lazys.append(alloc, lazy) catch {};
        self.commands.append(alloc, cmd) catch {};
        self.dirs.append(alloc, dir) catch {};
    }
};

fn fileExists(path: []const u8) bool {
    utility.platform.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn readCommandFromToml(alloc: std.mem.Allocator, toml_path: []const u8) []const u8 {
    const data = utility.platform.fs.cwd().readFileAlloc(alloc, toml_path, 64 * 1024) catch return "";
    defer alloc.free(data);

    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, &[_]u8{ '\r', ' ', '\t' });
        const trimmed = std.mem.trimLeft(u8, line, &[_]u8{ ' ', '\t' });
        if (!std.mem.startsWith(u8, trimmed, "command")) continue;
        const rest = std.mem.trimLeft(u8, trimmed["command".len..], &[_]u8{ ' ', '\t' });
        if (rest.len == 0 or rest[0] != '=') continue;
        const val = std.mem.trimLeft(u8, rest[1..], &[_]u8{ ' ', '\t' });
        const unquoted = unquote(val);
        if (unquoted.len == 0) continue;
        return alloc.dupe(u8, unquoted) catch "";
    }
    return "";
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}
