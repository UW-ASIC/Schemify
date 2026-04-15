// xschem_roundtrip.zig - XSchem roundtrip and SPICE comparison tests.
const std = @import("std");
const testing = std.testing;
const XSchem = @import("xschem");
const easyimport = @import("easyimport");
const core = @import("core");

const convert = XSchem.convert;
const reader = XSchem.fileio.reader;
const writer = XSchem.fileio.writer;
const types = XSchem.types;

/// Pinned commit of xschem_library submodule.
const XSCHEM_LIBRARY_COMMIT = "92fc6e06cbb0d3785a29d261b1b40490c502ec7a";

/// Fixture root: absolute path to xschem_library within the repo.
/// xschem_library files (devices/, ngspice/, etc.) are at:
/// plugins/EasyImport/test/fixtures/xschem_library/xschem_library/
const FIXTURE_ROOT = "plugins/EasyImport/test/fixtures/xschem_library/xschem_library";

// ============================================================================
// Dependency graph types and functions for xschem fixtures.
// ============================================================================

const FixtureCategory = enum {
    primitive, // .sym only (no matching .sch)
    paired, // has both .sch and .sym with same stem
    orphan, // .sch only (no matching .sym)
};

/// A fixture is a xschem component that may have both .sch and .sym files.
const Fixture = struct {
    stem: []const u8,
    category: FixtureCategory,
    sch_path: ?[]const u8, // null if primitive
    sym_path: ?[]const u8,
    refs: std.ArrayListUnmanaged([]const u8), // sym stems referenced by this .sch
};

/// A node in the dependency graph.
const GraphNode = struct {
    stem: []const u8,
    fixture: *Fixture,
    in_degree: u32,
};

/// Dependency graph for fixtures.
const DepGraph = struct {
    nodes: std.StringHashMapUnmanaged(*GraphNode),
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *DepGraph) void {
        self.arena.deinit();
    }
};

/// Extract stem from a .sym or .sch path.
/// e.g. "/path/to/and_ngspice.sym" -> "and_ngspice"
fn stemFromPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".sym")) {
        return path[0 .. path.len - 4];
    }
    if (std.mem.endsWith(u8, path, ".sch")) {
        return path[0 .. path.len - 4];
    }
    return path;
}

/// Scan fixtures_dir recursively, collecting all .sch and .sym files,
/// matching them by stem name, and parsing .sch files for symbol references.
fn scanFixtures(arena: std.mem.Allocator, fixtures_dir: []const u8) !std.ArrayListUnmanaged(Fixture) {
    var fixtures = std.ArrayListUnmanaged(Fixture){};
    errdefer {
        for (fixtures.items) |*f| {
            f.refs.deinit(arena);
        }
        fixtures.deinit(arena);
    }

    // First pass: collect all .sch and .sym paths grouped by stem.
    var sch_stems = std.StringHashMapUnmanaged([]const u8){};
    var sym_stems = std.StringHashMapUnmanaged([]const u8){};
    defer {
        var it = sch_stems.iterator();
        while (it.next()) |entry| arena.free(entry.value);
        it = sym_stems.iterator();
        while (it.next()) |entry| arena.free(entry.value);
        sch_stems.deinit(arena);
        sym_stems.deinit(arena);
    }

    var walker = try std.fs.walkDir(fixtures_dir, arena);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const p = entry.path;
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, p, ".sch") or std.mem.endsWith(u8, p, ".sym")) {
            const full_path = try std.fs.path.join(arena, &.{ fixtures_dir, p });
            const stem = stemFromPath(full_path);
            const stem_copy = try arena.dupe(u8, stem);

            if (std.mem.endsWith(u8, p, ".sch")) {
                try sch_stems.put(arena, stem_copy, full_path);
            } else {
                try sym_stems.put(arena, stem_copy, full_path);
            }
        }
    }

    // Determine category for each stem.
    var it = sch_stems.iterator();
    while (it.next()) |sch_entry| {
        const stem = sch_entry.key;
        const sch_path = sch_entry.value;
        const has_sym = sym_stems.contains(stem);

        const sym_path = if (has_sym) sym_stems.get(stem).? else null;
        const category: FixtureCategory = if (has_sym) .paired else .orphan;

        var refs = std.ArrayListUnmanaged([]const u8){};
        if (category == .paired) {
            // Parse .sch for C {symbol} lines.
            const content = try std.fs.cwd().readFileAlloc(arena, sch_path, 1024 * 1024);
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                var trimmed = std.mem.trim(u8, line, " \t\r");
                if (std.mem.startsWith(u8, trimmed, "C {")) {
                    const start = std.mem.indexOfScalar(u8, trimmed, '{').? + 1;
                    const end = std.mem.indexOfScalar(u8, trimmed[start..], '}').?;
                    const sym_ref_full = trimmed[start .. start + end];
                    // sym_ref_full may be an absolute path or just a stem.
                    const ref_stem = stemFromPath(sym_ref_full);
                    const ref_stem_copy = try arena.dupe(u8, ref_stem);
                    try refs.append(arena, ref_stem_copy);
                }
            }
        }

        try fixtures.append(arena, .{
            .stem = stem,
            .category = category,
            .sch_path = sch_path,
            .sym_path = sym_path,
            .refs = refs,
        });
    }

    // Primitives: .sym only, no .sch.
    it = sym_stems.iterator();
    while (it.next()) |sym_entry| {
        const stem = sym_entry.key;
        if (sch_stems.contains(stem)) continue; // already processed as paired/orphan
        const sym_path = sym_entry.value;
        try fixtures.append(arena, .{
            .stem = stem,
            .category = .primitive,
            .sch_path = null,
            .sym_path = sym_path,
            .refs = .{},
        });
    }

    return fixtures;
}

