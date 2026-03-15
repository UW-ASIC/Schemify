//! netlist/root.zig — SPICE netlist generation from canonical Schemify / XSchem data.
//!
//! This is the package root for the netlist/ sub-package.  It contains the
//! full `Netlister` implementation; helper logic is also present in sibling
//! files (FeatureModel, ConnectivityResolver, XschemExtractor, TemplateExpander,
//! DirectiveBuilder, UniversalLowering) which document the intended split
//! boundaries for future refactoring.
//!
//! `Netlister` is the central public type. Construction paths:
//!   - `fromSchemify`          — relational path, calls resolveNets automatically
//!   - `fromXSchem`            — converts XSchem then delegates to fromSchemify
//!   - `fromXSchemWithSymbols` — full symbol-resolved connectivity
//!   - `fromSchemifyLegacy`    — legacy geometric path
//!
//! `UniversalNetlistForm` is a backward-compat alias for `Netlister`.
//! `GenerateNetlist` is a convenience wrapper around `Netlister.emitSpice`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const MAL = std.MultiArrayList;

const is_wasm = builtin.cpu.arch == .wasm32;
const sch = @import("../Schemify.zig");
const xs = @import("../XSchem.zig");
const dev = @import("../Device.zig");
const spice = @import("spice");
const univ = spice.universal;

// ── Private supporting types ─────────────────────────────────────────────── //

const WireSeg = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    net_name: ?[]const u8,
    bus: bool = false,
};

const DeviceRef = struct {
    name: []const u8,
    symbol: []const u8,
    kind: sch.DeviceKind = .unknown,
    x: i32,
    y: i32,
    rot: u2,
    flip: bool,
    prop_start: u32,
    prop_count: u16,
    format: ?[]const u8 = null,
    sym_template: ?[]const u8 = null,
    sym_device_model: ?[]const u8 = null,
};

pub const DeviceProp = struct {
    key: []const u8,
    value: []const u8,
};

const PinRef = struct {
    name: []const u8,
    dir: sch.PinDir,
};

pub const DeviceNet = struct {
    device_idx: u32,
    pin_name: []const u8,
    net_id: u32,
};

const SymResUF = sch.UnionFind;

/// Round f64 → i32. Duplicated from xschem.zig because that function is private;
/// acceptable given it is two lines and has no meaningful divergence risk.
fn f2i(v: f64) i32 {
    return @intFromFloat(@round(v));
}

inline fn symPtKey(x: i32, y: i32) u64 {
    return sch.NetMap.pointKey(x, y);
}

fn applyRotFlip(px: i32, py: i32, rot: u2, flip: bool, ox: i32, oy: i32) struct { x: i32, y: i32 } {
    const fx: i32 = if (flip) -px else px;
    const fy: i32 = py;
    const rx: i32 = switch (rot) {
        0 => fx,
        1 => -fy,
        2 => -fx,
        3 => fy,
    };
    const ry: i32 = switch (rot) {
        0 => fy,
        1 => fx,
        2 => -fy,
        3 => -fx,
    };
    return .{ .x = ox + rx, .y = oy + ry };
}

fn lookupPropValue(props: []const DeviceProp, key: []const u8) ?[]const u8 {
    for (props) |p| if (std.mem.eql(u8, p.key, key)) return p.value;
    return null;
}

/// Returns true if `name` is an individual bus-bit element like `DATA_FROM_HASH[0]`.
/// A single-bit element has `[N]` suffix where N is a non-negative integer (no colon).
fn isSingleBitBusElement(name: []const u8) bool {
    const ob = std.mem.indexOfScalar(u8, name, '[') orelse return false;
    const cb = std.mem.lastIndexOfScalar(u8, name, ']') orelse return false;
    if (cb <= ob + 1) return false;
    if (std.mem.indexOfScalarPos(u8, name, ob + 1, ':') != null) return false;
    _ = std.fmt.parseInt(u32, name[ob + 1 .. cb], 10) catch return false;
    return true;
}

fn hasBusRange(name: []const u8) bool {
    const ob = std.mem.indexOfScalar(u8, name, '[') orelse return false;
    const colon = std.mem.indexOfScalarPos(u8, name, ob + 1, ':') orelse return false;
    const cb = std.mem.indexOfScalarPos(u8, name, colon + 1, ']') orelse return false;
    _ = std.fmt.parseInt(i32, name[ob + 1 .. colon], 10) catch return false;
    _ = std.fmt.parseInt(i32, name[colon + 1 .. cb], 10) catch return false;
    return true;
}

/// Returns the auto-net numeric suffix if `name` is an auto-generated net
/// ("netN" or "_nN"), or null if it is a user-defined name.
/// Replaces the old isAutoNetName + autoNetNum pair.
fn autoNetIndex(name: []const u8) ?u32 {
    if (name.len > 3 and std.mem.eql(u8, name[0..3], "net")) {
        return std.fmt.parseInt(u32, name[3..], 10) catch null;
    }
    if (name.len > 2 and name[0] == '_' and name[1] == 'n') {
        return std.fmt.parseInt(u32, name[2..], 10) catch null;
    }
    return null;
}

fn pinNameMatchesBbox(cir_pin: []const u8, bbox_pin: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(cir_pin, bbox_pin)) return true;
    const cir_ob = std.mem.indexOfScalar(u8, cir_pin, '[') orelse return false;
    const cir_cb = std.mem.indexOfScalarPos(u8, cir_pin, cir_ob + 1, ']') orelse return false;
    if (std.mem.indexOfScalarPos(u8, cir_pin, cir_ob + 1, ':') != null) return false;
    const cir_prefix = cir_pin[0..cir_ob];
    const cir_idx = std.fmt.parseInt(i32, cir_pin[cir_ob + 1 .. cir_cb], 10) catch return false;
    const bbox_ob = std.mem.indexOfScalar(u8, bbox_pin, '[') orelse return false;
    const bbox_colon = std.mem.indexOfScalarPos(u8, bbox_pin, bbox_ob + 1, ':') orelse return false;
    const bbox_cb = std.mem.indexOfScalarPos(u8, bbox_pin, bbox_colon + 1, ']') orelse return false;
    if (!std.ascii.eqlIgnoreCase(cir_prefix, bbox_pin[0..bbox_ob])) return false;
    const bbox_hi = std.fmt.parseInt(i32, bbox_pin[bbox_ob + 1 .. bbox_colon], 10) catch return false;
    const bbox_lo = std.fmt.parseInt(i32, bbox_pin[bbox_colon + 1 .. bbox_cb], 10) catch return false;
    const lo = @min(bbox_hi, bbox_lo);
    const hi = @max(bbox_hi, bbox_lo);
    return cir_idx >= lo and cir_idx <= hi;
}

fn findSymbolFile(a: Allocator, sym_path: []const u8, search_dirs: []const []const u8) ![]const u8 {
    if (comptime is_wasm) return error.FileNotFound;
    _ = std.fs.cwd().access(sym_path, .{}) catch {
        const base = std.fs.path.basename(sym_path);
        // Determine whether to also try with ".sym" extension (for volare-style extensionless refs).
        const base_ext = std.fs.path.extension(base);
        const try_sym_ext = base_ext.len == 0; // no extension → try adding ".sym"
        // Only fall back to basename-only search when sym_path has no directory component.
        // If sym_path is e.g. "sky130_tests/not.sym", the directory prefix is significant and
        // we must not match unrelated files (e.g. system examples/not.sym) via the basename.
        const sym_has_dir = std.mem.indexOfScalar(u8, sym_path, '/') != null;
        for (search_dirs) |dir| {
            const candidate1 = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, sym_path }) catch continue;
            _ = std.fs.cwd().access(candidate1, .{}) catch {
                if (!sym_has_dir) {
                    const candidate2 = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, base }) catch continue;
                    _ = std.fs.cwd().access(candidate2, .{}) catch {
                        if (try_sym_ext) {
                            const candidate3 = std.fmt.allocPrint(a, "{s}/{s}.sym", .{ dir, sym_path }) catch continue;
                            _ = std.fs.cwd().access(candidate3, .{}) catch {
                                const candidate4 = std.fmt.allocPrint(a, "{s}/{s}.sym", .{ dir, base }) catch continue;
                                _ = std.fs.cwd().access(candidate4, .{}) catch continue;
                                return candidate4;
                            };
                            return candidate3;
                        }
                        continue;
                    };
                    return candidate2;
                } else if (try_sym_ext) {
                    const candidate3 = std.fmt.allocPrint(a, "{s}/{s}.sym", .{ dir, sym_path }) catch continue;
                    _ = std.fs.cwd().access(candidate3, .{}) catch continue;
                    return candidate3;
                }
                continue;
            };
            return candidate1;
        }
        return error.NotFound;
    };
    return a.dupe(u8, sym_path);
}

fn appendExpandedPinName(out: *List(u8), name: []const u8, a: Allocator) !void {
    const ob = std.mem.indexOfScalar(u8, name, '[') orelse {
        try out.append(a, ' ');
        try out.appendSlice(a, name);
        return;
    };
    const colon = std.mem.indexOfScalarPos(u8, name, ob + 1, ':') orelse {
        try out.append(a, ' ');
        try out.appendSlice(a, name);
        return;
    };
    const cb = std.mem.indexOfScalarPos(u8, name, colon + 1, ']') orelse {
        try out.append(a, ' ');
        try out.appendSlice(a, name);
        return;
    };
    const prefix = name[0..ob];
    const hi = std.fmt.parseInt(i32, name[ob + 1 .. colon], 10) catch {
        try out.append(a, ' ');
        try out.appendSlice(a, name);
        return;
    };
    const lo = std.fmt.parseInt(i32, name[colon + 1 .. cb], 10) catch {
        try out.append(a, ' ');
        try out.appendSlice(a, name);
        return;
    };
    if (hi >= lo) {
        var i: i32 = hi;
        while (i >= lo) : (i -= 1) {
            const expanded = try std.fmt.allocPrint(a, " {s}[{d}]", .{ prefix, i });
            try out.appendSlice(a, expanded);
        }
    } else {
        var i: i32 = hi;
        while (i <= lo) : (i += 1) {
            const expanded = try std.fmt.allocPrint(a, " {s}[{d}]", .{ prefix, i });
            try out.appendSlice(a, expanded);
        }
    }
}

/// Like appendExpandedPinName but prepends `pin_prefix` (e.g. "a_") to each name.
fn appendExpandedPinNamePrefixed(out: *List(u8), name: []const u8, pin_prefix: []const u8, a: Allocator) !void {
    if (pin_prefix.len == 0) return appendExpandedPinName(out, name, a);
    const ob = std.mem.indexOfScalar(u8, name, '[') orelse {
        try out.append(a, ' ');
        try out.appendSlice(a, pin_prefix);
        try out.appendSlice(a, name);
        return;
    };
    const colon = std.mem.indexOfScalarPos(u8, name, ob + 1, ':') orelse {
        try out.append(a, ' ');
        try out.appendSlice(a, pin_prefix);
        try out.appendSlice(a, name);
        return;
    };
    const cb = std.mem.indexOfScalarPos(u8, name, colon + 1, ']') orelse {
        try out.append(a, ' ');
        try out.appendSlice(a, pin_prefix);
        try out.appendSlice(a, name);
        return;
    };
    const base_prefix = name[0..ob];
    const hi = std.fmt.parseInt(i32, name[ob + 1 .. colon], 10) catch {
        try out.append(a, ' ');
        try out.appendSlice(a, pin_prefix);
        try out.appendSlice(a, name);
        return;
    };
    const lo = std.fmt.parseInt(i32, name[colon + 1 .. cb], 10) catch {
        try out.append(a, ' ');
        try out.appendSlice(a, pin_prefix);
        try out.appendSlice(a, name);
        return;
    };
    if (hi >= lo) {
        var i: i32 = hi;
        while (i >= lo) : (i -= 1) {
            const expanded = try std.fmt.allocPrint(a, " {s}{s}[{d}]", .{ pin_prefix, base_prefix, i });
            try out.appendSlice(a, expanded);
        }
    } else {
        var i: i32 = hi;
        while (i <= lo) : (i += 1) {
            const expanded = try std.fmt.allocPrint(a, " {s}{s}[{d}]", .{ pin_prefix, base_prefix, i });
            try out.appendSlice(a, expanded);
        }
    }
}

/// Parse a template= property value into default parameter string for .subckt headers.
/// Excludes `name=`, `m=`, and optionally keys in `exclude` (pass null to skip).
/// Handles single- and double-quoted values including XSchem \\" escapes.
fn extractTemplateDefaults(
    a: Allocator,
    template_val: []const u8,
    exclude: ?*const std.StringHashMapUnmanaged(void),
) ![]const u8 {
    var buf: List(u8) = .{};
    var pos: usize = 0;
    var first = true;
    // Skip leading whitespace including newlines.
    while (pos < template_val.len and (template_val[pos] == ' ' or template_val[pos] == '\t' or
        template_val[pos] == '\n' or template_val[pos] == '\r')) pos += 1;
    while (pos < template_val.len) {
        const eq_pos = std.mem.indexOfScalarPos(u8, template_val, pos, '=') orelse break;
        const key_raw = std.mem.trim(u8, template_val[pos..eq_pos], " \t\n\r");
        const key = std.mem.trimLeft(u8, key_raw, "+ \t\n\r");
        pos = eq_pos + 1;
        var val_start: usize = pos;
        var val_end: usize = pos;
        const dq_esc = pos + 2 < template_val.len and
            template_val[pos] == '\\' and template_val[pos + 1] == '\\' and template_val[pos + 2] == '"';
        const dq_plain = pos < template_val.len and template_val[pos] == '"';
        if (dq_esc or dq_plain) {
            const quote_len: usize = if (dq_esc) 3 else 1;
            val_start = pos + quote_len;
            pos += quote_len;
            while (pos < template_val.len) {
                if (pos + 2 < template_val.len and
                    template_val[pos] == '\\' and template_val[pos + 1] == '\\' and template_val[pos + 2] == '"')
                {
                    if (dq_esc) { val_end = pos; pos += 3; break; }
                    pos += 3;
                } else if (template_val[pos] == '\\' and pos + 1 < template_val.len and template_val[pos + 1] == '"') {
                    pos += 2;
                } else if (template_val[pos] == '"') {
                    val_end = pos; pos += 1; break;
                } else { pos += 1; }
            }
            if (val_end == val_start and pos >= template_val.len) val_end = pos;
        } else if (pos < template_val.len and template_val[pos] == '\'') {
            val_start = pos; pos += 1;
            while (pos < template_val.len and template_val[pos] != '\'') pos += 1;
            if (pos < template_val.len) pos += 1;
            val_end = pos;
        } else {
            // Stop at whitespace (space, tab, newline).
            while (pos < template_val.len and template_val[pos] != ' ' and template_val[pos] != '\t' and
                template_val[pos] != '\n' and template_val[pos] != '\r') pos += 1;
            val_end = pos;
        }
        if (std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, "m") or
            (exclude != null and exclude.?.contains(key)))
        {
            while (pos < template_val.len and (template_val[pos] == ' ' or template_val[pos] == '\t' or
                template_val[pos] == '\n' or template_val[pos] == '\r')) pos += 1;
            continue;
        }
        if (!first) try buf.append(a, ' ');
        try buf.appendSlice(a, key);
        try buf.append(a, '=');
        try buf.appendSlice(a, template_val[val_start..val_end]);
        first = false;
        // Skip whitespace (including newlines) and SPICE continuation '+' markers.
        while (pos < template_val.len and (template_val[pos] == ' ' or template_val[pos] == '\t' or
            template_val[pos] == '\n' or template_val[pos] == '\r')) pos += 1;
    }
    return buf.toOwnedSlice(a);
}

// ── Symbol type classification — O(1) StaticStringMap lookups ────────────── //

/// Symbol types that produce X-subcircuit SPICE lines.
const subckt_type_map = std.StaticStringMap(void).initComptime(.{
    .{ "subcircuit", {} }, .{ "primitive", {} }, .{ "opamp", {} },
    .{ "ic", {} },         .{ "gate", {} },      .{ "generic", {} },
    .{ "regulator", {} },  .{ "esd", {} },       .{ "crystal", {} },
    .{ "uc", {} },         .{ "transmission_line", {} }, .{ "missing", {} },
    .{ "i2c_eprom", {} },
});

/// Symbol types that are explicitly NOT subcircuits (wires, ports, code blocks…).
const non_subckt_type_map = std.StaticStringMap(void).initComptime(.{
    .{ "netlist_commands", {} }, .{ "label", {} },          .{ "use", {} },
    .{ "package", {} },          .{ "port_attributes", {} }, .{ "arch_declarations", {} },
    .{ "attributes", {} },       .{ "spice_parameters", {} }, .{ "lcc_iopin", {} },
    .{ "lcc_ipin", {} },         .{ "lcc_opin", {} },         .{ "switch", {} },
    .{ "delay", {} },            .{ "nmos", {} },             .{ "pmos", {} },
    .{ "npn", {} },              .{ "pnp", {} },              .{ "diode", {} },
    .{ "noconn", {} },           .{ "and", {} },              .{ "inv", {} },
    .{ "nand", {} },             .{ "nand3", {} },            .{ "buff", {} },
    .{ "notif0", {} },           .{ "ao21", {} },             .{ "or", {} },
    .{ "xor", {} },              .{ "xnor", {} },             .{ "not", {} },
    .{ "coupler", {} },          .{ "ipin", {} },             .{ "opin", {} },
    .{ "iopin", {} },
});

// ── Main public type ─────────────────────────────────────────────────────── //

