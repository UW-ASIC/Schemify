// mod.zig — Public API for the SPICE netlist import backend.
//
// Provides the Backend struct conforming to the EasyImport interface contract,
// and the full parse -> layout -> route -> convert pipeline for transforming
// raw SPICE netlist text into Schemify schematic data.
//
// Usage:
//   const spice = @import("spice2schematic/mod.zig");
//   const netlist = try spice.parseNetlist(arena, source_text);
//   const results = try spice.convert(arena, netlist);
//
// Or via the Backend interface:
//   const backend = spice.Backend.init(alloc);
//   const results = try backend.convertProject(project_dir);

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const core = @import("schematic");

pub const parser = @import("parser.zig");
pub const layout = @import("layout.zig");
pub const router = @import("router.zig");
pub const pdk_map = @import("pdk_map.zig");

// Re-exports
pub const Netlist = parser.Netlist;
pub const Element = parser.Element;
pub const Param = parser.Param;
pub const Model = parser.Model;
pub const Subckt = parser.Subckt;
pub const PlacedElement = layout.PlacedElement;
pub const RouteWire = router.RouteWire;
pub const RouteResult = router.RouteResult;
pub const PowerKind = router.PowerKind;
pub const PowerSym = router.PowerSym;

const ct = @import("../types.zig");
pub const ConvertResult = ct.ConvertResult;
pub const ConvertResultList = ct.ConvertResultList;

const DeviceKind = core.types.DeviceKind;
const Instance = core.types.Instance;
const Wire = core.types.Wire;
const Pin = core.types.Pin;
const Property = core.types.Property;
const Conn = core.types.Conn;
const SchematicType = core.types.SchematicType;
const InstanceFlags = core.types.InstanceFlags;
const Schemify = core.Schemify;

// ── Backend struct (EasyImport interface) ───────────────────────────────────

pub const Backend = struct {
    alloc: Allocator,

    pub fn init(alloc: Allocator) Backend {
        return .{ .alloc = alloc };
    }

    pub fn deinit(_: *Backend) void {}

    pub fn label(_: *const Backend) []const u8 {
        return "SPICE Netlist";
    }

    /// Detect whether `project_dir` contains SPICE netlist files.
    pub fn detectProjectRoot(self: *const Backend, project_dir: []const u8) bool {
        const extensions = [_][]const u8{ ".spice", ".sp", ".cir", ".net", ".cdl" };
        for (&extensions) |ext| {
            if (self.hasFileWithExt(project_dir, ext)) return true;
        }
        return false;
    }

    /// Convert all SPICE netlist files in a project directory to Schemify format.
    pub fn convertProject(
        self: *const Backend,
        project_dir: []const u8,
    ) !ConvertResultList {
        var list_arena = std.heap.ArenaAllocator.init(self.alloc);
        errdefer list_arena.deinit();
        const la = list_arena.allocator();

        const spice_files = try self.findSpiceFiles(la, project_dir);
        if (spice_files.len == 0) return error.NoSpiceFiles;

        var results: List(ConvertResult) = .{};

        for (spice_files) |file_path| {
            const full_path = try std.fs.path.join(la, &.{ project_dir, file_path });
            const source = std.fs.cwd().readFileAlloc(la, full_path, 1 << 24) catch continue;

            const netlist = parser.parseNetlist(la, source) catch continue;
            const converted = convertNetlist(la, netlist, file_path) catch continue;

            for (converted) |result| {
                try results.append(la, result);
            }
        }

        return .{
            .results = try la.dupe(ConvertResult, results.items),
            .arena = list_arena,
        };
    }

    /// Stub for getFiles — SPICE import doesn't pair sch/sym files.
    pub fn getFiles(
        _: *const Backend,
        _: []const u8,
    ) !void {
        return error.BackendNotImplemented;
    }

    fn hasFileWithExt(_: *const Backend, dir: []const u8, ext: []const u8) bool {
        var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return false;
        defer d.close();
        var it = d.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.endsWith(u8, entry.name, ext)) return true;
        }
        return false;
    }

    fn findSpiceFiles(_: *const Backend, arena: Allocator, dir: []const u8) ![]const []const u8 {
        const extensions = [_][]const u8{ ".spice", ".sp", ".cir", ".net", ".cdl" };
        var files: List([]const u8) = .{};

        var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return &.{};
        defer d.close();
        var it = d.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            for (&extensions) |ext| {
                if (std.mem.endsWith(u8, entry.name, ext)) {
                    try files.append(arena, try arena.dupe(u8, entry.name));
                    break;
                }
            }
        }

        return files.items;
    }
};

