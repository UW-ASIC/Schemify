//! Plugin installer — downloads plugin artifacts and places them where the
//! runtimes expect them.
//!
//! ── Install layouts ──────────────────────────────────────────────────────────
//!
//!  Native  ~/.config/Schemify/<name>/
//!              lib<name>.so            ← Linux
//!              lib<name>.dylib         ← macOS
//!              <name>.dll              ← Windows
//!
//!  Web     <web-out-dir>/plugins/
//!              <name>.wasm
//!          <web-out-dir>/plugins/plugins.json   ← updated automatically
//!
//! ── Supported URL forms ──────────────────────────────────────────────────────
//!
//!  Direct file:
//!    https://example.com/releases/libMyPlugin.so
//!    https://example.com/MyPlugin.wasm
//!
//!  GitHub repository (auto-resolves latest release asset):
//!    https://github.com/user/repo
//!    https://github.com/user/repo/releases/latest
//!
//!  When --web is used, GitHub resolution prefers .wasm; otherwise it prefers
//!  the native platform extension (.so / .dylib / .dll).

const std = @import("std");
const builtin = @import("builtin");
const utility = @import("utility");
const Vfs = utility.Vfs;
const platform = utility.platform;

// ── Error sets ────────────────────────────────────────────────────────────── //

const ResolveError = error{
    InvalidUrl,
    InvalidGitHubUrl,
    NoPluginAsset,
    OutOfMemory,
};

const FetchError = error{
    HttpError,
    OutOfMemory,
};

pub const InstallError = ResolveError || FetchError || error{NoHomeDir};

// ── Platform constants ────────────────────────────────────────────────────── //

const native_ext: []const u8 = switch (builtin.os.tag) {
    .macos, .tvos, .watchos, .ios => ".dylib",
    .windows => ".dll",
    else => ".so",
};

const all_plugin_exts = [_][]const u8{ ".so", ".dylib", ".dll", ".wasm" };

// ── Types ─────────────────────────────────────────────────────────────────── //

pub const Target = enum {
    /// Download the platform-native binary (.so / .dylib / .dll).
    native,
    /// Download the .wasm artifact and update the web manifest.
    web,
};

pub const InstallOptions = struct {
    target: Target = .native,
    /// Only used when target == .web.  Defaults to zig-out/bin/plugins/.
    web_out_dir: []const u8 = "zig-out/bin/plugins",
};

// ── Module-level shims (so callers can do `Installer.install()`) ─────────── //

/// Module-level alias so `const I = @import("installer"); I.install(...)` works.
pub const install = Installer.install;

// ── Installer ─────────────────────────────────────────────────────────────── //