/// Universal intermediate representation shared across all source formats.
/// Uses SoA containers (MultiArrayList) for cache-friendly transformations and
/// backend export. All owned memory lives in a single backing arena.
///
/// Construction paths:
///   - `fromSchemifyLegacy`    — legacy geometric path from Schemify
///   - `fromSchemify`          — relational path (calls resolveNets automatically)
///   - `fromXSchem`            — converts XSchem then delegates to fromSchemify
///   - `fromXSchemWithSymbols` — full symbol-resolved connectivity
pub const Netlister = struct {
    arena: std.heap.ArenaAllocator,

    // Geometric SoA — wire segments and device placements
    wires: MAL(WireSeg) = .{},
    devices: MAL(DeviceRef) = .{},
    props: List(DeviceProp) = .{},

    // Resolved netlist — populated by fromSchemify / fromXSchemWithSymbols
    name: []const u8 = "",
    pins: List(PinRef) = .{},
    net_names: List([]const u8) = .{},
    device_nets: List(DeviceNet) = .{},
    global_nets: List([]const u8) = .{},
    sym_search_dirs: []const []const u8 = &.{},
    subckt_defaults: []const u8 = "",
    spice_body: []const u8 = "",
    spice_s_block: []const u8 = "",
    is_toplevel: bool = true,
    /// Non-null when the source schematic has VHDL behavioral content (G block).
    ghdl_body: ?[]const u8 = null,
    /// Non-null when the source schematic has Verilog behavioral content (V block).
    /// XSchem suppresses port listing only when BOTH ghdl_body AND verilog_body are set.
    verilog_body: ?[]const u8 = null,
    /// When true, XSchem prepends "a_" to all port names in the .subckt header.
    /// This happens when the schematic contains xspice element lines (starting with 'A')
    /// in a code/code_shown block.
    xspice_port_prefix: bool = false,
    /// Parameters passed from the parent instance (e.g. DEL=5 from `name=x1 DEL=5`).
    /// Used to substitute @PARAM tokens in child component values (expr(2500 * @DEL)).
    parent_params: []const DeviceProp = &.{},
    /// When true, bare parameter-name references in device values (e.g. L=L_N where L_N is
    /// a parent_param) are substituted with the parent instance's actual values.  Only set
    /// for named-variant subckts (schematic=NAME without .sch extension).
    inline_parent_params: bool = false,

    pub fn init(backing: Allocator) Netlister {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *Netlister) void {
        self.arena.deinit();
    }

    fn alloc(self: *Netlister) Allocator {
        return self.arena.allocator();
    }

    // ── Shared device+prop copy helper ──────────────────────────────── //

    /// Copy all instances and their props from a Schemify store into this
    /// Netlister's SoA.  Used by fromSchemify and fromSchemifyLegacy.
    fn copyDevicesFromSchemify(
        self: *Netlister,
        arena: Allocator,
        src: *const sch.Schemify,
    ) !void {
        const ins = src.instances.slice();
        // Hoist all field slices before the loop — one pointer per field,
        // not re-dereferenced on every iteration.
        const iname = ins.items(.name);
        const isym  = ins.items(.symbol);
        const ikind = ins.items(.kind);
        const ix    = ins.items(.x);
        const iy    = ins.items(.y);
        const irot  = ins.items(.rot);
        const iflip = ins.items(.flip);
        const ips   = ins.items(.prop_start);
        const ipc   = ins.items(.prop_count);
        try self.devices.ensureTotalCapacity(arena, src.instances.len);
        try self.props.ensureTotalCapacity(arena, src.props.items.len);
        for (0..src.instances.len) |i| {
            const prop_start: u32 = @intCast(self.props.items.len);
            for (src.props.items[ips[i]..][0..ipc[i]]) |p| {
                try self.props.append(arena, .{
                    .key   = try arena.dupe(u8, p.key),
                    .value = try arena.dupe(u8, p.val),
                });
            }
            try self.devices.append(arena, .{
                .name       = try arena.dupe(u8, iname[i]),
                .symbol     = try arena.dupe(u8, isym[i]),
                .kind       = ikind[i],
                .x          = ix[i],
                .y          = iy[i],
                .rot        = irot[i],
                .flip       = iflip[i],
                .prop_start = prop_start,
                .prop_count = @intCast(self.props.items.len - prop_start),
            });
        }
    }

    pub fn fromSchemifyLegacy(src: *const sch.Schemify, backing: Allocator) !Netlister {
        var out = Netlister.init(backing);
        const arena = out.alloc();
        // Copy wires — hoist slices before loop
        try out.wires.ensureTotalCapacity(arena, src.wires.len);
        {
            const ws  = src.wires.slice();
            const lwx0 = ws.items(.x0); const lwy0 = ws.items(.y0);
            const lwx1 = ws.items(.x1); const lwy1 = ws.items(.y1);
            const lwnn = ws.items(.net_name);
            for (0..src.wires.len) |i| {
                try out.wires.append(arena, .{
                    .x0 = lwx0[i], .y0 = lwy0[i],
                    .x1 = lwx1[i], .y1 = lwy1[i],
                    .net_name = if (lwnn[i]) |n| try arena.dupe(u8, n) else null,
                });
            }
        }
        try out.copyDevicesFromSchemify(arena, src);
        return out;
    }

    pub fn fromSchemify(a: Allocator, s: *sch.Schemify) !Netlister {
        var out = Netlister.init(a);
        const arena = out.alloc();

        if (s.nets.items.len == 0) s.resolveNets();

        out.name = if (s.name.len > 0) (arena.dupe(u8, s.name) catch "") else "";

        try out.copyDevicesFromSchemify(arena, s);

        // Copy net names
        try out.net_names.ensureTotalCapacity(arena, s.nets.items.len);
        for (s.nets.items) |net| {
            try out.net_names.append(arena, try arena.dupe(u8, net.name));
        }

        // Copy device nets from relational net_conns
        for (s.net_conns.items) |nc| {
            if (nc.kind != .instance_pin) continue;
            try out.device_nets.append(arena, .{
                .device_idx = @intCast(nc.ref_a),
                .pin_name   = if (nc.pin_or_label) |p| try arena.dupe(u8, p) else "",
                .net_id     = nc.net_id,
            });
        }

        // Copy symbol pins
        const pin_slice = s.pins.slice();
        try out.pins.ensureTotalCapacity(arena, s.pins.len);
        for (0..s.pins.len) |i| {
            try out.pins.append(arena, .{
                .name = try arena.dupe(u8, pin_slice.items(.name)[i]),
                .dir  = pin_slice.items(.dir)[i],
            });
        }

        return out;
    }

    pub fn fromXSchem(a: Allocator, x: *const xs.XSchem) !Netlister {
        var s = try x.toSchemify(a);
        defer s.deinit();
        return fromSchemify(a, &s);
    }

    pub fn fromXSchemWithSymbols(
        a: Allocator,
        x: *const xs.XSchem,
        sym_search_dirs: []const []const u8,
    ) !Netlister {
        var out = Netlister.init(a);
        const arena = out.alloc();

        // Store search dirs
        {
            var dirs_copy = try List([]const u8).initCapacity(arena, sym_search_dirs.len);
            for (sym_search_dirs) |d| dirs_copy.appendAssumeCapacity(try arena.dupe(u8, d));
            out.sym_search_dirs = try dirs_copy.toOwnedSlice(arena);
        }

        out.name = if (x.name.len > 0) (arena.dupe(u8, x.name) catch "") else "";
        if (x.ghdl_body) |vb| out.ghdl_body = arena.dupe(u8, vb) catch null;
        if (x.verilog_body) |vb| out.verilog_body = arena.dupe(u8, vb) catch null;

        // Detect xspice port-prefix: set when any code/code_shown block contains
        // xspice element lines (lines whose first non-space char is 'A' followed by
        // a digit, e.g. "A1 [A B] IX d_lut_...").
        // XSchem prepends "a_" to all .subckt port names in this case.
        detect_xspice: {
            const xi = x.instances.slice();
            for (0..x.instances.len) |i| {
                const sym_base = std.fs.path.basename(xi.items(.symbol)[i]);
                if (!std.mem.eql(u8, sym_base, "code.sym") and
                    !std.mem.eql(u8, sym_base, "code_shown.sym")) continue;
                const ps2 = xi.items(.prop_start)[i];
                const pc2 = xi.items(.prop_count)[i];
                const code_props = x.props.items[ps2..][0..pc2];
                const val2: ?[]const u8 = blk: {
                    for (code_props) |p| {
                        if (std.mem.eql(u8, p.key, "value")) break :blk p.value;
                    }
                    break :blk null;
                };
                if (val2 == null) continue;
                var line_it = std.mem.splitScalar(u8, val2.?, '\n');
                while (line_it.next()) |ln| {
                    const tl = std.mem.trimLeft(u8, ln, " \t");
                    if (tl.len > 1 and (tl[0] == 'A' or tl[0] == 'a') and
                        std.ascii.isDigit(tl[1]))
                    {
                        out.xspice_port_prefix = true;
                        break :detect_xspice;
                    }
                }
            }
        }

        // Copy devices from XSchem instances
        const xs_ins = x.instances.slice();
        try out.devices.ensureTotalCapacity(arena, x.instances.len);
        try out.props.ensureTotalCapacity(arena, x.props.items.len);
        for (0..x.instances.len) |i| {
            const prop_start: u32 = @intCast(out.props.items.len);
            const ps = xs_ins.items(.prop_start)[i];
            const pc = xs_ins.items(.prop_count)[i];
            for (x.props.items[ps..][0..pc]) |p| {
                try out.props.append(arena, .{
                    .key   = try arena.dupe(u8, p.key),
                    .value = try arena.dupe(u8, p.value),
                });
            }
            const sym = try arena.dupe(u8, xs_ins.items(.symbol)[i]);
            const rot_u: u2 = @truncate(@as(u32, @bitCast(xs_ins.items(.rot)[i])));
            try out.devices.append(arena, .{
                .name       = try arena.dupe(u8, xs_ins.items(.name)[i]),
                .symbol     = sym,
                .kind       = xs.inferDeviceKind(sym),
                .x          = f2i(xs_ins.items(.x)[i]),
                .y          = f2i(xs_ins.items(.y)[i]),
                .rot        = rot_u,
                .flip       = xs_ins.items(.flip)[i],
                .prop_start = prop_start,
                .prop_count = @intCast(out.props.items.len - prop_start),
            });
        }

        // Copy wires — hoist slices
        try out.wires.ensureTotalCapacity(arena, x.wires.len);
        {
            const xs_ws  = x.wires.slice();
            const xwx0   = xs_ws.items(.x0); const xwy0 = xs_ws.items(.y0);
            const xwx1   = xs_ws.items(.x1); const xwy1 = xs_ws.items(.y1);
            const xwnn   = xs_ws.items(.net_name);
            const xwbus  = xs_ws.items(.bus);
            for (0..x.wires.len) |i| {
                try out.wires.append(arena, .{
                    .x0 = f2i(xwx0[i]), .y0 = f2i(xwy0[i]),
                    .x1 = f2i(xwx1[i]), .y1 = f2i(xwy1[i]),
                    .net_name = if (xwnn[i]) |n| try arena.dupe(u8, n) else null,
                    .bus = xwbus[i],
                });
            }
        }

        var uf = SymResUF{ .a = arena };
        const ds = out.devices.slice();
        const ws = out.wires.slice();

        // Build UF from wire segments — hoist slices outside the loop
        {
            const wx0 = ws.items(.x0);
            const wy0 = ws.items(.y0);
            const wx1 = ws.items(.x1);
            const wy1 = ws.items(.y1);
            for (0..out.wires.len) |i| {
                const k0 = symPtKey(wx0[i], wy0[i]);
                const k1 = symPtKey(wx1[i], wy1[i]);
                uf.makeSet(k0);
                uf.makeSet(k1);
                uf.unite(k0, k1);
            }
            // T-junctions: wire endpoint landing in the interior of another non-bus wire.
            // Bus wires (bus=true) are not physical nodes — they are tapped only via
            // bus_tap components, so we must not create wire-level T-junctions into them.
            const wbus = ws.items(.bus);
            for (0..out.wires.len) |i| {
                for ([2]struct { x: i32, y: i32 }{
                    .{ .x = wx0[i], .y = wy0[i] },
                    .{ .x = wx1[i], .y = wy1[i] },
                }) |pt| {
                    const kp = symPtKey(pt.x, pt.y);
                    for (0..out.wires.len) |j| {
                        if (j == i) continue;
                        if (wbus[j]) continue; // never T-junction into a bus wire
                        const on_interior = blk: {
                            if (wy0[j] == wy1[j] and pt.y == wy0[j]) {
                                const lo = @min(wx0[j], wx1[j]);
                                const hi = @max(wx0[j], wx1[j]);
                                break :blk lo < pt.x and pt.x < hi;
                            } else if (wx0[j] == wx1[j] and pt.x == wx0[j]) {
                                const lo = @min(wy0[j], wy1[j]);
                                const hi = @max(wy0[j], wy1[j]);
                                break :blk lo < pt.y and pt.y < hi;
                            } else break :blk false;
                        };
                        if (on_interior) uf.unite(kp, symPtKey(wx0[j], wy0[j]));
                    }
                }
            }
        }

        // Sorted array of (root_key, net_name) — deterministic net ordering,
        // binary search for membership, no hash non-determinism.
        const RootName = struct { root: u64, name: []const u8 };
        var root_names = List(RootName){};

        const rnFind = struct {
            fn find(items: []const RootName, root: u64) ?usize {
                var lo: usize = 0;
                var hi: usize = items.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (items[mid].root < root) lo = mid + 1 else hi = mid;
                }
                return if (lo < items.len and items[lo].root == root) lo else null;
            }
            fn insert(items: *List(RootName), alloc_: Allocator, root: u64, name: []const u8) void {
                var lo: usize = 0;
                var hi: usize = items.items.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (items.items[mid].root < root) lo = mid + 1 else hi = mid;
                }
                items.insert(alloc_, lo, .{ .root = root, .name = name }) catch {};
            }
        };

        // Build a set of UF cluster roots that contain a TCL generator device,
        // and collect the lab= values those TCL devices inject.
        // Wire labels belonging to such clusters are XSchem display annotations
        // (cached from the TCL generator's lab= attribute) and must not be used
        // as authoritative SPICE net names.
        var tcl_roots = std.AutoHashMapUnmanaged(u64, void){};
        var tcl_labels = std.StringHashMapUnmanaged(void){};
        {
            const dsym = ds.items(.symbol);
            const dx   = ds.items(.x);
            const dy   = ds.items(.y);
            const dps_t = ds.items(.prop_start);
            const dpc_t = ds.items(.prop_count);
            for (0..out.devices.len) |i| {
                if (std.mem.indexOf(u8, dsym[i], ".tcl") == null) continue;
                const k = symPtKey(dx[i], dy[i]);
                uf.makeSet(k);
                tcl_roots.put(arena, uf.find(k), {}) catch {};
                for (out.props.items[dps_t[i]..][0..dpc_t[i]]) |p| {
                    if (std.mem.eql(u8, p.key, "lab"))
                        tcl_labels.put(arena, p.value, {}) catch {};
                }
            }
        }

        // Build list of TCL device positions for proximity checks.
        var tcl_pos_list = std.ArrayListUnmanaged(struct { x: i32, y: i32 }){};
        {
            const dsym_p = ds.items(.symbol);
            const dx_p   = ds.items(.x);
            const dy_p   = ds.items(.y);
            for (0..out.devices.len) |i| {
                if (std.mem.indexOf(u8, dsym_p[i], ".tcl") != null)
                    tcl_pos_list.append(arena, .{ .x = dx_p[i], .y = dy_p[i] }) catch {};
            }
        }

        // Wire labels: first-wins for unlabeled nets.
        // Exclusion rules — skip labels that are:
        //   1. In a UF cluster containing a TCL generator device origin.
        //   2. A label value published by a TCL generator (e.g. "VDD" from tier.tcl).
        //   3. An XSchem internal auto-label (#netN) whose wire endpoint lies within
        //      50 grid units of a TCL generator — these are stale cached display values
        //      reflecting pins of an absent TCL generator component.
        {
            const wx0 = ws.items(.x0);
            const wy0 = ws.items(.y0);
            const wx1 = ws.items(.x1);
            const wy1 = ws.items(.y1);
            const wnn = ws.items(.net_name);
            for (0..out.wires.len) |i| {
                const raw_name = wnn[i] orelse continue;
                // Rule 3: skip stale #netN auto-labels when a TCL generator is nearby.
                if (raw_name.len > 1 and raw_name[0] == '#') {
                    var near_tcl = false;
                    for (tcl_pos_list.items) |tp| {
                        const d0 = @abs(wx0[i] - tp.x) + @abs(wy0[i] - tp.y);
                        const d1 = @abs(wx1[i] - tp.x) + @abs(wy1[i] - tp.y);
                        if (d0 <= 50 or d1 <= 50) { near_tcl = true; break; }
                    }
                    if (near_tcl) continue;
                    // Not near any TCL device — treat as authoritative auto-name.
                    const k = symPtKey(wx0[i], wy0[i]);
                    uf.makeSet(k);
                    const root = uf.find(k);
                    if (tcl_roots.contains(root)) continue;
                    const nm = raw_name[1..]; // strip leading '#'
                    if (rnFind.find(root_names.items, root) == null)
                        rnFind.insert(&root_names, arena, root, nm);
                    continue;
                }
                const k = symPtKey(wx0[i], wy0[i]);
                uf.makeSet(k);
                const root = uf.find(k);
                // Rule 1: skip if cluster contains a TCL device
                if (tcl_roots.contains(root)) continue;
                // Rule 2: skip if label matches a TCL device's lab= value
                if (tcl_labels.contains(raw_name)) continue;
                if (rnFind.find(root_names.items, root) == null)
                    rnFind.insert(&root_names, arena, root, raw_name);
            }
        }
        // Injected names (gnd/vdd/lab_pin) always overwrite wire labels.
        // Also track which UF roots are "authoritative" (directly named by a
        // lab_pin/global) so the propag=0 cascade pass can distinguish them from
        // roots whose names came only from wire-label propagation.
        var authoritative_roots = std.AutoHashMapUnmanaged(u64, void){};
        {
            const dkind = ds.items(.kind);
            const dx    = ds.items(.x);
            const dy    = ds.items(.y);
            const dps   = ds.items(.prop_start);
            const dpc   = ds.items(.prop_count);
            for (0..out.devices.len) |i| {
                const kind = dkind[i];
                const injected: ?[]const u8 = switch (kind) {
                    .gnd, .vdd, .lab_pin => blk: {
                        for (out.props.items[dps[i]..][0..dpc[i]]) |p| {
                            if (std.mem.eql(u8, p.key, "lab")) break :blk p.value;
                        }
                        if (kind == .gnd) break :blk "0";
                        if (kind == .vdd) break :blk "VDD";
                        break :blk null;
                    },
                    // Unknown devices with `lab=` act as net labels (e.g. lab_wire.sym,
                    // other label-type symbols). Exclude TCL generator symbols (.tcl paths)
                    // since their `lab=` is display-only and XSchem does not inject it.
                    .unknown => blk: {
                        // Skip TCL generator symbols — their symbol path contains ".tcl"
                        const sym = ds.items(.symbol)[i];
                        if (std.mem.indexOf(u8, sym, ".tcl") != null) break :blk null;
                        for (out.props.items[dps[i]..][0..dpc[i]]) |p| {
                            if (std.mem.eql(u8, p.key, "lab")) break :blk p.value;
                        }
                        break :blk null;
                    },
                    else => null,
                };
                if (injected) |nm| {
                    const k = symPtKey(dx[i], dy[i]);
                    uf.makeSet(k);
                    const root = uf.find(k);
                    if (rnFind.find(root_names.items, root)) |pos| {
                        root_names.items[pos].name = nm; // injected names always win
                    } else {
                        rnFind.insert(&root_names, arena, root, nm);
                    }
                    authoritative_roots.put(arena, root, {}) catch {};
                    if ((kind == .gnd or kind == .vdd) and !std.mem.eql(u8, nm, "0")) {
                        var already = false;
                        for (out.global_nets.items) |gn| {
                            if (std.mem.eql(u8, gn, nm)) { already = true; break; }
                        }
                        if (!already) out.global_nets.append(arena, try arena.dupe(u8, nm)) catch {};
                    }
                }
            }
        }

        // auto_idx and wire-endpoint naming are deferred to after the propag=0
        // cascade so that the cascade can un-name tainted components before the
        // auto-index counter is advanced, ensuring auto-names align with XSchem's.

        var root_to_id = std.AutoHashMapUnmanaged(u64, u32){};

        // Symbol pin cache
        const PinEntry = struct { name: []const u8, x: f64, y: f64, pinnumber: u32, propag: bool = true };
        var sym_cache = std.StringHashMapUnmanaged([]PinEntry){};
        var subckt_sym_set = std.StringHashMapUnmanaged(void){};
        var format_sym_map = std.StringHashMapUnmanaged([]const u8){};
        var template_sym_map = std.StringHashMapUnmanaged([]const u8){};
        var device_model_sym_map = std.StringHashMapUnmanaged([]const u8){};
        var spice_sym_def_map = std.StringHashMapUnmanaged([]const u8){};

        for (0..out.devices.len) |i| {
            const sym_path = ds.items(.symbol)[i];
            if (sym_cache.contains(sym_path)) continue;

            if (std.mem.endsWith(u8, sym_path, ".sch")) {
                subckt_sym_set.put(arena, sym_path, {}) catch {};

                const sch_file_path = findSymbolFile(arena, sym_path, sym_search_dirs) catch null;
                const sch_data: ?[]const u8 = if (sch_file_path) |sfp|
                    if (comptime is_wasm) null else std.fs.cwd().readFileAlloc(arena, sfp, 4 * 1024 * 1024) catch null
                else
                    null;

                const SchPin = struct { x: f64, y: f64, name_num: u32 };
                var sch_pin_map = std.StringHashMapUnmanaged(SchPin){};
                if (sch_data) |sdata| {
                    var tmp_arena = std.heap.ArenaAllocator.init(arena);
                    const tmp_a = tmp_arena.allocator();
                    const sch_xs = xs.XSchem.readFile(sdata, tmp_a, null);
                    const sch_insts = sch_xs.instances.slice();
                    for (0..sch_xs.instances.len) |pi| {
                        const inst_sym2 = sch_insts.items(.symbol)[pi];
                        const inst_base2 = std.fs.path.basename(inst_sym2);
                        const is_port2 = std.mem.eql(u8, inst_base2, "ipin.sym") or
                            std.mem.eql(u8, inst_base2, "opin.sym") or
                            std.mem.eql(u8, inst_base2, "iopin.sym");
                        if (!is_port2) continue;
                        const ps2 = sch_insts.items(.prop_start)[pi];
                        const pc2 = sch_insts.items(.prop_count)[pi];
                        var lab_name: ?[]const u8 = null;
                        var name_num: u32 = 0;
                        for (sch_xs.props.items[ps2..][0..pc2]) |p| {
                            if (std.mem.eql(u8, p.key, "lab")) lab_name = p.value;
                            if (std.mem.eql(u8, p.key, "name")) {
                                const nm = p.value;
                                var nstart: usize = nm.len;
                                while (nstart > 0 and nm[nstart - 1] >= '0' and nm[nstart - 1] <= '9') nstart -= 1;
                                if (nstart < nm.len) name_num = std.fmt.parseInt(u32, nm[nstart..], 10) catch 0;
                            }
                        }
                        if (lab_name) |ln| {
                            const pname_arena = arena.dupe(u8, ln) catch continue;
                            sch_pin_map.put(arena, pname_arena, .{
                                .x = sch_insts.items(.x)[pi],
                                .y = sch_insts.items(.y)[pi],
                                .name_num = name_num,
                            }) catch {};
                        }
                    }
                    tmp_arena.deinit();
                }

                // Try companion .sym for port ordering and K-block data
                const sym_variant = std.fmt.allocPrint(arena, "{s}.sym", .{sym_path[0 .. sym_path.len - 4]}) catch sym_path;
                const companion_sym_path = findSymbolFile(arena, sym_variant, sym_search_dirs) catch null;

                var sym_pin_order: ?[][]const u8 = null;
                if (companion_sym_path) |sv_path| {
                    const sv_data = if (comptime is_wasm) null else std.fs.cwd().readFileAlloc(arena, sv_path, 4 * 1024 * 1024) catch null;
                    if (sv_data) |svd| {
                        var sv_arena = std.heap.ArenaAllocator.init(arena);
                        const sv_a = sv_arena.allocator();
                        const sv_xs = xs.XSchem.readFile(svd, sv_a, null);
                        // Single-pass over K-block props
                        for (sv_xs.props.items) |p| {
                            if (std.mem.eql(u8, p.key, "format")) {
                                format_sym_map.put(arena, sym_path, arena.dupe(u8, p.value) catch continue) catch {};
                            } else if (std.mem.eql(u8, p.key, "template")) {
                                template_sym_map.put(arena, sym_path, arena.dupe(u8, p.value) catch continue) catch {};
                            }
                        }
                        var order_list: List([]const u8) = .{};
                        const sp = sv_xs.pins.slice();
                        for (0..sv_xs.pins.len) |pi| {
                            const pname_str = arena.dupe(u8, sp.items(.name)[pi]) catch continue;
                            order_list.append(arena, pname_str) catch {};
                        }
                        sym_pin_order = order_list.toOwnedSlice(arena) catch null;
                        sv_arena.deinit();
                    }
                }

                var pins_list: List(PinEntry) = .{};
                if (sym_pin_order) |order| {
                    for (order, 0..) |pname, idx| {
                        const entry = sch_pin_map.get(pname) orelse continue;
                        const pname_arena = arena.dupe(u8, pname) catch continue;
                        pins_list.append(arena, .{
                            .name      = pname_arena,
                            .x         = entry.x,
                            .y         = entry.y,
                            .pinnumber = @intCast(idx),
                        }) catch continue;
                    }
                } else {
                    var it = sch_pin_map.iterator();
                    while (it.next()) |kv| {
                        const pname_arena = arena.dupe(u8, kv.key_ptr.*) catch continue;
                        pins_list.append(arena, .{
                            .name      = pname_arena,
                            .x         = kv.value_ptr.x,
                            .y         = kv.value_ptr.y,
                            .pinnumber = kv.value_ptr.name_num,
                        }) catch continue;
                    }
                    std.sort.block(PinEntry, pins_list.items, {}, struct {
                        fn lt(_: void, lhs: PinEntry, rhs: PinEntry) bool {
                            return lhs.pinnumber < rhs.pinnumber;
                        }
                    }.lt);
                }

                if (sch_data != null) {
                    sym_cache.put(arena, sym_path, pins_list.toOwnedSlice(arena) catch continue) catch {};
                } else {
                    sym_cache.put(arena, sym_path, &.{}) catch {};
                }
                continue;
            }

            // .sym path: load and parse for pins, kind, format, template
            const sym_file_path = findSymbolFile(arena, sym_path, sym_search_dirs) catch null;
            if (sym_file_path) |sfp| {
                const data = if (comptime is_wasm) continue else std.fs.cwd().readFileAlloc(arena, sfp, 4 * 1024 * 1024) catch continue;
                var tmp_arena = std.heap.ArenaAllocator.init(arena);
                const tmp_a = tmp_arena.allocator();
                var sym_xs = xs.XSchem.readFile(data, tmp_a, null);

                var is_subckt = false;
                var type_found = false;
                var spice_sym_def_val: ?[]const u8 = null;

                // Single-pass over K-block props for format/template/type/spice_sym_def
                for (sym_xs.props.items) |p| {
                    if (std.mem.eql(u8, p.key, "type")) {
                        type_found = true;
                        is_subckt = subckt_type_map.has(p.value);
                    } else if (std.mem.eql(u8, p.key, "format")) {
                        format_sym_map.put(arena, sym_path, arena.dupe(u8, p.value) catch continue) catch {};
                    } else if (std.mem.eql(u8, p.key, "template")) {
                        template_sym_map.put(arena, sym_path, arena.dupe(u8, p.value) catch continue) catch {};
                    } else if (std.mem.eql(u8, p.key, "device_model")) {
                        if (arena.dupe(u8, p.value) catch null) |v|
                            device_model_sym_map.put(arena, sym_path, v) catch {};
                    } else if (std.mem.eql(u8, p.key, "spice_sym_def")) {
                        spice_sym_def_val = p.value;
                    }
                }

                if (!type_found and sym_xs.pins.len > 0) is_subckt = true;
                if (!is_subckt and type_found and sym_xs.pins.len > 0) {
                    // Treat as subckt unless type is explicitly in non_subckt set
                    var type_val: ?[]const u8 = null;
                    for (sym_xs.props.items) |p| {
                        if (std.mem.eql(u8, p.key, "type")) { type_val = p.value; break; }
                    }
                    if (type_val) |tv| {
                        if (!non_subckt_type_map.has(tv)) is_subckt = true;
                    }
                }
                if (is_subckt) subckt_sym_set.put(arena, sym_path, {}) catch {};

                if (spice_sym_def_val) |ssd| {
                    if (arena.dupe(u8, ssd) catch null) |v|
                        spice_sym_def_map.put(arena, sym_path, v) catch {};
                }

                const sp = sym_xs.pins.slice();
                var pins_list: List(PinEntry) = .{};
                for (0..sym_xs.pins.len) |pi| {
                    const pname = arena.dupe(u8, sp.items(.name)[pi]) catch continue;
                    const pnum = sp.items(.number)[pi] orelse @as(u32, @intCast(pi));
                    pins_list.append(arena, .{
                        .name      = pname,
                        .x         = sp.items(.x)[pi],
                        .y         = sp.items(.y)[pi],
                        .pinnumber = pnum,
                        .propag    = sp.items(.propag)[pi],
                    }) catch continue;
                }

                // Reorder by .cir subckt pin order when spice_sym_def contains .include
                if (spice_sym_def_val) |ssd| {
                    const trimmed_ssd = std.mem.trim(u8, ssd, " \t\"");
                    if (std.mem.startsWith(u8, trimmed_ssd, ".include ") or
                        std.mem.startsWith(u8, trimmed_ssd, ".INCLUDE "))
                    {
                        var fname = std.mem.trim(u8, trimmed_ssd[9..], " \t");
                        fname = std.mem.trim(u8, fname, "\"");
                        const cir_path = findSymbolFile(arena, fname, sym_search_dirs) catch null;
                        if (cir_path) |cp| {
                            const cir_data = if (comptime is_wasm) null else std.fs.cwd().readFileAlloc(arena, cp, 512 * 1024) catch null;
                            if (cir_data) |cd| {
                                var cir_pins: List([]const u8) = .{};
                                var cir_it = std.mem.splitScalar(u8, cd, '\n');
                                var in_subckt = false;
                                while (cir_it.next()) |raw_line| {
                                    const line = std.mem.trim(u8, raw_line, " \t\r");
                                    if (line.len == 0 or line[0] == '*') continue;
                                    if (!in_subckt and (std.ascii.startsWithIgnoreCase(line, ".subckt ") or
                                        std.ascii.startsWithIgnoreCase(line, ".subckt\t")))
                                    {
                                        in_subckt = true;
                                        var tok_it = std.mem.tokenizeAny(u8, line[8..], " \t");
                                        _ = tok_it.next();
                                        while (tok_it.next()) |tok| {
                                            if (std.mem.indexOfScalar(u8, tok, '=') != null) break;
                                            cir_pins.append(arena, arena.dupe(u8, tok) catch tok) catch {};
                                        }
                                    } else if (in_subckt and line[0] == '+') {
                                        var tok_it = std.mem.tokenizeAny(u8, line[1..], " \t");
                                        while (tok_it.next()) |tok| {
                                            if (std.mem.indexOfScalar(u8, tok, '=') != null) break;
                                            cir_pins.append(arena, arena.dupe(u8, tok) catch tok) catch {};
                                        }
                                    } else if (in_subckt) {
                                        break;
                                    }
                                }
                                var reordered: List(PinEntry) = .{};
                                var used_bbox = std.AutoHashMapUnmanaged(usize, void){};
                                for (cir_pins.items) |cpin| {
                                    const bbox_idx = blk: {
                                        for (pins_list.items, 0..) |pe, bidx| {
                                            if (used_bbox.contains(bidx)) continue;
                                            if (pinNameMatchesBbox(cpin, pe.name)) break :blk bidx;
                                        }
                                        break :blk null;
                                    };
                                    if (bbox_idx) |bi| {
                                        used_bbox.put(arena, bi, {}) catch {};
                                        reordered.append(arena, .{
                                            .name      = pins_list.items[bi].name,
                                            .x         = pins_list.items[bi].x,
                                            .y         = pins_list.items[bi].y,
                                            .pinnumber = @intCast(reordered.items.len),
                                        }) catch {};
                                    }
                                }
                                if (reordered.items.len > 0) {
                                    pins_list.deinit(arena);
                                    pins_list = reordered;
                                }
                            }
                        }
                    }
                }
                tmp_arena.deinit();
                // Keep B-box file order — XSchem uses file order for @pinlist expansion.
                // Symbols with spice_sym_def already set sequential pinnumbers (0,1,2,...) in
                // their reordered array, so no sort is needed there either.
                sym_cache.put(arena, sym_path, pins_list.toOwnedSlice(arena) catch continue) catch {};
            }
        }

        // Override device kind and set format/template from cached K-block data
        {
            const ds_mut = out.devices.slice();
            for (0..out.devices.len) |i| {
                const sym = ds_mut.items(.symbol)[i];
                if (ds_mut.items(.kind)[i] == .unknown and subckt_sym_set.contains(sym)) {
                    ds_mut.items(.kind)[i] = .subckt;
                }
                if (format_sym_map.get(sym)) |fmt| ds_mut.items(.format)[i] = fmt;
                if (template_sym_map.get(sym)) |tmpl| ds_mut.items(.sym_template)[i] = tmpl;
                if (device_model_sym_map.get(sym)) |dm| ds_mut.items(.sym_device_model)[i] = dm;
            }
        }

        // Union pins sharing coordinates; connect interior-of-wire pins
        {
            const dkind2 = ds.items(.kind);
            const dx2    = ds.items(.x);
            const dy2    = ds.items(.y);
            const drot2  = ds.items(.rot);
            const dflip2 = ds.items(.flip);
            const dsym2  = ds.items(.symbol);
            // Hoist wire slices for the inner wire-scan loop
            const pwx0 = ws.items(.x0);
            const pwy0 = ws.items(.y0);
            const pwx1 = ws.items(.x1);
            const pwy1 = ws.items(.y1);
            for (0..out.devices.len) |i| {
                const kind = dkind2[i];
                // Include graph (noconn) devices so their pin positions connect to wires;
                // this lets the convertToSpice pre-pass detect noconn-marked nets and
                // prevent incorrect auto-indexing of scalar pins on bus instances.
                if (kind.isNonElectrical() and kind != .graph) continue;
                const ix     = dx2[i];
                const iy     = dy2[i];
                const rot    = drot2[i];
                const flip_b = dflip2[i];
                const pins_opt = sym_cache.get(dsym2[i]);
                if (pins_opt == null) continue;
                for (pins_opt.?) |pin| {
                    const abs = applyRotFlip(f2i(pin.x), f2i(pin.y), rot, flip_b, ix, iy);
                    const k   = symPtKey(abs.x, abs.y);
                    uf.makeSet(k);
                    for (0..out.wires.len) |wi| {
                        const wx0 = pwx0[wi]; const wy0 = pwy0[wi];
                        const wx1 = pwx1[wi]; const wy1 = pwy1[wi];
                        const on_wire = blk: {
                            if (wy0 == wy1 and wy0 == abs.y) {
                                break :blk abs.x >= @min(wx0, wx1) and abs.x <= @max(wx0, wx1);
                            } else if (wx0 == wx1 and wx0 == abs.x) {
                                break :blk abs.y >= @min(wy0, wy1) and abs.y <= @max(wy0, wy1);
                            }
                            break :blk false;
                        };
                        if (on_wire) { uf.unite(symPtKey(wx0, wy0), k); break; }
                    }
                }
            }
        }

        // Unite same-named pins on all devices (doublepin style — bidirectional symbols
        // have the same pin name on both sides; bus instances need this too).
        {
            const dkind3 = ds.items(.kind);
            const dx3    = ds.items(.x);
            const dy3    = ds.items(.y);
            const drot3  = ds.items(.rot);
            const dflip3 = ds.items(.flip);
            const dsym3  = ds.items(.symbol);
            for (0..out.devices.len) |i| {
                if (dkind3[i].isNonElectrical()) continue;
                const pins_nb = sym_cache.get(dsym3[i]);
                if (pins_nb == null) continue;
                const ix_nb = dx3[i]; const iy_nb = dy3[i];
                const rot_nb = drot3[i]; const flip_nb = dflip3[i];
                var first_key_for_pin = std.StringHashMapUnmanaged(u64){};
                defer first_key_for_pin.deinit(arena);
                for (pins_nb.?) |pin| {
                    const abs = applyRotFlip(f2i(pin.x), f2i(pin.y), rot_nb, flip_nb, ix_nb, iy_nb);
                    const k = symPtKey(abs.x, abs.y);
                    if (first_key_for_pin.get(pin.name)) |fk| {
                        uf.unite(fk, k);
                    } else {
                        first_key_for_pin.put(arena, pin.name, k) catch {};
                    }
                }
            }
        }

        // Short-circuit devices with spice_ignore=short: union all their pins
        // into one net so the two nodes they straddle become the same net.
        {
            const dkind_si = ds.items(.kind);
            const dx_si    = ds.items(.x);
            const dy_si    = ds.items(.y);
            const drot_si  = ds.items(.rot);
            const dflip_si = ds.items(.flip);
            const dsym_si  = ds.items(.symbol);
            const dps_si   = ds.items(.prop_start);
            const dpc_si   = ds.items(.prop_count);
            for (0..out.devices.len) |i| {
                if (dkind_si[i].isNonElectrical()) continue;
                const props_si = out.props.items[dps_si[i]..][0..dpc_si[i]];
                const si_val = lookupPropValue(props_si, "spice_ignore") orelse continue;
                if (!std.mem.eql(u8, std.mem.trim(u8, si_val, " \t"), "short")) continue;
                const pins_si = sym_cache.get(dsym_si[i]) orelse continue;
                const ix_si = dx_si[i]; const iy_si = dy_si[i];
                const rot_si = drot_si[i]; const flip_si = dflip_si[i];
                var first_k: ?u64 = null;
                for (pins_si) |pin| {
                    const abs = applyRotFlip(f2i(pin.x), f2i(pin.y), rot_si, flip_si, ix_si, iy_si);
                    const k = symPtKey(abs.x, abs.y);
                    uf.makeSet(k);
                    if (first_k) |fk| {
                        uf.unite(fk, k);
                    } else {
                        first_k = k;
                    }
                }
            }
        }

        // propag=0 pass: pins with propag=0 (e.g. the minus terminal of an ammeter)
        // should not share a net name with a propag=1 pin of the same device.  When they
        // do, it means the propag=0 side's name came from XSchem GUI wire-label propagation
        // (which crosses propag boundaries) rather than a real lab_pin.  Remove the
        // name so the auto-naming pass below gives it a fresh internal name.
        // After the direct removal, also cascade: any OTHER non-authoritative UF root
        // that still carries a tainted name is treated as "bleed" from the same
        // boundary and gets its name removed too (e.g. downstream wire segments that
        // have the same lab= stored by the XSchem GUI).
        var tainted_names = std.StringHashMapUnmanaged(void){};
        {
            const dkind_p = ds.items(.kind);
            const dx_p    = ds.items(.x);
            const dy_p    = ds.items(.y);
            const drot_p  = ds.items(.rot);
            const dflip_p = ds.items(.flip);
            const dsym_p  = ds.items(.symbol);
            for (0..out.devices.len) |i| {
                if (dkind_p[i].isNonElectrical()) continue;
                const pins_p = sym_cache.get(dsym_p[i]) orelse continue;
                var has_p0 = false;
                for (pins_p) |pin| if (!pin.propag) { has_p0 = true; break; };
                if (!has_p0) continue;
                const ix_p = dx_p[i]; const iy_p = dy_p[i];
                const rot_p = drot_p[i]; const flip_p = dflip_p[i];
                // Collect names of propag=1 pins (typically 1-3 per device)
                var p1_names: [8][]const u8 = undefined;
                var p1_count: usize = 0;
                for (pins_p) |pin| {
                    if (!pin.propag) continue;
                    const abs = applyRotFlip(f2i(pin.x), f2i(pin.y), rot_p, flip_p, ix_p, iy_p);
                    const root = uf.find(symPtKey(abs.x, abs.y));
                    if (rnFind.find(root_names.items, root)) |idx2| {
                        if (p1_count < p1_names.len) {
                            p1_names[p1_count] = root_names.items[idx2].name;
                            p1_count += 1;
                        }
                    }
                }
                if (p1_count == 0) continue;
                // For each propag=0 pin: if its name matches a propag=1 name, remove it.
                for (pins_p) |pin| {
                    if (pin.propag) continue;
                    const abs = applyRotFlip(f2i(pin.x), f2i(pin.y), rot_p, flip_p, ix_p, iy_p);
                    const root = uf.find(symPtKey(abs.x, abs.y));
                    if (rnFind.find(root_names.items, root)) |idx2| {
                        const cur = root_names.items[idx2].name;
                        for (p1_names[0..p1_count]) |pn| {
                            if (std.mem.eql(u8, cur, pn)) {
                                _ = root_names.orderedRemove(idx2);
                                tainted_names.put(arena, cur, {}) catch {};
                                break;
                            }
                        }
                    }
                }
            }
            // Cascade: remove tainted names from all non-authoritative roots that
            // still carry them (downstream wire segments with bled GUI labels).
            // Also track which roots were tainted (needed for short.sym union below).
            var tainted_roots = std.AutoHashMapUnmanaged(u64, void){};
            var ri = root_names.items.len;
            while (ri > 0) {
                ri -= 1;
                const rn = root_names.items[ri];
                if (!tainted_names.contains(rn.name)) continue;
                if (authoritative_roots.contains(rn.root)) continue;
                tainted_roots.put(arena, rn.root, {}) catch {};
                _ = root_names.orderedRemove(ri);
            }
            // Also record any roots that were directly removed in the propag=0 pin
            // step above.  They've already been removed from root_names so we can't
            // scan them again, but we already put their names in tainted_names.  Any
            // root whose UF representative is now unnamed AND was previously in
            // root_names with a tainted name is implicitly tainted — covered above.

            // After the cascade, short.sym instances that straddle two tainted
            // components should union them.  In XSchem, such shorts are activated
            // by TCL IGNORE toggles that we cannot evaluate.  However, when BOTH
            // sides of a short.sym are tainted (unnamed after propag=0 cascade), the
            // union is always safe: both sides are already "anonymous" and merging
            // them produces the correct single auto-name that XSchem assigns to the
            // entire wrong-side region.
            if (tainted_roots.count() > 0) {
                const dkind_ts = ds.items(.kind);
                const dx_ts    = ds.items(.x);
                const dy_ts    = ds.items(.y);
                const drot_ts  = ds.items(.rot);
                const dflip_ts = ds.items(.flip);
                const dsym_ts  = ds.items(.symbol);
                const dps_ts   = ds.items(.prop_start);
                const dpc_ts   = ds.items(.prop_count);
                for (0..out.devices.len) |i| {
                    if (dkind_ts[i].isNonElectrical()) continue;
                    // Only process short.sym instances
                    const sym_base_ts = std.fs.path.basename(dsym_ts[i]);
                    if (!std.mem.eql(u8, sym_base_ts, "short.sym")) continue;
                    // Skip if explicitly ignored (spice_ignore=true or =1)
                    const props_ts = out.props.items[dps_ts[i]..][0..dpc_ts[i]];
                    if (lookupPropValue(props_ts, "spice_ignore")) |si_ts| {
                        const sv_ts = std.mem.trim(u8, si_ts, " \t\"");
                        if (std.mem.eql(u8, sv_ts, "true") or std.mem.eql(u8, sv_ts, "1")) continue;
                    }
                    const pins_ts = sym_cache.get(dsym_ts[i]) orelse continue;
                    const ix_ts = dx_ts[i]; const iy_ts = dy_ts[i];
                    const rot_ts = drot_ts[i]; const flip_ts = dflip_ts[i];
                    // Collect the unique roots for all pins
                    var pin_roots: [4]u64 = undefined;
                    var pin_root_count: usize = 0;
                    for (pins_ts) |pin| {
                        const abs = applyRotFlip(f2i(pin.x), f2i(pin.y), rot_ts, flip_ts, ix_ts, iy_ts);
                        const k = symPtKey(abs.x, abs.y);
                        uf.makeSet(k);
                        const root_ts = uf.find(k);
                        var found_dup = false;
                        for (pin_roots[0..pin_root_count]) |pr| if (pr == root_ts) { found_dup = true; break; };
                        if (!found_dup and pin_root_count < pin_roots.len) {
                            pin_roots[pin_root_count] = root_ts;
                            pin_root_count += 1;
                        }
                    }
                    // Union all pin roots that are tainted (have no current name)
                    var first_tainted: ?u64 = null;
                    for (pin_roots[0..pin_root_count]) |pr| {
                        // A root is tainted if it was removed during cascade OR if it
                        // has no current name in root_names (unnamed after cascade).
                        const is_tainted = tainted_roots.contains(pr) or
                            rnFind.find(root_names.items, pr) == null;
                        if (!is_tainted) continue;
                        if (first_tainted) |ft| {
                            uf.unite(ft, pr);
                        } else {
                            first_tainted = pr;
                        }
                    }
                }
            }
        }

        // Find first free auto-net index so new names don't collide and don't
        // skip numbers that were "freed" by a merge (e.g. #net1 absorbed into
        // NET_E means net1 is free again for the next unnamed net).
        // Pre-resolve root_names to canonical roots so merged nets show their
        // final authoritative name rather than the stale auto-name.
        var auto_idx: u32 = 1;
        var taken_auto = std.AutoHashMapUnmanaged(u32, void){};
        {
            var pre_resolved = std.AutoHashMapUnmanaged(u64, []const u8){};
            for (root_names.items) |rn| {
                const cur_root = uf.find(rn.root);
                if (pre_resolved.get(cur_root)) |existing| {
                    const is_auto_e = autoNetIndex(existing) != null;
                    const is_auto_n = autoNetIndex(rn.name) != null;
                    if (is_auto_e and !is_auto_n) {
                        pre_resolved.put(arena, cur_root, rn.name) catch {};
                    } else if (is_auto_e and is_auto_n) {
                        if (autoNetIndex(rn.name).? < autoNetIndex(existing).?) {
                            pre_resolved.put(arena, cur_root, rn.name) catch {};
                        }
                    }
                } else {
                    pre_resolved.put(arena, cur_root, rn.name) catch {};
                }
            }
            var it = pre_resolved.valueIterator();
            while (it.next()) |name| {
                if (autoNetIndex(name.*)) |num| {
                    taken_auto.put(arena, num, {}) catch {};
                }
            }
        }
        while (taken_auto.contains(auto_idx)) auto_idx += 1;

        // Auto-name unlabeled wire net endpoints.
        {
            const awx0 = ws.items(.x0);
            const awy0 = ws.items(.y0);
            const awx1 = ws.items(.x1);
            const awy1 = ws.items(.y1);
            for (0..out.wires.len) |i| {
                for ([2]u64{
                    symPtKey(awx0[i], awy0[i]),
                    symPtKey(awx1[i], awy1[i]),
                }) |k| {
                    const root = uf.find(k);
                    if (rnFind.find(root_names.items, root) == null) {
                        const nm = std.fmt.allocPrint(arena, "net{d}", .{auto_idx}) catch {
                            auto_idx += 1;
                            while (taken_auto.contains(auto_idx)) auto_idx += 1;
                            continue;
                        };
                        rnFind.insert(&root_names, arena, root, nm);
                        auto_idx += 1;
                        while (taken_auto.contains(auto_idx)) auto_idx += 1;
                    }
                }
            }
        }

        // Auto-name unlabeled sets that contain at least one pin
        {
            const dkind4 = ds.items(.kind);
            const dx4    = ds.items(.x);
            const dy4    = ds.items(.y);
            const drot4  = ds.items(.rot);
            const dflip4 = ds.items(.flip);
            const dsym4  = ds.items(.symbol);
            for (0..out.devices.len) |i| {
                if (dkind4[i].isNonElectrical()) continue;
                const pins_opt = sym_cache.get(dsym4[i]);
                if (pins_opt == null) continue;
                const ix     = dx4[i]; const iy     = dy4[i];
                const rot    = drot4[i]; const flip_b = dflip4[i];
                for (pins_opt.?) |pin| {
                    const abs = applyRotFlip(f2i(pin.x), f2i(pin.y), rot, flip_b, ix, iy);
                    const k   = symPtKey(abs.x, abs.y);
                    const root = uf.find(k);
                    if (rnFind.find(root_names.items, root) == null) {
                        const nm = std.fmt.allocPrint(arena, "net{d}", .{auto_idx}) catch {
                            auto_idx += 1;
                            while (taken_auto.contains(auto_idx)) auto_idx += 1;
                            continue;
                        };
                        rnFind.insert(&root_names, arena, root, nm);
                        auto_idx += 1;
                        while (taken_auto.contains(auto_idx)) auto_idx += 1;
                    }
                }
            }
        }

        // Build net list: re-resolve stale roots (UF path compression may alias
        // two root_names entries to the same canonical root). Prefer user-defined
        // names over auto-generated ones; among auto names, keep the lower index.
        {
            const ResolvedName = struct { root: u64, name: []const u8 };
            var resolved = List(ResolvedName){};
            const resolvedFind = struct {
                fn find(items: []const ResolvedName, root: u64) ?usize {
                    var lo: usize = 0;
                    var hi: usize = items.len;
                    while (lo < hi) {
                        const mid = lo + (hi - lo) / 2;
                        if (items[mid].root < root) lo = mid + 1 else hi = mid;
                    }
                    return if (lo < items.len and items[lo].root == root) lo else null;
                }
                fn insert(items: *List(ResolvedName), alloc_: Allocator, root: u64, name: []const u8) void {
                    var lo: usize = 0;
                    var hi: usize = items.items.len;
                    while (lo < hi) {
                        const mid = lo + (hi - lo) / 2;
                        if (items.items[mid].root < root) lo = mid + 1 else hi = mid;
                    }
                    items.insert(alloc_, lo, .{ .root = root, .name = name }) catch {};
                }
            };
            for (root_names.items) |rn| {
                const cur_root = uf.find(rn.root);
                const nm = rn.name;
                if (resolvedFind.find(resolved.items, cur_root)) |pos| {
                    const existing = resolved.items[pos].name;
                    const is_auto_e = autoNetIndex(existing) != null;
                    const is_auto_n = autoNetIndex(nm) != null;
                    if (is_auto_e and !is_auto_n) {
                        resolved.items[pos].name = nm;
                    } else if (is_auto_e and is_auto_n) {
                        const num_e = autoNetIndex(existing).?;
                        const num_n = autoNetIndex(nm).?;
                        if (num_n < num_e) resolved.items[pos].name = nm;
                    }
                } else {
                    resolvedFind.insert(&resolved, arena, cur_root, nm);
                }
            }
            for (resolved.items) |rn| {
                const nid: u32 = @intCast(out.net_names.items.len);
                try out.net_names.append(arena, try arena.dupe(u8, rn.name));
                root_to_id.put(arena, rn.root, nid) catch {};
            }
        }

        // Per-pin connectivity to device_nets — hoist MAL slices
        {
            const dkind5 = ds.items(.kind);
            const dx5    = ds.items(.x);
            const dy5    = ds.items(.y);
            const drot5  = ds.items(.rot);
            const dflip5 = ds.items(.flip);
            const dsym5  = ds.items(.symbol);
            for (0..out.devices.len) |i| {
                // Include graph (noconn) for device_nets so convertToSpice can mark their nets.
                if (dkind5[i].isNonElectrical() and dkind5[i] != .graph) continue;
                const ix     = dx5[i]; const iy     = dy5[i];
                const rot    = drot5[i]; const flip_b = dflip5[i];
                const pins_opt = sym_cache.get(dsym5[i]);
                if (pins_opt == null or pins_opt.?.len == 0) {
                    const k = symPtKey(ix, iy);
                    uf.makeSet(k);
                    const nid = root_to_id.get(uf.find(k)) orelse continue;
                    try out.device_nets.append(arena, .{
                        .device_idx = @intCast(i),
                        .pin_name   = "",
                        .net_id     = nid,
                    });
                    continue;
                }
                for (pins_opt.?) |pin| {
                    const abs = applyRotFlip(f2i(pin.x), f2i(pin.y), rot, flip_b, ix, iy);
                    const k   = symPtKey(abs.x, abs.y);
                    uf.makeSet(k);
                    const nid = root_to_id.get(uf.find(k)) orelse continue;
                    try out.device_nets.append(arena, .{
                        .device_idx = @intCast(i),
                        .pin_name   = try arena.dupe(u8, pin.name),
                        .net_id     = nid,
                    });
                }
            }
        }

        // Store S {} block body
        if (x.spice_body) |sb| {
            const trimmed_sb = std.mem.trim(u8, sb, " \t\r\n");
            if (trimmed_sb.len > 0) {
                if (out.device_nets.items.len == 0) {
                    out.spice_body = arena.dupe(u8, sb) catch "";
                } else {
                    out.spice_s_block = arena.dupe(u8, sb) catch "";
                }
            }
        }

        return out;
    }

    pub fn generateSpice(
        self: *const Netlister,
        a: Allocator,
        registry: *const dev.Pdk,
    ) ![]u8 {
        var preamble_buf: List(u8) = .{};
        defer preamble_buf.deinit(a);
        if (!registry.isEmpty()) {
            var cell_names: List([]const u8) = .{};
            defer cell_names.deinit(a);
            const ds = self.devices.slice();
            for (0..self.devices.len) |i| {
                try cell_names.append(a, ds.items(.symbol)[i]);
            }
            const preamble = try registry.emitPreamble(a, cell_names.items, null);
            defer a.free(preamble);
            if (preamble.len > 0) try preamble_buf.appendSlice(a, preamble);
        }

        const body = try self.generateSpiceFor(a, .ngspice);
        defer a.free(body);

        if (preamble_buf.items.len == 0) return a.dupe(u8, body);

        var out: List(u8) = .{};
        defer out.deinit(a);
        const nl_pos = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
        try out.appendSlice(a, body[0 .. nl_pos + 1]);
        try out.appendSlice(a, preamble_buf.items);
        try out.appendSlice(a, body[nl_pos + 1 ..]);
        return out.toOwnedSlice(a);
    }

    pub fn generateSpiceFor(
        self: *const Netlister,
        a: Allocator,
        backend: spice.Backend,
    ) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const ta = arena.allocator();

        // Raw SPICE body path (extracted netlist schematics)
        if (self.spice_body.len > 0 and self.name.len > 0) {
            const xspice_pfx2: []const u8 = if (self.xspice_port_prefix) "a_" else "";
            var header: List(u8) = .{};
            try header.appendSlice(ta, ".subckt ");
            try header.appendSlice(ta, self.name);
            for (self.pins.items) |pin| {
                try appendExpandedPinNamePrefixed(&header, pin.name, xspice_pfx2, ta);
            }
            if (self.subckt_defaults.len > 0) {
                try header.appendSlice(ta, "  ");
                try header.appendSlice(ta, self.subckt_defaults);
            }
            var out: List(u8) = .{};
            try out.appendSlice(ta, "* Schemify netlist\n");
            try out.appendSlice(ta, header.items);
            try out.append(ta, '\n');
            try out.appendSlice(ta, self.spice_body);
            try out.append(ta, '\n');
            try out.appendSlice(ta, ".ends\n");
            return a.dupe(u8, out.items);
        }

        var nl2 = try convertToSpice(self, ta);
        const body = try nl2.emit(backend, ta);

        if (self.name.len == 0) return a.dupe(u8, body);

        // Build .subckt header
        var header: List(u8) = .{};
        try header.appendSlice(ta, ".subckt ");
        try header.appendSlice(ta, self.name);
        // XSchem suppresses port listing when BOTH G-block (VHDL) AND V-block (Verilog)
        // have content, and only for the top-level schematic (not sub-circuits), AND only
        // when no explicit pins have been provided (e.g. from a companion .sym file).
        // If explicit pins are set they always take priority — never suppress them.
        // XSchem adds "a_" prefix to all port names in the .subckt header when the
        // schematic contains xspice element lines (lines starting with 'A' + digit).
        const xspice_pfx: []const u8 = if (self.xspice_port_prefix) "a_" else "";
        if (self.pins.items.len == 0 and self.ghdl_body != null and self.verilog_body != null and self.is_toplevel) {
            // emit .subckt name with no port list
        } else if (self.pins.items.len > 0) {
            var seen = std.StringHashMapUnmanaged(void){};
            defer seen.deinit(ta);
            for (self.pins.items) |pin| {
                if (seen.contains(pin.name)) continue;
                try seen.put(ta, pin.name, {});
                try appendExpandedPinNamePrefixed(&header, pin.name, xspice_pfx, ta);
            }
        } else {
            // XSchem path: scan for ipin/opin/iopin sorted by pN suffix
            const PortEntry = struct { pnum: u32, file_idx: usize, lab: []const u8 };
            var ports: List(PortEntry) = .{};
            defer ports.deinit(ta);
            const ds = self.devices.slice();
            for (0..self.devices.len) |i| {
                const sym = ds.items(.symbol)[i];
                if (!isPortSymbol(sym)) continue;
                const ps = ds.items(.prop_start)[i];
                const pc = ds.items(.prop_count)[i];
                const props = self.props.items[ps..][0..pc];
                const lab = lookupPropValue(props, "lab") orelse continue;
                const pname = lookupPropValue(props, "name") orelse "";
                var pnum: u32 = @intCast(i);
                if (pname.len > 1 and pname[0] == 'p') {
                    pnum = std.fmt.parseInt(u32, pname[1..], 10) catch @intCast(i);
                }
                try ports.append(ta, .{ .pnum = pnum, .file_idx = i, .lab = lab });
            }
            std.sort.block(PortEntry, ports.items, {}, struct {
                fn lt(_: void, lhs: PortEntry, rhs: PortEntry) bool {
                    if (lhs.pnum != rhs.pnum) return lhs.pnum < rhs.pnum;
                    return lhs.file_idx < rhs.file_idx;
                }
            }.lt);
            for (ports.items) |pe| {
                try appendExpandedPinNamePrefixed(&header, pe.lab, xspice_pfx, ta);
            }
        }

        if (self.subckt_defaults.len > 0) {
            try header.appendSlice(ta, "  ");
            try header.appendSlice(ta, self.subckt_defaults);
        }

        const nl_pos = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
        var out: List(u8) = .{};
        try out.appendSlice(ta, body[0 .. nl_pos + 1]);
        try out.appendSlice(ta, header.items);
        try out.append(ta, '\n');
        try out.appendSlice(ta, body[nl_pos + 1 ..]);
        if (!std.mem.endsWith(u8, std.mem.trimRight(u8, out.items, " \t\r\n"), ".ends")) {
            try out.appendSlice(ta, ".ends\n");
        }

        // Collect globals across self and all children
        var all_globals = std.StringHashMapUnmanaged(void){};
        for (self.global_nets.items) |gn| all_globals.put(ta, gn, {}) catch {};

        if (self.sym_search_dirs.len > 0) {
            var emitted_names = std.StringHashMapUnmanaged(void){};
            const SubcktRef = struct {
                sym_path: []const u8,
                name: []const u8,
                /// When schematic= override is used but the override .sch does not exist,
                /// fall back to finding the .sch from this original sym path.
                fallback_sym_path: ?[]const u8 = null,
                /// Instance-level parameters (e.g. DEL=5) from the parent that references
                /// this subckt. Used to substitute @PARAM in child expr() values.
                parent_params: []const DeviceProp = &.{},
                /// When true, bare parameter-name references in device values are substituted
                /// with parent instance values.  Only set for named-variant subckts.
                inline_parent_params: bool = false,
            };
            var queue: List(SubcktRef) = .{};
            defer queue.deinit(ta);

            // Seed queue from current schematic's subckt instances
            {
                const ds_sub = self.devices.slice();
                for (0..self.devices.len) |i| {
                    if (ds_sub.items(.kind)[i] != .subckt) continue;
                    const sym_path = ds_sub.items(.symbol)[i];
                    const ps = ds_sub.items(.prop_start)[i];
                    const pc = ds_sub.items(.prop_count)[i];
                    const inst_props = self.props.items[ps..][0..pc];
                    // When schematic= ends in ".sch", treat it as a direct override pointing
                    // to a different schematic file.  When it has no extension (e.g.
                    // schematic=passgate_1), XSchem treats the value as a variant name: it
                    // emits a second subckt using the original schematic body but named after
                    // the variant.  In that case we queue BOTH the base symbol (passgate) AND
                    // the variant (passgate_1) so both subckts are emitted.
                    const sch_override_raw = lookupPropValue(inst_props, "schematic");
                    const sch_override: ?[]const u8 = if (sch_override_raw) |sov|
                        if (std.ascii.endsWithIgnoreCase(sov, ".sch")) sov else null
                    else
                        null;
                    // Name-only variant (no .sch extension): e.g. schematic=passgate_1
                    const variant_name: ?[]const u8 = if (sch_override == null)
                        sch_override_raw
                    else
                        null;
                    const effective_stem = if (sch_override) |sov| blk: {
                        const ov_base = std.fs.path.basename(sov);
                        break :blk if (std.mem.lastIndexOfScalar(u8, ov_base, '.')) |d| ov_base[0..d] else ov_base;
                    } else blk: {
                        const base = std.fs.path.basename(sym_path);
                        break :blk if (std.mem.lastIndexOfScalar(u8, base, '.')) |d| base[0..d] else base;
                    };
                    if (!emitted_names.contains(effective_stem)) {
                        try emitted_names.put(ta, effective_stem, {});
                        const effective_sym_path = if (sch_override != null)
                            try std.fmt.allocPrint(ta, "{s}.sch", .{effective_stem})
                        else
                            sym_path;
                        // Collect instance-level parameters (e.g. DEL=5) to pass into the child
                        // form so that @PARAM tokens in expr() values can be substituted.
                        // When a named variant (schematic=NAME) exists, the base subckt uses
                        // template defaults (not instance values), so don't propagate params
                        // to avoid accidentally substituting bare parameter name references.
                        var inst_param_list: List(DeviceProp) = .{};
                        if (variant_name == null) {
                            for (inst_props) |p| {
                                if (xschem_skip_map.has(p.key)) continue;
                                inst_param_list.append(ta, p) catch {};
                            }
                        }
                        try queue.append(ta, .{
                            .sym_path = effective_sym_path,
                            .name = effective_stem,
                            .fallback_sym_path = if (sch_override != null) sym_path else null,
                            .parent_params = inst_param_list.items,
                        });
                    }
                    // Also enqueue the variant subckt (schematic=NAME without .sch extension).
                    // XSchem emits a separate .subckt NAME block backed by the same schematic.
                    if (variant_name) |vname| {
                        if (!emitted_names.contains(vname)) {
                            try emitted_names.put(ta, vname, {});
                            const sym_dir_v = std.fs.path.dirname(sym_path);
                            const vname_sch = if (sym_dir_v) |d|
                                try std.fmt.allocPrint(ta, "{s}/{s}.sch", .{ d, vname })
                            else
                                try std.fmt.allocPrint(ta, "{s}.sch", .{vname});
                            var vinst_param_list: List(DeviceProp) = .{};
                            for (inst_props) |p| {
                                if (xschem_skip_map.has(p.key)) continue;
                                vinst_param_list.append(ta, p) catch {};
                            }
                            try queue.append(ta, .{
                                .sym_path = vname_sch,
                                .name = vname,
                                .fallback_sym_path = sym_path,
                                .parent_params = vinst_param_list.items,
                                .inline_parent_params = true,
                            });
                        }
                    }
                }
            }

            while (queue.items.len > 0) {
                const ref = queue.orderedRemove(0);
                const base = std.fs.path.basename(ref.sym_path);
                const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |d| base[0..d] else base;
                // Preserve directory component from ref.sym_path so that findSymbolFile
                // looks in the correct library subdirectory (e.g. "sky130_tests/not.sch"
                // rather than just "not.sch"), preventing wrong files from being found
                // via the basename-only fallback search.
                const sym_dir = std.fs.path.dirname(ref.sym_path);
                const sch_name = if (sym_dir) |d| try std.fmt.allocPrint(ta, "{s}/{s}.sch", .{ d, stem }) else try std.fmt.allocPrint(ta, "{s}.sch", .{stem});
                const sym_name = if (sym_dir) |d| try std.fmt.allocPrint(ta, "{s}/{s}.sym", .{ d, stem }) else try std.fmt.allocPrint(ta, "{s}.sym", .{stem});

                // Check for spice_sym_def= to emit .include directly
                const sym_file_for_ssd = findSymbolFile(ta, sym_name, self.sym_search_dirs) catch null;
                if (sym_file_for_ssd) |sfp_ssd| {
                    const ssd_data = if (comptime is_wasm) null else std.fs.cwd().readFileAlloc(ta, sfp_ssd, 4 * 1024 * 1024) catch null;
                    if (ssd_data) |sd| {
                        const ssd_xs = xs.XSchem.readFile(sd, ta, null);
                        var ssd_val: ?[]const u8 = null;
                        for (ssd_xs.props.items) |p| {
                            if (std.mem.eql(u8, p.key, "spice_sym_def")) { ssd_val = p.value; break; }
                        }
                        if (ssd_val) |ssd| {
                            const trimmed_ssd = std.mem.trim(u8, ssd, " \t\"");
                            try out.appendSlice(ta, trimmed_ssd);
                            try out.append(ta, '\n');
                            continue;
                        }
                    }
                }

                var actual_sym_name = sym_name;
                var sch_file_path = findSymbolFile(ta, sch_name, self.sym_search_dirs) catch null;
                // If the override .sch doesn't exist, fall back to the original sym's .sch.
                // This happens when schematic=foo.sch is specified but foo.sch doesn't exist
                // on disk — XSchem uses the original schematic but names the subckt after foo.
                if (sch_file_path == null) {
                    if (ref.fallback_sym_path) |fbsp| {
                        const fb_base = std.fs.path.basename(fbsp);
                        const fb_stem = if (std.mem.lastIndexOfScalar(u8, fb_base, '.')) |d| fb_base[0..d] else fb_base;
                        const fb_dir = std.fs.path.dirname(fbsp);
                        const fb_sch = if (fb_dir) |d| try std.fmt.allocPrint(ta, "{s}/{s}.sch", .{ d, fb_stem }) else try std.fmt.allocPrint(ta, "{s}.sch", .{fb_stem});
                        const fb_sym = if (fb_dir) |d| try std.fmt.allocPrint(ta, "{s}/{s}.sym", .{ d, fb_stem }) else try std.fmt.allocPrint(ta, "{s}.sym", .{fb_stem});
                        sch_file_path = findSymbolFile(ta, fb_sch, self.sym_search_dirs) catch null;
                        if (sch_file_path != null) actual_sym_name = fb_sym;
                    }
                }
                if (sch_file_path == null) continue;
                const sch_data = if (comptime is_wasm) continue else std.fs.cwd().readFileAlloc(ta, sch_file_path.?, 128 * 1024 * 1024) catch continue;

                var child_xs = xs.XSchem.readFile(sch_data, ta, null);
                // Use ref.name (the subcircuit name, e.g. "test_evaluated_param2") not stem
                // which may differ when falling back to the original schematic.
                child_xs.name = ref.name;

                var child_form = fromXSchemWithSymbols(ta, &child_xs, self.sym_search_dirs) catch continue;
                child_form.sym_search_dirs = &.{};
                child_form.is_toplevel = false;
                // Propagate parent instance parameters so child can substitute @PARAM tokens.
                child_form.parent_params = ref.parent_params;
                child_form.inline_parent_params = ref.inline_parent_params;

                if (child_xs.spice_body) |sb| {
                    if (child_form.device_nets.items.len == 0) {
                        const child_a = child_form.arena.allocator();
                        child_form.spice_body = child_a.dupe(u8, sb) catch "";
                    }
                }

                // Load .sym for correct pin order and template defaults
                const sym_file_path = findSymbolFile(ta, actual_sym_name, self.sym_search_dirs) catch null;
                const child_a = child_form.arena.allocator();
                if (sym_file_path) |sfp| {
                    const sym_data = if (comptime is_wasm) null else std.fs.cwd().readFileAlloc(ta, sfp, 4 * 1024 * 1024) catch null;
                    if (sym_data) |sd| {
                        var sym_xs = xs.XSchem.readFile(sd, ta, null);
                        child_form.pins.clearRetainingCapacity();
                        const sp = sym_xs.pins.slice();

                        var pin_dir_map_child = std.StringHashMapUnmanaged(sch.PinDir){};
                        defer pin_dir_map_child.deinit(child_a);
                        for (0..sym_xs.pins.len) |pi| {
                            const pname = sp.items(.name)[pi];
                            const dir = sch.PinDir.fromStr(sp.items(.direction)[pi].toStr());
                            pin_dir_map_child.put(child_a, pname, dir) catch {};
                        }

                        var format_str_child: ?[]const u8 = null;
                        for (sym_xs.props.items) |p| {
                            if (std.mem.eql(u8, p.key, "format")) { format_str_child = p.value; break; }
                        }
                        const has_explicit_pins_child = if (format_str_child) |fs|
                            std.mem.indexOf(u8, fs, "@@") != null and
                                std.mem.indexOf(u8, fs, "@pinlist") == null
                        else
                            false;

                        if (has_explicit_pins_child) {
                            const fs = format_str_child.?;
                            var fpos: usize = 0;
                            while (fpos < fs.len) {
                                const at = std.mem.indexOfPos(u8, fs, fpos, "@@") orelse break;
                                fpos = at + 2;
                                var fend = fpos;
                                while (fend < fs.len and fs[fend] != ' ' and fs[fend] != '"' and
                                    fs[fend] != '\t' and fs[fend] != '\n') : (fend += 1) {}
                                if (fend > fpos) {
                                    const pname = fs[fpos..fend];
                                    // Skip individual bus-bit pins like DATA_FROM_HASH[0].
                                    // XSchem does not include per-bit bus elements in the
                                    // child subckt header; only scalar port names are emitted.
                                    if (!isSingleBitBusElement(pname)) {
                                        const dir = pin_dir_map_child.get(pname) orelse .inout;
                                        try child_form.pins.append(child_a, .{
                                            .name = try child_a.dupe(u8, pname),
                                            .dir  = dir,
                                        });
                                    }
                                }
                                fpos = fend;
                            }
                        } else {
                            for (0..sym_xs.pins.len) |pi| {
                                const pname = try child_a.dupe(u8, sp.items(.name)[pi]);
                                const dir = sch.PinDir.fromStr(sp.items(.direction)[pi].toStr());
                                try child_form.pins.append(child_a, .{ .name = pname, .dir = dir });
                            }
                        }

                        var extra_port_names: std.StringHashMapUnmanaged(void) = .{};
                        defer extra_port_names.deinit(child_a);
                        // Read the format string from the sym so we can test whether
                        // an extra= name is a real SPICE port (@name) or just a TCL
                        // parameter that happens to appear in extra= (e.g. DEL in
                        // test_evaluated_param.sym whose format has no @DEL token).
                        var sym_format: []const u8 = "";
                        for (sym_xs.props.items) |p| {
                            if (std.mem.eql(u8, p.key, "format")) { sym_format = p.value; break; }
                        }
                        for (sym_xs.props.items) |p| {
                            if (std.mem.eql(u8, p.key, "extra")) {
                                var extra_it = std.mem.tokenizeScalar(u8, p.value, ' ');
                                while (extra_it.next()) |port_name| {
                                    const trimmed_port = std.mem.trim(u8, port_name, "\"");
                                    if (trimmed_port.len == 0) continue;
                                    // An extra= name is a true SPICE port only when the
                                    // format string references it as @<name>.  Without
                                    // that reference (e.g. extra=DEL in a sym whose
                                    // format is "@name @pinlist @symname") it is a TCL
                                    // parameter used for template expansion only.
                                    if (sym_format.len > 0) {
                                        const at_name = std.fmt.allocPrint(child_a, "@{s}", .{trimmed_port}) catch continue;
                                        const found = std.mem.indexOf(u8, sym_format, at_name) != null;
                                        if (!found) {
                                            extra_port_names.put(child_a, trimmed_port, {}) catch {};
                                            continue;
                                        }
                                    }
                                    try child_form.pins.append(child_a, .{
                                        .name = try child_a.dupe(u8, trimmed_port),
                                        .dir  = .inout,
                                    });
                                    extra_port_names.put(child_a, trimmed_port, {}) catch {};
                                }
                                break;
                            }
                        }
                        for (sym_xs.props.items) |p| {
                            if (std.mem.eql(u8, p.key, "template")) {
                                child_form.subckt_defaults = try extractTemplateDefaults(
                                    child_a, p.value, &extra_port_names);
                                break;
                            }
                        }
                    }
                } else {
                    for (child_xs.props.items) |p| {
                        if (std.mem.eql(u8, p.key, "template")) {
                            child_form.subckt_defaults = try extractTemplateDefaults(child_a, p.value, null);
                            break;
                        }
                    }
                }

                for (child_form.global_nets.items) |gn| all_globals.put(ta, gn, {}) catch {};

                const child_spice = child_form.generateSpiceFor(ta, backend) catch continue;
                const child_body = blk: {
                    const nl_pos2 = std.mem.indexOfScalar(u8, child_spice, '\n') orelse child_spice.len;
                    const after = child_spice[nl_pos2..];
                    break :blk if (after.len > 0 and after[0] == '\n') after[1..] else after;
                };
                try out.appendSlice(ta, child_body);

                // Enqueue child's subcircuits
                const child_ds = child_form.devices.slice();
                for (0..child_form.devices.len) |i| {
                    if (child_ds.items(.kind)[i] != .subckt) continue;
                    const child_sym = child_ds.items(.symbol)[i];
                    const child_base = std.fs.path.basename(child_sym);
                    const child_stem = if (std.mem.lastIndexOfScalar(u8, child_base, '.')) |d| child_base[0..d] else child_base;
                    if (emitted_names.contains(child_stem)) continue;
                    try emitted_names.put(ta, child_stem, {});
                    try queue.append(ta, .{ .sym_path = child_sym, .name = child_stem });
                }
            }
        }

        // .GLOBAL declarations (top-level only) — emitted before toplevel code blocks
        // to match XSchem's output order (.GLOBAL first, then .MODEL/.subckt defs).
        if (self.is_toplevel) {
            var git = all_globals.keyIterator();
            while (git.next()) |gn| {
                try out.appendSlice(ta, ".GLOBAL ");
                try out.appendSlice(ta, gn.*);
                try out.append(ta, '\n');
            }
        }

        // Toplevel code blocks (.SUBCKT/.MODEL defs from device_model=)
        {
            var tl_buf: List(u8) = .{};
            defer tl_buf.deinit(ta);
            nl2.emitToplevelCodeBlocks(tl_buf.writer(ta)) catch {};
            if (tl_buf.items.len > 0) try out.appendSlice(ta, tl_buf.items);
        }

        return a.dupe(u8, out.items);
    }
};

