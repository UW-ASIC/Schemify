//! Plugin binary discovery -- resolves installed plugin binaries for the runtime.
//!
//! For each enabled PluginSpec, probes config_dir/<name>/ for a matching
//! shared library or WASM module and records the path + binary type.
//!
//! Candidate filenames (tried in order):
//!   lib<name>.so, <name>.so, lib/lib<name>.so, lib/<name>.so   (native)
//!   <name>.wasm, lib/<name>.wasm                                (wasm)

const std = @import("std");
const utility = @import("utility");

pub const BinaryType = enum { native_so, wasm };

pub const PluginSpec = struct {
    name: []const u8,
    enabled: bool = true,
    lazy: bool = false,
};

const FindResult = struct { path: []const u8, binary_type: BinaryType };

pub const PluginManager = struct {
    names: std.ArrayListUnmanaged([]const u8) = .{},
    paths: std.ArrayListUnmanaged(?[]const u8) = .{},
    lazys: std.ArrayListUnmanaged(bool) = .{},
    binary_types: std.ArrayListUnmanaged(BinaryType) = .{},

    pub fn deinit(self: *PluginManager, alloc: std.mem.Allocator) void {
        for (self.names.items) |n| alloc.free(n);
        for (self.paths.items) |p| if (p) |path| alloc.free(path);
        self.names.deinit(alloc);
        self.paths.deinit(alloc);
        self.lazys.deinit(alloc);
        self.binary_types.deinit(alloc);
    }

    pub fn hasSpec(self: *const PluginManager, name: []const u8) bool {
        for (self.names.items) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    /// Resolve binary paths for all enabled specs.  Returns the number of
    /// specs for which no binary could be found.
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
                self.appendEntry(alloc, name_owned, null, spec.lazy, .native_so);
                fail_count += 1;
                continue;
            };
            defer alloc.free(plugin_dir);

            if (findBinary(alloc, plugin_dir, spec.name)) |found| {
                self.appendEntry(alloc, name_owned, found.path, spec.lazy, found.binary_type);
            } else {
                self.appendEntry(alloc, name_owned, null, spec.lazy, .native_so);
                fail_count += 1;
            }
        }
        return fail_count;
    }

    /// Scan `config_dir` for subdirectories containing plugin binaries that
    /// are not already tracked.  Returns the number of newly discovered plugins.
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
            // Skip if already tracked.
            if (self.hasSpec(entry.name)) continue;

            // Probe this subdirectory for a plugin binary.
            const plugin_dir = std.fmt.allocPrint(alloc, "{s}/{s}", .{ config_dir, entry.name }) catch continue;
            defer alloc.free(plugin_dir);

            if (findBinary(alloc, plugin_dir, entry.name)) |bin| {
                const name_owned = alloc.dupe(u8, entry.name) catch {
                    alloc.free(bin.path);
                    continue;
                };
                self.appendEntry(alloc, name_owned, bin.path, false, bin.binary_type);
                found += 1;
            }
        }
        return found;
    }

    fn appendEntry(self: *PluginManager, alloc: std.mem.Allocator, name: []const u8, path: ?[]const u8, lazy: bool, btype: BinaryType) void {
        self.names.append(alloc, name) catch {
            alloc.free(name);
            if (path) |p| alloc.free(p);
            return;
        };
        self.paths.append(alloc, path) catch {
            if (path) |p| alloc.free(p);
            return;
        };
        self.lazys.append(alloc, lazy) catch {};
        self.binary_types.append(alloc, btype) catch {};
    }
};

/// Try candidate filenames and return the first that exists on disk.
/// Caller owns the returned path string.
fn findBinary(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ?FindResult {
    // Native .so candidates
    const so_fmts = [_][]const u8{
        "{s}/lib{s}.so",
        "{s}/{s}.so",
        "{s}/lib/lib{s}.so",
        "{s}/lib/{s}.so",
    };
    inline for (so_fmts) |fmt| {
        if (std.fmt.allocPrint(alloc, fmt, .{ dir, name })) |path| {
            if (fileExists(path)) return .{ .path = path, .binary_type = .native_so };
            alloc.free(path);
        } else |_| {}
    }
    // WASM candidates
    const wasm_fmts = [_][]const u8{
        "{s}/{s}.wasm",
        "{s}/lib/{s}.wasm",
    };
    inline for (wasm_fmts) |fmt| {
        if (std.fmt.allocPrint(alloc, fmt, .{ dir, name })) |path| {
            if (fileExists(path)) return .{ .path = path, .binary_type = .wasm };
            alloc.free(path);
        } else |_| {}
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    utility.platform.fs.cwd().access(path, .{}) catch return false;
    return true;
}
