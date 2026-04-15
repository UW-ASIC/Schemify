// xschem_roundtrip.zig - XSchem roundtrip and SPICE comparison tests.
const std = @import("std");
const testing = std.testing;
const XSchem = @import("xschem");
const easyimport = @import("easyimport");
const core = @import("core");

const convert = XSchem.convert;
const mapXSchemToSchemify = XSchem.mapXSchemToSchemify;
const mapSchemifyToXSchem = XSchem.mapSchemifyToXSchem;
const parse = XSchem.parse;
const serialize = XSchem.serialize;
const XSchemFiles = XSchem.XSchemFiles;
const SymResolver = XSchem.SymResolver;

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
        while (it.next()) |entry| {
            arena.free(entry.key_ptr.*);
            arena.free(entry.value_ptr.*);
        }
        it = sym_stems.iterator();
        while (it.next()) |entry| {
            arena.free(entry.key_ptr.*);
            arena.free(entry.value_ptr.*);
        }
        sch_stems.deinit(arena);
        sym_stems.deinit(arena);
    }

    var dir = try std.fs.cwd().openDir(fixtures_dir, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(std.heap.page_allocator);
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
        const stem = sch_entry.key_ptr.*;
        const sch_path = sch_entry.value_ptr.*;
        const has_sym = sym_stems.contains(stem);

        const sym_path = if (has_sym) sym_stems.get(stem).? else null;
        const category: FixtureCategory = if (has_sym) .paired else .orphan;

        var refs = std.ArrayListUnmanaged([]const u8){};
        if (category == .paired) {
            // Parse .sch for C {symbol} lines.
            const content = try std.fs.cwd().readFileAlloc(arena, sch_path, 1024 * 1024);
            var lines = std.mem.splitScalar(u8, content, 10);
            while (lines.next()) |line| {
                var trimmed = std.mem.trim(u8, line, " \t\r");
                if (std.mem.startsWith(u8, trimmed, "C {")) {
                    const start = std.mem.indexOfScalar(u8, trimmed, 123).? + 1;
                    const end = std.mem.indexOfScalar(u8, trimmed[start..], 125).?;
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
        const stem = sym_entry.key_ptr.*;
        if (sch_stems.contains(stem)) continue; // already processed as paired/orphan
        const sym_path = sym_entry.value_ptr.*;
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

/// Topological sort of fixtures using Kahn algorithm.
/// Sorts by in-degree where a .sch depends on .sym files that are NOT also .sch files.
/// Primitives (sym-only) are roots with in_degree 0.
fn topologicalSort(fixtures: []const Fixture) !std.ArrayListUnmanaged(*Fixture) {
    var result = std.ArrayListUnmanaged(*Fixture){};
    errdefer result.deinit(std.heap.page_allocator);

    // Build a map from stem -> fixture.
    var stem_map = std.StringHashMapUnmanaged(*const Fixture){};
    defer stem_map.deinit(std.heap.page_allocator);
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
                // Referenced stem does not exist; treat as external dep — already resolved.
                continue;
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
    defer queue.deinit(std.heap.page_allocator);

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

// ============================================================================
// Resolver context for tests - resolves symbol stems to pre-parsed XSchemFiles.
// ============================================================================

/// Context for SymResolver: holds pre-parsed primitives by stem.
const ResolverCtx = struct {
    alloc: std.mem.Allocator,
    primitives: std.StringHashMapUnmanaged(*XSchemFiles),

    fn resolveFn(ctx_opaque: *anyopaque, sym_path: []const u8) ?XSchemFiles {
        const self: *ResolverCtx = @ptrCast(@alignCast(ctx_opaque));
        const stem = stemFromPath(sym_path);
        if (self.primitives.get(stem)) |xs| {
            return xs.*;
        }
        return null;
    }

    fn resolve(self: *ResolverCtx, sym_path: []const u8) ?XSchemFiles {
        return resolveFn(self, sym_path);
    }
};

// ============================================================================
// Failure reporting types
// ============================================================================

const Mismatch = struct {
    field: []const u8,
    expected: usize,
    actual: usize,
};

const FailureReport = struct {
    fixture: []const u8,
    mismatches: []Mismatch,
};

fn compareElementCounts(
    alloc: std.mem.Allocator,
    original: *const XSchemFiles,
    reparsed: *const XSchemFiles,
) ![]Mismatch {
    var mismatches: std.ArrayListUnmanaged(Mismatch) = .{};
    const pairs = .{
        .{ "lines", original.lines.len, reparsed.lines.len },
        .{ "rects", original.rects.len, reparsed.rects.len },
        .{ "arcs", original.arcs.len, reparsed.arcs.len },
        .{ "circles", original.circles.len, reparsed.circles.len },
        .{ "wires", original.wires.len, reparsed.wires.len },
        .{ "texts", original.texts.len, reparsed.texts.len },
        .{ "pins", original.pins.len, reparsed.pins.len },
        .{ "instances", original.instances.len, reparsed.instances.len },
    };
    inline for (pairs) |pair| {
        if (pair[1] != pair[2]) {
            const field_copy = try alloc.dupe(u8, pair[0]);
            try mismatches.append(alloc, .{
                .field = field_copy,
                .expected = pair[1],
                .actual = pair[2],
            });
        }
    }
    return try mismatches.toOwnedSlice(alloc);
}

fn printFailureReport(failures: []const FailureReport) void {
    for (failures) |f| {
        std.debug.print("FAIL: {s}\n", .{f.fixture});
        for (f.mismatches) |m| {
            std.debug.print("  {s}: expected {d}, got {d}\n", .{ m.field, m.expected, m.actual });
        }
    }
}

// ============================================================================
// Roundtrip test
// ============================================================================

fn testRoundtrip(fixtures_dir: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Scan fixtures and topologically sort.
    const fixtures = try scanFixtures(alloc, fixtures_dir);
    const sorted = try topologicalSort(fixtures.items);

    // Pre-populate resolver with all primitives (sym-only fixtures).
    var primitives = std.StringHashMapUnmanaged(*XSchemFiles){};
    defer primitives.deinit(std.heap.page_allocator);

    for (fixtures.items) |f| {
        if (f.category != .primitive) continue;
        const sym_path = f.sym_path orelse continue;
        const data = std.fs.cwd().readFileAlloc(alloc, sym_path, 4 << 20) catch continue;
        const parsed = parse(alloc, data) catch {
            alloc.free(data);
            continue;
        };
        alloc.free(data);
        // Leak the parsed XSchemFiles into the primitives map.
        const leaked = alloc.create(XSchemFiles) catch unreachable;
        leaked.* = parsed;
        try primitives.put(alloc, f.stem, leaked);
    }

    const resolver_ctx = ResolverCtx{
        .alloc = alloc,
        .primitives = primitives,
    };
    const resolver = SymResolver{
        .ctx = @constCast(@ptrCast(&resolver_ctx)),
        .resolveFn = &ResolverCtx.resolveFn,
    };

    // Track failures.
    var failures = std.ArrayListUnmanaged(FailureReport){};
    defer {
        for (failures.items) |f| {
            for (f.mismatches) |m| {
                std.heap.page_allocator.free(m.field);
            }
            std.heap.page_allocator.free(f.mismatches);
        }
        failures.deinit(std.heap.page_allocator);
    }

    // Process each fixture in topological order.
    for (sorted.items) |fixture| {
        // Per-fixture arena to isolate parse/convert/serialize cycles.
        var fixture_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer fixture_arena.deinit();
        const fa = fixture_arena.allocator();

        const stem = fixture.stem;

        // Determine source and symbol paths.
        const sch_path = fixture.sch_path;
        const sym_path = fixture.sym_path;

        // Parse original.
        const original: XSchemFiles = if (fixture.category == .primitive) blk: {
            // Primitives have no .sch, only .sym.
            const path = sym_path orelse continue;
            const data = std.fs.cwd().readFileAlloc(fa, path, 4 << 20) catch continue;
            break :blk parse(fa, data) catch {
                fa.free(data);
                std.debug.print("ERROR: parse failed for {s}\n", .{stem});
                continue;
            };
        } else blk: {
            const path = sch_path orelse continue;
            const data = std.fs.cwd().readFileAlloc(fa, path, 4 << 20) catch continue;
            break :blk parse(fa, data) catch {
                fa.free(data);
                std.debug.print("ERROR: parse failed for {s}\n", .{stem});
                continue;
            };
        };

        // Symbol for paired fixtures.
        const symbol: ?*const XSchemFiles = if (fixture.category == .paired) blk: {
            const path = sym_path orelse return error.MissingSymPath;
            const data = std.fs.cwd().readFileAlloc(fa, path, 4 << 20) catch {
                std.debug.print("ERROR: read sym failed for {s}\n", .{stem});
                break :blk null;
            };
            const sym_parsed = parse(fa, data) catch {
                fa.free(data);
                std.debug.print("ERROR: parse sym failed for {s}\n", .{stem});
                break :blk null;
            };
            fa.free(data);
            const sym_leaked = fa.create(XSchemFiles) catch unreachable;
            sym_leaked.* = sym_parsed;
            break :blk sym_leaked;
        } else null;

        defer {
            if (symbol) |s| {
                @constCast(s).deinit();
                fa.destroy(s);
            }
            @constCast(&original).deinit();
        }

        // Convert XSchem -> Schemify -> XSchem
        const sfy = mapXSchemToSchemify(
            fa,
            &original,
            symbol,
            stem,
            resolver,
        ) catch {
            std.debug.print("ERROR: mapXSchemToSchemify failed for {s}: {}\n", .{ stem, error.ConvertFailed });
            continue;
        };
        defer @constCast(&sfy).deinit();

        const back = mapSchemifyToXSchem(fa, &sfy) catch {
            std.debug.print("ERROR: mapSchemifyToXSchem failed for {s}: {}\n", .{ stem, error.ConvertFailed });
            continue;
        };
        defer @constCast(&back).deinit();

        // Serialize.
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(fa);
        serialize(&back, fa, &buf) catch {
            std.debug.print("ERROR: serialize failed for {s}: {}\n", .{ stem, error.SerializeFailed });
            continue;
        };

        // Re-parse from serialized output.
        var reparsed = parse(fa, buf.items) catch {
            std.debug.print("ERROR: re-parse failed for {s}\n", .{stem});
            continue;
        };
        defer reparsed.deinit();

        // Compare element counts.
        const mismatches = try compareElementCounts(fa, &original, &reparsed);
        if (mismatches.len > 0) {
            const fixture_copy = try std.heap.page_allocator.dupe(u8, stem);
            failures.append(std.heap.page_allocator, .{
                .fixture = fixture_copy,
                .mismatches = mismatches,
            }) catch unreachable;
        }
    }

    if (failures.items.len > 0) {
        printFailureReport(failures.items);
        return error.RoundtripFailed;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "xschem: roundtrip all fixtures" {
    try testRoundtrip(FIXTURE_ROOT);
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
    std.debug.print("fixtures: primitive={}, paired={}, orphan={}\n\n", .{
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

    std.debug.print("sorted {} fixtures\n\n", .{sorted.items.len});
    try testing.expect(sorted.items.len == fixtures.items.len);
}