// ── Backward-compat alias ────────────────────────────────────────────────── //

/// Alias for callers that reference `UniversalNetlistForm` directly.
pub const UniversalNetlistForm = Netlister;

// ── Public entry point ───────────────────────────────────────────────────── //

/// Generate a SPICE netlist from a `Netlister`. Returns null if no devices present.
pub fn GenerateNetlist(obj: Netlister) ?[]u8 {
    if (obj.devices.len == 0) return null;
    var mutable_obj = obj;
    const a = mutable_obj.arena.allocator();
    return mutable_obj.generateSpiceFor(a, .ngspice) catch null;
}

// ── Xschem-internal prop keys to skip on subcircuit instances ──────────────

const xschem_skip_map = std.StaticStringMap(void).initComptime(.{
    .{ "name", {} },            .{ "lab", {} },              .{ "pinnumber", {} },
    .{ "pintype", {} },         .{ "pinnamesvisible", {} },  .{ "savecurrent", {} },
    .{ "spice_ignore", {} },    .{ "program", {} },          .{ "tclcommand", {} },
    .{ "device_model", {} },    .{ "verilog_ignore", {} },   .{ "vhdl_ignore", {} },
    .{ "xvalue", {} },          .{ "current", {} },          .{ "conduct", {} },
    .{ "val", {} },             .{ "only_toplevel", {} },    .{ "format", {} },
    .{ "template", {} },        .{ "schematic", {} },        .{ "sig_type", {} },
    .{ "comm", {} },            .{ "verilog_type", {} },     .{ "xschematic", {} },
    .{ "xspice_sym_def", {} },  .{ "spice_sym_def", {} },    .{ "xdefault_schematic", {} },
});

