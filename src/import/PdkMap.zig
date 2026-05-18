// PdkMap.zig — PDK device mapping: JSON reader + comptime defaults.
//
// Single source of truth for model-name → DeviceKind resolution.
// Plugins and users override by writing a JSON file; import always reads
// from the same path. No merge — file overrides defaults entirely.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("schematic");
const platform = @import("utility").platform;
const DeviceKind = core.types.DeviceKind;

// ── Types ───────────────────────────────────────────────────────────────────

pub const PdkEntry = struct {
    prefix: []const u8,
    kind: DeviceKind,
};

// ── Comptime defaults ───────────────────────────────────────────────────────

/// Fallback table — generic/universal prefixes only.
/// PDK-specific mappings (sky130, GF180, IHP, TSMC, etc.) are loaded
/// at runtime from a project-level JSON file via `loadFromFile`.
pub const pdk_table = [_]PdkEntry{
    .{ .prefix = "nmos", .kind = .nmos4 },
    .{ .prefix = "pmos", .kind = .pmos4 },
    .{ .prefix = "vpnp", .kind = .pnp },
    .{ .prefix = "npn", .kind = .npn },
    .{ .prefix = "pnp", .kind = .pnp },
    .{ .prefix = "diode", .kind = .diode },
    .{ .prefix = "ndio", .kind = .diode },
    .{ .prefix = "pdio", .kind = .diode },
    .{ .prefix = "res", .kind = .resistor },
    .{ .prefix = "cap", .kind = .capacitor },
    .{ .prefix = "mim", .kind = .capacitor },
    .{ .prefix = "ind_", .kind = .inductor },
};

comptime {
    @setEvalBranchQuota(10_000);
    for (&pdk_table, 0..) |a, i| {
        for (pdk_table[i + 1 ..]) |b| {
            if (a.prefix.len == b.prefix.len) {
                for (a.prefix, b.prefix) |ac, bc| {
                    if (ac != bc) break;
                } else {
                    @compileError("duplicate PDK prefix: " ++ a.prefix);
                }
            }
        }
    }
}

// ── Cadence analogLib / GPDK / TSMC exact cell map ──────────────────────────