/// Stateless installer — all state lives in the caller's allocator.
/// No instances are ever created; every function is pub and takes an allocator.
pub const Installer = struct {
    // ── Public API ────────────────────────────────────────────────────────── //

    /// Download `url` and install it according to `opts`.
    /// Returns the installed file path (caller owns).
    pub fn install(
        allocator: std.mem.Allocator,
        url: []const u8,
        opts: InstallOptions,
    ) InstallError![]u8 {
        // Resolve URL: if it points to a GitHub repo (not a direct file), fetch
        // the latest release API to find the matching asset download URL.
        const resolved: []u8 = resolved: {
            const is_github = std.mem.startsWith(u8, url, "https://github.com/") and
                !hasPluginExt(std.fs.path.extension(url));
            if (is_github) {
                break :resolved resolveGitHubRelease(allocator, url, opts.target) catch
                    allocator.dupe(u8, url) catch return error.OutOfMemory;
            }
            break :resolved allocator.dupe(u8, url) catch return error.OutOfMemory;
        };
        defer allocator.free(resolved);

        const filename = std.fs.path.basename(resolved);
        if (filename.len == 0) return error.InvalidUrl;

        // Strip lib prefix and extension to derive the plugin name.
        // "libfoo.so" -> "foo",  "bar.wasm" -> "bar"
        const name: []const u8 = name: {
            var n = std.fs.path.stem(filename);
            if (std.mem.startsWith(u8, n, "lib")) n = n[3..];
            break :name n;
        };

        const dest_dir: []u8 = switch (opts.target) {
            .native => blk: {
                const home = platform.getEnvVar(allocator, "HOME") catch return error.NoHomeDir;
                defer allocator.free(home);
                break :blk std.fs.path.join(allocator, &.{ home, ".config", "Schemify", name }) catch
                    return error.OutOfMemory;
            },
            .web => allocator.dupe(u8, opts.web_out_dir) catch return error.OutOfMemory,
        };
        defer allocator.free(dest_dir);

        Vfs.makePath(dest_dir) catch return error.InvalidUrl;

        const body = try fetchUrl(allocator, resolved);
        defer allocator.free(body);

        const out_path = std.fs.path.join(allocator, &.{ dest_dir, filename }) catch return error.OutOfMemory;
        errdefer allocator.free(out_path);

        Vfs.writeAll(out_path, body) catch return error.InvalidUrl;

        if (opts.target == .web) {
            updateWebManifest(allocator, dest_dir, filename) catch return error.InvalidUrl;
        }

        return out_path;
    }

    // ── Private: GitHub resolution ────────────────────────────────────────── //

    fn resolveGitHubRelease(allocator: std.mem.Allocator, gh_url: []const u8, tgt: Target) (ResolveError || FetchError)![]u8 {
        const prefix = "https://github.com/";
        const rest = gh_url[prefix.len..];
        var it = std.mem.splitScalar(u8, rest, '/');
        const owner = it.next() orelse return error.InvalidGitHubUrl;
        const repo = it.next() orelse return error.InvalidGitHubUrl;

        const api_url = std.fmt.allocPrint(
            allocator,
            "https://api.github.com/repos/{s}/{s}/releases/latest",
            .{ owner, repo },
        ) catch return error.OutOfMemory;
        defer allocator.free(api_url);

        const json = try fetchUrl(allocator, api_url);
        defer allocator.free(json);

        const preferred_ext: []const u8 = if (tgt == .web) ".wasm" else native_ext;
        return findDownloadUrl(allocator, json, preferred_ext) orelse
            findDownloadUrl(allocator, json, null) orelse
            error.NoPluginAsset;
    }

    /// Scan `json` for `browser_download_url` values.
    /// If `preferred_ext` is non-null, only return URLs with that extension.
    /// If null, return the first URL with any known plugin extension.
    fn findDownloadUrl(
        allocator: std.mem.Allocator,
        json: []const u8,
        preferred_ext: ?[]const u8,
    ) ?[]u8 {
        const key = "\"browser_download_url\":\"";
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, json, pos, key)) |start| {
            const vs = start + key.len;
            const ve = std.mem.indexOfPos(u8, json, vs, "\"") orelse break;
            const url = json[vs..ve];
            const ext = std.fs.path.extension(url);
            const matches = if (preferred_ext) |pe|
                std.mem.eql(u8, ext, pe)
            else
                hasPluginExt(ext);
            if (matches) return allocator.dupe(u8, url) catch null;
            pos = ve + 1;
        }
        return null;
    }

    // ── Private: web manifest ─────────────────────────────────────────────── //

    fn updateWebManifest(
        allocator: std.mem.Allocator,
        dir: []const u8,
        filename: []const u8,
    ) !void {
        const manifest_path = try std.fs.path.join(allocator, &.{ dir, "plugins.json" });
        defer allocator.free(manifest_path);

        var entries = std.ArrayListUnmanaged([]u8){};
        defer {
            for (entries.items) |e| allocator.free(e);
            entries.deinit(allocator);
        }

        // Parse existing manifest if present; silently ignore missing/corrupt file.
        if (Vfs.readAlloc(allocator, manifest_path)) |existing| {
            defer allocator.free(existing);
            // Inline: scan JSON array for quoted filename strings.
            if (std.mem.indexOf(u8, existing, "\"plugins\"")) |arr_start| {
                if (std.mem.indexOfPos(u8, existing, arr_start, "[")) |bracket| {
                    if (std.mem.indexOfPos(u8, existing, bracket, "]")) |bracket_end| {
                        const arr_body = existing[bracket + 1 .. bracket_end];
                        var pos: usize = 0;
                        while (std.mem.indexOfPos(u8, arr_body, pos, "\"")) |qs| {
                            const qe = std.mem.indexOfPos(u8, arr_body, qs + 1, "\"") orelse break;
                            const entry = arr_body[qs + 1 .. qe];
                            if (entry.len > 0) try entries.append(allocator, try allocator.dupe(u8, entry));
                            pos = qe + 1;
                        }
                    }
                }
            }
        } else |_| {}

        const already = for (entries.items) |e| {
            if (std.mem.eql(u8, e, filename)) break true;
        } else false;

        if (!already) {
            try entries.append(allocator, try allocator.dupe(u8, filename));
        }

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(allocator);
        const w = out.writer(allocator);
        try w.writeAll("{\n  \"plugins\": [\n");
        for (entries.items, 0..) |e, i| {
            if (i > 0) try w.writeAll(",\n");
            try w.print("    \"{s}\"", .{e});
        }
        try w.writeAll("\n  ]\n}\n");

        try Vfs.writeAll(manifest_path, out.items);
    }

    // ── Private: HTTP fetch ───────────────────────────────────────────────── //

    fn fetchUrl(allocator: std.mem.Allocator, url: []const u8) FetchError![]u8 {
        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &aw.writer,
            .extra_headers = &.{
                .{ .name = "User-Agent", .value = "Schemify/1.0" },
                .{ .name = "Accept", .value = "*/*" },
            },
        }) catch return error.HttpError;

        if (result.status != .ok) return error.HttpError;
        return allocator.dupe(u8, aw.writer.buffered()) catch return error.OutOfMemory;
    }
};

// ── Module-level private helper ───────────────────────────────────────────── //

fn hasPluginExt(ext: []const u8) bool {
    for (all_plugin_exts) |e| {
        if (std.mem.eql(u8, ext, e)) return true;
    }
    return false;
}

// ── Size test ─────────────────────────────────────────────────────────────── //

test "Expose struct size for installer" {
    const print = @import("std").debug.print;
    print("Installer: {d}B\n", .{@sizeOf(Installer)});
}