/// Topological sort of fixtures using Kahn's algorithm.
/// Sorts by in-degree where a .sch depends on .sym files that are NOT also .sch files.
/// Primitives (sym-only) are roots with in_degree 0.
fn topologicalSort(fixtures: []const Fixture) !std.ArrayListUnmanaged(*Fixture) {
    var result = std.ArrayListUnmanaged(*Fixture){};
    errdefer result.deinit();

    // Build a map from stem -> fixture.
    var stem_map = std.StringHashMapUnmanaged(*const Fixture){};
    defer stem_map.deinit();
    for (fixtures) |*f| {
        try stem_map.put(std.heap.page_allocator, f.stem, f);
    }

    // Compute in-degree for each fixture.
    // in_degree = number of refs that are .sym-only (not .sch files)
    var in_degrees = std.AutoHashMap(*const Fixture, u32).init(std.heap.page_allocator);
    defer in_degrees.deinit();

    for (fixtures) |*f| {
        if (f.category != .paired and f.category != .orphan) continue;
        var deg: u32 = 0;
        for (f.refs.items) |ref_stem| {
            if (!stem_map.contains(ref_stem)) {
                // Referenced stem doesn't exist; treat as external dep (in_degree counts it)
                deg += 1;
            } else {
                // Only count if the referenced stem is NOT a .sch (i.e., is a sym-only primitive)
                const ref_fixture = stem_map.get(ref_stem).?;
                if (ref_fixture.category == .primitive) {
                    deg += 1;
                }
            }
        }
        try in_degrees.put(f, deg);
    }

    // Queue of fixtures with in_degree 0.
    var queue = std.ArrayListUnmanaged(*const Fixture){};
    defer queue.deinit();

    var visited = std.AutoHashMap(*const Fixture, void).init(std.heap.page_allocator);
    defer visited.deinit();

    for (fixtures) |*f| {
        if (f.category == .primitive or (in_degrees.get(f) orelse 0) == 0) {
            try queue.append(std.heap.page_allocator, f);
            try visited.put(f, {});
        }
    }

    while (queue.items.len > 0) {
        const node = queue.items[queue.items.len - 1];
        queue.items.len -= 1;
        try result.append(std.heap.page_allocator, @constCast(node));

        // Find all fixtures that depend on this node.
        for (fixtures) |*f| {
            if (f.category != .paired and f.category != .orphan) continue;
            if (visited.contains(f)) continue;
            for (f.refs.items) |ref_stem| {
                if (std.mem.eql(u8, ref_stem, node.stem)) {
                    const new_deg = in_degrees.get(f).? - 1;
                    try in_degrees.put(f, new_deg);
                    if (new_deg == 0) {
                        try queue.append(std.heap.page_allocator, f);
                        try visited.put(f, {});
                    }
                    break;
                }
            }
        }
    }

    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "xschem: roundtrip all fixtures" {
    // skeleton: just print "TODO" for now
    try testing.expect(true);
}

test "xschem: spice comparison" {
    // skeleton: just print "TODO" for now
    try testing.expect(true);
}

test "xschem: scan fixtures" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fixtures = try scanFixtures(alloc, FIXTURE_ROOT);

    // Count categories.
    var primitive_count: u32 = 0;
    var paired_count: u32 = 0;
    var orphan_count: u32 = 0;
    for (fixtures.items) |f| {
        switch (f.category) {
            .primitive => primitive_count += 1,
            .paired => paired_count += 1,
            .orphan => orphan_count += 1,
        }
    }
    std.debug.print("fixtures: primitive={}, paired={}, orphan={}\n", .{
        primitive_count, paired_count, orphan_count,
    });

    // Expect at least some fixtures.
    try testing.expect(fixtures.items.len > 0);
    try testing.expect(paired_count > 0);
}

test "xschem: topological sort" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fixtures = try scanFixtures(alloc, FIXTURE_ROOT);
    const sorted = try topologicalSort(fixtures.items);

    std.debug.print("sorted {} fixtures\n", .{sorted.items.len});
    try testing.expect(sorted.items.len == fixtures.items.len);
}
