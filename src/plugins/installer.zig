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

const std     = @import("std");
const builtin = @import("builtin");

// ── Platform helpers ─────────────────────────────────────────────────────── //

/// Native plugin file extension for the current OS.
pub const native_ext: []const u8 = switch (builtin.os.tag) {
    .macos, .tvos, .watchos, .ios => ".dylib",
    .windows                      => ".dll",
    else                          => ".so",
};

/// All extensions the installer and GitHub resolver recognise as plugin files.
pub const all_plugin_exts = [_][]const u8{ ".so", ".dylib", ".dll", ".wasm" };

/// Return the native plugin directory for the given plugin name.
/// Caller owns the result.
pub fn nativePluginDir(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fs.path.join(allocator, &.{ home, ".config", "Schemify", name });
}

// ── Public API ────────────────────────────────────────────────────────────── //

pub const Target = enum {
    /// Download the platform-native binary (.so / .dylib / .dll).
    native,
    /// Download the .wasm artifact and update the web manifest.
    web,
};

pub const InstallOptions = struct {
    target:      Target        = .native,
    /// Only used when target == .web.  Defaults to zig-out/bin/plugins/.
    web_out_dir: []const u8   = "zig-out/bin/plugins",
};

/// Download `url` and install it according to `opts`.
/// Returns the installed file path (caller owns).
pub fn install(
    allocator: std.mem.Allocator,
    url:       []const u8,
    opts:      InstallOptions,
) ![]u8 {
    const resolved = try resolveUrl(allocator, url, opts.target);
    defer allocator.free(resolved);

    const filename = std.fs.path.basename(resolved);
    if (filename.len == 0) return error.InvalidUrl;

    // Derive plugin name from filename (strip lib prefix and extension).
    const name = pluginName(filename);

    const dest_dir = switch (opts.target) {
        .native => try nativePluginDir(allocator, name),
        .web    => try allocator.dupe(u8, opts.web_out_dir),
    };
    defer allocator.free(dest_dir);

    try std.fs.cwd().makePath(dest_dir);

    const body = try fetchUrl(allocator, resolved);
    defer allocator.free(body);

    const out_path = try std.fs.path.join(allocator, &.{ dest_dir, filename });
    errdefer allocator.free(out_path);

    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = body });

    if (opts.target == .web) {
        try updateWebManifest(allocator, dest_dir, filename);
    }

    return out_path;
}

// ── URL resolution ────────────────────────────────────────────────────────── //

fn resolveUrl(allocator: std.mem.Allocator, url: []const u8, tgt: Target) ![]u8 {
    if (isGitHubRepo(url)) {
        return resolveGitHubRelease(allocator, url, tgt) catch
            allocator.dupe(u8, url);
    }
    return allocator.dupe(u8, url);
}

fn isGitHubRepo(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://github.com/")) return false;
    const ext = std.fs.path.extension(url);
    for (all_plugin_exts) |e| if (std.mem.eql(u8, ext, e)) return false;
    return true;
}

fn resolveGitHubRelease(allocator: std.mem.Allocator, gh_url: []const u8, tgt: Target) ![]u8 {
    const prefix = "https://github.com/";
    const rest   = gh_url[prefix.len..];
    var it       = std.mem.splitScalar(u8, rest, '/');
    const owner  = it.next() orelse return error.InvalidGitHubUrl;
    const repo   = it.next() orelse return error.InvalidGitHubUrl;

    const api_url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}/releases/latest",
        .{ owner, repo },
    );
    defer allocator.free(api_url);

    const json = try fetchUrl(allocator, api_url);
    defer allocator.free(json);

    // Prefer the target-specific extension, fall back to any plugin extension.
    const preferred_ext: []const u8 = if (tgt == .web) ".wasm" else native_ext;
    return findDownloadUrl(allocator, json, preferred_ext)
        orelse findDownloadUrl(allocator, json, null)
        orelse error.NoPluginAsset;
}