pub const cell_map = std.StaticStringMap(DeviceKind).initComptime(.{
    .{ "res", .resistor },
    .{ "cap", .capacitor },
    .{ "ind", .inductor },
    .{ "nmos", .nmos3 },
    .{ "pmos", .pmos3 },
    .{ "nmos4", .nmos4 },
    .{ "pmos4", .pmos4 },
    .{ "npn", .npn },
    .{ "npn4", .npn },
    .{ "pnp", .pnp },
    .{ "pnp4", .pnp },
    .{ "njfet", .njfet },
    .{ "pjfet", .pjfet },
    .{ "diode", .diode },
    .{ "mesfet", .mesfet },
    .{ "vdc", .vsource },
    .{ "vsin", .vsource },
    .{ "vpulse", .vsource },
    .{ "vpwl", .vsource },
    .{ "vpwlf", .vsource },
    .{ "vexp", .vsource },
    .{ "vsource", .vsource },
    .{ "vac", .vsource },
    .{ "idc", .isource },
    .{ "isin", .isource },
    .{ "ipulse", .isource },
    .{ "ipwl", .isource },
    .{ "ipwlf", .isource },
    .{ "iexp", .isource },
    .{ "isource", .isource },
    .{ "iac", .isource },
    .{ "vcvs", .vcvs },
    .{ "vccs", .vccs },
    .{ "ccvs", .ccvs },
    .{ "cccs", .cccs },
    .{ "vcvs4", .vcvs },
    .{ "vccs4", .vccs },
    .{ "ccvs4", .ccvs },
    .{ "cccs4", .cccs },
    .{ "pvcvs", .vcvs },
    .{ "pvccs", .vccs },
    .{ "pccvs", .ccvs },
    .{ "pcccs", .cccs },
    .{ "bsource", .behavioral },
    .{ "iprobe", .ammeter },
    .{ "port", .probe },
    .{ "switch", .vswitch },
    .{ "relay", .iswitch },
    .{ "tline", .tline },
    .{ "tline4", .tline },
    .{ "mind", .coupling },
    .{ "mutual_ind", .coupling },
    .{ "ideal_balun", .generic },
    .{ "xfmr", .generic },
    .{ "delay", .generic },
    .{ "gnd", .gnd },
    .{ "vdd", .vdd },
    .{ "noConn", .noconn },
    .{ "noconn", .noconn },
    .{ "iopin", .inout_pin },
    .{ "ipin", .input_pin },
    .{ "opin", .output_pin },
    .{ "nmos1v", .nmos4 },
    .{ "nmos1v_hvt", .nmos4 },
    .{ "nmos1v_lvt", .nmos4 },
    .{ "nmos1v_nat", .nmos4 },
    .{ "nmos2v", .nmos4 },
    .{ "nmos2v_nat", .nmos4 },
    .{ "pmos1v", .pmos4 },
    .{ "pmos1v_hvt", .pmos4 },
    .{ "pmos1v_lvt", .pmos4 },
    .{ "pmos2v", .pmos4 },
    .{ "nch", .nmos4 },
    .{ "pch", .pmos4 },
    .{ "nch_lvt", .nmos4 },
    .{ "pch_lvt", .pmos4 },
    .{ "nch_hvt", .nmos4 },
    .{ "pch_hvt", .pmos4 },
    .{ "nch_svt", .nmos4 },
    .{ "pch_svt", .pmos4 },
    .{ "nch_na", .nmos4 },
    .{ "nch_native", .nmos4 },
    .{ "nch_25", .nmos4 },
    .{ "pch_25", .pmos4 },
    .{ "nch_25_dnw", .nmos4 },
    .{ "nch_mac", .nmos4 },
    .{ "pch_mac", .pmos4 },
    .{ "nch_io", .nmos4 },
    .{ "pch_io", .pmos4 },
});

// ── Public API ──────────────────────────────────────────────────────────────

/// Resolve a model or cell name to a DeviceKind.
/// Checks cell_map exact match, then prefix scan over entries, then .subckt.
pub fn resolveKind(entries: []const PdkEntry, model_or_cell: []const u8) DeviceKind {
    if (cell_map.get(model_or_cell)) |kind| return kind;
    if (matchPdkPrefix(entries, model_or_cell)) |entry| return entry.kind;
    return .subckt;
}

/// Prefix scan over an entry list. Returns the matching entry or null.
pub fn matchPdkPrefix(entries: []const PdkEntry, model_name: []const u8) ?PdkEntry {
    for (entries) |entry| {
        if (model_name.len >= entry.prefix.len and
            std.mem.startsWith(u8, model_name, entry.prefix))
        {
            return entry;
        }
    }
    return null;
}

/// Load PDK entries from a JSON file. The file must contain a JSON array of
/// objects with "prefix" (string) and "kind" (string matching DeviceKind).
/// Caller owns the returned slice.
pub fn loadFromFile(alloc: Allocator, path: []const u8) ![]PdkEntry {
    const content = try platform.fs.cwd().readFileAlloc(alloc, path, 1 << 20);
    defer alloc.free(content);
    return parseJson(alloc, content);
}

pub fn parseJson(alloc: Allocator, content: []const u8) ![]PdkEntry {
    const parsed = std.json.parseFromSlice([]const JsonEntry, alloc, content, .{
        .ignore_unknown_fields = true,
    }) catch return error.MalformedJson;
    defer parsed.deinit();

    var result: std.ArrayListUnmanaged(PdkEntry) = .{};
    errdefer result.deinit(alloc);

    for (parsed.value) |je| {
        const kind = std.meta.stringToEnum(DeviceKind, je.kind) orelse
            return error.UnknownDeviceKind;
        try result.append(alloc, .{
            .prefix = try alloc.dupe(u8, je.prefix),
            .kind = kind,
        });
    }
    return try result.toOwnedSlice(alloc);
}

