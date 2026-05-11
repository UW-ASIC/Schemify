const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const fs = std.fs;

const Decl = struct {
    name: []const u8,
    file_path: []const u8,
    line: u32,
    is_pub: bool,
};

const FileEntry = struct {
    path: []const u8,
    content: []const u8,
};

const special_fns = [_][]const u8{
    "main",    "panic",  "log",      "format",
    "hash",    "eql",    "lessThan", "compare",
    "init",    "deinit", "next",     "reset",
};

const skip_files = [_][]const u8{
    "src/plugins/Writer.zig",
    "src/plugins/Framework.zig",
    "src/plugins/Runtime.zig",
};

fn isSkippedFile(path: []const u8) bool {
    for (skip_files) |s| {
        if (mem.eql(u8, path, s)) return true;
    }
    return false;
}

fn isSpecialFn(name: []const u8) bool {
    if (name.len > 0 and name[0] == '_') return true;
    for (special_fns) |s| {
        if (mem.eql(u8, name, s)) return true;
    }
    return false;
}

fn isInTestBlock(content: []const u8, pos: usize) bool {
    const before = content[0..pos];
    const last_test = mem.lastIndexOf(u8, before, "test \"") orelse return false;
    var depth: i32 = 0;
    for (before[last_test..]) |ch| {
        if (ch == '{') {
            depth += 1;
        } else if (ch == '}') {
            depth -= 1;
            if (depth == 0) return false;
        }
    }
    return depth > 0;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isWordChar(c: u8) bool {
    return isIdentChar(c) or (c >= '0' and c <= '9');
}

fn extractDecls(alloc: Allocator, file_path: []const u8, content: []const u8, decls: *std.ArrayListUnmanaged(Decl)) !void {
    var line_no: u32 = 1;
    var i: usize = 0;

    while (i < content.len) {
        const line_start = i;

        while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}

        var is_pub = false;
        var found_fn = false;

        if (i + 7 <= content.len and mem.eql(u8, content[i .. i + 7], "pub fn ")) {
            is_pub = true;
            found_fn = true;
            i += 7;
        } else if (i + 3 <= content.len and mem.eql(u8, content[i .. i + 3], "fn ")) {
            found_fn = true;
            i += 3;
        }

        if (!found_fn) {
            while (i < content.len and content[i] != '\n') : (i += 1) {}
            if (i < content.len) i += 1;
            line_no += 1;
            continue;
        }

        const name_start = i;
        while (i < content.len and isWordChar(content[i])) : (i += 1) {}
        const name = content[name_start..i];

        if (name.len == 0) {
            while (i < content.len and content[i] != '\n') : (i += 1) {}
            if (i < content.len) i += 1;
            line_no += 1;
            continue;
        }

        while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}
        if (i >= content.len or content[i] != '(') {
            while (i < content.len and content[i] != '\n') : (i += 1) {}
            if (i < content.len) i += 1;
            line_no += 1;
            continue;
        }

        if (!isInTestBlock(content, line_start)) {
            const name_copy = try alloc.dupe(u8, name);
            try decls.append(alloc, .{
                .name = name_copy,
                .file_path = file_path,
                .line = line_no,
                .is_pub = is_pub,
            });
        }

        while (i < content.len and content[i] != '\n') : (i += 1) {}
        if (i < content.len) i += 1;
        line_no += 1;
    }
}

fn countRefsIn(name: []const u8, content: []const u8) u32 {
    var count: u32 = 0;
    var i: usize = 0;
    while (i + name.len <= content.len) {
        if (mem.eql(u8, content[i .. i + name.len], name)) {
            const before_ok = (i == 0) or !isWordChar(content[i - 1]);
            const after_ok = (i + name.len >= content.len) or !isWordChar(content[i + name.len]);
            if (before_ok and after_ok) {
                count += 1;
            }
            i += name.len;
        } else {
            i += 1;
        }
    }
    return count;
}