/// Scan `json` for `browser_download_url` values.
/// If `preferred_ext` is non-null, only return URLs with that extension.
/// If null, return the first URL with any plugin extension.
fn findDownloadUrl(
    allocator:    std.mem.Allocator,
    json:         []const u8,
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
        else blk: {
            for (all_plugin_exts) |e| if (std.mem.eql(u8, ext, e)) break :blk true;
            break :blk false;
        };
        if (matches) return allocator.dupe(u8, url) catch null;
        pos = ve + 1;
    }
    return null;
}

// ── Web manifest (plugins.json) ───────────────────────────────────────────── //

/// Add `filename` to `<dir>/plugins.json` if not already listed.
/// Creates the file with an empty list if it doesn't exist.
fn updateWebManifest(
    allocator: std.mem.Allocator,
    dir:       []const u8,
    filename:  []const u8,
) !void {
    const manifest_path = try std.fs.path.join(
        allocator, &.{ dir, "plugins.json" },
    );
    defer allocator.free(manifest_path);

    // Read existing manifest or start fresh.
    var entries = std.ArrayListUnmanaged([]u8){};
    defer {
        for (entries.items) |e| allocator.free(e);
        entries.deinit(allocator);
    }

    if (std.fs.cwd().readFileAlloc(allocator, manifest_path, 1 * 1024 * 1024)) |existing| {
        defer allocator.free(existing);
        try parseManifestEntries(allocator, existing, &entries);
    } else |_| {}

    // Append if not already present.
    const already = for (entries.items) |e| {
        if (std.mem.eql(u8, e, filename)) break true;
    } else false;

    if (!already) {
        try entries.append(allocator, try allocator.dupe(u8, filename));
    }

    // Serialise back.
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.writeAll("{\n  \"plugins\": [\n");
    for (entries.items, 0..) |e, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.print("    \"{s}\"", .{e});
    }
    try w.writeAll("\n  ]\n}\n");

    try std.fs.cwd().writeFile(.{ .sub_path = manifest_path, .data = out.items });
}

fn parseManifestEntries(
    allocator: std.mem.Allocator,
    json:      []const u8,
    out:       *std.ArrayListUnmanaged([]u8),
) !void {
    // Minimal parser: find each quoted string inside the "plugins" array.
    const arr_start = std.mem.indexOf(u8, json, "\"plugins\"") orelse return;
    const bracket   = std.mem.indexOfPos(u8, json, arr_start, "[") orelse return;
    const bracket_end = std.mem.indexOfPos(u8, json, bracket, "]") orelse return;
    const arr_body = json[bracket + 1 .. bracket_end];

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, arr_body, pos, "\"")) |qs| {
        const qe = std.mem.indexOfPos(u8, arr_body, qs + 1, "\"") orelse break;
        const entry = arr_body[qs + 1 .. qe];
        if (entry.len > 0) try out.append(allocator, try allocator.dupe(u8, entry));
        pos = qe + 1;
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────── //

/// Strip lib prefix and file extension from a filename to get the plugin name.
/// "libfoo.so" → "foo",  "bar.wasm" → "bar",  "baz.dll" → "baz"
pub fn pluginName(filename: []const u8) []const u8 {
    var name = std.fs.path.stem(filename);
    if (std.mem.startsWith(u8, name, "lib")) name = name[3..];
    return name;
}

// ── HTTP fetch ────────────────────────────────────────────────────────────── //

fn fetchUrl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = try client.fetch(.{
        .location        = .{ .url = url },
        .response_writer = &aw.writer,
        .extra_headers   = &.{
            .{ .name = "User-Agent", .value = "Schemify/1.0" },
            .{ .name = "Accept",     .value = "*/*" },
        },
    });

    if (result.status != .ok) return error.HttpError;
    return allocator.dupe(u8, aw.writer.buffered());
}
