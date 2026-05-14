const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.cpu.arch.isWasm();

// ── Filesystem abstraction ───────────────────────────────────────────────────
// Native: thin wrappers around std.fs.
// WASM:   calls into JS host VFS (IndexedDB-backed in-memory Map).

pub const fs = if (is_wasm) WasmFs else NativeFs;

// ── Native filesystem ────────────────────────────────────────────────────────

const NativeFs = struct {
    pub fn cwd() std.fs.Dir {
        return std.fs.cwd();
    }

    pub const File = std.fs.File;

    pub fn stdout() std.fs.File {
        return std.fs.File.stdout();
    }

    pub fn stderr() std.fs.File {
        return std.fs.File.stderr();
    }

    pub fn stdin() std.fs.File {
        return std.fs.File.stdin();
    }
};

// ── WASM VFS ─────────────────────────────────────────────────────────────────
// Backed by JS host functions defined in schemify_host.js.
// The JS side stores files in an in-memory Map, persisted to OPFS/IndexedDB
// via a Web Worker (write-through on every mutation).

const WasmFs = struct {
    pub fn cwd() WasmDir {
        return .{ .prefix = "" };
    }

    pub const File = WasmFile;

    pub fn stdout() WasmFile {
        return .{ .slot = 0 };
    }
    pub fn stderr() WasmFile {
        return .{ .slot = 0 };
    }
    pub fn stdin() WasmFile {
        return .{ .slot = 0 };
    }
};

// -- JS host imports (namespace "host" in schemify_host.js) --

extern "host" fn vfs_file_len(path_ptr: [*]const u8, path_len: u32) i32;
extern "host" fn vfs_file_read(path_ptr: [*]const u8, path_len: u32, dest: [*]u8, dlen: u32) i32;
extern "host" fn vfs_file_write(path_ptr: [*]const u8, path_len: u32, src: [*]const u8, slen: u32) i32;
extern "host" fn vfs_file_delete(path_ptr: [*]const u8, path_len: u32) i32;
extern "host" fn vfs_dir_list_len(path_ptr: [*]const u8, path_len: u32) i32;
extern "host" fn vfs_dir_list_read(path_ptr: [*]const u8, path_len: u32, dest: [*]u8, dlen: u32) i32;

// -- WasmDir: std.fs.Dir-compatible interface over the JS VFS --

const WasmDir = struct {
    prefix: []const u8,

    pub fn close(_: WasmDir) void {}

    pub fn readFileAlloc(self: WasmDir, alloc: std.mem.Allocator, sub_path: []const u8, max_bytes: usize) ![]u8 {
        var path_buf: [1024]u8 = undefined;
        const full = self.joinPath(&path_buf, sub_path) orelse return error.FileNotFound;
        const len = vfs_file_len(full.ptr, @intCast(full.len));
        if (len < 0) return error.FileNotFound;
        const size: usize = @min(@as(usize, @intCast(len)), max_bytes);
        const buf = try alloc.alloc(u8, size);
        errdefer alloc.free(buf);
        const n = vfs_file_read(full.ptr, @intCast(full.len), buf.ptr, @intCast(size));
        if (n < 0) {
            alloc.free(buf);
            return error.FileNotFound;
        }
        return buf[0..@as(usize, @intCast(n))];
    }

    pub fn writeFile(self: WasmDir, args: struct { sub_path: []const u8, data: []const u8 }) !void {
        var path_buf: [1024]u8 = undefined;
        const full = self.joinPath(&path_buf, args.sub_path) orelse return error.FileNotFound;
        const rc = vfs_file_write(full.ptr, @intCast(full.len), args.data.ptr, @intCast(args.data.len));
        if (rc < 0) return error.AccessDenied;
    }

    pub fn access(self: WasmDir, sub_path: []const u8, _: std.fs.File.OpenFlags) !void {
        var path_buf: [1024]u8 = undefined;
        const full = self.joinPath(&path_buf, sub_path) orelse return error.FileNotFound;
        if (vfs_file_len(full.ptr, @intCast(full.len)) < 0) return error.FileNotFound;
    }

    pub fn createFile(self: WasmDir, sub_path: []const u8, _: std.fs.File.CreateFlags) !WasmFile {
        var path_buf: [1024]u8 = undefined;
        const full = self.joinPath(&path_buf, sub_path) orelse return error.FileNotFound;
        // Allocate a slot for buffered writes.
        for (&wasm_file_slots, 0..) |*slot, i| {
            if (!slot.active) {
                slot.active = true;
                const n = @min(full.len, slot.path_buf.len);
                @memcpy(slot.path_buf[0..n], full[0..n]);
                slot.path_len = n;
                slot.buf_len = 0;
                return .{ .slot = @intCast(i) };
            }
        }
        return error.SystemResources;
    }

    pub fn deleteTree(self: WasmDir, sub_path: []const u8) !void {
        var path_buf: [1024]u8 = undefined;
        const full = self.joinPath(&path_buf, sub_path) orelse return error.FileNotFound;
        _ = vfs_file_delete(full.ptr, @intCast(full.len));
    }

    pub fn openDir(self: WasmDir, sub_path: []const u8, _: anytype) !WasmDir {
        var path_buf: [1024]u8 = undefined;
        const full = self.joinPath(&path_buf, sub_path) orelse return error.FileNotFound;
        // Copy the path so the returned Dir owns its prefix.
        var owned: [512]u8 = undefined;
        const n = @min(full.len, owned.len);
        @memcpy(owned[0..n], full[0..n]);
        return .{ .prefix = owned[0..n] };
    }

    pub fn iterate(self: WasmDir) WasmDirIterator {
        const total = vfs_dir_list_len(self.prefix.ptr, @intCast(self.prefix.len));
        if (total <= 0) return .{ .data = &.{}, .pos = 0 };
        const size: usize = @intCast(total);
        const buf = std.heap.page_allocator.alloc(u8, size) catch return .{ .data = &.{}, .pos = 0 };
        const read = vfs_dir_list_read(self.prefix.ptr, @intCast(self.prefix.len), buf.ptr, @intCast(size));
        if (read <= 0) {
            std.heap.page_allocator.free(buf);
            return .{ .data = &.{}, .pos = 0 };
        }
        return .{ .data = buf[0..@as(usize, @intCast(read))], .pos = 0 };
    }

    fn joinPath(self: WasmDir, buf: *[1024]u8, sub_path: []const u8) ?[]const u8 {
        if (self.prefix.len == 0) {
            if (sub_path.len > buf.len) return null;
            @memcpy(buf[0..sub_path.len], sub_path);
            return buf[0..sub_path.len];
        }
        const total = self.prefix.len + 1 + sub_path.len;
        if (total > buf.len) return null;
        @memcpy(buf[0..self.prefix.len], self.prefix);
        buf[self.prefix.len] = '/';
        @memcpy(buf[self.prefix.len + 1 ..][0..sub_path.len], sub_path);
        return buf[0..total];
    }
};

