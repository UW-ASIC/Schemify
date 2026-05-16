// mod.zig — Public API for the SPICE netlist import backend.
//
// Pipeline:
//   parse → resolveKinds → Layout.place → Router.route → LabelPlacer.placeLabels → build
//
// Usage:
//   const spice = @import("spice/mod.zig");
//   const netlist = try spice.parseNetlist(arena, source_text);
//   const results = try spice.convert(arena, netlist);

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const core = @import("schematic");
const platform = @import("utility").platform;

pub const parser = @import("parser.zig");

const Layout = core.layout;
const Router = @import("../Router.zig");
const LabelPlacer = @import("../LabelPlacer.zig");
const conventions = @import("../conventions.zig");

// Re-exports
pub const Netlist = parser.Netlist;
pub const Element = parser.Element;
pub const Param = parser.Param;
pub const Model = parser.Model;
pub const Subckt = parser.Subckt;
pub const Include = parser.Include;
pub const PlacedDevice = Layout.PlacedDevice;
pub const RouteWire = Router.RouteWire;
pub const RouteResult = Router.RouteResult;
pub const PowerKind = Router.PowerKind;
pub const PowerSym = Router.PowerSym;
pub const LabelOffset = LabelPlacer.LabelOffset;

const ct = @import("../types.zig");
pub const ConvertResult = ct.ConvertResult;
pub const ConvertResultList = ct.ConvertResultList;