// ── Port symbol base names (ipin/opin/iopin in xschem schematics) ─────────

/// Returns true if the device's symbol is an XSchem port pin declaration.
pub fn isPortSymbol(symbol: []const u8) bool {
    const base = if (std.mem.lastIndexOfScalar(u8, symbol, '/')) |i| symbol[i + 1 ..] else symbol;
    return std.mem.eql(u8, base, "ipin.sym") or
        std.mem.eql(u8, base, "opin.sym") or
        std.mem.eql(u8, base, "iopin.sym");
}

// ── Bus expansion helpers ─────────────────────────────────────────────────── //

const BusRange = struct {
    prefix: []const u8,
    hi: i32,
    lo: i32,
    suffix: []const u8,
};

fn parseBusRange(name: []const u8) ?BusRange {
    const ob = std.mem.indexOfScalar(u8, name, '[') orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, name, ob + 1, ':') orelse return null;
    const cb = std.mem.indexOfScalarPos(u8, name, colon + 1, ']') orelse return null;
    const hi = std.fmt.parseInt(i32, name[ob + 1 .. colon], 10) catch return null;
    const lo = std.fmt.parseInt(i32, name[colon + 1 .. cb], 10) catch return null;
    return .{ .prefix = name[0..ob], .hi = hi, .lo = lo, .suffix = name[cb + 1 ..] };
}