// ── Public conversion API ───────────────────────────────────────────────────

/// Parse a SPICE netlist source string into structured Netlist data.
pub const parseNetlist = parser.parseNetlist;

/// Full pipeline: parse -> layout -> route -> build Schemify structs.
/// Returns one ConvertResult per .subckt, plus one for top-level elements.
pub fn convertNetlist(
    alloc: Allocator,
    netlist: Netlist,
    source_path: []const u8,
) ![]const ConvertResult {
    var results: List(ConvertResult) = .{};

    // Convert each .subckt to a component schematic
    for (netlist.subckts) |subckt| {
        var tmp_arena = std.heap.ArenaAllocator.init(alloc);
        defer tmp_arena.deinit();
        const tmp = tmp_arena.allocator();

        const placed = try layout.place(tmp, subckt.elements, netlist.models);
        const route_result = try router.route(tmp, subckt.elements, placed);
        const sch = try buildComponent(alloc, netlist, subckt, placed, route_result);

        try results.append(alloc, .{
            .name = try alloc.dupe(u8, subckt.name),
            .sch_path = null,
            .sym_path = null,
            .schemify = sch,
        });
    }

    // Convert top-level elements to testbench if present
    if (netlist.top_elements.len > 0) {
        var tmp_arena = std.heap.ArenaAllocator.init(alloc);
        defer tmp_arena.deinit();
        const tmp = tmp_arena.allocator();

        const placed = try layout.place(tmp, netlist.top_elements, netlist.models);
        const route_result = try router.route(tmp, netlist.top_elements, placed);
        const sch = try buildTestbench(alloc, netlist, placed, route_result, source_path);

        const tb_name = if (netlist.title.len > 0)
            try alloc.dupe(u8, sanitizeName(netlist.title))
        else
            try alloc.dupe(u8, "testbench");

        try results.append(alloc, .{
            .name = tb_name,
            .sch_path = null,
            .sym_path = null,
            .schemify = sch,
        });
    }

    return results.items;
}

/// Convenience: parse and convert in one call.
pub fn importSpice(
    alloc: Allocator,
    source: []const u8,
    source_path: []const u8,
) ![]const ConvertResult {
    var parse_arena = std.heap.ArenaAllocator.init(alloc);
    defer parse_arena.deinit();
    const pa = parse_arena.allocator();

    const netlist = try parser.parseNetlist(pa, source);
    return convertNetlist(alloc, netlist, source_path);
}

// ── Schemify construction ───────────────────────────────────────────────────

fn buildComponent(
    alloc: Allocator,
    netlist: Netlist,
    subckt: Subckt,
    placed: []const PlacedElement,
    route_result: RouteResult,
) !Schemify {
    var sch = Schemify{};
    sch.name = try alloc.dupe(u8, subckt.name);
    sch.stype = .schematic;

    // Add pins from subcircuit ports
    const n_ports = subckt.ports.len;
    for (subckt.ports, 0..) |port, i| {
        const pin_x: i32 = if (i < n_ports / 2 + n_ports % 2) -40 else 40;
        const pin_y: i32 = -@as(i32, @intCast(i)) * 40;
        try sch.pins.append(alloc, .{
            .name = try alloc.dupe(u8, port),
            .x = pin_x,
            .y = pin_y,
            .dir = .inout,
        });
    }

    try populateInstances(alloc, &sch, subckt.elements, placed, netlist.models);
    try populateWires(alloc, &sch, route_result);
    try populatePower(alloc, &sch, route_result.power);

    for (netlist.globals) |g| {
        try sch.globals.append(alloc, try alloc.dupe(u8, g));
    }

    try sch.sym_props.append(alloc, .{
        .key = try alloc.dupe(u8, "type"),
        .val = try alloc.dupe(u8, "subcircuit"),
    });
    try sch.sym_props.append(alloc, .{
        .key = try alloc.dupe(u8, "format"),
        .val = try buildFormatStr(alloc, subckt),
    });

    return sch;
}

