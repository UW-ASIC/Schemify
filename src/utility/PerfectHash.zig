const std = @import("std");

fn hash(seed: u64, key: []const u8) u64 {
    return std.hash.Wyhash.hash(seed, key);
}

fn strEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// gperf-style comptime perfect hash for small key sets (<100 keys).
/// Brute-force searches for a collision-free seed. Runtime: 1 hash + key verify.
pub fn PerfectHash(comptime V: type, comptime entries: anytype) type {
    const n = entries.len;
    return struct {
        const seed: u64 = findSeed();
        const keys: [n][]const u8 = extractKeys();
        const vals: [n]V = buildTable();

        pub fn get(key: []const u8) ?V {
            const idx = hash(seed, key) % n;
            if (strEql(keys[idx], key)) return vals[idx];
            return null;
        }

        fn findSeed() u64 {
            @setEvalBranchQuota(200_000);
            var s: u64 = 0;
            while (s < 200_000) : (s += 1) {
                var used: [n]bool = .{false} ** n;
                var ok = true;
                for (entries) |e| {
                    const idx = hash(s, e[0]) % n;
                    if (used[idx]) { ok = false; break; }
                    used[idx] = true;
                }
                if (ok) return s;
            }
            @compileError("PerfectHash: could not find collision-free seed");
        }

        fn extractKeys() [n][]const u8 {
            var k: [n][]const u8 = undefined;
            for (entries) |e| {
                k[hash(seed, e[0]) % n] = e[0];
            }
            return k;
        }

        fn buildTable() [n]V {
            var t: [n]V = undefined;
            for (entries) |e| {
                t[hash(seed, e[0]) % n] = e[1];
            }
            return t;
        }
    };
}