fn expandBusNetByPos(net: []const u8, pos: u32, a: Allocator) []const u8 {
    if (std.mem.indexOfScalar(u8, net, ',') != null) {
        var it = std.mem.tokenizeScalar(u8, net, ',');
        var elem_idx: u32 = 0;
        while (it.next()) |elem| {
            if (elem_idx == pos) return elem;
            elem_idx += 1;
        }
        return net;
    }
    const ob = std.mem.indexOfScalar(u8, net, '[') orelse return net;
    var sep_start: usize = 0;
    var sep_end: usize = 0;
    var use_dot_notation = false;
    if (std.mem.indexOfScalarPos(u8, net, ob + 1, ':')) |colon| {
        sep_start = colon;
        sep_end = colon + 1;
    } else if (std.mem.indexOfPos(u8, net, ob + 1, "..")) |dot2| {
        sep_start = dot2;
        sep_end = dot2 + 2;
        use_dot_notation = true;
    } else return net;
    const cb = std.mem.indexOfScalarPos(u8, net, sep_end, ']') orelse return net;
    const hi = std.fmt.parseInt(i32, net[ob + 1 .. sep_start], 10) catch return net;
    const lo = std.fmt.parseInt(i32, net[sep_end .. cb], 10) catch return net;
    const size: i32 = @as(i32, @intCast(@abs(hi - lo))) + 1;
    if (@as(i32, @intCast(pos)) >= size) return net;
    const idx: i32 = if (hi >= lo) hi - @as(i32, @intCast(pos)) else hi + @as(i32, @intCast(pos));
    const prefix = net[0..ob];
    const suffix = net[cb + 1 ..];
    if (use_dot_notation) {
        return std.fmt.allocPrint(a, "{s}{d}{s}", .{ prefix, idx, suffix }) catch net;
    } else {
        return std.fmt.allocPrint(a, "{s}[{d}]{s}", .{ prefix, idx, suffix }) catch net;
    }
}

fn expandBusNet(a: Allocator, net: []const u8, out: *std.ArrayListUnmanaged(u8)) bool {
    const ob = std.mem.indexOfScalar(u8, net, '[') orelse return false;
    var sep_start: usize = 0;
    var sep_end: usize = 0;
    var use_dot = false;
    if (std.mem.indexOfScalarPos(u8, net, ob + 1, ':')) |colon| {
        sep_start = colon;
        sep_end = colon + 1;
    } else if (std.mem.indexOfPos(u8, net, ob + 1, "..")) |dot2| {
        sep_start = dot2;
        sep_end = dot2 + 2;
        use_dot = true;
    } else return false;
    const cb = std.mem.indexOfScalarPos(u8, net, sep_end, ']') orelse return false;
    const hi = std.fmt.parseInt(i32, net[ob + 1 .. sep_start], 10) catch return false;
    const lo = std.fmt.parseInt(i32, net[sep_end .. cb], 10) catch return false;
    const prefix = net[0..ob];
    const suffix = net[cb + 1 ..];
    const step: i32 = if (hi >= lo) -1 else 1;
    var idx = hi;
    var first = true;
    while (true) {
        if (!first) out.append(a, ' ') catch {};
        first = false;
        if (use_dot) {
            const s = std.fmt.allocPrint(a, "{s}{d}{s}", .{ prefix, idx, suffix }) catch break;
            out.appendSlice(a, s) catch {};
        } else {
            const s = std.fmt.allocPrint(a, "{s}[{d}]{s}", .{ prefix, idx, suffix }) catch break;
            out.appendSlice(a, s) catch {};
        }
        if (idx == lo) break;
        idx += step;
    }
    return true;
}

// ── Convert Netlister → SPICE IR ─────────────────────────────────────────── //