const JsonEntry = struct {
    prefix: []const u8,
    kind: []const u8,
};

/// Default JSON filename looked up in the project directory.
pub const default_json_name = "pdk_map.json";

/// Load PDK entries from a project directory: tries `pdk_map.json`, then
/// falls back to the comptime `pdk_table`.  JSON entries are prepended
/// (higher priority) before the universal fallback entries.
pub fn loadOrDefault(alloc: Allocator, project_dir: ?[]const u8) []const PdkEntry {
    if (project_dir) |dir| {
        var buf: [1024]u8 = undefined;
        const json_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, default_json_name }) catch
            return &pdk_table;
        if (loadFromFile(alloc, json_path)) |user_entries| {
            // Concat: user entries (checked first) + universal fallback
            var combined: std.ArrayListUnmanaged(PdkEntry) = .{};
            combined.appendSlice(alloc, user_entries) catch return user_entries;
            combined.appendSlice(alloc, &pdk_table) catch return user_entries;
            return combined.toOwnedSlice(alloc) catch user_entries;
        } else |_| {}
    }
    return &pdk_table;
}

// ── Pin translation (Cadence pin names -> Schemify) ─────────────────────────

pub const PinContext = enum {
    mosfet,
    bjt,
    passive,
    controlled_source,
    probe,
    other,
};

pub fn pinContext(kind: DeviceKind) PinContext {
    return switch (kind) {
        .nmos3, .nmos4, .pmos3, .pmos4, .nmos4_depl, .nmos_sub, .pmos_sub,
        .nmoshv4, .pmoshv4, .rnmos4,
        => .mosfet,
        .npn, .pnp => .bjt,
        .resistor, .resistor3, .var_resistor, .capacitor, .inductor,
        .diode, .zener, .vsource, .isource,
        => .passive,
        .vcvs, .vccs, .ccvs, .cccs => .controlled_source,
        .ammeter, .probe, .probe_diff => .probe,
        else => .other,
    };
}

pub fn translatePin(cadence_pin: []const u8, ctx: PinContext) []const u8 {
    if (ctx == .mosfet) {
        if (std.mem.eql(u8, cadence_pin, "D")) return "drain";
        if (std.mem.eql(u8, cadence_pin, "G")) return "gate";
        if (std.mem.eql(u8, cadence_pin, "S")) return "source";
        if (std.mem.eql(u8, cadence_pin, "B")) return "body";
        return cadence_pin;
    }
    if (ctx == .bjt) {
        if (std.mem.eql(u8, cadence_pin, "C")) return "collector";
        if (std.mem.eql(u8, cadence_pin, "B")) return "base";
        if (std.mem.eql(u8, cadence_pin, "E")) return "emitter";
        if (std.mem.eql(u8, cadence_pin, "S")) return "sub";
        return cadence_pin;
    }
    if (ctx == .passive) {
        if (std.mem.eql(u8, cadence_pin, "PLUS")) return "p";
        if (std.mem.eql(u8, cadence_pin, "MINUS")) return "n";
        if (std.mem.eql(u8, cadence_pin, "B")) return "body";
        return cadence_pin;
    }
    if (ctx == .controlled_source) {
        if (std.mem.eql(u8, cadence_pin, "inp")) return "inp";
        if (std.mem.eql(u8, cadence_pin, "inn")) return "inn";
        if (std.mem.eql(u8, cadence_pin, "outp")) return "outp";
        if (std.mem.eql(u8, cadence_pin, "outn")) return "outn";
        return cadence_pin;
    }
    if (ctx == .probe) {
        if (std.mem.eql(u8, cadence_pin, "in")) return "p";
        if (std.mem.eql(u8, cadence_pin, "out")) return "n";
        if (std.mem.eql(u8, cadence_pin, "PLUS")) return "p";
        if (std.mem.eql(u8, cadence_pin, "MINUS")) return "n";
        return cadence_pin;
    }
    if (std.mem.eql(u8, cadence_pin, "PLUS")) return "p";
    if (std.mem.eql(u8, cadence_pin, "MINUS")) return "n";
    return cadence_pin;
}

