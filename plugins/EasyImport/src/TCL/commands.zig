const std = @import("std");

pub const CommandError = error{
    InvalidArgCount,
    UnknownSubcommand,
    FileNotFound,
    PathError,
    OutOfMemory,
};

/// Execute `file` subcommands: dirname, normalize, join, isdir, isfile, tail, extension.
pub fn execFile(args: []const []const u8, allocator: std.mem.Allocator) CommandError![]const u8 {
    if (args.len < 1) return error.InvalidArgCount;
    const sub = args[0];
    const map = std.StaticStringMap(enum { dirname, normalize, join, isdir, isfile, tail, extension }).initComptime(.{
        .{ "dirname", .dirname },     .{ "normalize", .normalize },
        .{ "join", .join },           .{ "isdir", .isdir },
        .{ "isfile", .isfile },       .{ "tail", .tail },
        .{ "extension", .extension },
    });
    switch (map.get(sub) orelse return error.UnknownSubcommand) {
        .dirname => {
            if (args.len < 2) return error.InvalidArgCount;
            return std.fs.path.dirname(args[1]) orelse ".";
        },
        .normalize => {
            if (args.len < 2) return error.InvalidArgCount;
            const paths: []const []const u8 = &.{args[1]};
            return std.fs.path.resolve(allocator, paths) catch return error.PathError;
        },
        .join => {
            if (args.len < 2) return error.InvalidArgCount;
            return std.fs.path.join(allocator, args[1..]) catch return error.OutOfMemory;
        },
        .isdir => {
            if (args.len < 2) return error.InvalidArgCount;
            return if (isDirExists(args[1])) "1" else "0";
        },
        .isfile => {
            if (args.len < 2) return error.InvalidArgCount;
            return if (isFileExists(args[1])) "1" else "0";
        },
        .tail => {
            if (args.len < 2) return error.InvalidArgCount;
            return std.fs.path.basename(args[1]);
        },
        .extension => {
            if (args.len < 2) return error.InvalidArgCount;
            return std.fs.path.extension(args[1]);
        },
    }
}

/// Execute `info` subcommands: exists, script.
pub fn execInfo(
    args: []const []const u8,
    var_exists: *const fn ([]const u8) bool,
    script_path: ?[]const u8,
) CommandError![]const u8 {
    if (args.len < 1) return error.InvalidArgCount;
    if (std.mem.eql(u8, args[0], "exists")) {
        if (args.len < 2) return error.InvalidArgCount;
        const name = args[1];
        // Check for env(NAME) pattern
        if (std.mem.startsWith(u8, name, "env(") and std.mem.endsWith(u8, name, ")")) {
            const env_name = name[4 .. name.len - 1];
            return if (std.posix.getenv(env_name) != null) "1" else "0";
        }
        return if (var_exists(name)) "1" else "0";
    }
    if (std.mem.eql(u8, args[0], "script")) {
        return script_path orelse "";
    }
    return error.UnknownSubcommand;
}

/// Execute `string` subcommands: equal, tolower, length.
pub fn execString(args: []const []const u8, allocator: std.mem.Allocator) CommandError![]const u8 {
    if (args.len < 1) return error.InvalidArgCount;
    const sub = args[0];
    if (std.mem.eql(u8, sub, "equal")) {
        if (args.len >= 4 and std.mem.eql(u8, args[1], "-nocase")) {
            return if (std.ascii.eqlIgnoreCase(args[2], args[3])) "1" else "0";
        }
        if (args.len < 3) return error.InvalidArgCount;
        return if (std.mem.eql(u8, args[1], args[2])) "1" else "0";
    }
    if (std.mem.eql(u8, sub, "tolower")) {
        if (args.len < 2) return error.InvalidArgCount;
        const out = allocator.alloc(u8, args[1].len) catch return error.OutOfMemory;
        for (args[1], 0..) |c, i| out[i] = std.ascii.toLower(c);
        return out;
    }
    if (std.mem.eql(u8, sub, "length")) {
        if (args.len < 2) return error.InvalidArgCount;
        return std.fmt.allocPrint(allocator, "{d}", .{args[1].len}) catch return error.OutOfMemory;
    }
    if (std.mem.eql(u8, sub, "is")) {
        // string is double/integer -- used by sky130 xschemrc in proc bodies
        // We cannot fully evaluate this, return "1" for non-empty values
        if (args.len < 3) return error.InvalidArgCount;
        const val = args[2];
        if (std.mem.eql(u8, args[1], "double")) {
            return if (std.fmt.parseFloat(f64, val)) |_| "1" else |_| "0";
        }
        if (std.mem.eql(u8, args[1], "integer")) {
            return if (std.fmt.parseInt(i64, val, 10)) |_| "1" else |_| "0";
        }
        return "0";
    }
    return error.UnknownSubcommand;
}