/// Convert a `Netlister` (UniversalNetlistForm) into a typed `univ.Netlist`.
/// The returned Netlist owns its data; caller must call `deinit()`.
fn convertToSpice(form: *const Netlister, a: Allocator) error{OutOfMemory}!univ.Netlist {
    var netlist = univ.Netlist.init(a);
    errdefer netlist.deinit();

    netlist.title = "* Schemify netlist";

    // Pre-pass: collect Tcl variable definitions from code blocks.
    var tcl_vars = std.StringHashMapUnmanaged([]const u8){};
    defer tcl_vars.deinit(a);
    {
        const slice_pre = form.devices.slice();
        for (0..form.devices.len) |i| {
            if (slice_pre.items(.kind)[i] != .code) continue;
            const ps = slice_pre.items(.prop_start)[i];
            const pc = slice_pre.items(.prop_count)[i];
            const props = form.props.items[ps..][0..pc];
            const value = lookupPropValue(props, "value") orelse continue;
            const stripped = std.mem.trim(u8, value, "\"");
            const content = stripTclEval(std.mem.trim(u8, stripped, " \t\n\r"));
            var it = std.mem.splitScalar(u8, content, '\n');
            while (it.next()) |line| {
                const tl2 = std.mem.trimLeft(u8, line, " \t");
                if (!std.ascii.startsWithIgnoreCase(tl2, ".param ")) continue;
                const eq2 = std.mem.indexOfScalar(u8, tl2, '=') orelse continue;
                const k2 = std.mem.trim(u8, tl2[".param ".len..eq2], " \t");
                const rhs2 = std.mem.trim(u8, tl2[eq2 + 1 ..], " \t");
                const val2 = extractTclSetValue(rhs2) orelse rhs2;
                tcl_vars.put(a, k2, val2) catch {};
            }
        }
    }
    {
        var it = tcl_vars.iterator();
        while (it.next()) |entry| {
            netlist.tcl_vars.put(a, entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }

    // Pre-pass: collect net names used by non-bus devices.
    // Also include nets touched by noconn/graph markers so that scalar auto-nets on
    // explicitly unconnected pins (e.g. COUT tied to noconn) are never auto-indexed.
    var non_bus_net_names: std.StringHashMapUnmanaged(void) = .{};
    defer non_bus_net_names.deinit(a);
    {
        const slice_pre = form.devices.slice();
        for (0..form.devices.len) |i| {
            const k = slice_pre.items(.kind)[i];
            // Include graph (noconn) markers so their nets are not auto-indexed.
            const is_graph = k == .graph;
            if (!is_graph and (k.isNonElectrical() or k == .code)) continue;
            if (isPortSymbol(slice_pre.items(.symbol)[i])) continue;
            const inst_name_pre = slice_pre.items(.name)[i];
            if (parseBusRange(inst_name_pre) != null) continue;
            for (form.device_nets.items) |dn| {
                if (dn.device_idx != @as(u32, @intCast(i))) continue;
                const net = resolveNetName(form, dn.net_id);
                non_bus_net_names.put(a, net, {}) catch {};
            }
        }
    }

    const slice = form.devices.slice();
    for (0..form.devices.len) |i| {
        const kind = slice.items(.kind)[i];
        if (kind.isNonElectrical()) continue;
        if (isPortSymbol(slice.items(.symbol)[i])) continue;
        if (kind == .code) {
            try buildCode(&netlist, form, @intCast(i), a);
            continue;
        }
        const inst_name_raw = slice.items(.name)[i];
        if (parseBusRange(inst_name_raw)) |br| {
            const num_instances: u32 = @as(u32, @intCast(@abs(br.hi - br.lo))) + 1;
            const step: i32 = if (br.hi >= br.lo) -1 else 1;
            // For multi-line format strings, XSchem groups output by format sub-line first,
            // then iterates bus indices — matching how XSchem's netlist generator works.
            const ps_i = slice.items(.prop_start)[i];
            const pc_i = slice.items(.prop_count)[i];
            const props_i = form.props.items[ps_i..][0..pc_i];
            const raw_fmt = lookupPropValue(props_i, "format") orelse slice.items(.format)[i];
            const trimmed_fmt = if (raw_fmt) |f| std.mem.trim(u8, f, "\n\r\t ") else null;
            const is_multiline_fmt = if (trimmed_fmt) |tf| std.mem.indexOfScalar(u8, tf, '\n') != null else false;
            if (is_multiline_fmt) {
                var fmt_line_it = std.mem.splitScalar(u8, trimmed_fmt.?, '\n');
                while (fmt_line_it.next()) |raw_fmt_line| {
                    const fmt_line = std.mem.trim(u8, raw_fmt_line, "\r\t ");
                    if (fmt_line.len == 0) continue;
                    var bidx = br.hi;
                    var pos: u32 = 0;
                    while (true) {
                        const exp_name = try std.fmt.allocPrint(a, "{s}[{d}]{s}", .{ br.prefix, bidx, br.suffix });
                        try buildDeviceExpanded(&netlist, form, @intCast(i), kind, exp_name, pos, bidx, num_instances, &non_bus_net_names, fmt_line, a);
                        if (bidx == br.lo) break;
                        bidx += step;
                        pos += 1;
                    }
                }
            } else {
                var bidx = br.hi;
                var pos: u32 = 0;
                while (true) {
                    const exp_name = try std.fmt.allocPrint(a, "{s}[{d}]{s}", .{ br.prefix, bidx, br.suffix });
                    try buildDeviceExpanded(&netlist, form, @intCast(i), kind, exp_name, pos, bidx, num_instances, &non_bus_net_names, null, a);
                    if (bidx == br.lo) break;
                    bidx += step;
                    pos += 1;
                }
            }
            continue;
        }
        try buildDevice(&netlist, form, @intCast(i), kind, a);
    }

    if (form.spice_s_block.len > 0) {
        try netlist.code_blocks.append(a, a.dupe(u8, form.spice_s_block) catch form.spice_s_block);
    }

    return netlist;
}

// ── Net lookup helpers ────────────────────────────────────────────────────── //

inline fn resolveNetName(form: *const Netlister, net_id: u32) []const u8 {
    return if (net_id < form.net_names.items.len) form.net_names.items[net_id] else "0";
}

/// Find the net name for `device_idx` with `pin_name` (case-insensitive), or null if not found.
/// Used in format-string `@@pin` expansion where a missing pin should emit nothing.
fn netByPinExact(form: *const Netlister, device_idx: u32, pin_name: []const u8) ?[]const u8 {
    var found = false;
    var best: []const u8 = "0";
    for (form.device_nets.items) |dn| {
        if (dn.device_idx != device_idx) continue;
        if (!std.ascii.eqlIgnoreCase(dn.pin_name, pin_name)) continue;
        found = true;
        const net = resolveNetName(form, dn.net_id);
        if (std.mem.eql(u8, best, "0")) {
            best = net;
        } else if (autoNetIndex(best) == null) {
            // keep best (real name wins)
        } else if (autoNetIndex(net) == null) {
            best = net;
        } else if ((autoNetIndex(net) orelse std.math.maxInt(u32)) < (autoNetIndex(best) orelse std.math.maxInt(u32))) {
            best = net;
        }
    }
    return if (found) best else null;
}

/// Find the net name for `device_idx` with `pin_name` (case-insensitive).
/// Prefers user-defined names over auto-generated; among auto names, keeps lower index.
fn netByPin(form: *const Netlister, device_idx: u32, pin_name: []const u8) []const u8 {
    var best: []const u8 = "0";
    for (form.device_nets.items) |dn| {
        if (dn.device_idx != device_idx) continue;
        if (!std.ascii.eqlIgnoreCase(dn.pin_name, pin_name)) continue;
        const net = resolveNetName(form, dn.net_id);
        if (std.mem.eql(u8, best, "0")) {
            best = net;
        } else if (autoNetIndex(best) == null) {
            // keep best (real name wins)
        } else if (autoNetIndex(net) == null) {
            best = net;
        } else if ((autoNetIndex(net) orelse std.math.maxInt(u32)) < (autoNetIndex(best) orelse std.math.maxInt(u32))) {
            best = net;
        }
    }
    return best;
}

fn netByPinAny(form: *const Netlister, device_idx: u32, pin_names: []const []const u8) []const u8 {
    std.debug.assert(pin_names.len > 0);
    for (pin_names) |pin_name| {
        const net = netByPin(form, device_idx, pin_name);
        if (!std.mem.eql(u8, net, "0")) return net;
    }
    return netByPin(form, device_idx, pin_names[0]);
}

// ── Device builders ───────────────────────────────────────────────────────── //

fn buildDevice(
    netlist: *univ.Netlist,
    form: *const Netlister,
    idx: u32,
    kind: dev.DeviceKind,
    a: Allocator,
) error{OutOfMemory}!void {
    const slice = form.devices.slice();
    const inst_name = slice.items(.name)[idx];
    const prop_start = slice.items(.prop_start)[idx];
    const prop_count = slice.items(.prop_count)[idx];
    const props = form.props.items[prop_start..][0..prop_count];
    const symbol = slice.items(.symbol)[idx];

    // Handle spice_ignore: "true"/1 → omit; "short" → emit comment with merged nets.
    if (lookupPropValue(props, "spice_ignore")) |si| {
        const sv = std.mem.trim(u8, si, " \t");
        if (std.mem.eql(u8, sv, "true") or std.mem.eql(u8, sv, "1")) return;
        if (std.mem.eql(u8, sv, "short")) {
            var net_a: []const u8 = "";
            var net_b: []const u8 = "";
            var count: usize = 0;
            for (form.device_nets.items) |dn| {
                if (dn.device_idx != idx) continue;
                if (count == 0) net_a = resolveNetName(form, dn.net_id)
                else if (count == 1) net_b = resolveNetName(form, dn.net_id);
                count += 1;
            }
            if (net_b.len == 0) net_b = net_a;
            const comment = try std.fmt.allocPrint(a, "* short {s} : {s} <--> {s}", .{ inst_name, net_a, net_b });
            try netlist.addComponent(.{ .raw = comment });
            return;
        }
    }

    // Instance-level `format=` prop overrides the symbol's format string.
    const eff_format: ?[]const u8 = lookupPropValue(props, "format") orelse slice.items(.format)[idx];

    switch (kind) {
        .resistor => try buildPassive(netlist, form, inst_name, props, symbol, idx, .resistor),
        .capacitor => try buildPassive(netlist, form, inst_name, props, symbol, idx, .capacitor),
        .inductor => try buildPassive(netlist, form, inst_name, props, symbol, idx, .inductor),
        .diode => blk: {
            if (eff_format) |fmt| {
                try buildFormatTemplate(netlist, form, idx, fmt, a);
                break :blk;
            }
            try buildDiode(netlist, form, inst_name, props, symbol, idx, a);
        },
        .mosfet => blk: {
            if (eff_format) |fmt| {
                try buildFormatTemplate(netlist, form, idx, fmt, a);
                break :blk;
            }
            try buildMosfetRaw(netlist, form, inst_name, props, symbol, idx, a);
        },
        .bjt => blk: {
            if (eff_format) |fmt| {
                try buildFormatTemplate(netlist, form, idx, fmt, a);
                break :blk;
            }
            try buildBjt(netlist, form, inst_name, props, symbol, idx, a);
        },
        .jfet => blk: {
            if (eff_format) |fmt| {
                try buildFormatTemplate(netlist, form, idx, fmt, a);
                break :blk;
            }
            try buildJfetRaw(netlist, form, inst_name, props, symbol, idx, a);
        },
        .vsource => try buildVsource(netlist, form, inst_name, props, idx, false),
        .ammeter => try buildVsource(netlist, form, inst_name, props, idx, true),
        .isource => try buildIsource(netlist, form, inst_name, props, idx),
        .vcvs, .vccs, .ccvs, .cccs => try buildControlledRaw(netlist, form, inst_name, kind, props, idx, a),
        .subckt => blk: {
            if (eff_format) |fmt| {
                try buildFormatTemplate(netlist, form, idx, fmt, a);
                break :blk;
            }
            try buildSubcircuit(netlist, form, inst_name, props, symbol, idx, a);
        },
        else => {
            if (eff_format) |fmt| {
                try buildFormatTemplate(netlist, form, idx, fmt, a);
            } else {
                const line = try std.fmt.allocPrint(a, "* unhandled {s} {s}", .{ @tagName(kind), inst_name });
                try netlist.addComponent(.{ .raw = line });
            }
        },
    }
    // Emit any device_model= block from instance props (deduped) for all device kinds.
    try emitDeviceModelBlock(netlist, props, a);
    // Also emit device_model= inherited from the sym K-block (e.g. tcleval subckts).
    if (slice.items(.sym_device_model)[idx]) |sdm| {
        const fake_prop = [1]DeviceProp{.{ .key = "device_model", .value = sdm }};
        try emitDeviceModelBlock(netlist, &fake_prop, a);
    }
}

fn buildDeviceExpanded(
    netlist: *univ.Netlist,
    form: *const Netlister,
    idx: u32,
    kind: dev.DeviceKind,
    exp_name: []const u8,
    pos: u32,
    bus_idx: i32,
    num_instances: u32,
    non_bus_net_names: *const std.StringHashMapUnmanaged(void),
    /// When non-null, use this single format sub-line instead of the full format string.
    /// Used when the outer bus loop already split a multi-line format into individual lines.
    format_override: ?[]const u8,
    a: Allocator,
) error{OutOfMemory}!void {
    var expanded_nets: std.ArrayListUnmanaged(DeviceNet) = .{};
    defer expanded_nets.deinit(a);
    var expanded_net_names: std.ArrayListUnmanaged([]const u8) = .{};
    defer expanded_net_names.deinit(a);
    var net_id_map: std.AutoHashMapUnmanaged(u32, u32) = .{};
    defer net_id_map.deinit(a);

    for (form.device_nets.items) |dn| {
        if (dn.device_idx != idx) continue;
        const orig_net = resolveNetName(form, dn.net_id);
        const expanded_net = blk: {
            const already_bus = std.mem.indexOfScalar(u8, orig_net, '[') != null;
            if (num_instances > 1) {
                if (parseBusRange(dn.pin_name)) |pin_br| {
                    const pin_width: u32 = @as(u32, @intCast(@abs(pin_br.hi - pin_br.lo))) + 1;
                    if (already_bus) {
                        // Bus pin connected to a bus net: compute the sub-range for this instance.
                        // e.g. pin A[3:0] on bus net A[15:0] at pos=0 → A[15:12]
                        if (parseBusRange(orig_net)) |net_br| {
                            const hi_idx: i32 = net_br.hi - @as(i32, @intCast(pos)) * @as(i32, @intCast(pin_width));
                            const lo_idx: i32 = hi_idx - @as(i32, @intCast(pin_width)) + 1;
                            break :blk std.fmt.allocPrint(a, "{s}[{d}:{d}]{s}", .{ net_br.prefix, hi_idx, lo_idx, net_br.suffix }) catch orig_net;
                        }
                    } else {
                        // Bus pin connected to a scalar net: synthesise the range from instance position.
                        const total_width: u32 = pin_width * num_instances;
                        const hi_idx: i32 = @as(i32, @intCast(total_width)) - 1 - @as(i32, @intCast(pos)) * @as(i32, @intCast(pin_width));
                        const lo_idx: i32 = hi_idx - @as(i32, @intCast(pin_width)) + 1;
                        break :blk std.fmt.allocPrint(a, "{s}[{d}:{d}]", .{ orig_net, hi_idx, lo_idx }) catch orig_net;
                    }
                }
                // Auto-index scalar auto-nets shared only between bus instances.
                // Nets also connected to a noconn (graph) marker are excluded via non_bus_net_names.
                if (!already_bus and autoNetIndex(orig_net) != null and !non_bus_net_names.contains(orig_net)) {
                    break :blk std.fmt.allocPrint(a, "{s}[{d}]", .{ orig_net, bus_idx }) catch orig_net;
                }
            }
            break :blk expandBusNetByPos(orig_net, pos, a);
        };
        const new_id: u32 = if (net_id_map.get(dn.net_id)) |id| id else blk: {
            const new_id_inner: u32 = @intCast(expanded_net_names.items.len);
            expanded_net_names.append(a, expanded_net) catch {};
            net_id_map.put(a, dn.net_id, new_id_inner) catch {};
            break :blk new_id_inner;
        };
        expanded_nets.append(a, .{
            .device_idx = dn.device_idx,
            .pin_name = dn.pin_name,
            .net_id = new_id,
        }) catch {};
    }

    var tmp_form: Netlister = form.*;
    tmp_form.device_nets = .{ .items = expanded_nets.items, .capacity = expanded_nets.items.len };
    tmp_form.net_names = .{};
    tmp_form.net_names.items = expanded_net_names.items;
    tmp_form.net_names.capacity = expanded_net_names.items.len;

    const slice = form.devices.slice();
    const prop_start = slice.items(.prop_start)[idx];
    const prop_count = slice.items(.prop_count)[idx];
    const props = form.props.items[prop_start..][0..prop_count];
    const symbol = slice.items(.symbol)[idx];

    // Handle spice_ignore for expanded bus instances.
    if (lookupPropValue(props, "spice_ignore")) |si| {
        const sv = std.mem.trim(u8, si, " \t");
        if (std.mem.eql(u8, sv, "true") or std.mem.eql(u8, sv, "1")) return;
        if (std.mem.eql(u8, sv, "short")) {
            var net_a: []const u8 = "";
            var net_b: []const u8 = "";
            var count: usize = 0;
            for (expanded_nets.items) |dn| {
                if (count == 0) net_a = if (dn.net_id < expanded_net_names.items.len) expanded_net_names.items[dn.net_id] else ""
                else if (count == 1) net_b = if (dn.net_id < expanded_net_names.items.len) expanded_net_names.items[dn.net_id] else "";
                count += 1;
            }
            if (net_b.len == 0) net_b = net_a;
            const comment = try std.fmt.allocPrint(a, "* short {s} : {s} <--> {s}", .{ exp_name, net_a, net_b });
            try netlist.addComponent(.{ .raw = comment });
            return;
        }
    }

    // Instance-level `format=` prop overrides the symbol's format string.
    // format_override (from outer multi-line bus loop) takes precedence over all.
    const eff_format_exp: ?[]const u8 = format_override orelse lookupPropValue(props, "format") orelse slice.items(.format)[idx];

    switch (kind) {
        .resistor => try buildPassive(netlist, &tmp_form, exp_name, props, symbol, idx, .resistor),
        .capacitor => try buildPassive(netlist, &tmp_form, exp_name, props, symbol, idx, .capacitor),
        .inductor => try buildPassive(netlist, &tmp_form, exp_name, props, symbol, idx, .inductor),
        .diode => blk: {
            if (eff_format_exp) |fmt| {
                try buildFormatTemplateInner(netlist, &tmp_form, idx, fmt, exp_name, a);
                break :blk;
            }
            try buildDiode(netlist, &tmp_form, exp_name, props, symbol, idx, a);
        },
        .mosfet => blk: {
            if (eff_format_exp) |fmt| {
                try buildFormatTemplateInner(netlist, &tmp_form, idx, fmt, exp_name, a);
                break :blk;
            }
            try buildMosfetRaw(netlist, &tmp_form, exp_name, props, symbol, idx, a);
        },
        .bjt => blk: {
            if (eff_format_exp) |fmt| {
                try buildFormatTemplateInner(netlist, &tmp_form, idx, fmt, exp_name, a);
                break :blk;
            }
            try buildBjt(netlist, &tmp_form, exp_name, props, symbol, idx, a);
        },
        .subckt => blk: {
            if (eff_format_exp) |fmt| {
                try buildFormatTemplateInner(netlist, &tmp_form, idx, fmt, exp_name, a);
                break :blk;
            }
            try buildSubcircuit(netlist, &tmp_form, exp_name, props, symbol, idx, a);
        },
        else => {
            if (eff_format_exp) |fmt| {
                try buildFormatTemplateInner(netlist, &tmp_form, idx, fmt, exp_name, a);
                return;
            }
            const line = try std.fmt.allocPrint(a, "* unhandled {s} {s}", .{ @tagName(kind), exp_name });
            try netlist.addComponent(.{ .raw = line });
        },
    }
}

// ── Per-kind builders ─────────────────────────────────────────────────────── //

fn emitDeviceModelBlock(netlist: *univ.Netlist, props: []const DeviceProp, a: Allocator) error{OutOfMemory}!void {
    const dm = lookupPropValue(props, "device_model") orelse return;
    const stripped = std.mem.trim(u8, dm, "\"");
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(a);
    var it = std.mem.splitScalar(u8, stripped, '\n');
    while (it.next()) |raw_ln| {
        const ln = std.mem.trimLeft(u8, raw_ln, " \t\r");
        if (ln.len == 0) continue;
        if (ln[0] == '+') {
            buf.append(a, ' ') catch {};
            buf.appendSlice(a, std.mem.trimLeft(u8, ln[1..], " \t")) catch {};
        } else {
            if (ln[0] == '*') continue;
            if (buf.items.len > 0) buf.append(a, '\n') catch {};
            buf.appendSlice(a, ln) catch {};
        }
    }
    if (buf.items.len > 0) {
        try netlist.addToplevelCodeBlock(try a.dupe(u8, buf.items));
    }
}

const PassiveKind = enum { resistor, capacitor, inductor };

fn buildPassive(
    netlist: *univ.Netlist,
    form: *const Netlister,
    inst_name: []const u8,
    props: []const DeviceProp,
    symbol: []const u8,
    idx: u32,
    comptime pk: PassiveKind,
) error{OutOfMemory}!void {
    std.debug.assert(inst_name.len > 0);
    const val_raw_orig = lookupPropValue(props, "value") orelse "0";
    // Resolve expr(...) values that contain @PARAM tokens from the parent instance.
    const val_raw = resolveExprValue(val_raw_orig, form.parent_params, netlist.allocator);
    const val = processSpiceExpr(val_raw, netlist.allocator);
    const p_net = netByPinAny(form, idx, &.{ "p", "P", "plus" });
    const n_net = netByPinAny(form, idx, &.{ "m", "M", "n", "N", "minus" });
    const m_val = lookupPropValue(props, "m") orelse
        if (hasXschemTemplateM(symbol)) @as([]const u8, "1") else null;

    if (pk == .resistor and std.mem.indexOfScalar(u8, val, '\n') != null) {
        const normalized = normalizeSpiceValue(val, netlist.allocator) catch val;
        const m_suffix: []const u8 = if (m_val) |m|
            std.fmt.allocPrint(netlist.allocator, " m={s}", .{m}) catch ""
        else
            "";
        const line = try std.fmt.allocPrint(netlist.allocator, "{s} {s} {s} {s}{s}", .{
            inst_name, p_net, n_net, normalized, m_suffix,
        });
        try netlist.addComponent(.{ .raw = line });
        return;
    }

    const ic: ?f64 = if (pk != .resistor) blk: {
        const ic_str = lookupPropValue(props, "ic") orelse break :blk null;
        break :blk std.fmt.parseFloat(f64, ic_str) catch null;
    } else null;

    switch (pk) {
        .resistor => try netlist.addComponent(.{ .resistor = .{
            .name = inst_name, .p = p_net, .n = n_net,
            .value = parseValue(val), .m = m_val,
        } }),
        .capacitor => try netlist.addComponent(.{ .capacitor = .{
            .name = inst_name, .p = p_net, .n = n_net,
            .value = parseValue(val), .ic = ic, .m = m_val,
        } }),
        .inductor => try netlist.addComponent(.{ .inductor = .{
            .name = inst_name, .p = p_net, .n = n_net,
            .value = parseValue(val), .ic = ic, .m = m_val,
        } }),
    }
}

fn buildDiode(
    netlist: *univ.Netlist,
    form: *const Netlister,
    inst_name: []const u8,
    props: []const DeviceProp,
    symbol: []const u8,
    idx: u32,
    a: Allocator,
) error{OutOfMemory}!void {
    const model_raw = lookupPropValue(props, "model") orelse baseSymbol(symbol);
    const anode = netByPinAny(form, idx, &.{ "p", "P", "a", "A", "anode" });
    const cathode = netByPinAny(form, idx, &.{ "m", "M", "n", "N", "c", "C", "k", "K", "cathode", "minus" });
    var line_buf: std.ArrayListUnmanaged(u8) = .{};
    defer line_buf.deinit(a);
    const lw = line_buf.writer(a);
    try lw.print("{s} {s} {s} {s}", .{ inst_name, anode, cathode, model_raw });
    if (lookupPropValue(props, "area")) |area| try lw.print(" area={s}", .{area});
    if (lookupPropValue(props, "m")) |m| try lw.print(" m={s}", .{m});
    try netlist.addComponent(.{ .raw = try a.dupe(u8, line_buf.items) });
}

fn buildMosfetRaw(
    netlist: *univ.Netlist,
    form: *const Netlister,
    inst_name: []const u8,
    props: []const DeviceProp,
    symbol: []const u8,
    idx: u32,
    a: Allocator,
) error{OutOfMemory}!void {
    const model_raw = lookupPropValue(props, "model") orelse baseSymbol(symbol);
    const d = netByPinAny(form, idx, &.{ "d", "D", "drain" });
    const g = netByPinAny(form, idx, &.{ "g", "G", "gate" });
    const s = netByPinAny(form, idx, &.{ "s", "S", "source" });
    const b = netByPinAny(form, idx, &.{ "b", "B", "bulk", "sub" });
    var line_buf: std.ArrayListUnmanaged(u8) = .{};
    defer line_buf.deinit(a);
    const lw = line_buf.writer(a);
    try lw.print("{s} {s} {s} {s} {s} {s}", .{ inst_name, d, g, s, b, model_raw });
    if (lookupPropValue(props, "W") orelse lookupPropValue(props, "w")) |w| try lw.print(" w={s}", .{w});
    if (lookupPropValue(props, "L") orelse lookupPropValue(props, "l")) |l| try lw.print(" l={s}", .{l});
    if (lookupPropValue(props, "m")) |m| try lw.print(" m={s}", .{m});
    try netlist.addComponent(.{ .raw = try a.dupe(u8, line_buf.items) });
    try emitDeviceModelBlock(netlist, props, a);
}

fn buildBjt(
    netlist: *univ.Netlist,
    form: *const Netlister,
    inst_name: []const u8,
    props: []const DeviceProp,
    symbol: []const u8,
    idx: u32,
    a: Allocator,
) error{OutOfMemory}!void {
    const model_raw = lookupPropValue(props, "model") orelse baseSymbol(symbol);
    const c = netByPinAny(form, idx, &.{ "C", "c" });
    const b = netByPinAny(form, idx, &.{ "B", "b" });
    const e = netByPinAny(form, idx, &.{ "E", "e" });
    var line_buf: std.ArrayListUnmanaged(u8) = .{};
    defer line_buf.deinit(a);
    const lw = line_buf.writer(a);
    try lw.print("{s} {s} {s} {s} {s}", .{ inst_name, c, b, e, model_raw });
    if (lookupPropValue(props, "area")) |area| try lw.print(" area={s}", .{area});
    const m_str = lookupPropValue(props, "m") orelse
        if (hasXschemTemplateBjt(symbol)) @as([]const u8, "1") else null;
    if (m_str) |m| try lw.print(" m={s}", .{m});
    try netlist.addComponent(.{ .raw = try a.dupe(u8, line_buf.items) });
}

fn buildJfetRaw(
    netlist: *univ.Netlist,
    form: *const Netlister,
    inst_name: []const u8,
    props: []const DeviceProp,
    symbol: []const u8,
    idx: u32,
    a: Allocator,
) error{OutOfMemory}!void {
    const model_raw = lookupPropValue(props, "model") orelse baseSymbol(symbol);
    const d = netByPin(form, idx, "d");
    const g = netByPin(form, idx, "g");
    const s = netByPin(form, idx, "s");
    const has_tmpl = hasXschemTemplateJfet(symbol);
    var line_buf: std.ArrayListUnmanaged(u8) = .{};
    defer line_buf.deinit(a);
    const lw = line_buf.writer(a);
    try lw.print("{s} {s} {s} {s} {s}", .{ inst_name, d, g, s, model_raw });
    const area_str = lookupPropValue(props, "area") orelse if (has_tmpl) @as([]const u8, "1") else null;
    const m_str = lookupPropValue(props, "m") orelse if (has_tmpl) @as([]const u8, "1") else null;
    if (area_str) |area| try lw.print(" area={s}", .{area});
    if (m_str) |m| try lw.print(" m={s}", .{m});
    try netlist.addComponent(.{ .raw = try a.dupe(u8, line_buf.items) });
}

fn buildVsource(
    netlist: *univ.Netlist,
    form: *const Netlister,
    inst_name: []const u8,
    props: []const DeviceProp,
    idx: u32,
    is_ammeter: bool,
) error{OutOfMemory}!void {
    const p_net = netByPinAny(form, idx, &.{ "p", "P", "plus" });
    const n_net = netByPinAny(form, idx, &.{ "m", "M", "n", "N", "minus" });
    const do_save = blk: {
        if (is_ammeter) {
            const sc = lookupPropValue(props, "savecurrent") orelse "true";
            break :blk !std.mem.eql(u8, sc, "false") and !std.mem.eql(u8, sc, "0");
        }
        const sc = lookupPropValue(props, "savecurrent") orelse "0";
        break :blk std.mem.eql(u8, sc, "1") or std.mem.eql(u8, sc, "true");
    };

    if (lookupPropValue(props, "value")) |v| {
        const v_tcl = evalTclEval(v, &netlist.tcl_vars, netlist.allocator);
        const v_unesc = xschemTclUnescape(v_tcl, netlist.allocator);
        const emitted = if (isWaveformSpec(v_unesc) or isPlainNumber(v_unesc))
            v_unesc
        else
            processSpiceExpr(v_unesc, netlist.allocator);
        if (is_ammeter) {
            try netlist.addSource(.{
                .name = inst_name, .kind = .voltage,
                .p = p_net, .n = n_net,
                .dc = std.fmt.parseFloat(f64, v_unesc) catch 0.0,
                .save_current = do_save,
            });
            return;
        }
        const raw_line = try std.fmt.allocPrint(netlist.allocator, "{s} {s} {s} {s}", .{ inst_name, p_net, n_net, emitted });
        try netlist.addComponent(.{ .raw = collapseSpaces(raw_line, netlist.allocator) });
        if (do_save) {
            const lower_name_buf = try netlist.allocator.dupe(u8, inst_name);
            const lower_name = std.ascii.lowerString(lower_name_buf, inst_name);
            const save_line = try std.fmt.allocPrint(netlist.allocator, ".save i({s})", .{lower_name});
            try netlist.addComponent(.{ .raw = save_line });
        }
        return;
    }

    try netlist.addSource(.{
        .name = inst_name,
        .kind = .voltage,
        .p = p_net,
        .n = n_net,
        .dc = parseOptF64(props, "dc") orelse if (is_ammeter) @as(?f64, 0.0) else null,
        .ac_mag = parseOptF64(props, "ac"),
        .waveform = parseWaveform(props),
        .save_current = do_save,
    });
}

fn buildCode(
    netlist: *univ.Netlist,
    form: *const Netlister,
    idx: u32,
    a: Allocator,
) error{OutOfMemory}!void {
    const slice = form.devices.slice();
    const prop_start = slice.items(.prop_start)[idx];
    const prop_count = slice.items(.prop_count)[idx];
    const props = form.props.items[prop_start..][0..prop_count];
    if (lookupPropValue(props, "spice_ignore")) |v| {
        if (std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "1")) return;
    }
    if (lookupPropValue(props, "simulator")) |sim| {
        if (!std.ascii.eqlIgnoreCase(sim, "ngspice")) return;
    }
    if (!form.is_toplevel) {
        if (lookupPropValue(props, "only_toplevel")) |v| {
            const tv = std.mem.trim(u8, v, " \t");
            if (std.mem.eql(u8, tv, "true") or std.mem.eql(u8, tv, "1")) return;
        }
    }
    const value = lookupPropValue(props, "value") orelse return;
    const stripped = std.mem.trim(u8, value, "\"");
    var unesc_buf: std.ArrayListUnmanaged(u8) = .{};
    {
        var i: usize = 0;
        while (i < stripped.len) {
            if (stripped[i] == '\\' and i + 1 < stripped.len) {
                const next = stripped[i + 1];
                if (next == '\\' and i + 2 < stripped.len and stripped[i + 2] == '"') {
                    unesc_buf.append(a, '"') catch {};
                    i += 3;
                    continue;
                }
                switch (next) {
                    '\\' => { unesc_buf.append(a, '\\') catch {}; i += 2; continue; },
                    '"'  => { unesc_buf.append(a, '"')  catch {}; i += 2; continue; },
                    '{'  => { unesc_buf.append(a, '{')  catch {}; i += 2; continue; },
                    '}'  => { unesc_buf.append(a, '}')  catch {}; i += 2; continue; },
                    else => {},
                }
            }
            unesc_buf.append(a, stripped[i]) catch {};
            i += 1;
        }
    }
    const unescaped = stripTclEval(std.mem.trim(u8, unesc_buf.items, " \t\n\r"));
    // Substitute @PARAM tokens from parent instance parameters in code blocks.
    // E.g. ".param DEL=@DEL" with parent param DEL=5 → ".param DEL=5".
    const unescaped_subst = if (form.parent_params.len > 0 and std.mem.indexOfScalar(u8, unescaped, '@') != null)
        substituteAtParams(unescaped, form.parent_params, a)
    else
        unescaped;
    var lines_buf: std.ArrayListUnmanaged(u8) = .{};
    var line_it = std.mem.splitScalar(u8, unescaped_subst, '\n');
    while (line_it.next()) |line| {
        const trimmed_line = std.mem.trimLeft(u8, line, " \t");
        if (std.ascii.startsWithIgnoreCase(trimmed_line, "tcleval(")) continue;
        const simplified = simplifyParamLine(trimmed_line, a);
        lines_buf.appendSlice(a, simplified) catch {};
        lines_buf.append(a, '\n') catch {};
    }
    while (lines_buf.items.len > 0 and lines_buf.items[lines_buf.items.len - 1] == '\n') {
        lines_buf.items.len -= 1;
    }
    if (lines_buf.items.len == 0) return;
    try netlist.addCodeBlock(try a.dupe(u8, lines_buf.items));
}

fn buildFormatTemplate(
    netlist: *univ.Netlist,
    form: *const Netlister,
    idx: u32,
    fmt: []const u8,
    a: Allocator,
) error{OutOfMemory}!void {
    return buildFormatTemplateInner(netlist, form, idx, fmt, form.devices.slice().items(.name)[idx], a);
}

fn buildFormatTemplateInner(
    netlist: *univ.Netlist,
    form: *const Netlister,
    idx: u32,
    fmt: []const u8,
    inst_name: []const u8,
    a: Allocator,
) error{OutOfMemory}!void {
    const slice = form.devices.slice();
    const prop_start = slice.items(.prop_start)[idx];
    const prop_count = slice.items(.prop_count)[idx];
    const props = form.props.items[prop_start..][0..prop_count];
    const sym_template = slice.items(.sym_template)[idx];
    const symbol_path = slice.items(.symbol)[idx];
    const symname: []const u8 = blk: {
        if (lookupPropValue(props, "schematic")) |sch_v| {
            const base = if (std.mem.lastIndexOfScalar(u8, sch_v, '/')) |si| sch_v[si + 1 ..] else sch_v;
            break :blk if (std.mem.indexOfScalar(u8, base, '.')) |di| base[0..di] else base;
        }
        const sym_base = if (std.mem.lastIndexOfScalar(u8, symbol_path, '/')) |si|
            symbol_path[si + 1 ..] else symbol_path;
        break :blk if (std.mem.indexOfScalar(u8, sym_base, '.')) |di| sym_base[0..di] else sym_base;
    };

    var pin_nets: std.ArrayListUnmanaged([]const u8) = .{};
    defer pin_nets.deinit(a);
    var pin_pin_names: std.ArrayListUnmanaged([]const u8) = .{};
    defer pin_pin_names.deinit(a);
    var seen_pins: std.StringHashMapUnmanaged(void) = .{};
    defer seen_pins.deinit(a);
    for (form.device_nets.items) |dn| {
        if (dn.device_idx != idx) continue;
        if (dn.pin_name.len > 0) {
            if (seen_pins.contains(dn.pin_name)) continue;
            seen_pins.put(a, dn.pin_name, {}) catch {};
        }
        pin_nets.append(a, resolveNetName(form, dn.net_id)) catch {};
        pin_pin_names.append(a, dn.pin_name) catch {};
    }

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(a);
    const template = std.mem.trim(u8, fmt, "\n\r\t ");

    // Multi-line format strings: each line becomes a separate netlist component.
    if (std.mem.indexOfScalar(u8, template, '\n') != null) {
        var line_it = std.mem.splitScalar(u8, template, '\n');
        while (line_it.next()) |raw_line| {
            const trimmed = std.mem.trim(u8, raw_line, "\r\t ");
            if (trimmed.len > 0) {
                try buildFormatTemplateInner(netlist, form, idx, trimmed, inst_name, a);
            }
        }
        return;
    }

    var i: usize = 0;
    while (i < template.len) {
        // In XSchem format strings, `\\` is a "join" operator (emit nothing).
        // `\x` (including `\@`) is a TCL-style escape: emit `x` literally.
        if (template[i] == '\\') {
            i += 1;
            if (i < template.len) {
                if (template[i] == '\\') {
                    i += 1; // `\\` → skip both backslashes, emit nothing.
                } else {
                    out.append(a, template[i]) catch {}; // `\x` → emit `x`.
                    i += 1;
                }
            }
            continue;
        }
        // `#text#` emits `text` literally (XSchem name-prefix syntax, e.g. `#xa#@name`).
        if (template[i] == '#') {
            i += 1;
            const start = i;
            while (i < template.len and template[i] != '#' and template[i] != '\n') i += 1;
            out.appendSlice(a, template[start..i]) catch {};
            if (i < template.len and template[i] == '#') i += 1;
            continue;
        }
        if (template[i] != '@') {
            out.append(a, template[i]) catch {};
            i += 1;
            continue;
        }
        i += 1;
        if (i >= template.len) {
            out.append(a, '@') catch {};
            break;
        }
        const is_pin_ref = (template[i] == '@');
        if (is_pin_ref) i += 1;
        const id_start = i;
        while (i < template.len and (std.ascii.isAlphanumeric(template[i]) or template[i] == '_')) i += 1;
        var id_with_range_end = i;
        if (is_pin_ref and i < template.len and template[i] == '[') {
            const bracket_start = i;
            i += 1;
            while (i < template.len and template[i] != ']') i += 1;
            if (i < template.len and template[i] == ']') {
                i += 1;
                id_with_range_end = i;
            } else {
                i = bracket_start;
            }
        }
        const id = if (is_pin_ref) template[id_start..id_with_range_end] else template[id_start..i];

        if (is_pin_ref) {
            // Use netByPinExact so that @@pin emits nothing for pins not found in the symbol
            // (XSchem behaviour: unresolved @@pin → empty string, not ground "0").
            const net_opt = netByPinExact(form, idx, id);
            const net = net_opt orelse "";
            if (net.len == 0 and net_opt == null) {
                // pin not found — emit nothing, just like XSchem does
            } else if (expandBusNet(a, net, &out)) {
                // expanded
            } else if (parseBusRange(id)) |pin_br| {
                const step: i32 = if (pin_br.hi >= pin_br.lo) -1 else 1;
                var bidx: i32 = pin_br.hi;
                var first_bit = true;
                while (true) {
                    if (!first_bit) out.append(a, ' ') catch {};
                    const expanded = std.fmt.allocPrint(a, "{s}[{d}]", .{ net, bidx }) catch net;
                    out.appendSlice(a, expanded) catch {};
                    first_bit = false;
                    if (bidx == pin_br.lo) break;
                    bidx += step;
                }
            } else {
                out.appendSlice(a, net) catch {};
            }
        } else if (std.ascii.eqlIgnoreCase(id, "name")) {
            out.appendSlice(a, inst_name) catch {};
        } else if (std.ascii.eqlIgnoreCase(id, "symname")) {
            out.appendSlice(a, symname) catch {};
        } else if (std.ascii.eqlIgnoreCase(id, "pinlist")) {
            var first_pin = true;
            for (pin_nets.items, 0..) |net, pni| {
                var expanded_buf: std.ArrayListUnmanaged(u8) = .{};
                defer expanded_buf.deinit(a);
                if (!first_pin) out.append(a, ' ') catch {};
                if (expandBusNet(a, net, &expanded_buf)) {
                    out.appendSlice(a, expanded_buf.items) catch {};
                } else {
                    // If the net is a scalar but the pin has a bus range (e.g. pin
                    // `alucontrol[2:0]` connected to net `net3`), expand the scalar
                    // net to individual bits: `net3[2] net3[1] net3[0]`.
                    const maybe_pin_br: ?BusRange = if (pni < pin_pin_names.items.len)
                        parseBusRange(pin_pin_names.items[pni])
                    else
                        null;
                    if (maybe_pin_br) |pin_br| {
                        const step: i32 = if (pin_br.hi >= pin_br.lo) -1 else 1;
                        var bidx: i32 = pin_br.hi;
                        var first_bit = true;
                        while (true) {
                            if (!first_bit) out.append(a, ' ') catch {};
                            const expanded = std.fmt.allocPrint(a, "{s}[{d}]", .{ net, bidx }) catch net;
                            out.appendSlice(a, expanded) catch {};
                            first_bit = false;
                            if (bidx == pin_br.lo) break;
                            bidx += step;
                        }
                    } else {
                        out.appendSlice(a, net) catch {};
                    }
                }
                first_pin = false;
            }
        } else if (std.ascii.eqlIgnoreCase(id, "spiceprefix")) {
            const val_raw = lookupPropValueI(props, "spiceprefix") orelse blk: {
                if (sym_template) |tmpl| break :blk lookupTemplateDefault(tmpl, "spiceprefix") orelse "";
                break :blk @as([]const u8, "");
            };
            out.appendSlice(a, xschemTclUnescape(val_raw, a)) catch {};
        } else {
            // Use case-sensitive lookup first (XSchem behaviour): instance property key
            // must exactly match the @TOKEN case. Fall back to template default if not found.
            const val_raw = lookupPropValue(props, id) orelse blk: {
                if (sym_template) |tmpl| break :blk lookupTemplateDefault(tmpl, id) orelse "";
                break :blk @as([]const u8, "");
            };
            // If the resolved value itself starts with '@', it's a second-level reference
            // that we cannot evaluate (requires TCL context). Emit empty string like XSchem does.
            const unescaped_raw = xschemTclUnescape(val_raw, a);
            // If the value is an expr() template default, process it like XSchem does.
            const unescaped = if (std.ascii.startsWithIgnoreCase(unescaped_raw, "expr("))
                processExprDefault(unescaped_raw, a)
            else
                unescaped_raw;
            if (unescaped.len > 0 and unescaped[0] == '@') {
                // unresolved reference — emit nothing
            } else {
                // When generating a named variant (e.g. passgate_1), XSchem substitutes bare
                // parameter name references with the instance's actual values.  For example,
                // if the child device has L=L_N and parent_params contains L_N=0.35, emit 0.35.
                // Only substitute when the value is a plain identifier (no spaces, operators, or
                // quotes) and a matching parent_param exists.
                const effective_val = blk: {
                    if (form.inline_parent_params and isPlainIdentifier(unescaped)) {
                        for (form.parent_params) |pp| {
                            if (std.ascii.eqlIgnoreCase(pp.key, unescaped)) {
                                break :blk pp.value;
                            }
                        }
                    }
                    break :blk unescaped;
                };
                out.appendSlice(a, effective_val) catch {};
            }
        }
    }

    const raw_line_unesc = xschemTclUnescape(dedupeSpaces(out.items, a), a);
    const raw_line: []const u8 = blk: {
        const src = raw_line_unesc;
        if (std.mem.indexOf(u8, src, " + ") == null) break :blk src;
        var stripped_buf: std.ArrayListUnmanaged(u8) = .{};
        var si: usize = 0;
        var brace_depth: u32 = 0;
        var paren_depth: u32 = 0;
        while (si < src.len) {
            const c = src[si];
            if (c == '{') { brace_depth += 1; stripped_buf.append(a, c) catch {}; si += 1; continue; }
            if (c == '}') { if (brace_depth > 0) brace_depth -= 1; stripped_buf.append(a, c) catch {}; si += 1; continue; }
            if (c == '(') { paren_depth += 1; stripped_buf.append(a, c) catch {}; si += 1; continue; }
            if (c == ')') { if (paren_depth > 0) paren_depth -= 1; stripped_buf.append(a, c) catch {}; si += 1; continue; }
            // Only strip " + " as a SPICE continuation marker at the top level (not inside expressions).
            if (brace_depth == 0 and paren_depth == 0 and c == ' ' and si + 2 < src.len and src[si + 1] == '+' and src[si + 2] == ' ') {
                stripped_buf.append(a, ' ') catch {};
                si += 3;
                continue;
            }
            stripped_buf.append(a, c) catch {};
            si += 1;
        }
        break :blk stripped_buf.toOwnedSlice(a) catch src;
    };

    const tl = std.mem.trimLeft(u8, raw_line, " ");
    if (std.ascii.startsWithIgnoreCase(tl, ".save") or std.ascii.startsWithIgnoreCase(tl, ".probe")) {
        const dir_prefix = if (std.ascii.startsWithIgnoreCase(tl, ".probe")) ".probe" else ".save";
        var tokens: std.ArrayListUnmanaged([]const u8) = .{};
        defer tokens.deinit(a);
        var has_vi_token = false;
        var j: usize = 0;
        while (j < raw_line.len) {
            while (j < raw_line.len and raw_line[j] == ' ') j += 1;
            if (j >= raw_line.len) break;
            if (j + 1 < raw_line.len and raw_line[j + 1] == '(' and
                (raw_line[j] == 'v' or raw_line[j] == 'V' or
                 raw_line[j] == 'i' or raw_line[j] == 'I'))
            {
                const letter = std.ascii.toLower(raw_line[j]);
                j += 2;
                while (j < raw_line.len and raw_line[j] == ' ') j += 1;
                const node_start = j;
                while (j < raw_line.len and raw_line[j] != ')' and raw_line[j] != ' ') j += 1;
                var node_end = j;
                while (node_end > node_start and raw_line[node_end - 1] == '\\') node_end -= 1;
                while (j < raw_line.len and raw_line[j] == ' ') j += 1;
                if (j < raw_line.len and raw_line[j] == ')') j += 1;
                var tok: std.ArrayListUnmanaged(u8) = .{};
                tok.append(a, letter) catch {};
                tok.append(a, '(') catch {};
                for (raw_line[node_start..node_end]) |c| tok.append(a, std.ascii.toLower(c)) catch {};
                tok.append(a, ')') catch {};
                tokens.append(a, try tok.toOwnedSlice(a)) catch {};
                has_vi_token = true;
            } else {
                const tok_start = j;
                while (j < raw_line.len and raw_line[j] != ' ') j += 1;
                const tok = raw_line[tok_start..j];
                if (std.ascii.startsWithIgnoreCase(tok, ".save") or
                    std.ascii.startsWithIgnoreCase(tok, ".probe")) continue;
                tokens.append(a, tok) catch {};
            }
        }
        if (has_vi_token) {
            for (tokens.items) |tok| {
                const is_vi = tok.len > 2 and tok[1] == '(' and (tok[0] == 'v' or tok[0] == 'i');
                if (!is_vi) continue;
                var save_line: std.ArrayListUnmanaged(u8) = .{};
                save_line.appendSlice(a, dir_prefix) catch {};
                save_line.append(a, ' ') catch {};
                save_line.appendSlice(a, tok) catch {};
                try netlist.addComponent(.{ .raw = try save_line.toOwnedSlice(a) });
            }
            return;
        }
        try netlist.addComponent(.{ .raw = try a.dupe(u8, std.mem.trim(u8, raw_line, " ")) });
        return;
    }
    try netlist.addComponent(.{ .raw = try a.dupe(u8, raw_line) });
}

fn lookupPropValueI(props: []const DeviceProp, key: []const u8) ?[]const u8 {
    for (props) |p| {
        if (std.ascii.eqlIgnoreCase(p.key, key)) return p.value;
    }
    return null;
}

fn buildIsource(
    netlist: *univ.Netlist,
    form: *const Netlister,
    inst_name: []const u8,
    props: []const DeviceProp,
    idx: u32,
) error{OutOfMemory}!void {
    const p_net = netByPinAny(form, idx, &.{ "p", "P", "plus" });
    const n_net = netByPinAny(form, idx, &.{ "m", "M", "n", "N", "minus" });
    if (lookupPropValue(props, "value")) |v| {
        const v_unesc = xschemTclUnescape(v, netlist.allocator);
        const emitted = if (isWaveformSpec(v_unesc) or isPlainNumber(v_unesc))
            v_unesc
        else
            processSpiceExpr(v_unesc, netlist.allocator);
        const line = try std.fmt.allocPrint(netlist.allocator, "{s} {s} {s} {s}", .{ inst_name, p_net, n_net, emitted });
        try netlist.addComponent(.{ .raw = line });
        return;
    }
    try netlist.addSource(.{
        .name = inst_name,
        .kind = .current,
        .p = p_net,
        .n = n_net,
        .dc = parseOptF64(props, "dc"),
        .ac_mag = parseOptF64(props, "ac"),
        .waveform = parseWaveform(props),
    });
}

fn buildControlledRaw(
    netlist: *univ.Netlist,
    form: *const Netlister,
    inst_name: []const u8,
    kind: dev.DeviceKind,
    props: []const DeviceProp,
    idx: u32,
    a: Allocator,
) error{OutOfMemory}!void {
    const gain_str = processSpiceExpr(lookupPropValue(props, "value") orelse "1.0", a);
    const p = netByPinAny(form, idx, &.{ "p", "P", "plus" });
    const n = netByPinAny(form, idx, &.{ "n", "N", "m", "M", "minus" });

    const line = switch (kind) {
        .vcvs, .vccs => blk: {
            const cp = netByPinAny(form, idx, &.{ "cp", "CP", "ip", "vp" });
            const cn = netByPinAny(form, idx, &.{ "cn", "CN", "cm", "CM", "in", "vn" });
            break :blk try std.fmt.allocPrint(a, "{s} {s} {s} {s} {s} {s}", .{ inst_name, p, n, cp, cn, gain_str });
        },
        .ccvs, .cccs => blk: {
            const ctrl = lookupPropValue(props, "ctrl") orelse "Vctrl";
            break :blk try std.fmt.allocPrint(a, "{s} {s} {s} {s} {s}", .{ inst_name, p, n, ctrl, gain_str });
        },
        else => try std.fmt.allocPrint(a, "* unhandled controlled source {s}", .{inst_name}),
    };
    try netlist.addComponent(.{ .raw = line });
}

fn buildSubcircuit(
    netlist: *univ.Netlist,
    form: *const Netlister,
    inst_name: []const u8,
    props: []const DeviceProp,
    symbol: []const u8,
    idx: u32,
    a: Allocator,
) error{OutOfMemory}!void {
    const cell_name_raw: []const u8 = blk: {
        if (lookupPropValue(props, "schematic")) |sch_v| {
            const base = if (std.mem.lastIndexOfScalar(u8, sch_v, '/')) |si| sch_v[si + 1 ..] else sch_v;
            break :blk if (std.mem.indexOfScalar(u8, base, '.')) |di| base[0..di] else base;
        }
        break :blk lookupPropValue(props, "device_model") orelse baseSymbol(symbol);
    };
    const cell_name = try a.dupe(u8, cell_name_raw);

    var nodes_list: std.ArrayListUnmanaged([]const u8) = .{};
    defer nodes_list.deinit(a);
    for (form.device_nets.items) |dn| {
        if (dn.device_idx != idx) continue;
        const net = resolveNetName(form, dn.net_id);
        var expanded_buf: std.ArrayListUnmanaged(u8) = .{};
        defer expanded_buf.deinit(a);
        if (expandBusNet(a, net, &expanded_buf)) {
            var it = std.mem.splitScalar(u8, expanded_buf.items, ' ');
            while (it.next()) |sig| try nodes_list.append(a, try a.dupe(u8, sig));
        } else {
            try nodes_list.append(a, net);
        }
    }

    var params: std.ArrayListUnmanaged(univ.ParamOverride) = .{};
    defer params.deinit(a);
    if (lookupPropValue(props, "schematic") == null) {
        for (props) |p| {
            if (xschem_skip_map.has(p.key)) continue;
            try params.append(a, .{ .name = p.key, .value = parseValue(p.value) });
        }
    }

    try netlist.addComponent(.{ .subcircuit = .{
        .name = cell_name,
        .inst_name = inst_name,
        .nodes = try nodes_list.toOwnedSlice(a),
        .params = try params.toOwnedSlice(a),
    } });
}

// ── Waveform parsing ──────────────────────────────────────────────────────── //

fn parseWaveform(props: []const DeviceProp) ?univ.SourceWaveform {
    if (lookupPropValue(props, "pulse")) |_| {
        return .{ .pulse = .{
            .v1     = parseOptF64(props, "v1")  orelse 0,
            .v2     = parseOptF64(props, "v2")  orelse 1,
            .delay  = parseOptF64(props, "td")  orelse 0,
            .rise   = parseOptF64(props, "tr")  orelse 0,
            .fall   = parseOptF64(props, "tf")  orelse 0,
            .width  = parseOptF64(props, "pw")  orelse 1e-9,
            .period = parseOptF64(props, "per") orelse 2e-9,
        } };
    }
    if (lookupPropValue(props, "sin")) |_| {
        return .{ .sin = .{
            .offset    = parseOptF64(props, "vo")   orelse 0,
            .amplitude = parseOptF64(props, "va")   orelse 1,
            .freq      = parseOptF64(props, "freq") orelse 1e6,
        } };
    }
    return null;
}

fn parseOptF64(props: []const DeviceProp, key: []const u8) ?f64 {
    const s = lookupPropValue(props, key) orelse return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

// ── Value parsing ─────────────────────────────────────────────────────────── //

fn parseValue(s: []const u8) univ.Value {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return .{ .literal = 0 };
    if (trimmed.len > 6 and std.ascii.startsWithIgnoreCase(trimmed, "expr(") and trimmed[trimmed.len - 1] == ')')
        return .{ .expr = std.mem.trim(u8, trimmed[5 .. trimmed.len - 1], " \t") };
    if (trimmed.len > 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}')
        return .{ .param = trimmed[1 .. trimmed.len - 1] };
    if (trimmed.len > 2 and trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'')
        return .{ .expr = trimmed };
    return .{ .expr = trimmed };
}

// ── Symbol helpers ────────────────────────────────────────────────────────── //

fn symbolIn(symbol: []const u8, comptime names: []const []const u8) bool {
    const base = if (std.mem.lastIndexOfScalar(u8, symbol, '/')) |i| symbol[i + 1 ..] else symbol;
    inline for (names) |k| if (std.mem.eql(u8, base, k)) return true;
    return false;
}

inline fn hasXschemTemplateM(symbol: []const u8) bool {
    return symbolIn(symbol, &.{ "res.sym", "capa.sym", "ind.sym", "capa-2.sym", "res2.sym" });
}

inline fn hasXschemTemplateJfet(symbol: []const u8) bool {
    return symbolIn(symbol, &.{ "njfet.sym", "pjfet.sym" });
}

inline fn hasXschemTemplateBjt(symbol: []const u8) bool {
    return symbolIn(symbol, &.{ "npn.sym", "pnp.sym", "npn2.sym", "pnp2.sym" });
}

fn baseSymbol(sym: []const u8) []const u8 {
    const after_slash = if (std.mem.lastIndexOfScalar(u8, sym, '/')) |i| sym[i + 1 ..] else sym;
    return if (std.mem.indexOfScalar(u8, after_slash, '.')) |i| after_slash[0..i] else after_slash;
}

// ── Tcl helpers ───────────────────────────────────────────────────────────── //

fn stripTclEval(s: []const u8) []const u8 {
    if (std.ascii.startsWithIgnoreCase(s, "tcleval(") and std.mem.endsWith(u8, s, ")"))
        return s["tcleval(".len .. s.len - 1];
    return s;
}

fn extractTclSetValue(rhs: []const u8) ?[]const u8 {
    if (rhs.len < 1 or rhs[0] != '[') return null;
    const rb = std.mem.lastIndexOfScalar(u8, rhs, ']') orelse return null;
    const inner = std.mem.trim(u8, rhs[1..rb], " \t");
    if (!std.ascii.startsWithIgnoreCase(inner, "set ")) return null;
    const after = std.mem.trim(u8, inner[4..], " \t");
    const sp = std.mem.indexOfScalar(u8, after, ' ') orelse return null;
    return std.mem.trim(u8, after[sp + 1 ..], " \t");
}

fn evalTclEval(s: []const u8, tcl_vars: *const std.StringHashMapUnmanaged([]const u8), a: Allocator) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "tcleval(")) return s;
    if (!std.mem.endsWith(u8, trimmed, ")")) return s;
    const inner = trimmed["tcleval(".len .. trimmed.len - 1];
    var out: std.ArrayListUnmanaged(u8) = .{};
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '$') {
            i += 1;
            const var_start = i;
            while (i < inner.len and (std.ascii.isAlphanumeric(inner[i]) or inner[i] == '_')) i += 1;
            const var_name = inner[var_start..i];
            if (tcl_vars.get(var_name)) |val| {
                out.appendSlice(a, val) catch {};
            } else {
                out.append(a, '$') catch {};
                out.appendSlice(a, var_name) catch {};
            }
        } else {
            out.append(a, inner[i]) catch {};
            i += 1;
        }
    }
    return out.toOwnedSlice(a) catch inner;
}

