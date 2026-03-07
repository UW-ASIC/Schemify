//! Logger — ring-buffer message store for GUI display.
//!
//! Entry is 40 bytes on 64-bit (seq:u32 + level:u8 + pad + 2 slices).
//! Drain with entries() / entriesSince(seq), or filter with countAt().
//!
//! ── Error Handling ────────────────────────────────────────────────────────
//!
//! Currently all internal allocation failures are silently swallowed with
//! `catch return` / `catch {}`. This is deliberate: the logger is called
//! from hot paths (parsers, netlist writer) where OOM should degrade
//! gracefully rather than crash. If you need to detect OOM, call
//! `logger.hasErrors()` after a major operation and check for a specific
//! "logger OOM" sentinel you inject manually.
//!
//! To make error handling more verbose, change individual `catch return`
//! sites to `catch |e| { std.debug.print("logger OOM: {}\n", .{e}); return; }`
//! and guard those prints with `if (!is_wasm)`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

/// Severity levels in ascending order. The `min` field on Logger gates emission.
pub const Level = enum(u8) {
    trace,
    debug,
    info,
    warn,
    err,
    fatal,

    /// Three-letter uppercase abbreviation used in stderr output.
    pub fn sym(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRC",
            .debug => "DBG",
            .info => "INF",
            .warn => "WRN",
            .err => "ERR",
            .fatal => "FTL",
        };
    }
};

/// One log record. Stored by value in the ring-buffer array.
/// Strings (`msg`, `src`) point into the Logger's arena — valid until `clear()`.
///
/// IMPROVE: The struct comment says 28 bytes but `msg` and `src` are each
/// 16 bytes on 64-bit (ptr+len), so the actual size is 2×16 + 4 + 1 + 3 pad = 40 bytes.
/// The module-level doc comment is correct; the struct-level comment is stale.
pub const Entry = struct { // 40 bytes (2 slices + u32 + u8 + pad)
    msg: []const u8,
    src: []const u8,
    seq: u32,
    level: Level,
};

/// Ring-buffer logger.
///
/// Owns two allocations:
///   `buf`   — the Entry array, backed by `alloc` (GPA / page allocator).
///   `arena` — string storage for `msg` and `src` slices inside each Entry.
///
/// The arena is only reset on `clear()`, not on individual evictions.
///
/// IMPROVE: When the ring is full, `orderedRemove(0)` is O(n) because it
/// shifts every element left. A proper ring-buffer with head/tail indices
/// and `buf.items[head % cap]` access would make eviction O(1). For 2048
/// entries and typical schematic sizes this is acceptable, but becomes
/// noticeable in tight parse loops emitting thousands of warnings.
///
/// IMPROVE: `countAt()` does a full O(n) scan on every call. If `hasErrors()`
/// or badge counts are polled every frame, keep a per-level counter array
/// `counts: [6]u32` that is incremented in `log()` and zeroed in `clear()`.
pub const Logger = struct {
    alloc: Allocator,
    /// Minimum level to store; messages below this are dropped immediately.
    min: Level,
    buf: std.ArrayListUnmanaged(Entry) = .{},
    /// Arena for message/source strings. Reset only on `clear()`.
    arena: std.heap.ArenaAllocator,
    /// Monotonically increasing sequence number. Used by `entriesSince`.
    /// NOTE: Not reset on `clear()` — sequence numbers remain globally unique
    /// across clears, which lets GUI panels remember their last-seen seq.
    seq: u32 = 0,
    /// Maximum entries before oldest is evicted. Default 2048.
    cap: u32 = 2048,

    /// Create a logger with the given backing allocator and minimum level.
    pub fn init(a: Allocator, min: Level) Logger {
        return .{ .alloc = a, .min = min, .arena = std.heap.ArenaAllocator.init(a) };
    }

    pub fn deinit(self: *Logger) void {
        self.buf.deinit(self.alloc);
        self.arena.deinit();
    }

    /// Core log function. Drops the message if `lvl < self.min`.
    /// On OOM: silently drops the entry (see module-level error-handling note).
    /// On native targets: also calls `emit()` to write to stderr.
    pub fn log(self: *Logger, lvl: Level, src: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(lvl) < @intFromEnum(self.min)) return;
        const a = self.arena.allocator();
        const msg = std.fmt.allocPrint(a, fmt, args) catch return;
        const s = a.dupe(u8, src) catch return;
        // Evict oldest entry when at capacity. O(n) — see struct-level IMPROVE note.
        if (self.buf.items.len >= self.cap) _ = self.buf.orderedRemove(0);
        self.buf.append(self.alloc, .{ .msg = msg, .src = s, .seq = self.seq, .level = lvl }) catch return;
        self.seq += 1;
        if (!is_wasm) self.emit(lvl, s, msg);
    }

    // ── convenience ─────────────────────────────────────────────────── //

    pub fn trace(self: *Logger, src: []const u8, comptime f: []const u8, a: anytype) void {
        self.log(.trace, src, f, a);
    }
    pub fn debug(self: *Logger, src: []const u8, comptime f: []const u8, a: anytype) void {
        self.log(.debug, src, f, a);
    }
    pub fn info(self: *Logger, src: []const u8, comptime f: []const u8, a: anytype) void {
        self.log(.info, src, f, a);
    }
    pub fn warn(self: *Logger, src: []const u8, comptime f: []const u8, a: anytype) void {
        self.log(.warn, src, f, a);
    }
    pub fn err(self: *Logger, src: []const u8, comptime f: []const u8, a: anytype) void {
        self.log(.err, src, f, a);
    }
    pub fn fatal(self: *Logger, src: []const u8, comptime f: []const u8, a: anytype) void {
        self.log(.fatal, src, f, a);
    }

    // ── query ───────────────────────────────────────────────────────── //

    /// Return all stored entries in chronological order.
    pub fn entries(self: *const Logger) []const Entry {
        return self.buf.items;
    }

    /// Return entries whose sequence number is >= `since`.
    /// Useful for GUI panels that track a watermark and poll for new messages.
    /// Relies on the buffer being sorted by seq (it always is — append-only).
    pub fn entriesSince(self: *const Logger, since: u32) []const Entry {
        for (self.buf.items, 0..) |e, i| if (e.seq >= since) return self.buf.items[i..];
        return &.{};
    }

    /// Count entries at or above `min` level. O(n) — see struct-level IMPROVE note.
    pub fn countAt(self: *const Logger, min: Level) u32 {
        var n: u32 = 0;
        for (self.buf.items) |e| if (@intFromEnum(e.level) >= @intFromEnum(min)) {
            n += 1;
        };
        return n;
    }

    /// True if any stored entry is at `.err` or above.
    pub fn hasErrors(self: *const Logger) bool {
        return self.countAt(.err) > 0;
    }

    /// Discard all entries and reset the string arena.
    /// NOTE: `seq` is intentionally NOT reset — see field comment above.
    pub fn clear(self: *Logger) void {
        self.buf.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    // ── stderr (native only) ────────────────────────────────────────── //

    /// Write a single entry to stderr. Only called on non-WASM targets.
    /// The `_` receiver is correct — no Logger state is needed for formatting.
    fn emit(_: *const Logger, lvl: Level, src: []const u8, msg: []const u8) void {
        std.debug.print("[{s}] {s}: {s}\n", .{ lvl.sym(), src, msg });
    }
};
