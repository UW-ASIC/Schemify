//! Vfs — platform-agnostic virtual filesystem.
//!
//! Comptime-selects the backend at build time:
//!
//!   Native  (Linux / macOS / Windows)
//!     Thin wrappers around std.fs.  Full OS filesystem access.
//!
//!   Web  (wasm32 / wasm64)
//!     Two-step protocol via extern "host" imports: the caller allocates
//!     a buffer in WASM linear memory, then asks the host to fill it.
//!     The JavaScript host maintains an in-memory VFS backed by a Map
//!     (and optionally persisted to IndexedDB / OPFS by the host page).
//!
//! ── WASM host import contract ─────────────────────────────────────────────
//!
//!   host.vfs_file_len(path_ptr, path_len)              → i32  (-1 = not found)
//!   host.vfs_file_read(path_ptr, path_len, dest, dlen) → i32  (bytes, -1 = err)
//!   host.vfs_file_write(path_ptr, path_len, src, slen) → i32  (0 = ok, -1 = err)
//!   host.vfs_file_delete(path_ptr, path_len)           → i32
//!   host.vfs_dir_make(path_ptr, path_len)              → i32
//!   host.vfs_dir_list_len(path_ptr, path_len)          → i32  (NUL-sep list bytes)
//!   host.vfs_dir_list_read(path_ptr, path_len, d, dl)  → i32
//!
//! See build.zig (plugin_host.js) for the JavaScript implementation.
//!
//! ── Error Handling ─────────────────────────────────────────────────────────
//!
//! All functions return typed errors (`error.FileNotFound`, `error.ReadError`,
//! etc.) for WASM paths, and underlying `std.fs` errors on native. Both
//! integrate with Zig's `!T` error union — propagate with `try` everywhere.
//!
//! To make errors more verbose, callers should log the path alongside the error:
//!   const data = Vfs.readAlloc(alloc, path) catch |e| {
//!       logger.err("vfs", "read failed for {s}: {}", .{path, e});
//!       return null;
//!   };
//!
//! ── PDKLoader Usage ────────────────────────────────────────────────────────
//!
//! The PDKLoader uses Vfs to scan and read PDK files. Because Vfs is
//! platform-agnostic, the same loader code runs on both native and WASM
//! (as long as the WASM host has the PDK tree in its virtual FS).
//!
//!   // Enumerate all .sym files in a PDK library
//!   const listing = try Vfs.listDir(alloc, "$PDK_ROOT/sky130A/libs.ref/sky130_fd_pr/");
//!   defer listing.deinit(alloc);
//!   for (listing.entries) |entry| {
//!       if (std.mem.endsWith(u8, entry, ".sym")) {
//!           const full_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{dir_path, entry});
//!           defer alloc.free(full_path);
//!           const data = try Vfs.readAlloc(alloc, full_path);
//!           defer alloc.free(data);
//!           // parse and convert to .chn_sym ...
//!       }
//!   }

const std = @import("std");
const builtin = @import("builtin");

pub const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

// ── WASM host imports ─────────────────────────────────────────────────────── //
//
// These are linked by the WASM host (plugin_host.js). On native builds they
// are never referenced (guarded by `comptime is_wasm` at every call site).

extern "host" fn vfs_file_len(path_ptr: i32, path_len: i32) i32;
extern "host" fn vfs_file_read(path_ptr: i32, path_len: i32, dest: i32, dest_len: i32) i32;
extern "host" fn vfs_file_write(path_ptr: i32, path_len: i32, src: i32, src_len: i32) i32;
extern "host" fn vfs_file_delete(path_ptr: i32, path_len: i32) i32;
extern "host" fn vfs_dir_make(path_ptr: i32, path_len: i32) i32;
extern "host" fn vfs_dir_list_len(path_ptr: i32, path_len: i32) i32;
extern "host" fn vfs_dir_list_read(path_ptr: i32, path_len: i32, dest: i32, dest_len: i32) i32;

// ── Helpers ───────────────────────────────────────────────────────────────── //
//
// WASM host functions receive pointer and length as separate i32 parameters
// because WASM does not have a native slice type.

/// Cast a slice pointer to i32 for WASM host calls.
fn wp(s: []const u8) i32 { return @intCast(@intFromPtr(s.ptr)); }

/// Cast a slice length to i32 for WASM host calls.
fn wl(s: []const u8) i32 { return @intCast(s.len); }

// ── File operations ───────────────────────────────────────────────────────── //