fn simplifyParamLine(line: []const u8, a: Allocator) []const u8 {
    const tl = std.mem.trimLeft(u8, line, " \t");
    if (!std.ascii.startsWithIgnoreCase(tl, ".param ")) return line;
    const eq_pos = std.mem.indexOfScalar(u8, tl, '=') orelse return line;
    const rhs = std.mem.trim(u8, tl[eq_pos + 1 ..], " \t");
    const val = extractTclSetValue(rhs) orelse return line;
    const prefix = tl[0 .. eq_pos + 1];
    return std.fmt.allocPrint(a, "{s}{s}", .{ prefix, val }) catch line;
}

/// Look up a default value from an XSchem template= string.
/// Handles multiline templates and quoted values (\\"...\\", "...", '...').
/// Returns a slice into `template` (the inner content without quote delimiters).
fn lookupTemplateDefault(template: []const u8, key: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < template.len) {
        // Skip whitespace between tokens.
        while (pos < template.len and (template[pos] == ' ' or template[pos] == '\t' or
            template[pos] == '\n' or template[pos] == '\r' or template[pos] == '+')) pos += 1;
        if (pos >= template.len) break;
        // Find '=' for the key.
        const eq_pos = std.mem.indexOfScalarPos(u8, template, pos, '=') orelse break;
        const tok_key = std.mem.trim(u8, template[pos..eq_pos], " \t\n\r");
        pos = eq_pos + 1;
        // Parse value (may be \\"...\\", "...", '...', or bare word).
        const dq_esc = pos + 2 < template.len and template[pos] == '\\' and
            template[pos + 1] == '\\' and template[pos + 2] == '"';
        const dq_plain = !dq_esc and pos < template.len and template[pos] == '"';
        const sq = !dq_esc and !dq_plain and pos < template.len and template[pos] == '\'';
        var val_start: usize = undefined;
        var val_end: usize = undefined;
        if (dq_esc) {
            val_start = pos + 3;
            pos += 3;
            while (pos < template.len) {
                if (pos + 2 < template.len and template[pos] == '\\' and
                    template[pos + 1] == '\\' and template[pos + 2] == '"')
                { val_end = pos; pos += 3; break; }
                pos += 1;
            } else val_end = pos;
        } else if (dq_plain) {
            val_start = pos + 1; pos += 1;
            while (pos < template.len and template[pos] != '"') pos += 1;
            val_end = pos;
            if (pos < template.len) pos += 1;
        } else if (sq) {
            val_start = pos; pos += 1;
            while (pos < template.len and template[pos] != '\'') pos += 1;
            if (pos < template.len) pos += 1;
            val_end = pos;
        } else {
            val_start = pos;
            while (pos < template.len and template[pos] != ' ' and template[pos] != '\t' and
                template[pos] != '\n' and template[pos] != '\r') pos += 1;
            val_end = pos;
        }
        if (std.ascii.eqlIgnoreCase(tok_key, key)) return template[val_start..val_end];
    }
    return null;
}

