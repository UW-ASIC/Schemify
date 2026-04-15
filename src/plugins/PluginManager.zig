//! Plugin manager stub — satisfies the interface expected by runtime.zig.
//!
//! A full implementation requires ProjectConfig.PluginSpec which is not
//! yet available in this version of the codebase. This stub provides the
//! minimal struct shape so that runtime.zig compiles.

const std = @import("std");
const Logger = @import("utility").Logger;

const PluginSpec = @import("core").Toml.ProjectConfig.PluginSpec;
const Scope = enum { project, user };

pub const EnsureResult = struct {
    fail_count: u32,
};

pub const PluginManager = struct {
    alloc: std.mem.Allocator,
    names: std.ArrayListUnmanaged([]const u8) = .{},
    paths: std.ArrayListUnmanaged(?[]const u8) = .{},
    lazys: std.ArrayListUnmanaged(bool) = .{},

    pub fn init(alloc: std.mem.Allocator) PluginManager {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *PluginManager) void {
        for (self.names.items) |n| self.alloc.free(n);
        for (self.paths.items) |p| if (p) |path| self.alloc.free(path);
        self.names.deinit(self.alloc);
        self.paths.deinit(self.alloc);
        self.lazys.deinit(self.alloc);
    }

    pub fn hasSpec(self: *const PluginManager, name: []const u8) bool {
        for (self.names.items) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    /// Stub: ensure plugins are installed. Returns zero failures.
    pub fn ensureInstalled(
        self: *PluginManager,
        specs: []const PluginSpec,
        scope: Scope,
        log: *Logger,
        alloc: std.mem.Allocator,
    ) EnsureResult {
        _ = self;
        _ = specs;
        _ = scope;
        _ = log;
        _ = alloc;
        return .{ .fail_count = 0 };
    }
};
