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
//!   host.vfs_dir_make(path_ptr, path_len)              → i32
//!   host.vfs_dir_list_len(path_ptr, path_len)          → i32  (NUL-sep list bytes)
//!   host.vfs_dir_list_read(path_ptr, path_len, d, dl)  → i32
//!
//! See build.zig (plugin_host.js) for the JavaScript implementation.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

// WASM host imports — linked by plugin_host.js; dead code on native builds.
const wasm = struct {
    extern "host" fn vfs_file_len(path_ptr: i32, path_len: i32) i32;
    extern "host" fn vfs_file_read(path_ptr: i32, path_len: i32, dest: i32, dest_len: i32) i32;
    extern "host" fn vfs_file_write(path_ptr: i32, path_len: i32, src: i32, src_len: i32) i32;
    extern "host" fn vfs_dir_make(path_ptr: i32, path_len: i32) i32;
    extern "host" fn vfs_dir_list_len(path_ptr: i32, path_len: i32) i32;
    extern "host" fn vfs_dir_list_read(path_ptr: i32, path_len: i32, dest: i32, dest_len: i32) i32;
};

/// Reinterpret a Zig pointer as an i32 address for the WASM host ABI.
inline fn wp(s: []const u8) i32 {
    return @intCast(@intFromPtr(s.ptr));
}

/// Truncate a usize length to i32 for the WASM host ABI (files < 2 GiB).
inline fn wl(s: []const u8) i32 {
    return @intCast(s.len);
}

fn countNulEntries(buf: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, buf, 0);
    while (it.next()) |tok| {
        if (tok.len == 0) break;
        count += 1;
    }
    return count;
}

fn buildEntriesFromNulBuf(allocator: Allocator, buf: []u8) ![][]const u8 {
    const entries = try allocator.alloc([]const u8, countNulEntries(buf));
    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, buf, 0);
    while (it.next()) |tok| {
        if (tok.len == 0) break;
        entries[idx] = tok;
        idx += 1;
    }
    return entries;
}

/// Platform-agnostic filesystem — static, no init/deinit needed.
/// Native: thin wrappers around std.fs. WASM: two-step host-import protocol.
pub const Vfs = struct {
    /// Named error set so callers can match specific failure modes.
    pub const IoError = error{
        FileNotFound,
        ReadError,
        WriteError,
        MakePathFailed,
        DirNotFound,
        DirReadError,
        OutOfMemory,
    };

    /// Owns two allocations; `entries` are views into `buf` — both freed by `deinit`.
    pub const DirList = struct {
        buf: []u8,
        entries: [][]const u8,

        /// Free both allocations; `entries` slices become invalid after this call.
        pub fn deinit(self: DirList, allocator: Allocator) void {
            allocator.free(self.entries);
            allocator.free(self.buf);
        }
    };

    /// Load a complete file so parsers get a contiguous slice to work from.
    pub fn readAlloc(allocator: Allocator, path: []const u8) ![]u8 {
        if (comptime is_wasm) {
            const len = wasm.vfs_file_len(wp(path), wl(path));
            if (len < 0) return error.FileNotFound;
            const buf = try allocator.alloc(u8, @intCast(len));
            errdefer allocator.free(buf);
            const got = wasm.vfs_file_read(wp(path), wl(path), wp(buf), wl(buf));
            if (got < 0) return error.ReadError;
            return buf;
        }
        return std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    }

    /// Atomically replace `path` with `data`, creating the file if absent.
    pub fn writeAll(path: []const u8, data: []const u8) !void {
        if (comptime is_wasm) {
            const rc = wasm.vfs_file_write(wp(path), wl(path), wp(data), wl(data));
            if (rc < 0) return error.WriteError;
            return;
        }
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
    }

    /// Guard plugin load paths without allocating a full read just to check presence.
    pub fn exists(path: []const u8) bool {
        if (comptime is_wasm) {
            return wasm.vfs_file_len(wp(path), wl(path)) >= 0;
        }
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    /// Ensure the plugin install directory exists before writing the .so/.wasm.
    pub fn makePath(path: []const u8) !void {
        if (comptime is_wasm) {
            if (wasm.vfs_dir_make(wp(path), wl(path)) < 0) return error.MakePathFailed;
            return;
        }
        try std.fs.cwd().makePath(path);
    }

    /// Check whether `path` refers to a directory.
    /// WASM: a path is a "directory" if any VFS entry has it as a prefix.
    pub fn isDir(path: []const u8) bool {
        if (comptime is_wasm) {
            return wasm.vfs_dir_list_len(wp(path), wl(path)) >= 0;
        }
        var dir = std.fs.cwd().openDir(path, .{}) catch return false;
        dir.close();
        return true;
    }

    /// Enumerate a plugin directory so the installer can diff installed vs. available.
    /// Returns bare filenames; build full paths with `std.fmt.allocPrint("{s}/{s}", ...)`.
    pub fn listDir(allocator: Allocator, path: []const u8) !DirList {
        if (comptime is_wasm) {
            const total = wasm.vfs_dir_list_len(wp(path), wl(path));
            if (total < 0) return error.DirNotFound;
            const buf = try allocator.alloc(u8, @intCast(total));
            errdefer allocator.free(buf);
            const rc = wasm.vfs_dir_list_read(wp(path), wl(path), wp(buf), wl(buf));
            if (rc < 0) return error.DirReadError;
            const entries = try buildEntriesFromNulBuf(allocator, buf);
            return .{ .buf = buf, .entries = entries };
        }

        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();

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
};

test "Expose struct size for Vfs" {
    const print = std.debug.print;
    print("Vfs: {d}B\n", .{@sizeOf(Vfs)});
    print("DirList: {d}B\n", .{@sizeOf(Vfs.DirList)});
}
