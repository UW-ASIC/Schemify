//! Marketplace / plugin registry tests.
//!
//! test_registry_reachable  — network: fetches live registry, asserts ≥1 plugin.
//! test_local_plugins_match — offline: compares plugins/registry.json vs plugins/ dir.
//!
//! Run individually:
//!   zig build test_marketplace                   (all)
//!   zig build test_marketplace -- --test-filter local

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

// Non-network test: reads plugins/registry.json from the source tree and
// compares it against the actual plugins/ subdirectories.  Reports:
//   [OK]            — entry has a matching directory
//   [REGISTRY ONLY] — in registry but no local directory
//   [DIR ONLY]      — directory exists but not in registry
//   [NO plugin.toml]— directory present but missing plugin.toml
test "local plugins dir matches registry" {
    const alloc = std.testing.allocator;

    // ── Load local registry.json ──────────────────────────────────────────────
    const json_text = std.fs.cwd().readFileAlloc(alloc, "plugins/registry.json", 1024 * 1024) catch |err| {
        std.debug.print("SKIP: cannot open plugins/registry.json ({s})\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer alloc.free(json_text);

    const parsed = try std.json.parseFromSlice(Registry, alloc, json_text, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const entries = parsed.value.plugins;
    std.debug.print("\n=== Local registry v{d}: {d} plugin(s) ===\n", .{ parsed.value.version, entries.len });

    // ── Collect plugin subdirectories ─────────────────────────────────────────
    var plugins_dir = std.fs.cwd().openDir("plugins", .{ .iterate = true }) catch |err| {
        std.debug.print("SKIP: cannot open plugins/ ({s})\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer plugins_dir.close();

    var local_dirs: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (local_dirs.items) |n| alloc.free(n);
        local_dirs.deinit(alloc);
    }

    // Directories that are not plugins
    const skip_dirs = [_][]const u8{"examples"};

    var dir_it = plugins_dir.iterate();
    while (try dir_it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const skip = for (skip_dirs) |s| {
            if (std.mem.eql(u8, entry.name, s)) break true;
        } else false;
        if (skip) continue;
        try local_dirs.append(alloc, try alloc.dupe(u8, entry.name));
    }

    std.debug.print("plugins/ dir: {d} subdirector(ies)\n\n", .{local_dirs.items.len});

    // ── Registry entries vs local directories ─────────────────────────────────
    var registry_only: u32 = 0;
    std.debug.print("Registry entries:\n", .{});
    for (entries) |e| {
        // Match on name OR id (e.g. dir=EasyImport, id=XSchemDropIN, name=EasyImport)
        const found = for (local_dirs.items) |dir| {
            if (std.mem.eql(u8, dir, e.name) or std.mem.eql(u8, dir, e.id)) break true;
        } else false;

        if (found) {
            std.debug.print("  [OK]            {s} (id={s})\n", .{ e.name, e.id });
        } else {
            std.debug.print("  [REGISTRY ONLY] {s} (id={s}) — no matching directory\n", .{ e.name, e.id });
            registry_only += 1;
        }
    }

    // ── Local directories vs registry ─────────────────────────────────────────
    var dir_only: u32 = 0;
    std.debug.print("\nLocal directories:\n", .{});
    for (local_dirs.items) |dir| {
        const in_registry = for (entries) |e| {
            if (std.mem.eql(u8, dir, e.name) or std.mem.eql(u8, dir, e.id)) break true;
        } else false;

        // Check for plugin.toml
        const toml_path = std.fmt.allocPrint(alloc, "plugins/{s}/plugin.toml", .{dir}) catch continue;
        defer alloc.free(toml_path);
        const has_toml = if (std.fs.cwd().access(toml_path, .{})) |_| true else |_| false;

        if (!in_registry) {
            std.debug.print("  [DIR ONLY]      {s}{s}\n", .{ dir, if (!has_toml) " [NO plugin.toml]" else "" });
            dir_only += 1;
        } else {
            std.debug.print("  [OK]            {s}{s}\n", .{ dir, if (!has_toml) " [NO plugin.toml]" else "" });
        }
    }

    // ── Summary ───────────────────────────────────────────────────────────────
    std.debug.print("\n--- Summary ---\n", .{});
    if (registry_only == 0 and dir_only == 0) {
        std.debug.print("All entries match: {d} registry == {d} directories\n", .{ entries.len, local_dirs.items.len });
    } else {
        if (registry_only > 0)
            std.debug.print("WARN: {d} registry entry(s) have no local directory\n", .{registry_only});
        if (dir_only > 0)
            std.debug.print("WARN: {d} local directory(s) not in registry\n", .{dir_only});
    }

    // Basic sanity: both sides are non-empty
    try std.testing.expect(entries.len > 0);
    try std.testing.expect(local_dirs.items.len > 0);
}
