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
const PinRef = core.types.PinRef;
const StringRef = core.string_pool.StringRef;
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

    // Classify ports: power on top/bottom, signals split left/right
    var left_ports: List([]const u8) = .{};
    var right_ports: List([]const u8) = .{};
    var top_ports: List([]const u8) = .{};
    var bottom_ports: List([]const u8) = .{};
    for (subckt.ports) |port| {
        if (Layout.isVddNet(port)) {
            try top_ports.append(alloc, port);
        } else if (Layout.isGndNet(port)) {
            try bottom_ports.append(alloc, port);
        } else if (isInputLikePort(port)) {
            try left_ports.append(alloc, port);
        } else if (isOutputLikePort(port)) {
            try right_ports.append(alloc, port);
        } else if (left_ports.items.len <= right_ports.items.len) {
            try left_ports.append(alloc, port);
        } else {
            try right_ports.append(alloc, port);
        }
    }

    const PIN_SPACING: i32 = 40;
    const side_max: i32 = @intCast(@max(left_ports.items.len, right_ports.items.len));
    const top_max: i32 = @intCast(@max(top_ports.items.len, bottom_ports.items.len));
    const half_h: i32 = @divTrunc(@max(side_max, 1) * PIN_SPACING, 2);
    const half_w: i32 = @max(@divTrunc(@max(top_max, 1) * PIN_SPACING, 2), half_h);
    const sym_left: i32 = -half_w - 40;
    const sym_right: i32 = half_w + 40;
    const sym_top: i32 = -half_h - 40;
    const sym_bottom: i32 = half_h + 40;

    for (left_ports.items, 0..) |port, i| {
        const py = -half_h + @as(i32, @intCast(i)) * PIN_SPACING;
        try sch.drawPinStr(alloc, port, sym_left, py, .inout);
    }
    for (right_ports.items, 0..) |port, i| {
        const py = -half_h + @as(i32, @intCast(i)) * PIN_SPACING;
        try sch.drawPinStr(alloc, port, sym_right, py, .inout);
    }
    for (top_ports.items, 0..) |port, i| {
        const n: i32 = @intCast(top_ports.items.len -| 1);
        const px = @divTrunc(-n * PIN_SPACING, 2) + @as(i32, @intCast(i)) * PIN_SPACING;
        try sch.drawPinStr(alloc, port, px, sym_top, .inout);
    }
    for (bottom_ports.items, 0..) |port, i| {
        const n: i32 = @intCast(bottom_ports.items.len -| 1);
        const px = @divTrunc(-n * PIN_SPACING, 2) + @as(i32, @intCast(i)) * PIN_SPACING;
        try sch.drawPinStr(alloc, port, px, sym_bottom, .inout);
    }

    try populateInstances(alloc, &sch, subckt.elements, placed, labels);
    try populateWires(alloc, &sch, route_result);
    try populateNetLabels(alloc, &sch, route_result);
    try populatePower(alloc, &sch, route_result.power);
    try populateModels(alloc, &sch, netlist.models);

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
    try populateNetLabels(alloc, &sch, route_result);
    try populatePower(alloc, &sch, route_result.power);
    try populateModels(alloc, &sch, netlist.models);

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

        // Build sym_data with pin positions from Router geometry + net names from SPICE
        const pin_names = pinNamesForKind(p.kind);
        if (pin_names.len > 0) {
            const pins = try alloc.alloc(PinRef, pin_names.len);
            for (pin_names, 0..) |name, i| {
                const abs = Router.pinPos(p, i) orelse {
                    pins[i] = .{ .name = try sch.strings.add(alloc, name) };
                    continue;
                };
                // Store explicit net from SPICE nodes
                const net_ref: StringRef = if (i < elem.nodes.len)
                    try sch.strings.add(alloc, elem.nodes[i])
                else
                    .empty;
                pins[i] = .{
                    .name = try sch.strings.add(alloc, name),
                    .x = abs.x - p.x,
                    .y = abs.y - p.y,
                    .dir = .inout,
                    .net = net_ref,
                };
            }
            try sch.sym_data.append(alloc, .{ .pins = pins });
        } else if (elem.nodes.len > 0) {
            // Subcircuit/unknown instances: build pins from SPICE nodes with
            // dynamic pin positions matching Router.pinPosN.
            const pins = try alloc.alloc(PinRef, elem.nodes.len);
            for (elem.nodes, 0..) |node, i| {
                const abs_pos = Router.pinPosN(p, i, elem.nodes.len);
                pins[i] = .{
                    .name = try sch.strings.add(alloc, node),
                    .x = if (abs_pos) |ap| ap.x - p.x else 0,
                    .y = if (abs_pos) |ap| ap.y - p.y else 0,
                    .dir = .inout,
                    .net = try sch.strings.add(alloc, node),
                };
            }
            try sch.sym_data.append(alloc, .{ .pins = pins });
        } else {
            try sch.sym_data.append(alloc, .{});
        }
    }
}

/// Canonical pin names per device kind, matching Router pin offset order.
fn pinNamesForKind(kind: DeviceKind) []const []const u8 {
    return switch (kind) {
        .nmos3, .pmos3 => &.{ "d", "g", "s" },
        .nmos4, .pmos4, .nmos4_depl, .nmos_sub, .pmos_sub, .nmoshv4, .pmoshv4, .rnmos4 => &.{ "d", "g", "s", "b" },
        .npn => &.{ "C", "B", "E" },
        .pnp => &.{ "C", "B", "E" },
        .njfet, .pjfet => &.{ "d", "g", "s" },
        .vcvs, .vccs => &.{ "p", "n", "cp", "cn" },
        .resistor, .resistor3, .var_resistor,
        .capacitor, .inductor,
        .vsource, .isource,
        .diode, .zener,
        => &.{ "p", "n" },
        else => &.{},
    };
}