// ── Cadence global net utilities ────────────────────────────────────────────

pub fn stripGlobalSuffix(net_name: []const u8) ?[]const u8 {
    if (net_name.len > 1 and net_name[net_name.len - 1] == '!') {
        return net_name[0 .. net_name.len - 1];
    }
    return null;
}

pub fn isGlobalNet(net_name: []const u8) bool {
    return net_name.len > 1 and net_name[net_name.len - 1] == '!';
}

// ── Property translation (Cadence -> Schemify) ─────────────────────────────

const preserved_props = std.StaticStringMap([]const u8).initComptime(.{
    .{ "w", "w" },
    .{ "l", "l" },
    .{ "m", "m" },
    .{ "nf", "nf" },
    .{ "model", "model" },
    .{ "area", "area" },
    .{ "pj", "pj" },
});

const renamed_props = std.StaticStringMap([]const u8).initComptime(.{
    .{ "r", "value" },
    .{ "c", "value" },
    .{ "vdc", "dc" },
    .{ "idc", "dc" },
    .{ "egain", "gain" },
    .{ "ggain", "gain" },
    .{ "hgain", "gain" },
    .{ "fgain", "gain" },
});

const stripped_props = std.StaticStringMap(void).initComptime(.{
    .{ "sa", {} },
    .{ "sb", {} },
    .{ "sd", {} },
    .{ "nrd", {} },
    .{ "nrs", {} },
    .{ "topography", {} },
});