/// CHD (Compress, Hash, Displace) comptime perfect hash for larger key sets.
/// Two-level scheme: bucket distribution + per-bucket displacement.
/// Runtime: 2 hashes + displacement lookup + key verify.
pub fn ChdHash(comptime V: type, comptime entries: anytype) type {
    const n = entries.len;
    const num_buckets = if (n / 4 > 0) n / 4 else 1;
    const seed1: u64 = 0x517cc1b727220a95;
    const seed2: u64 = 0x6c62272e07bb0142;

    return struct {
        const displacements: [num_buckets]u32 = buildDisplacements();
        const keys: [n][]const u8 = buildKeys();
        const vals: [n]V = buildVals();

        pub fn get(key: []const u8) ?V {
            const bucket = hash(seed1, key) % num_buckets;
            const idx = (hash(seed2, key) +% displacements[bucket]) % n;
            if (strEql(keys[idx], key)) return vals[idx];
            return null;
        }

        fn buildDisplacements() [num_buckets]u32 {
            @setEvalBranchQuota(1_000_000);

            // Assign keys to buckets.
            var buckets: [num_buckets][n]u32 = undefined;
            var bucket_lens: [num_buckets]u32 = .{0} ** num_buckets;
            for (0..n) |i| {
                const b = hash(seed1, entries[i][0]) % num_buckets;
                buckets[b][bucket_lens[b]] = @intCast(i);
                bucket_lens[b] += 1;
            }

            // Sort buckets by decreasing size for greedy placement.
            var order: [num_buckets]u32 = undefined;
            for (0..num_buckets) |i| order[i] = @intCast(i);
            // Simple insertion sort (comptime-safe).
            for (1..num_buckets) |i| {
                const key_i = order[i];
                var j: usize = i;
                while (j > 0 and bucket_lens[order[j - 1]] < bucket_lens[key_i]) : (j -= 1) {
                    order[j] = order[j - 1];
                }
                order[j] = key_i;
            }

            var placed: [n]bool = .{false} ** n;
            var disps: [num_buckets]u32 = .{0} ** num_buckets;

            for (order) |bi| {
                const blen = bucket_lens[bi];
                if (blen == 0) continue;

                var d: u32 = 0;
                disp_search: while (d < n * 10) : (d += 1) {
                    var trial_slots: [n]u32 = undefined;
                    var ok = true;
                    for (0..blen) |ki| {
                        const entry_idx = buckets[bi][ki];
                        const slot = @as(u32, @intCast(
                            (hash(seed2, entries[entry_idx][0]) +% d) % n,
                        ));
                        if (placed[slot]) { ok = false; break; }
                        // Check within-bucket collision.
                        for (0..ki) |prev| {
                            if (trial_slots[prev] == slot) { ok = false; break; }
                        }
                        if (!ok) break;
                        trial_slots[ki] = slot;
                    }
                    if (ok) {
                        // Place all keys in this bucket.
                        for (0..blen) |ki| {
                            placed[trial_slots[ki]] = true;
                        }
                        disps[bi] = d;
                        break :disp_search;
                    }
                }
            }
            return disps;
        }

        fn buildKeys() [n][]const u8 {
            const disps = buildDisplacements();
            var k: [n][]const u8 = .{""} ** n;
            for (entries) |e| {
                const bucket = hash(seed1, e[0]) % num_buckets;
                const idx = (hash(seed2, e[0]) +% disps[bucket]) % n;
                k[idx] = e[0];
            }
            return k;
        }

        fn buildVals() [n]V {
            const disps = buildDisplacements();
            var v: [n]V = undefined;
            for (entries) |e| {
                const bucket = hash(seed1, e[0]) % num_buckets;
                const idx = (hash(seed2, e[0]) +% disps[bucket]) % n;
                v[idx] = e[1];
            }
            return v;
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "PerfectHash: small key set returns correct values" {
    const Map = PerfectHash(u32, .{
        .{ "alpha", 1 },
        .{ "bravo", 2 },
        .{ "charlie", 3 },
        .{ "delta", 4 },
        .{ "echo", 5 },
    });
    try testing.expectEqual(@as(?u32, 1), Map.get("alpha"));
    try testing.expectEqual(@as(?u32, 2), Map.get("bravo"));
    try testing.expectEqual(@as(?u32, 3), Map.get("charlie"));
    try testing.expectEqual(@as(?u32, 4), Map.get("delta"));
    try testing.expectEqual(@as(?u32, 5), Map.get("echo"));
}

test "PerfectHash: unknown key returns null" {
    const Map = PerfectHash(u32, .{
        .{ "alpha", 1 },
        .{ "bravo", 2 },
        .{ "charlie", 3 },
        .{ "delta", 4 },
        .{ "echo", 5 },
    });
    try testing.expectEqual(@as(?u32, null), Map.get("foxtrot"));
    try testing.expectEqual(@as(?u32, null), Map.get(""));
    try testing.expectEqual(@as(?u32, null), Map.get("alph"));
}

test "PerfectHash: all entries have unique slots" {
    const Map = PerfectHash(u32, .{
        .{ "one", 1 },
        .{ "two", 2 },
        .{ "three", 3 },
        .{ "four", 4 },
        .{ "five", 5 },
    });
    try testing.expectEqual(@as(?u32, 1), Map.get("one"));
    try testing.expectEqual(@as(?u32, 2), Map.get("two"));
    try testing.expectEqual(@as(?u32, 3), Map.get("three"));
    try testing.expectEqual(@as(?u32, 4), Map.get("four"));
    try testing.expectEqual(@as(?u32, 5), Map.get("five"));
}

const chd_test_entries = .{
    .{ "struct", 1 },   .{ "enum", 2 },     .{ "union", 3 },
    .{ "fn", 4 },       .{ "return", 5 },    .{ "if", 6 },
    .{ "else", 7 },     .{ "while", 8 },     .{ "for", 9 },
    .{ "switch", 10 },  .{ "break", 11 },    .{ "continue", 12 },
    .{ "const", 13 },   .{ "var", 14 },      .{ "pub", 15 },
    .{ "extern", 16 },  .{ "export", 17 },   .{ "inline", 18 },
    .{ "comptime", 19 },.{ "defer", 20 },    .{ "errdefer", 21 },
    .{ "test", 22 },    .{ "catch", 23 },    .{ "try", 24 },
    .{ "orelse", 25 },  .{ "unreachable", 26 }, .{ "undefined", 27 },
    .{ "null", 28 },    .{ "true", 29 },     .{ "false", 30 },
    .{ "error", 31 },   .{ "anytype", 32 },  .{ "type", 33 },
    .{ "void", 34 },    .{ "bool", 35 },     .{ "u8", 36 },
    .{ "u16", 37 },     .{ "u32", 38 },      .{ "u64", 39 },
    .{ "i8", 40 },      .{ "i16", 41 },      .{ "i32", 42 },
    .{ "i64", 43 },     .{ "f16", 44 },      .{ "f32", 45 },
    .{ "f64", 46 },     .{ "usize", 47 },    .{ "isize", 48 },
    .{ "align", 49 },   .{ "nosuspend", 50 }, .{ "noalias", 51 },
};

test "ChdHash: larger key set returns correct values" {
    const Map = ChdHash(u8, chd_test_entries);
    try testing.expectEqual(@as(?u8, 1), Map.get("struct"));
    try testing.expectEqual(@as(?u8, 24), Map.get("try"));
    try testing.expectEqual(@as(?u8, 51), Map.get("noalias"));
    try testing.expectEqual(@as(?u8, 33), Map.get("type"));
}

test "ChdHash: unknown key returns null" {
    const Map = ChdHash(u8, chd_test_entries);
    try testing.expectEqual(@as(?u8, null), Map.get("class"));
    try testing.expectEqual(@as(?u8, null), Map.get(""));
    try testing.expectEqual(@as(?u8, null), Map.get("int"));
}