const DeviceKind = core.types.DeviceKind;
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

    pub fn detectProjectRoot(self: *const Backend, project_dir: []const u8) bool {
        const extensions = [_][]const u8{ ".spice", ".sp", ".cir", ".net", ".cdl" };
        for (&extensions) |ext| {
            if (self.hasFileWithExt(project_dir, ext)) return true;
        }
        return false;
    }

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
            const source = platform.fs.cwd().readFileAlloc(la, full_path, 1 << 24) catch continue;

            var netlist = parser.parseNetlist(la, source) catch continue;
            netlist = resolveIncludes(la, netlist, project_dir) catch netlist;
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

    pub fn getFiles(
        _: *const Backend,
        _: []const u8,
    ) !void {
        return error.BackendNotImplemented;
    }

    fn hasFileWithExt(_: *const Backend, dir: []const u8, ext: []const u8) bool {
        var d = platform.fs.cwd().openDir(dir, .{ .iterate = true }) catch return false;
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

        var d = platform.fs.cwd().openDir(dir, .{ .iterate = true }) catch return &.{};
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

pub const parseNetlist = parser.parseNetlist;

/// Full pipeline: parse → resolveKinds → Layout → Router → LabelPlacer → build.
/// Returns one ConvertResult per .subckt, plus one for top-level elements.
pub fn convertNetlist(
    alloc: Allocator,
    netlist: Netlist,
    source_path: []const u8,
) ![]const ConvertResult {
    var results: List(ConvertResult) = .{};

    for (netlist.subckts) |subckt| {
        var tmp_arena = std.heap.ArenaAllocator.init(alloc);
        defer tmp_arena.deinit();
        const tmp = tmp_arena.allocator();

        const layout_elems = try toLayoutElements(tmp, subckt.elements);
        const kinds = try resolveKinds(tmp, subckt.elements, netlist.models);
        const placed = try Layout.place(tmp, layout_elems, kinds);
        const route_result = try Router.route(tmp, subckt.elements, placed);
        const labels = try LabelPlacer.placeLabels(tmp, placed, route_result.wires);
        const sch = try buildComponent(alloc, netlist, subckt, placed, route_result, labels);

        try results.append(alloc, .{
            .name = try alloc.dupe(u8, subckt.name),
            .sch_path = null,
            .sym_path = null,
            .schemify = sch,
        });
    }

    if (netlist.top_elements.len > 0) {
        var tmp_arena = std.heap.ArenaAllocator.init(alloc);
        defer tmp_arena.deinit();
        const tmp = tmp_arena.allocator();

        const layout_elems = try toLayoutElements(tmp, netlist.top_elements);
        const kinds = try resolveKinds(tmp, netlist.top_elements, netlist.models);
        const placed = try Layout.place(tmp, layout_elems, kinds);
        const route_result = try Router.route(tmp, netlist.top_elements, placed);
        const labels = try LabelPlacer.placeLabels(tmp, placed, route_result.wires);
        const sch = try buildTestbench(alloc, netlist, placed, route_result, labels, source_path);

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

// ── Bridge: parser.Element → Layout.LayoutElement ───────────────────────────

fn toLayoutElements(arena: Allocator, elements: []const Element) ![]const Layout.LayoutElement {
    const result = try arena.alloc(Layout.LayoutElement, elements.len);
    for (elements, 0..) |elem, i| {
        result[i] = .{
            .prefix = elem.prefix,
            .name = elem.name,
            .nodes = elem.nodes,
            .model = elem.model,
        };
    }
    return result;
}

fn resolveKinds(arena: Allocator, elements: []const Element, models: []const Model) ![]const DeviceKind {
    const result = try arena.alloc(DeviceKind, elements.len);
    for (elements, 0..) |elem, i| {
        const model_kind = findModelKind(elem.model, models);
        result[i] = conventions.inferPolarity(elem.prefix, elem.model, model_kind);
    }
    return result;
}

fn findModelKind(model_name: ?[]const u8, models: []const Model) ?[]const u8 {
    const name = model_name orelse return null;
    for (models) |m| {
        if (std.ascii.eqlIgnoreCase(m.name, name)) {
            return m.kind;
        }
    }
    return null;
}

// ── Schemify construction ───────────────────────────────────────────────────

fn buildComponent(
    alloc: Allocator,
    netlist: Netlist,
    subckt: Subckt,
    placed: []const PlacedDevice,
    route_result: RouteResult,
    labels: []const LabelOffset,
) !Schemify {
    var sch = Schemify{};
    try sch.setName(alloc, subckt.name);
    sch.stype = .schematic;

    const n_ports = subckt.ports.len;
    for (subckt.ports, 0..) |port, i| {
        const pin_x: i32 = if (i < n_ports / 2 + n_ports % 2) -40 else 40;
        const pin_y: i32 = -@as(i32, @intCast(i)) * 40;
        try sch.drawPinStr(alloc, port, pin_x, pin_y, .inout);
    }

    try populateInstances(alloc, &sch, subckt.elements, placed, labels);
    try populateWires(alloc, &sch, route_result);
    try populatePower(alloc, &sch, route_result.power);

    for (netlist.globals) |g| {
        try sch.addGlobal(alloc, g);
    }

    try sch.addSymProp(alloc, "type", "subcircuit");
    try sch.addSymProp(alloc, "format", try buildFormatStr(alloc, subckt));

    return sch;
}

fn buildTestbench(
    alloc: Allocator,
    netlist: Netlist,
    placed: []const PlacedDevice,
    route_result: RouteResult,
    labels: []const LabelOffset,
    source_path: []const u8,
) !Schemify {
    var sch = Schemify{};
    const title = if (netlist.title.len > 0) netlist.title else "testbench";
    try sch.setName(alloc, title);
    sch.stype = .testbench;

    try populateInstances(alloc, &sch, netlist.top_elements, placed, labels);
    try populateWires(alloc, &sch, route_result);
    try populatePower(alloc, &sch, route_result.power);

    for (netlist.globals) |g| {
        try sch.addGlobal(alloc, g);
    }

    if (source_path.len > 0) {
        try sch.addSymProp(alloc, "source", source_path);
    }

    return sch;
}

fn populateInstances(
    alloc: Allocator,
    sch: *Schemify,
    elements: []const Element,
    placed: []const PlacedDevice,
    labels: []const LabelOffset,
) !void {
    // Build elem_idx -> label lookup
    var label_map = std.AutoHashMapUnmanaged(u32, LabelOffset){};
    defer label_map.deinit(alloc);
    for (labels) |lbl| {
        try label_map.put(alloc, lbl.elem_idx, lbl);
    }

    for (placed) |p| {
        if (p.elem_idx >= elements.len) continue;
        const elem = elements[p.elem_idx];

        // Collect properties into temp buffer
        var props_buf: [32]PropPair = undefined;
        var prop_count: usize = 0;
        try collectElementProps(elem, &props_buf, &prop_count);

        const spice_line: []const u8 = if (elem.prefix == 'e' or elem.prefix == 'g' or
            elem.prefix == 'f' or elem.prefix == 'h' or elem.prefix == 'b')
            (elem.value orelse "")
        else
            "";

        const lbl = label_map.get(p.elem_idx);

        // Build props via string pool
        const prop_start: u32 = @intCast(sch.props.items.len);
        for (props_buf[0..prop_count]) |prop| {
            try sch.props.append(alloc, .{
                .key = try sch.strings.add(alloc, prop.key),
                .val = try sch.strings.add(alloc, prop.val),
            });
        }

        try sch.instances.append(alloc, .{
            .name = try sch.strings.add(alloc, elem.name),
            .symbol = try sch.strings.add(alloc, p.symbol),
            .spice_line = if (spice_line.len > 0) try sch.strings.add(alloc, spice_line) else .empty,
            .prop_start = prop_start,
            .prop_count = @intCast(prop_count),
            .x = p.x,
            .y = p.y,
            .kind = p.kind,
            .flags = .{},
            .name_dx = if (lbl) |l| l.name_dx else 0,
            .name_dy = if (lbl) |l| l.name_dy else 0,
            .param_dx = if (lbl) |l| l.param_dx else 0,
            .param_dy = if (lbl) |l| l.param_dy else 0,
        });
        try sch.sym_data.append(alloc, .{});
    }
}

fn populateWires(alloc: Allocator, sch: *Schemify, route_result: RouteResult) !void {
    for (route_result.wires) |w| {
        _ = try sch.addWireWithNet(alloc, w.x0, w.y0, w.x1, w.y1, w.net_name);
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
            .name = try sch.strings.add(alloc, name),
            .symbol = try sch.strings.add(alloc, sym_name),
            .x = ps.x,
            .y = ps.y,
            .kind = kind,
            .flags = .{},
        });
        try sch.sym_data.append(alloc, .{});
    }
}

// ── Property collection ─────────────────────────────────────────────────────

const PropPair = struct { key: []const u8, val: []const u8 };

fn collectElementProps(
    elem: Element,
    buf: *[32]PropPair,
    count: *usize,
) !void {
    count.* = 0;
    switch (elem.prefix) {
        'r', 'c' => {
            if (elem.value) |v| {
                buf[count.*] = .{ .key = "value", .val = v };
                count.* += 1;
            }
            const device = if (elem.prefix == 'r') "resistor" else "capacitor";
            buf[count.*] = .{ .key = "device", .val = device };
            count.* += 1;
            for (elem.params) |p| {
                if (count.* >= 32) break;
                buf[count.*] = .{ .key = p.key, .val = p.val };
                count.* += 1;
            }
        },
        'l' => {
            if (elem.value) |v| {
                buf[count.*] = .{ .key = "value", .val = v };
                count.* += 1;
            }
            for (elem.params) |p| {
                if (count.* >= 32) break;
                buf[count.*] = .{ .key = p.key, .val = p.val };
                count.* += 1;
            }
        },
        'd' => {
            if (elem.model) |m| {
                buf[count.*] = .{ .key = "model", .val = m };
                count.* += 1;
            }
            for (elem.params) |p| {
                if (count.* >= 32) break;
                buf[count.*] = .{ .key = p.key, .val = p.val };
                count.* += 1;
            }
        },
        'm' => {
            if (elem.model) |m| {
                buf[count.*] = .{ .key = "model", .val = m };
                count.* += 1;
            }
            var has_m = false;
            for (elem.params) |p| {
                if (count.* >= 32) break;
                var key_buf: [16]u8 = undefined;
                const lo_key = toLowerBuf(p.key, &key_buf) orelse p.key;
                const canon_key = canonMosfetKey(lo_key) orelse continue;
                buf[count.*] = .{ .key = canon_key, .val = p.val };
                count.* += 1;
                if (std.mem.eql(u8, lo_key, "m")) has_m = true;
            }
            if (!has_m and count.* < 32) {
                buf[count.*] = .{ .key = "M", .val = "1" };
                count.* += 1;
            }
        },
        'q', 'j' => {
            if (elem.model) |m| {
                buf[count.*] = .{ .key = "model", .val = m };
                count.* += 1;
            }
            for (elem.params) |p| {
                if (count.* >= 32) break;
                buf[count.*] = .{ .key = p.key, .val = p.val };
                count.* += 1;
            }
        },
        'v', 'i' => {
            if (elem.value) |v| {
                buf[count.*] = .{ .key = "value", .val = v };
                count.* += 1;
            }
        },
        'x' => {
            for (elem.params) |p| {
                if (count.* >= 32) break;
                buf[count.*] = .{ .key = p.key, .val = p.val };
                count.* += 1;
            }
        },
        else => {
            if (elem.value) |v| {
                buf[count.*] = .{ .key = "value", .val = v };
                count.* += 1;
            }
            for (elem.params) |p| {
                if (count.* >= 32) break;
                buf[count.*] = .{ .key = p.key, .val = p.val };
                count.* += 1;
            }
        },
    }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn resolveIncludes(arena: Allocator, netlist: Netlist, project_dir: []const u8) !Netlist {
    if (netlist.includes.len == 0) return netlist;

    var extra_subckts: List(Subckt) = .{};
    var extra_models: List(Model) = .{};

    for (netlist.includes) |inc| {
        const inc_path = std.fs.path.join(arena, &.{ project_dir, inc.path }) catch continue;
        const inc_source = platform.fs.cwd().readFileAlloc(arena, inc_path, 1 << 24) catch continue;
        const inc_netlist = parser.parseNetlist(arena, inc_source) catch continue;

        for (inc_netlist.subckts) |sc| try extra_subckts.append(arena, sc);
        for (inc_netlist.models) |m| try extra_models.append(arena, m);
    }

    if (extra_subckts.items.len == 0 and extra_models.items.len == 0) return netlist;

    var merged_subckts: List(Subckt) = .{};
    for (netlist.subckts) |sc| try merged_subckts.append(arena, sc);
    for (extra_subckts.items) |sc| try merged_subckts.append(arena, sc);

    var merged_models: List(Model) = .{};
    for (netlist.models) |m| try merged_models.append(arena, m);
    for (extra_models.items) |m| try merged_models.append(arena, m);

    return .{
        .title = netlist.title,
        .subckts = try arena.dupe(Subckt, merged_subckts.items),
        .top_elements = netlist.top_elements,
        .models = try arena.dupe(Model, merged_models.items),
        .params = netlist.params,
        .globals = netlist.globals,
        .includes = netlist.includes,
    };
}

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
    // 5 MOSFETs + power symbols
    try std.testing.expect(results[0].schemify.instances.len >= 5);
    try std.testing.expectEqual(@as(usize, 5), results[0].schemify.pins.len);
}

test "sanitizeName" {
    try std.testing.expectEqualStrings("OTA", sanitizeName("OTA Testbench"));
    try std.testing.expectEqualStrings("netlist", sanitizeName(""));
}

test "toLayoutElements — bridge conversion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nodes = try arena.dupe([]const u8, &.{ "vdd", "0" });
    const elements = [_]Element{
        .{ .prefix = 'v', .name = "V1", .nodes = nodes, .value = "1.8" },
    };

    const layout_elems = try toLayoutElements(arena, &elements);
    try std.testing.expectEqual(@as(usize, 1), layout_elems.len);
    try std.testing.expectEqual(@as(u8, 'v'), layout_elems[0].prefix);
    try std.testing.expectEqualStrings("V1", layout_elems[0].name);
}

test "resolveKinds — MOSFET polarity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nodes = try arena.dupe([]const u8, &.{ "d", "g", "s", "b" });
    const elements = [_]Element{
        .{ .prefix = 'm', .name = "M1", .nodes = nodes, .model = "sky130_fd_pr__pfet_01v8" },
        .{ .prefix = 'm', .name = "M2", .nodes = nodes, .model = "sky130_fd_pr__nfet_01v8" },
    };
    const models = [_]Model{};

    const kinds = try resolveKinds(arena, &elements, &models);
    try std.testing.expectEqual(DeviceKind.pmos4, kinds[0]);
    try std.testing.expectEqual(DeviceKind.nmos4, kinds[1]);
}

// Force-reference sub-modules for test discovery
comptime {
    _ = parser;
}