fn collectZigFiles(alloc: Allocator, dir: fs.Dir, prefix: []const u8, files: *std.ArrayListUnmanaged(FileEntry)) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, entry.name });

        switch (entry.kind) {
            .directory => {
                var sub_dir = try dir.openDir(entry.name, .{ .iterate = true });
                defer sub_dir.close();
                try collectZigFiles(alloc, sub_dir, full_path, files);
            },
            .file => {
                if (mem.endsWith(u8, entry.name, ".zig")) {
                    const content = try dir.readFileAlloc(alloc, entry.name, std.math.maxInt(usize));
                    try files.append(alloc, .{ .path = full_path, .content = content });
                }
            },
            else => {},
        }
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var files: std.ArrayListUnmanaged(FileEntry) = .empty;

    for ([_][]const u8{ "src", "plugins" }) |dir_name| {
        var dir = fs.cwd().openDir(dir_name, .{ .iterate = true }) catch continue;
        defer dir.close();
        try collectZigFiles(alloc, dir, dir_name, &files);
    }

    var decls: std.ArrayListUnmanaged(Decl) = .empty;
    for (files.items) |f| {
        try extractDecls(alloc, f.path, f.content, &decls);
    }

    var dead_fns: std.ArrayListUnmanaged(Decl) = .empty;
    var unnecessary_pub: std.ArrayListUnmanaged(Decl) = .empty;

    for (decls.items) |decl| {
        if (isSpecialFn(decl.name)) continue;
        if (isSkippedFile(decl.file_path)) continue;

        var same_file: u32 = 0;
        var other_files: u32 = 0;

        for (files.items) |f| {
            const count = countRefsIn(decl.name, f.content);
            if (mem.eql(u8, f.path, decl.file_path)) {
                same_file = if (count > 0) count - 1 else 0;
            } else {
                other_files += count;
            }
        }

        if (same_file == 0 and other_files == 0) {
            try dead_fns.append(alloc, decl);
        } else if (decl.is_pub and other_files == 0 and same_file > 0) {
            try unnecessary_pub.append(alloc, decl);
        }
    }

    const stdout = std.io.getStdOut().writer();

    if (dead_fns.items.len > 0) {
        try stdout.print("\n{s}\n", .{"=" ** 60});
        try stdout.print(" DEAD FUNCTIONS ({d} found)\n", .{dead_fns.items.len});
        try stdout.print(" Never referenced anywhere in the codebase\n", .{});
        try stdout.print("{s}\n\n", .{"=" ** 60});
        for (dead_fns.items) |d| {
            const pub_str: []const u8 = if (d.is_pub) "pub " else "    ";
            try stdout.print("  {s}:{d}  {s}fn {s}\n", .{ d.file_path, d.line, pub_str, d.name });
        }
    }

    if (unnecessary_pub.items.len > 0) {
        try stdout.print("\n{s}\n", .{"=" ** 60});
        try stdout.print(" UNNECESSARY PUB ({d} found)\n", .{unnecessary_pub.items.len});
        try stdout.print(" Only used within their own file — pub can be removed\n", .{});
        try stdout.print("{s}\n\n", .{"=" ** 60});
        for (unnecessary_pub.items) |d| {
            try stdout.print("  {s}:{d}  pub fn {s}\n", .{ d.file_path, d.line, d.name });
        }
    }

    if (dead_fns.items.len == 0 and unnecessary_pub.items.len == 0) {
        try stdout.print("\nNo dead code found!\n", .{});
        return;
    }

    const total = dead_fns.items.len + unnecessary_pub.items.len;
    try stdout.print("\n{s}\n", .{"-" ** 60});
    try stdout.print(" Total issues: {d} ({d} dead, {d} unnecessary pub)\n", .{ total, dead_fns.items.len, unnecessary_pub.items.len });
    try stdout.print("{s}\n\n", .{"-" ** 60});

    if (dead_fns.items.len > 0) {
        std.process.exit(1);
    }
}
