//! Network test: fetches the live plugin registry and asserts at least one plugin exists.
//! Requires internet access. Run with: zig build test_marketplace

const std = @import("std");
const utility = @import("utility");

const REGISTRY_URL = "https://raw.githubusercontent.com/UW-ASIC/Schemify/main/plugins/registry.json";

const RegistryDownload = struct {
    linux: []const u8 = "",
    macos: []const u8 = "",
    wasm: []const u8 = "",
};

/// Schema matching the auto-generated registry.json format.
const RegistryEntry = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    author: []const u8 = "",
    version: []const u8 = "",
    description: []const u8 = "",
    tags: [][]const u8 = &.{},
    repo: []const u8 = "",
    readme_url: []const u8 = "",
    download: RegistryDownload = .{},
};

const Registry = struct {
    version: u32 = 0,
    plugins: []RegistryEntry = &.{},
};

test "registry is reachable and has plugins" {
    const alloc = std.testing.allocator;

    const body = utility.platform.httpGetSync(alloc, REGISTRY_URL) catch |err| {
        std.debug.print("SKIP: registry fetch failed ({s}) — check network\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer alloc.free(body);

    std.testing.expect(body.len > 0) catch {
        std.debug.print("FAIL: registry response is empty\n", .{});
        return error.TestFailed;
    };

    const parsed = std.json.parseFromSlice(Registry, alloc, body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("FAIL: JSON parse error ({s})\nBody: {s}\n", .{ @errorName(err), body[0..@min(body.len, 200)] });
        return error.TestFailed;
    };
    defer parsed.deinit();

    const entries = parsed.value.plugins;
    std.debug.print("Registry v{d} has {d} plugin(s):\n", .{ parsed.value.version, entries.len });
    for (entries) |e| {
        std.debug.print("  - {s} by {s} v{s}\n", .{ e.name, e.author, e.version });
    }

    try std.testing.expect(entries.len > 0);
}