fn buildTestbench(
    alloc: Allocator,
    netlist: Netlist,
    placed: []const PlacedElement,
    route_result: RouteResult,
    source_path: []const u8,
) !Schemify {
    var sch = Schemify{};
    const title = if (netlist.title.len > 0) netlist.title else "testbench";
    sch.name = try alloc.dupe(u8, title);
    sch.stype = .testbench;

    try populateInstances(alloc, &sch, netlist.top_elements, placed, netlist.models);
    try populateWires(alloc, &sch, route_result);
    try populatePower(alloc, &sch, route_result.power);

    for (netlist.globals) |g| {
        try sch.globals.append(alloc, try alloc.dupe(u8, g));
    }

    if (source_path.len > 0) {
        try sch.sym_props.append(alloc, .{
            .key = try alloc.dupe(u8, "source"),
            .val = try alloc.dupe(u8, source_path),
        });
    }

    return sch;
}

fn populateInstances(
    alloc: Allocator,
    sch: *Schemify,
    elements: []const Element,
    placed: []const PlacedElement,
    models: []const Model,
) !void {
    _ = models;
    for (placed) |p| {
        if (p.elem_idx >= elements.len) continue;
        const elem = elements[p.elem_idx];

        // Build properties
        const prop_start: u32 = @intCast(sch.props.items.len);
        try appendElementProps(alloc, sch, elem);
        const prop_count: u16 = @intCast(sch.props.items.len - prop_start);

        // Build connections
        const conn_start: u32 = @intCast(sch.conns.items.len);
        try appendElementConns(alloc, sch, elem, p.kind);
        const conn_count: u16 = @intCast(sch.conns.items.len - conn_start);

        // Spice line for controlled sources
        const spice_line: ?[]const u8 = if (elem.prefix == 'e' or elem.prefix == 'g' or
            elem.prefix == 'f' or elem.prefix == 'h' or elem.prefix == 'b')
        blk: {
            break :blk if (elem.value) |v| try alloc.dupe(u8, v) else null;
        } else null;

        try sch.instances.append(alloc, .{
            .name = try alloc.dupe(u8, elem.name),
            .symbol = try alloc.dupe(u8, p.symbol),
            .spice_line = spice_line,
            .prop_start = prop_start,
            .prop_count = prop_count,
            .conn_start = conn_start,
            .conn_count = conn_count,
            .x = p.x,
            .y = p.y,
            .kind = p.kind,
            .flags = .{},
        });
    }
}

fn populateWires(alloc: Allocator, sch: *Schemify, route_result: RouteResult) !void {
    for (route_result.wires) |w| {
        try sch.wires.append(alloc, .{
            .x0 = w.x0,
            .y0 = w.y0,
            .x1 = w.x1,
            .y1 = w.y1,
            .net_name = try alloc.dupe(u8, w.net_name),
        });
    }
}

fn populatePower(alloc: Allocator, sch: *Schemify, power_syms: []const PowerSym) !void {
    for (power_syms, 0..) |ps, i| {
        const kind: DeviceKind = switch (ps.kind) {
            .vdd => .vdd,
            .gnd => .gnd,
        };
        const sym_name: []const u8 = switch (ps.kind) {
            .vdd => "vdd",
            .gnd => "gnd",
        };

        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}{d}", .{ sym_name, i }) catch "pwr";

        try sch.instances.append(alloc, .{
            .name = try alloc.dupe(u8, name),
            .symbol = try alloc.dupe(u8, sym_name),
            .x = ps.x,
            .y = ps.y,
            .kind = kind,
            .flags = .{},
        });
    }
}

// ── Property / connection builders ──────────────────────────────────────────