fn populateWires(alloc: Allocator, sch: *Schemify, route_result: RouteResult) !void {
    const bus_mod = core.bus;
    const Wire = core.types.Wire;
    for (route_result.wires) |w| {
        const is_bus = bus_mod.parseBusName(w.net_name) != null;
        const color: u32 = if (Layout.isVddNet(w.net_name))
            Wire.packColor(200, 50, 50) // red for VDD
        else if (Layout.isGndNet(w.net_name))
            Wire.packColor(50, 80, 200) // blue for VSS/GND
        else
            0;
        const thickness: u8 = if (Layout.isPowerNet(w.net_name)) 20 else 0; // 2.0x for power
        const idx = if (is_bus)
            try sch.addWireFull(alloc, .{ .x0 = w.x0, .y0 = w.y0, .x1 = w.x1, .y1 = w.y1, .bus = true, .net_name = if (w.net_name.len > 0) try sch.strings.add(alloc, w.net_name) else .empty, .color = color, .thickness = thickness })
        else
            try sch.addWireWithNet(alloc, w.x0, w.y0, w.x1, w.y1, w.net_name);
        // Set color/thickness for non-bus wires (addWireWithNet doesn't support them)
        if (!is_bus and (color != 0 or thickness != 0)) {
            sch.wires.items(.color)[idx] = color;
            sch.wires.items(.thickness)[idx] = thickness;
        }
    }
}

const LabelPoint = struct { x: i32, y: i32 };

fn populateNetLabels(alloc: Allocator, sch: *Schemify, route_result: RouteResult) !void {
    var seen = std.StringHashMapUnmanaged(LabelPoint){};
    defer seen.deinit(alloc);

    for (route_result.wires) |w| {
        if (w.net_name.len == 0) continue;
        if (Layout.isPowerNet(w.net_name)) continue;

        const gop = try seen.getOrPut(alloc, w.net_name);
        if (gop.found_existing) {
            // Check manhattan distance from last label to this wire endpoint
            const prev = gop.value_ptr.*;
            const dx = if (w.x0 > prev.x) w.x0 - prev.x else prev.x - w.x0;
            const dy = if (w.y0 > prev.y) w.y0 - prev.y else prev.y - w.y0;
            if (dx + dy <= 300) continue;
            gop.value_ptr.* = .{ .x = w.x0, .y = w.y0 };
        } else {
            gop.value_ptr.* = .{ .x = w.x0, .y = w.y0 };
        }

        const prop_start: u32 = @intCast(sch.props.items.len);
        try sch.props.append(alloc, .{
            .key = try sch.strings.add(alloc, "lab"),
            .val = try sch.strings.add(alloc, w.net_name),
        });

        try sch.instances.append(alloc, .{
            .name = try sch.strings.add(alloc, w.net_name),
            .symbol = try sch.strings.add(alloc, "lab_pin"),
            .x = w.x0,
            .y = w.y0,
            .kind = .lab_pin,
            .prop_start = prop_start,
            .prop_count = 1,
            .flags = .{},
        });
        // Lab pin has a single connection point at its origin
        const pin = try alloc.alloc(PinRef, 1);
        pin[0] = .{ .name = try sch.strings.add(alloc, "pin"), .x = 0, .y = 0, .dir = .inout };
        try sch.sym_data.append(alloc, .{ .pins = pin });
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
        // Power symbol connects at -10 offset (Router places them +10 from pin)
        const pin = try alloc.alloc(PinRef, 1);
        const pin_dy: i32 = switch (ps.kind) {
            .gnd => -10,
            .vdd => 10,
        };
        pin[0] = .{ .name = try sch.strings.add(alloc, "pin"), .x = 0, .y = pin_dy, .dir = .inout };
        try sch.sym_data.append(alloc, .{ .pins = pin });
    }
}

fn populateModels(alloc: Allocator, sch: *Schemify, models: []const Model) !void {
    for (models) |m| {
        const prop_start: u32 = @intCast(sch.props.items.len);
        for (m.params) |p| {
            try sch.props.append(alloc, .{
                .key = try sch.strings.add(alloc, p.key),
                .val = try sch.strings.add(alloc, p.val),
            });
        }
        const prop_count: u16 = @intCast(sch.props.items.len - prop_start);
        try sch.model_defs.append(alloc, .{
            .name = try sch.strings.add(alloc, m.name),
            .kind = try sch.strings.add(alloc, m.kind),
            .prop_start = prop_start,
            .prop_count = prop_count,
        });
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

fn isInputLikePort(name: []const u8) bool {
    var buf: [128]u8 = undefined;
    const lower = toLowerBuf(name, &buf) orelse return false;
    const input_patterns = [_][]const u8{ "inp", "inn", "clk", "rst", "reset", "bias", "en", "in" };
    for (input_patterns) |pat| {
        if (std.mem.indexOf(u8, lower, pat) != null) return true;
    }
    return false;
}

fn isOutputLikePort(name: []const u8) bool {
    var buf: [128]u8 = undefined;
    const lower = toLowerBuf(name, &buf) orelse return false;
    const output_patterns = [_][]const u8{ "outp", "outn", "out" };
    for (output_patterns) |pat| {
        if (std.mem.indexOf(u8, lower, pat) != null) return true;
    }
    return false;
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