pub fn translatePropKey(key: []const u8, kind: DeviceKind) ?[]const u8 {
    if (stripped_props.has(key)) return null;
    if (std.mem.eql(u8, key, "l") and kind == .inductor) return "value";
    if (renamed_props.get(key)) |new_key| return new_key;
    if (preserved_props.has(key)) return key;
    return key;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "resolveKind -- analogLib exact matches" {
    const testing = std.testing;
    try testing.expectEqual(DeviceKind.resistor, resolveKind(&pdk_table, "res"));
    try testing.expectEqual(DeviceKind.capacitor, resolveKind(&pdk_table, "cap"));
    try testing.expectEqual(DeviceKind.nmos4, resolveKind(&pdk_table, "nmos4"));
    try testing.expectEqual(DeviceKind.pmos4, resolveKind(&pdk_table, "pmos4"));
    try testing.expectEqual(DeviceKind.vsource, resolveKind(&pdk_table, "vdc"));
    try testing.expectEqual(DeviceKind.ammeter, resolveKind(&pdk_table, "iprobe"));
    try testing.expectEqual(DeviceKind.gnd, resolveKind(&pdk_table, "gnd"));
    try testing.expectEqual(DeviceKind.noconn, resolveKind(&pdk_table, "noConn"));
    try testing.expectEqual(DeviceKind.behavioral, resolveKind(&pdk_table, "bsource"));
}

test "resolveKind -- universal prefix fallback" {
    try std.testing.expectEqual(DeviceKind.nmos4, resolveKind(&pdk_table, "nmos_3v3"));
    try std.testing.expectEqual(DeviceKind.pmos4, resolveKind(&pdk_table, "pmos_1v8"));
    try std.testing.expectEqual(DeviceKind.npn, resolveKind(&pdk_table, "npn_10x10"));
    try std.testing.expectEqual(DeviceKind.capacitor, resolveKind(&pdk_table, "cap_100f"));
}

test "resolveKind -- unknown falls to .subckt" {
    try std.testing.expectEqual(DeviceKind.subckt, resolveKind(&pdk_table, "my_custom_opamp"));
}

test "resolveKind -- PDK-specific needs JSON (falls to .subckt without it)" {
    try std.testing.expectEqual(DeviceKind.subckt, resolveKind(&pdk_table, "sky130_fd_pr__nfet_01v8"));
    try std.testing.expectEqual(DeviceKind.subckt, resolveKind(&pdk_table, "gf180mcu_fd_pr__nfet_03v3"));
}

test "matchPdkPrefix -- universal nmos" {
    const m = matchPdkPrefix(&pdk_table, "nmos") orelse unreachable;
    try std.testing.expectEqual(DeviceKind.nmos4, m.kind);
}

test "matchPdkPrefix -- no match" {
    try std.testing.expect(matchPdkPrefix(&pdk_table, "generic_xyz") == null);
}

test "parseJson -- loaded entries resolve PDK names" {
    const json =
        \\[{"prefix":"sky130_fd_pr__nfet","kind":"nmos4"},{"prefix":"sky130_fd_pr__pfet","kind":"pmos4"}]
    ;
    const entries = try parseJson(std.testing.allocator, json);
    defer {
        for (entries) |e| std.testing.allocator.free(e.prefix);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(DeviceKind.nmos4, resolveKind(entries, "sky130_fd_pr__nfet_01v8"));
    try std.testing.expectEqual(DeviceKind.pmos4, resolveKind(entries, "sky130_fd_pr__pfet_01v8"));
}

test "parseJson -- valid entries" {
    const json =
        \\[{"prefix":"my_nfet","kind":"nmos4"},{"prefix":"my_pfet","kind":"pmos4"}]
    ;
    const entries = try parseJson(std.testing.allocator, json);
    defer {
        for (entries) |e| std.testing.allocator.free(e.prefix);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("my_nfet", entries[0].prefix);
    try std.testing.expectEqual(DeviceKind.nmos4, entries[0].kind);
}

test "parseJson -- unknown kind produces error" {
    const json =
        \\[{"prefix":"foo","kind":"nonexistent_kind"}]
    ;
    const result = parseJson(std.testing.allocator, json);
    try std.testing.expectError(error.UnknownDeviceKind, result);
}

test "parseJson -- malformed JSON produces error" {
    const result = parseJson(std.testing.allocator, "not json at all");
    try std.testing.expectError(error.MalformedJson, result);
}

test "translatePin -- MOSFET context" {
    try std.testing.expectEqualStrings("drain", translatePin("D", .mosfet));
    try std.testing.expectEqualStrings("gate", translatePin("G", .mosfet));
    try std.testing.expectEqualStrings("source", translatePin("S", .mosfet));
    try std.testing.expectEqualStrings("body", translatePin("B", .mosfet));
}

test "translatePin -- BJT context" {
    try std.testing.expectEqualStrings("collector", translatePin("C", .bjt));
    try std.testing.expectEqualStrings("base", translatePin("B", .bjt));
    try std.testing.expectEqualStrings("emitter", translatePin("E", .bjt));
}

test "stripGlobalSuffix" {
    try std.testing.expectEqualStrings("VDD", stripGlobalSuffix("VDD!").?);
    try std.testing.expect(stripGlobalSuffix("normal_net") == null);
}

test "translatePropKey -- preserved" {
    try std.testing.expectEqualStrings("w", translatePropKey("w", .nmos4).?);
    try std.testing.expectEqualStrings("nf", translatePropKey("nf", .pmos4).?);
}

test "translatePropKey -- renamed" {
    try std.testing.expectEqualStrings("value", translatePropKey("r", .resistor).?);
    try std.testing.expectEqualStrings("dc", translatePropKey("vdc", .vsource).?);
}

test "translatePropKey -- stripped" {
    try std.testing.expect(translatePropKey("sa", .nmos4) == null);
    try std.testing.expect(translatePropKey("topography", .nmos4) == null);
}

test "pinContext" {
    try std.testing.expectEqual(PinContext.mosfet, pinContext(.nmos4));
    try std.testing.expectEqual(PinContext.bjt, pinContext(.npn));
    try std.testing.expectEqual(PinContext.passive, pinContext(.resistor));
    try std.testing.expectEqual(PinContext.other, pinContext(.subckt));
}