fn appendElementProps(alloc: Allocator, sch: *Schemify, elem: Element) !void {
    switch (elem.prefix) {
        'r', 'c' => {
            if (elem.value) |v| {
                try sch.props.append(alloc, .{
                    .key = try alloc.dupe(u8, "value"),
                    .val = try alloc.dupe(u8, v),
                });
            }
            const device = if (elem.prefix == 'r') "resistor" else "capacitor";
            try sch.props.append(alloc, .{
                .key = try alloc.dupe(u8, "device"),
                .val = try alloc.dupe(u8, device),
            });
            for (elem.params) |p| {
                try sch.props.append(alloc, .{
                    .key = try alloc.dupe(u8, p.key),
                    .val = try alloc.dupe(u8, p.val),
                });
            }
        },
        'l' => {
            if (elem.value) |v| {
                try sch.props.append(alloc, .{
                    .key = try alloc.dupe(u8, "value"),
                    .val = try alloc.dupe(u8, v),
                });
            }
            for (elem.params) |p| {
                try sch.props.append(alloc, .{
                    .key = try alloc.dupe(u8, p.key),
                    .val = try alloc.dupe(u8, p.val),
                });
            }
        },
        'd' => {
            if (elem.model) |m| {
                try sch.props.append(alloc, .{
                    .key = try alloc.dupe(u8, "model"),
                    .val = try alloc.dupe(u8, m),
                });
            }
            for (elem.params) |p| {
                try sch.props.append(alloc, .{
                    .key = try alloc.dupe(u8, p.key),
                    .val = try alloc.dupe(u8, p.val),
                });
            }
        },
        'm' => {
            if (elem.model) |m| {
                try sch.props.append(alloc, .{
                    .key = try alloc.dupe(u8, "model"),
                    .val = try alloc.dupe(u8, m),
                });
            }
            var has_m = false;
            for (elem.params) |p| {
                var key_buf: [16]u8 = undefined;
                const lo_key = toLowerBuf(p.key, &key_buf) orelse p.key;
                const canon_key = canonMosfetKey(lo_key) orelse continue;
                try sch.props.append(alloc, .{
                    .key = try alloc.dupe(u8, canon_key),
                    .val = try alloc.dupe(u8, p.val),
                });
                if (std.mem.eql(u8, lo_key, "m")) has_m = true;
            }
            if (!has_m) {
                try sch.props.append(alloc, .{
                    .key = try alloc.dupe(u8, "M"),
                    .val = try alloc.dupe(u8, "1"),
                });
            }
        },
        'q', 'j' => {
            if (elem.model) |m| {
                try sch.props.append(alloc, .{
                    .key = try alloc.dupe(u8, "model"),
                    .val = try alloc.dupe(u8, m),
                });
            }
            for (elem.params) |p| {
                try sch.props.append(alloc, .{
                    .key = try alloc.dupe(u8, p.key),
                    .val = try alloc.dupe(u8, p.val),
                });
            }
        },
        'v', 'i' => {
            if (elem.value) |v| {
                try sch.props.append(alloc, .{
                    .key = try alloc.dupe(u8, "value"),
                    .val = try alloc.dupe(u8, v),
                });
            }
        },
        'x' => {
            for (elem.params) |p| {
                try sch.props.append(alloc, .{
                    .key = try alloc.dupe(u8, p.key),
                    .val = try alloc.dupe(u8, p.val),
                });
            }
        },
        else => {
            if (elem.value) |v| {
                try sch.props.append(alloc, .{
                    .key = try alloc.dupe(u8, "value"),
                    .val = try alloc.dupe(u8, v),
                });
            }
            for (elem.params) |p| {
                try sch.props.append(alloc, .{
                    .key = try alloc.dupe(u8, p.key),
                    .val = try alloc.dupe(u8, p.val),
                });
            }
        },
    }
}

fn appendElementConns(alloc: Allocator, sch: *Schemify, elem: Element, kind: DeviceKind) !void {
    const pin_names = pinNamesForKind(kind);
    const count = @min(elem.nodes.len, pin_names.len);
    for (0..count) |i| {
        try sch.conns.append(alloc, .{
            .pin = try alloc.dupe(u8, pin_names[i]),
            .net = try alloc.dupe(u8, elem.nodes[i]),
        });
    }
    // Extra nodes beyond named pins get numbered
    if (elem.nodes.len > pin_names.len) {
        for (pin_names.len..elem.nodes.len) |i| {
            var buf: [8]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, "p{d}", .{i}) catch "p";
            try sch.conns.append(alloc, .{
                .pin = try alloc.dupe(u8, name),
                .net = try alloc.dupe(u8, elem.nodes[i]),
            });
        }
    }
}