/// Read a file for `source` command. Returns file contents or null if not found.
pub fn readSourceFile(path: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    if (stat.size > 10 * 1024 * 1024) return null; // 10MB safety limit
    return file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch null;
}

fn isDirExists(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

fn isFileExists(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    _ = stat;
    return true;
}

// --- Parsing helpers shared between evaluator and this module ---

pub fn findMatchingBrace(src: []const u8, open_idx: usize) !usize {
    var depth: usize = 0;
    var i = open_idx;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\\' and i + 1 < src.len) { i += 1; continue; }
        if (src[i] == '{') depth += 1;
        if (src[i] == '}') { depth -= 1; if (depth == 0) return i; }
    }
    return error.Unbalanced;
}

pub fn findMatchingBracket(src: []const u8, open_idx: usize) !usize {
    var depth: usize = 0;
    var i = open_idx;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\\' and i + 1 < src.len) { i += 1; continue; }
        if (src[i] == '[') depth += 1;
        if (src[i] == ']') { depth -= 1; if (depth == 0) return i; }
    }
    return error.Unbalanced;
}

pub fn parseBlocks(src: []const u8, buf: *[32][]const u8, count: *usize) void {
    count.* = 0;
    var i: usize = 0;
    while (i < src.len and count.* < 32) {
        while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\n' or src[i] == '\r')) i += 1;
        if (i >= src.len) break;
        if (src[i] == '{') {
            const end = findMatchingBrace(src, i) catch break;
            buf[count.*] = src[i + 1 .. end];
            count.* += 1;
            i = end + 1;
        } else {
            const start = i;
            while (i < src.len and src[i] != ' ' and src[i] != '\t' and src[i] != '\n' and src[i] != '{') i += 1;
            buf[count.*] = src[start..i];
            count.* += 1;
        }
    }
}

pub const SegmentScanner = struct {
    src: []const u8,
    pos: usize,

    pub fn init(src: []const u8) SegmentScanner {
        return .{ .src = src, .pos = 0 };
    }

    pub fn next(self: *SegmentScanner) ?[]const u8 {
        while (self.pos < self.src.len and
            (self.src[self.pos] == '\n' or self.src[self.pos] == ';' or
            self.src[self.pos] == ' ' or self.src[self.pos] == '\t' or self.src[self.pos] == '\r'))
            self.pos += 1;
        if (self.pos >= self.src.len) return null;
        const start = self.pos;
        var brace_depth: usize = 0;
        var bracket_depth: usize = 0;
        var in_quote = false;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            if (c == '\\' and self.pos + 1 < self.src.len) { self.pos += 1; continue; }
            if (c == '"') { in_quote = !in_quote; continue; }
            if (in_quote) continue;
            switch (c) {
                '{' => brace_depth += 1,
                '}' => { if (brace_depth > 0) brace_depth -= 1; },
                '[' => bracket_depth += 1,
                ']' => { if (bracket_depth > 0) bracket_depth -= 1; },
                ';', '\n' => if (brace_depth == 0 and bracket_depth == 0) {
                    const seg = self.src[start..self.pos];
                    self.pos += 1;
                    return seg;
                },
                else => {},
            }
        }
        return if (start < self.src.len) self.src[start..] else null;
    }
};
