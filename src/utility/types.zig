//! types — shared data types for the utility module.
//!
//! Public within the module; external callers access these only through
//! the re-exports in `lib.zig` or through the structs that use them.

/// Severity levels in ascending order. Gates emission via Logger.min.
pub const Level = enum(u8) {
    trace,
    debug,
    info,
    warn,
    err,
    fatal,

    /// Three-letter abbreviation for compact log output ("TRC", "DBG", ...).
    pub fn sym(self: Level) *const [3]u8 {
        return &sym_table[@intFromEnum(self)];
    }

    // Comptime level-symbol table: one indexed load instead of a runtime switch.
    const sym_table: [6][3]u8 = blk: {
        const std = @import("std");
        const fields = @typeInfo(Level).@"enum".fields;
        var t: [fields.len][3]u8 = undefined;
        for (fields, 0..) |f, i| {
            const name = f.name;
            t[i] = [3]u8{
                std.ascii.toUpper(name[0]),
                std.ascii.toUpper(name[1]),
                std.ascii.toUpper(name[2]),
            };
        }
        break :blk t;
    };
};

/// One log record stored by value in the ring buffer.
/// `extern struct` guarantees C-compatible layout for direct memory inspection.
/// Fields ordered by alignment: u32 first, then u8 arrays, then u8 scalars.
pub const Entry = extern struct {
    seq: u32,
    level: Level,
    msg_len: u8,
    src_len: u8,
    _pad: u8 = 0,
    msg_buf: [MSG_CAP]u8,
    src_buf: [SRC_CAP]u8,

    /// Maximum characters stored per message field.
    pub const MSG_CAP = 128;
    /// Maximum characters stored per source field.
    pub const SRC_CAP = 32;

    /// Slice the message text without copying.
    pub fn msg(self: *const Entry) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }

    /// Slice the source tag without copying.
    pub fn src(self: *const Entry) []const u8 {
        return self.src_buf[0..self.src_len];
    }
};

/// Logger ring-buffer capacity.
pub const RING_CAP = 64;

// ── Platform error sets ─────────────────────────────────────────────

pub const UrlError = error{
    SpawnFailed,
};

pub const HttpError = error{
    UseAsyncGetOnWasm,
    HttpRequestFailed,
    OutOfMemory,
};

pub const AsyncGetError = error{
    NativeUseHttpGetSync,
    OutOfMemory,
};

pub const EnvError = error{
    NotFound,
    OutOfMemory,
};

pub const ProcessError = error{
    ProcessesNotSupported,
    SpawnFailed,
};

// ── Vfs types ───────────────────────────────────────────────────────

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
/// Fields ordered by alignment: slices (pointer+len = 2x usize) first.
pub const DirList = struct {
    buf: []u8,
    entries: [][]const u8,

    /// Free both allocations; `entries` slices become invalid after this call.
    pub fn deinit(self: DirList, allocator: @import("std").mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.buf);
    }
};

/// SIMD vector width for text scanning primitives.
pub const VEC_LEN = 16;

/// 16-byte SIMD vector type used by Simd scanning functions.
pub const Vec = @Vector(VEC_LEN, u8);