// -- WasmDirIterator --

const WasmDirIterator = struct {
    data: []const u8,
    pos: usize,

    pub const Entry = struct {
        name: []const u8,
        kind: std.fs.File.Kind,
    };

    pub fn next(self: *WasmDirIterator) !?Entry {
        if (self.pos >= self.data.len) return null;
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != 0) : (self.pos += 1) {}
        const name = self.data[start..self.pos];
        if (self.pos < self.data.len) self.pos += 1; // skip null
        if (name.len == 0) return null;
        // VFS is flat — entries without extensions are treated as directories.
        const kind: std.fs.File.Kind = if (std.mem.indexOfScalar(u8, name, '.') != null) .file else .directory;
        return .{ .name = name, .kind = kind };
    }
};

// -- WasmFile: buffered file writer for createFile --

const MAX_WASM_FILE_SLOTS = 4;
const WASM_FILE_BUF_SIZE = 1 << 20; // 1 MB per slot

const WasmFileSlot = struct {
    active: bool = false,
    path_buf: [512]u8 = undefined,
    path_len: usize = 0,
    buf: [WASM_FILE_BUF_SIZE]u8 = undefined,
    buf_len: usize = 0,
};

var wasm_file_slots: [MAX_WASM_FILE_SLOTS]WasmFileSlot = [_]WasmFileSlot{.{}} ** MAX_WASM_FILE_SLOTS;

const WasmFile = struct {
    slot: u8,

    pub fn writeAll(self: WasmFile, data: []const u8) !void {
        const s = &wasm_file_slots[self.slot];
        if (s.buf_len + data.len > s.buf.len) return error.NoSpaceLeft;
        @memcpy(s.buf[s.buf_len..][0..data.len], data);
        s.buf_len += data.len;
    }

    pub fn read(_: WasmFile, _: []u8) !usize {
        return 0;
    }

    pub fn close(self: WasmFile) void {
        const s = &wasm_file_slots[self.slot];
        if (s.active) {
            _ = vfs_file_write(&s.path_buf, @intCast(s.path_len), &s.buf, @intCast(s.buf_len));
            s.active = false;
            s.buf_len = 0;
        }
    }
};

// ── HTTP ─────────────────────────────────────────────────────────────────────

/// Synchronous HTTP GET via curl. Caller owns returned slice.
pub fn httpGetSync(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    if (comptime is_wasm) return error.HttpRequestFailed; // Use async JS fetch on WASM.
    var child = std.process.Child.init(&.{ "curl", "-sfL", url }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const stdout_reader = child.stdout.?.readToEndAlloc(alloc, std.math.maxInt(usize)) catch
        return error.HttpRequestFailed;
    const term = try child.wait();
    if (term.Exited != 0) {
        alloc.free(stdout_reader);
        return error.HttpRequestFailed;
    }
    return stdout_reader;
}

// ── Directories ──────────────────────────────────────────────────────────────

/// Returns `$HOME/.config/Schemify` (runtime, caller owns memory).
pub fn pluginConfigDir(alloc: std.mem.Allocator) ![]u8 {
    if (comptime is_wasm) return alloc.dupe(u8, ".config/Schemify");
    const home = homeDir() orelse return error.HomeNotFound;
    return std.fmt.allocPrint(alloc, "{s}/.config/Schemify", .{home});
}

/// Return HOME environment variable, or null.
pub fn homeDir() ?[]const u8 {
    if (comptime is_wasm) return null;
    return std.posix.getenv("HOME");
}

test "homeDir returns non-null on linux" {
    if (builtin.os.tag == .linux) {
        try std.testing.expect(homeDir() != null);
    }
}