fn pinNamesForKind(kind: DeviceKind) []const []const u8 {
    const two_term: []const []const u8 = &.{ "p", "n" };
    const mos4: []const []const u8 = &.{ "d", "g", "s", "b" };
    const bjt4: []const []const u8 = &.{ "c", "b", "e", "s" };
    const jfet3: []const []const u8 = &.{ "d", "g", "s" };
    const ctrl4: []const []const u8 = &.{ "p", "n", "cp", "cn" };

    return switch (kind) {
        .nmos4, .pmos4 => mos4,
        .npn, .pnp => bjt4,
        .njfet, .pjfet => jfet3,
        .vcvs, .vccs => ctrl4,
        .ccvs, .cccs => two_term,
        else => two_term,
    };
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn canonMosfetKey(lo_key: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, lo_key, "w")) return "W";
    if (std.mem.eql(u8, lo_key, "l")) return "L";
    if (std.mem.eql(u8, lo_key, "m")) return "M";
    if (std.mem.eql(u8, lo_key, "nf")) return "nf";
    if (std.mem.eql(u8, lo_key, "ad")) return "ad";
    if (std.mem.eql(u8, lo_key, "as")) return "as";
    return null;
}

fn buildFormatStr(alloc: Allocator, subckt: Subckt) ![]const u8 {
    var parts: List(u8) = .{};
    try parts.appendSlice(alloc, "@name @pinlist @symname");
    for (subckt.params) |p| {
        try parts.append(alloc, ' ');
        try parts.appendSlice(alloc, p.key);
        try parts.appendSlice(alloc, "=@");
        try parts.appendSlice(alloc, p.key);
    }
    return parts.items;
}

fn sanitizeName(name: []const u8) []const u8 {
    if (name.len == 0) return "netlist";
    var iter = std.mem.tokenizeAny(u8, name, " \t");
    return iter.next() orelse "netlist";
}

fn toLowerBuf(s: []const u8, buf: []u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return buf[0..s.len];
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "Backend label" {
    const b = Backend.init(std.testing.allocator);
    try std.testing.expectEqualStrings("SPICE Netlist", b.label());
}

test "importSpice — simple inverter" {
    const source =
        \\* Inverter Test
        \\.subckt inv in out vdd vss
        \\M1 out in vdd vdd sky130_fd_pr__pfet_01v8 W=1u L=0.18u
        \\M2 out in vss vss sky130_fd_pr__nfet_01v8 W=0.5u L=0.18u
        \\.ends inv
        \\V1 vdd 0 1.8
        \\.end
    ;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const netlist = try parser.parseNetlist(arena, source);
    try std.testing.expectEqual(@as(usize, 1), netlist.subckts.len);
    try std.testing.expectEqual(@as(usize, 1), netlist.top_elements.len);

    const sc = netlist.subckts[0];
    try std.testing.expectEqualStrings("inv", sc.name);
    try std.testing.expectEqual(@as(usize, 2), sc.elements.len);
}

test "convertNetlist — produces Schemify output" {
    const source =
        \\* OTA
        \\.subckt ota inp inn out vdd vss
        \\M1 net1 inp net3 vss sky130_fd_pr__nfet_01v8 W=2u L=0.5u
        \\M2 out inn net3 vss sky130_fd_pr__nfet_01v8 W=2u L=0.5u
        \\M3 net1 net1 vdd vdd sky130_fd_pr__pfet_01v8 W=4u L=0.5u
        \\M4 out net1 vdd vdd sky130_fd_pr__pfet_01v8 W=4u L=0.5u
        \\M5 net3 vbias vss vss sky130_fd_pr__nfet_01v8 W=4u L=1u
        \\.ends ota
        \\.end
    ;

    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    const pa = parse_arena.allocator();

    const netlist = try parser.parseNetlist(pa, source);
    const results = try convertNetlist(pa, netlist, "test.sp");

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("ota", results[0].name);
    // 5 MOSFETs + power symbols (VDD/GND at each supply connection)
    try std.testing.expect(results[0].schemify.instances.len >= 5);
    try std.testing.expectEqual(@as(usize, 5), results[0].schemify.pins.len);
}

test "sanitizeName" {
    try std.testing.expectEqualStrings("OTA", sanitizeName("OTA Testbench"));
    try std.testing.expectEqualStrings("netlist", sanitizeName(""));
}

// Force-reference sub-modules for test discovery
comptime {
    _ = parser;
    _ = layout;
    _ = router;
    _ = pdk_map;
}