// ── String helpers ────────────────────────────────────────────────────────── //

fn isWaveformSpec(s: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, s, " \t");
    if (trimmed.len == 0) return false;
    const keywords = [_][]const u8{ "pulse", "sin", "cos", "exp", "pwl", "sffm", "am", "dc ", "ac ", "tcleval(" };
    for (keywords) |kw| if (std.ascii.startsWithIgnoreCase(trimmed, kw)) return true;
    if (std.mem.indexOfScalar(u8, trimmed, ' ')) |sp| {
        const after = std.mem.trimLeft(u8, trimmed[sp..], " \t");
        for (keywords) |kw| if (std.ascii.startsWithIgnoreCase(after, kw)) return true;
        if (std.ascii.startsWithIgnoreCase(after, "dc") or std.ascii.startsWithIgnoreCase(after, "ac")) return true;
    }
    return false;
}

fn normalizeSpiceValue(val: []const u8, a: Allocator) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    var it = std.mem.splitScalar(u8, val, '\n');
    var first = true;
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r");
        if (trimmed.len == 0) continue;
        const content = if (trimmed[0] == '+') std.mem.trim(u8, trimmed[1..], " \t") else trimmed;
        if (content.len == 0) continue;
        if (!first) try buf.append(a, ' ');
        try buf.appendSlice(a, content);
        first = false;
    }
    return buf.toOwnedSlice(a);
}

fn collapseSpaces(s: []const u8, a: std.mem.Allocator) []const u8 {
    var joined: std.ArrayListUnmanaged(u8) = .{};
    defer joined.deinit(a);
    var line_it = std.mem.splitScalar(u8, s, '\n');
    var first = true;
    while (line_it.next()) |raw_ln| {
        const ln = std.mem.trimLeft(u8, raw_ln, " \t\r");
        if (ln.len > 0 and ln[0] == '+') {
            joined.append(a, ' ') catch return s;
            joined.appendSlice(a, std.mem.trimLeft(u8, ln[1..], " \t")) catch return s;
        } else {
            if (!first) joined.append(a, ' ') catch return s;
            joined.appendSlice(a, raw_ln) catch return s;
        }
        first = false;
    }
    return dedupeSpaces(joined.items, a);
}

fn dedupeSpaces(s: []const u8, a: std.mem.Allocator) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    var prev_space = false;
    var started = false;
    for (s) |c| {
        const is_ws = c == ' ' or c == '\t' or c == '\r';
        if (is_ws) {
            if (started and !prev_space) buf.append(a, ' ') catch return s;
            prev_space = true;
        } else {
            buf.append(a, c) catch return s;
            prev_space = false;
            started = true;
        }
    }
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') buf.items.len -= 1;
    return buf.toOwnedSlice(a) catch s;
}

fn xschemTclUnescape(s: []const u8, a: std.mem.Allocator) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var buf = a.alloc(u8, s.len) catch return s;
    var wi: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            const next = s[i + 1];
            if (next == '{' or next == '}' or next == '\\') {
                buf[wi] = next;
                wi += 1;
                i += 2;
                continue;
            }
        }
        buf[wi] = s[i];
        wi += 1;
        i += 1;
    }
    return buf[0..wi];
}

fn isPlainNumber(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0) return false;
    _ = std.fmt.parseFloat(f64, t) catch {
        var i: usize = t.len;
        while (i > 0 and std.ascii.isAlphabetic(t[i - 1])) : (i -= 1) {}
        if (i == 0 or i == t.len) return false;
        const suffix = t[i..];
        const known = [_][]const u8{ "k", "m", "u", "n", "p", "f", "g", "t", "meg" };
        var ok = false;
        for (known) |kw| if (std.ascii.eqlIgnoreCase(suffix, kw)) { ok = true; break; };
        if (!ok) return false;
        _ = std.fmt.parseFloat(f64, t[0..i]) catch return false;
        return true;
    };
    return true;
}

fn needsSpiceQuoting(s: []const u8) bool {
    if (s.len == 0) return false;
    if ((s[0] == '\'' and s[s.len - 1] == '\'') or (s[0] == '{' and s[s.len - 1] == '}')) return false;
    if (std.mem.indexOfScalar(u8, s, ' ') != null) return false;
    if (std.ascii.startsWithIgnoreCase(s, "tcleval(")) return false;
    if (std.ascii.startsWithIgnoreCase(s, "expr(")) return false;
    if (isPlainNumber(s)) return false;
    for (s) |c| if (c == '/' or c == '*' or c == '(' or c == ')') return true;
    return false;
}

fn processSpiceExpr(s: []const u8, a: std.mem.Allocator) []const u8 {
    const unescaped = xschemTclUnescape(std.mem.trim(u8, s, " \t"), a);
    if (needsSpiceQuoting(unescaped)) {
        return std.fmt.allocPrint(a, "'{s}'", .{unescaped}) catch unescaped;
    }
    return unescaped;
}

/// Parse an engineering-suffix number (e.g. "100f", "2500", "1k") → f64.
/// Returns null if the string is not a valid number+suffix.
fn parseEngValue(s: []const u8) ?f64 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0) return null;
    // Determine where the numeric part ends and suffix begins.
    // Suffixes: f p n u m k meg g t (case-insensitive)
    // "meg" must be checked before "m" to avoid ambiguity.
    var num_end: usize = t.len;
    var multiplier: f64 = 1.0;
    // Check multi-char suffix first
    if (t.len >= 3 and std.ascii.eqlIgnoreCase(t[t.len - 3 ..], "meg")) {
        num_end = t.len - 3;
        multiplier = 1e6;
    } else if (t.len >= 1) {
        const last = t[t.len - 1];
        switch (last) {
            'f', 'F' => { num_end = t.len - 1; multiplier = 1e-15; },
            'p', 'P' => { num_end = t.len - 1; multiplier = 1e-12; },
            'n', 'N' => { num_end = t.len - 1; multiplier = 1e-9;  },
            'u', 'U' => { num_end = t.len - 1; multiplier = 1e-6;  },
            'm', 'M' => { num_end = t.len - 1; multiplier = 1e-3;  },
            'k', 'K' => { num_end = t.len - 1; multiplier = 1e3;   },
            'g', 'G' => { num_end = t.len - 1; multiplier = 1e9;   },
            't', 'T' => { num_end = t.len - 1; multiplier = 1e12;  },
            else => {},
        }
    }
    if (num_end == 0) return null;
    const num_f = std.fmt.parseFloat(f64, t[0..num_end]) catch return null;
    return num_f * multiplier;
}

/// Evaluate a simple arithmetic expression containing only numbers (with optional
/// engineering suffixes) and binary operators * / + - with left-to-right precedence.
/// Returns null if the expression cannot be fully evaluated (e.g. unresolved tokens).
fn evalSimpleArith(expr_str: []const u8, a: std.mem.Allocator) ?f64 {
    _ = a;
    const t = std.mem.trim(u8, expr_str, " \t");
    // Tokenize: split on +, -, *, / while keeping operators.
    // We do a simple left-to-right evaluation (no precedence, but * / before + - is
    // not needed for the current use case which only uses * in XSchem expr() values).
    // Use a simple state machine: accumulate operands and operators.
    var result: f64 = 0;
    var pending_op: u8 = '+'; // initial: result = 0 + first_token
    var i: usize = 0;
    while (i <= t.len) {
        // Find next operator or end of string
        var j = i;
        while (j < t.len and t[j] != '+' and t[j] != '-' and t[j] != '*' and t[j] != '/') j += 1;
        const token = std.mem.trim(u8, t[i..j], " \t");
        if (token.len == 0) {
            if (j < t.len) { pending_op = t[j]; i = j + 1; }
            else break;
            continue;
        }
        const val = parseEngValue(token) orelse return null;
        switch (pending_op) {
            '+' => result += val,
            '-' => result -= val,
            '*' => result *= val,
            '/' => if (val != 0) { result /= val; } else return null,
            else => return null,
        }
        if (j < t.len) { pending_op = t[j]; i = j + 1; }
        else break;
    }
    return result;
}

/// Format an f64 result using engineering notation suitable for SPICE.
/// Produces compact output: integers as plain integers, small/large values in
/// scientific notation (e.g. 5e-13, 1.23e-10).
fn formatEvalResult(val: f64, a: std.mem.Allocator) []const u8 {
    // If it is an exact integer (|val| >= 1) and not too large, emit as integer.
    // Use relative tolerance: avoid treating small floats (e.g. 5e-13) as 0.
    const rounded = @round(val);
    const is_integer = blk: {
        if (rounded == 0.0) break :blk (val == 0.0);
        if (@abs(rounded) < 1.0) break :blk false; // sub-unity numbers are never integers
        const rel_err = @abs(val - rounded) / @abs(rounded);
        break :blk rel_err < 1e-9 and @abs(rounded) < 1e15;
    };
    if (is_integer) {
        const int_val: i64 = @intFromFloat(rounded);
        return std.fmt.allocPrint(a, "{d}", .{int_val}) catch return "0";
    }
    // Otherwise use scientific notation. Zig's {e} already produces compact output.
    // We want "5e-13" not "5.000000e-13". Use allocPrint with {e} then strip trailing zeros.
    const raw = std.fmt.allocPrint(a, "{e}", .{val}) catch return "0";
    // raw looks like "5e-13" or "1.5e-10" — trim unnecessary zeros from mantissa.
    const e_pos = std.mem.indexOfScalar(u8, raw, 'e') orelse return raw;
    var mant = raw[0..e_pos];
    const exp_part = raw[e_pos..];
    // Remove trailing zeros after decimal point in mantissa.
    if (std.mem.indexOfScalar(u8, mant, '.') != null) {
        var end = mant.len;
        while (end > 1 and mant[end - 1] == '0') end -= 1;
        if (end > 1 and mant[end - 1] == '.') end -= 1;
        mant = mant[0..end];
    }
    return std.fmt.allocPrint(a, "{s}{s}", .{ mant, exp_part }) catch raw;
}

/// Returns true if `s` is a plain identifier: only alphanumeric characters and underscores,
/// non-empty, starts with a letter or underscore.  Used to detect bare parameter name
/// references (e.g. `L_N`, `W_P`) that should be substituted with parent instance values
/// when generating named subckt variants (schematic=NAME without .sch extension).
fn isPlainIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// Substitute @PARAM tokens in a string using parent_params.
/// Returns the substituted string (allocated), or the original if no substitution needed.
fn substituteAtParams(s: []const u8, parent_params: []const DeviceProp, a: std.mem.Allocator) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '@') == null) return s;
    var out: List(u8) = .{};
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '@') {
            i += 1;
            const name_start = i;
            while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) i += 1;
            const param_name = s[name_start..i];
            if (param_name.len > 0) {
                var found = false;
                for (parent_params) |p| {
                    if (std.ascii.eqlIgnoreCase(p.key, param_name)) {
                        out.appendSlice(a, p.value) catch {};
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    out.append(a, '@') catch {};
                    out.appendSlice(a, param_name) catch {};
                }
            } else {
                out.append(a, '@') catch {};
            }
        } else {
            out.append(a, s[i]) catch {};
            i += 1;
        }
    }
    return out.toOwnedSlice(a) catch s;
}

/// Process an `expr('...')` template default value the way XSchem does:
/// 1. Strip the `expr(` prefix and `)` suffix.
/// 2. Strip `@` from `@TOKEN` references inside the expression.
/// 3. Remove spaces around `+`, `-`, `/` when neither adjacent token is a float literal.
/// Returns the processed string, or val unchanged if not an expr() value.
fn processExprDefault(val: []const u8, a: std.mem.Allocator) []const u8 {
    const trimmed = std.mem.trim(u8, val, " \t");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "expr(")) return val;
    if (trimmed[trimmed.len - 1] != ')') return val;
    const inner = trimmed[5 .. trimmed.len - 1];

    // Step 1: strip @TOKEN → TOKEN
    var s1: std.ArrayListUnmanaged(u8) = .{};
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '@') {
            i += 1;
            while (i < inner.len and (std.ascii.isAlphanumeric(inner[i]) or inner[i] == '_')) {
                s1.append(a, inner[i]) catch {};
                i += 1;
            }
        } else {
            s1.append(a, inner[i]) catch {};
            i += 1;
        }
    }
    const s = s1.items;

    // Step 2: remove spaces around binary operators between non-float tokens
    var out: std.ArrayListUnmanaged(u8) = .{};
    var j: usize = 0;
    while (j < s.len) {
        if (s[j] == ' ' and j + 2 < s.len and
            (s[j + 1] == '+' or s[j + 1] == '-' or s[j + 1] == '/') and
            s[j + 2] == ' ')
        {
            const left_has_dot = blk: {
                var k: usize = out.items.len;
                while (k > 0) {
                    k -= 1;
                    const c = out.items[k];
                    if (c == '.') break :blk true;
                    if (!std.ascii.isAlphanumeric(c) and c != '_') break :blk false;
                }
                break :blk false;
            };
            const right_has_dot = blk: {
                var k: usize = j + 3;
                while (k < s.len) {
                    const c = s[k];
                    if (c == '.') break :blk true;
                    if (!std.ascii.isAlphanumeric(c) and c != '_') break :blk false;
                    k += 1;
                }
                break :blk false;
            };
            if (!left_has_dot and !right_has_dot) {
                out.append(a, s[j + 1]) catch {};
                j += 3;
                continue;
            }
        }
        out.append(a, s[j]) catch {};
        j += 1;
    }

    // Trim trailing outer whitespace
    var result = out.items;
    while (result.len > 0 and result[result.len - 1] == ' ') result.len -= 1;
    // Also trim spaces before a trailing single-quote delimiter:
    // e.g. '0.29 / W ' → '0.29 / W'
    if (result.len >= 2 and result[result.len - 1] == '\'') {
        var k2: usize = result.len - 1;
        while (k2 > 0 and result[k2 - 1] == ' ') k2 -= 1;
        if (k2 < result.len - 1) {
            result[k2] = '\'';
            result = result[0 .. k2 + 1];
        }
    }
    return a.dupe(u8, result) catch val;
}

/// Resolve an `expr(...)` value string using parent_params.
/// If all @PARAM tokens can be substituted and the result is pure arithmetic, evaluates it.
/// Returns the resolved string, or the original val_raw if resolution is not possible.
fn resolveExprValue(val_raw: []const u8, parent_params: []const DeviceProp, a: std.mem.Allocator) []const u8 {
    const trimmed = std.mem.trim(u8, val_raw, " \t");
    // Only handle expr(...) wrapped values.
    if (!std.ascii.startsWithIgnoreCase(trimmed, "expr(")) return val_raw;
    if (trimmed[trimmed.len - 1] != ')') return val_raw;
    const inner = std.mem.trim(u8, trimmed[5 .. trimmed.len - 1], " \t");
    if (parent_params.len == 0) return val_raw;
    // Substitute @PARAM tokens.
    const substituted = substituteAtParams(inner, parent_params, a);
    // If any @TOKEN remains unresolved, leave as-is.
    if (std.mem.indexOfScalar(u8, substituted, '@') != null) return val_raw;
    // Try to evaluate the arithmetic.
    const eval_result = evalSimpleArith(substituted, a) orelse {
        // Substitution succeeded but evaluation failed — return expr(substituted).
        return std.fmt.allocPrint(a, "expr({s})", .{substituted}) catch val_raw;
    };
    return formatEvalResult(eval_result, a);
}