/// Read entire file into a new allocation. Caller owns the returned slice.
/// On WASM: two-step — first query length, then fill buffer.
/// On native: delegates to `std.fs.cwd().readFileAlloc`.
pub fn readAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (comptime is_wasm) {
        const len = vfs_file_len(wp(path), wl(path));
        if (len < 0) return error.FileNotFound;
        const buf = try allocator.alloc(u8, @intCast(len));
        errdefer allocator.free(buf);
        const got = vfs_file_read(wp(path), wl(path), wp(buf), wl(buf));
        if (got < 0) return error.ReadError;
        return buf;
    }
    return std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
}

/// Write `data` to `path`, creating or overwriting the file.
/// On WASM: passes the buffer directly to the host.
pub fn writeAll(path: []const u8, data: []const u8) !void {
    if (comptime is_wasm) {
        const rc = vfs_file_write(wp(path), wl(path), wp(data), wl(data));
        if (rc < 0) return error.WriteError;
        return;
    }
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
}

/// Delete a file at `path`.
pub fn delete(path: []const u8) !void {
    if (comptime is_wasm) {
        if (vfs_file_delete(wp(path), wl(path)) < 0) return error.DeleteError;
        return;
    }
    try std.fs.cwd().deleteFile(path);
}

/// Return true if `path` exists as a file or directory.
/// On WASM: uses `vfs_file_len` as a proxy existence check (≥0 means exists).
/// On native: uses `cwd().access`.
pub fn exists(path: []const u8) bool {
    if (comptime is_wasm) {
        return vfs_file_len(wp(path), wl(path)) >= 0;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

// ── Directory operations ──────────────────────────────────────────────────── //

/// Create `path` as a directory, creating all missing parent components.
pub fn makePath(path: []const u8) !void {
    if (comptime is_wasm) {
        if (vfs_dir_make(wp(path), wl(path)) < 0) return error.MakePathFailed;
        return;
    }
    try std.fs.cwd().makePath(path);
}

/// Directory listing result. Owns two allocations; free with `deinit`.
///
/// `entries` are slices into `buf` — they become invalid after `deinit`.
/// Each entry is the bare filename (not a full path).
///
/// IMPROVE: Native path iterates the directory twice (once for total byte
/// count, once to fill). A single pass building a `List([]const u8)` into
/// an arena would halve syscall count. This matters for large PDK directories
/// with thousands of .sym files.
pub const DirList = struct {
    /// Flat buffer — individual entries are null-terminated slices into it.
    buf: []u8,
    entries: [][]const u8,

    pub fn deinit(self: DirList, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.buf);
    }
};

/// List all entries in `path`. Returns a `DirList` whose lifetime is tied
/// to the returned allocations — call `deinit` when done.
///
/// Entry names are bare filenames (not full paths). To construct a full path:
///   const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{path, entry});
///
/// On WASM: the host returns a NUL-separated list via `vfs_dir_list_*`.
/// IMPROVE (WASM): `vfs_dir_list_read` return value is silently ignored.
/// If the host fails to fill the buffer, the entries will be garbage.
/// Check: `if (vfs_dir_list_read(...) < 0) return error.DirReadError;`
pub fn listDir(allocator: std.mem.Allocator, path: []const u8) !DirList {
    if (comptime is_wasm) {
        const total = vfs_dir_list_len(wp(path), wl(path));
        if (total < 0) return error.DirNotFound;
        const buf = try allocator.alloc(u8, @intCast(total));
        errdefer allocator.free(buf);
        // IMPROVE: check return value — currently silently ignoring errors here.
        _ = vfs_dir_list_read(wp(path), wl(path), wp(buf), wl(buf));
        return parseNulSepList(allocator, buf);
    }

    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    // First pass: calculate total bytes needed for names.
    var total: usize = 0;
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        total += entry.name.len + 1;
        count += 1;
    }

    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);
    const entries = try allocator.alloc([]const u8, count);

    var pos: usize = 0;
    var idx: usize = 0;
    it = dir.iterate();
    while (try it.next()) |entry| {
        const n = entry.name.len;
        @memcpy(buf[pos..][0..n], entry.name);
        buf[pos + n] = 0;
        entries[idx] = buf[pos..][0..n];
        pos += n + 1;
        idx += 1;
    }
    return .{ .buf = buf, .entries = entries };
}

/// Parse a NUL-separated flat buffer into a DirList. Used by the WASM path.
/// The returned `entries` slices point into `buf` — `buf` must outlive the entries.
fn parseNulSepList(allocator: std.mem.Allocator, buf: []u8) !DirList {
    var count: usize = 0;
    for (buf) |b| if (b == 0) { count += 1; };

    const entries = try allocator.alloc([]const u8, count);
    var idx: usize = 0;
    var start: usize = 0;
    for (buf, 0..) |b, i| {
        if (b == 0) {
            entries[idx] = buf[start..i];
            idx += 1;
            start = i + 1;
        }
    }
    return .{ .buf = buf, .entries = entries };
}
