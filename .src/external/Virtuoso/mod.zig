// mod.zig - Cadence Virtuoso import backend.
//
// Implements the Backend interface for importing Cadence Virtuoso projects.
// Supports:
//   - cds.lib project detection and library path resolution
//   - CDL netlist parsing (via oa.zig)
//   - Spectre netlist parsing
//   - 49+ analogLib cell -> DeviceKind mappings via comptime StaticStringMap
//   - PDK prefix-based fallback matching (TSMC, GF180MCU, GPDK)
//   - DeviceKind-aware pin name translation

const std = @import("std");
const core = @import("core");
const ct = @import("../types.zig");

pub const ConvertResult = ct.ConvertResult;
pub const ConvertResultList = ct.ConvertResultList;
pub const OA = @import("oa.zig");
pub const Skill = @import("skill.zig");

const Allocator = std.mem.Allocator;
const Schemify = core.Schemify;
const DeviceKind = core.types.DeviceKind;
const Property = core.types.Property;
const Conn = core.types.Conn;

// ── analogLib Cell -> DeviceKind comptime mapping ─────────────────────────────

pub const cadence_cell_map = std.StaticStringMap(DeviceKind).initComptime(.{
    // Passives
    .{ "res", .resistor },
    .{ "cap", .capacitor },
    .{ "ind", .inductor },
    // Active: MOSFETs
    .{ "nmos", .nmos3 },
    .{ "pmos", .pmos3 },
    .{ "nmos4", .nmos4 },
    .{ "pmos4", .pmos4 },
    // Active: BJTs
    .{ "npn", .npn },
    .{ "npn4", .npn },
    .{ "pnp", .pnp },
    .{ "pnp4", .pnp },
    // Active: JFETs / MESFET
    .{ "njfet", .njfet },
    .{ "pjfet", .pjfet },
    .{ "diode", .diode },
    .{ "mesfet", .mesfet },
    // Voltage sources (all variants -> .vsource)
    .{ "vdc", .vsource },
    .{ "vsin", .vsource },
    .{ "vpulse", .vsource },
    .{ "vpwl", .vsource },
    .{ "vpwlf", .vsource },
    .{ "vexp", .vsource },
    .{ "vsource", .vsource },
    .{ "vac", .vsource },
    // Current sources (all variants -> .isource)
    .{ "idc", .isource },
    .{ "isin", .isource },
    .{ "ipulse", .isource },
    .{ "ipwl", .isource },
    .{ "ipwlf", .isource },
    .{ "iexp", .isource },
    .{ "isource", .isource },
    .{ "iac", .isource },
    // Controlled sources
    .{ "vcvs", .vcvs },
    .{ "vccs", .vccs },
    .{ "ccvs", .ccvs },
    .{ "cccs", .cccs },
    .{ "vcvs4", .vcvs },
    .{ "vccs4", .vccs },
    .{ "ccvs4", .ccvs },
    .{ "cccs4", .cccs },
    // Polynomial controlled sources
    .{ "pvcvs", .vcvs },
    .{ "pvccs", .vccs },
    .{ "pccvs", .ccvs },
    .{ "pcccs", .cccs },
    // Behavioral
    .{ "bsource", .behavioral },
    // Probes & ports
    .{ "iprobe", .ammeter },
    .{ "port", .probe },
    // Switches
    .{ "switch", .vswitch },
    .{ "relay", .iswitch },
    // Transmission line / coupling
    .{ "tline", .tline },
    .{ "tline4", .tline },
    .{ "mind", .coupling },
    .{ "mutual_ind", .coupling },
    // Ideal blocks (generic fallback)
    .{ "ideal_balun", .generic },
    .{ "xfmr", .generic },
    .{ "delay", .generic },
    // Power / ground
    .{ "gnd", .gnd },
    .{ "vdd", .vdd },
    // basic library
    .{ "noConn", .noconn },
    .{ "noconn", .noconn },
    .{ "iopin", .inout_pin },
    .{ "ipin", .input_pin },
    .{ "opin", .output_pin },
    // GPDK cells
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
    // TSMC cells (common names)
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

// ── PDK prefix-based fallback matching ───────────────────────────────────────

/// Attempt to match a cell name by prefix for PDK-specific cells not in the
/// static map. Ordered by specificity (longest prefix first where relevant).
pub fn matchPdkPrefix(cell: []const u8) ?DeviceKind {
    // GF180MCU prefixes
    const gf_prefixes = .{
        .{ "nfet_", DeviceKind.nmos4 },
        .{ "pfet_", DeviceKind.pmos4 },
        .{ "npn_", DeviceKind.npn },
        .{ "pnp_", DeviceKind.pnp },
        .{ "diode_", DeviceKind.diode },
        .{ "sc_diode", DeviceKind.diode },
        .{ "cap_mim_", DeviceKind.capacitor },
        .{ "cap_nmos_", DeviceKind.capacitor },
        .{ "cap_pmos_", DeviceKind.capacitor },
    };
    // TSMC prefixes
    const tsmc_prefixes = .{
        .{ "nch_", DeviceKind.nmos4 },
        .{ "pch_", DeviceKind.pmos4 },
    };
    // GPDK / universal prefixes
    const universal_prefixes = .{
        .{ "nmos", DeviceKind.nmos4 },
        .{ "pmos", DeviceKind.pmos4 },
        .{ "npn", DeviceKind.npn },
        .{ "pnp", DeviceKind.pnp },
        .{ "vpnp", DeviceKind.pnp },
        .{ "diode", DeviceKind.diode },
        .{ "ndio", DeviceKind.diode },
        .{ "pdio", DeviceKind.diode },
        .{ "res", DeviceKind.resistor },
        .{ "cap", DeviceKind.capacitor },
        .{ "mim", DeviceKind.capacitor },
        .{ "ind_", DeviceKind.inductor },
    };

    inline for (gf_prefixes) |entry| {
        if (std.mem.startsWith(u8, cell, entry[0])) return entry[1];
    }
    inline for (tsmc_prefixes) |entry| {
        if (std.mem.startsWith(u8, cell, entry[0])) return entry[1];
    }
    inline for (universal_prefixes) |entry| {
        if (std.mem.startsWith(u8, cell, entry[0])) return entry[1];
    }
    return null;
}

/// Resolve a Cadence cell name to a DeviceKind.
/// First attempts exact match in the static map, then falls back to prefix matching.
pub fn resolveDeviceKind(cell: []const u8) DeviceKind {
    if (cadence_cell_map.get(cell)) |kind| return kind;
    if (matchPdkPrefix(cell)) |kind| return kind;
    return .subckt;
}

// ── Pin Name Translation (DeviceKind-aware) ──────────────────────────────────

pub const PinContext = enum {
    mosfet,
    bjt,
    passive,
    controlled_source,
    probe,
    other,
};

/// Determine the pin translation context from a DeviceKind.
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

/// Translate a Cadence pin name to a Schemify pin name, given the device context.
/// Returns the translated name, or the original if no translation applies.
pub fn translatePin(cadence_pin: []const u8, ctx: PinContext) []const u8 {
    // MOSFET pins: D->drain, G->gate, S->source, B->body
    if (ctx == .mosfet) {
        if (std.mem.eql(u8, cadence_pin, "D")) return "drain";
        if (std.mem.eql(u8, cadence_pin, "G")) return "gate";
        if (std.mem.eql(u8, cadence_pin, "S")) return "source";
        if (std.mem.eql(u8, cadence_pin, "B")) return "body";
        return cadence_pin;
    }
    // BJT pins: C->collector, B->base, E->emitter, S->sub
    if (ctx == .bjt) {
        if (std.mem.eql(u8, cadence_pin, "C")) return "collector";
        if (std.mem.eql(u8, cadence_pin, "B")) return "base";
        if (std.mem.eql(u8, cadence_pin, "E")) return "emitter";
        if (std.mem.eql(u8, cadence_pin, "S")) return "sub";
        return cadence_pin;
    }
    // Passive / source pins: PLUS->p, MINUS->n
    if (ctx == .passive) {
        if (std.mem.eql(u8, cadence_pin, "PLUS")) return "p";
        if (std.mem.eql(u8, cadence_pin, "MINUS")) return "n";
        if (std.mem.eql(u8, cadence_pin, "B")) return "body";
        return cadence_pin;
    }
    // Controlled sources: inp/inn/outp/outn stay the same
    if (ctx == .controlled_source) {
        if (std.mem.eql(u8, cadence_pin, "inp")) return "inp";
        if (std.mem.eql(u8, cadence_pin, "inn")) return "inn";
        if (std.mem.eql(u8, cadence_pin, "outp")) return "outp";
        if (std.mem.eql(u8, cadence_pin, "outn")) return "outn";
        return cadence_pin;
    }
    // Probe (iprobe): in->p, out->n
    if (ctx == .probe) {
        if (std.mem.eql(u8, cadence_pin, "in")) return "p";
        if (std.mem.eql(u8, cadence_pin, "out")) return "n";
        if (std.mem.eql(u8, cadence_pin, "PLUS")) return "p";
        if (std.mem.eql(u8, cadence_pin, "MINUS")) return "n";
        return cadence_pin;
    }
    // Default: PLUS/MINUS fallback
    if (std.mem.eql(u8, cadence_pin, "PLUS")) return "p";
    if (std.mem.eql(u8, cadence_pin, "MINUS")) return "n";
    return cadence_pin;
}

// ── Global Net Handling ──────���───────────────────────────────────────────────

/// Strip the Cadence `!` suffix from global net names and return the clean name.
/// Returns null if the name is not a global net.
pub fn stripGlobalSuffix(net_name: []const u8) ?[]const u8 {
    if (net_name.len > 1 and net_name[net_name.len - 1] == '!') {
        return net_name[0 .. net_name.len - 1];
    }
    return null;
}

/// Check if a net name is a Cadence global net (ends with `!`).
pub fn isGlobalNet(net_name: []const u8) bool {
    return net_name.len > 1 and net_name[net_name.len - 1] == '!';
}

// ── cds.lib Parser ──────────────────────────────────────────────────────────

pub const LibEntry = struct {
    name: []const u8,
    path: []const u8,
};

pub const CdsLib = struct {
    entries: []LibEntry,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *CdsLib) void {
        self.arena.deinit();
    }

    /// Look up a library path by name.
    pub fn getLibPath(self: *const CdsLib, lib_name: []const u8) ?[]const u8 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, lib_name)) return entry.path;
        }
        return null;
    }
};

/// Parse a cds.lib file content into a list of DEFINE entries.
/// Supports DEFINE and INCLUDE directives.
/// Relative paths are resolved against `base_dir`.
pub fn parseCdsLib(alloc: Allocator, content: []const u8, base_dir: []const u8) !CdsLib {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    var entries: std.ArrayListUnmanaged(LibEntry) = .{};

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // DEFINE <lib_name> <path>
        if (std.mem.startsWith(u8, line, "DEFINE")) {
            const after = std.mem.trimLeft(u8, line["DEFINE".len..], " \t");
            var tok_iter = std.mem.tokenizeAny(u8, after, " \t");
            const lib_name = tok_iter.next() orelse continue;
            const raw_path = tok_iter.next() orelse continue;

            const resolved_path = if (raw_path.len > 0 and raw_path[0] == '/')
                try a.dupe(u8, raw_path)
            else if (std.mem.startsWith(u8, raw_path, "./"))
                try std.fmt.allocPrint(a, "{s}/{s}", .{ base_dir, raw_path[2..] })
            else
                try std.fmt.allocPrint(a, "{s}/{s}", .{ base_dir, raw_path });

            try entries.append(a, .{
                .name = try a.dupe(u8, lib_name),
                .path = resolved_path,
            });
        }
        // INCLUDE <path> -- recursively include another cds.lib
        // For now, we just note it; full recursive support would open that file.
    }

    return .{
        .entries = try entries.toOwnedSlice(a),
        .arena = arena,
    };
}

// ── Property Translation ─────────────────────────────────────────────────────

/// Properties that are universally preserved (needed for simulation).
const preserved_props = std.StaticStringMap([]const u8).initComptime(.{
    .{ "w", "w" },
    .{ "l", "l" },
    .{ "m", "m" },
    .{ "nf", "nf" },
    .{ "model", "model" },
    .{ "area", "area" },
    .{ "pj", "pj" },
});

/// Properties to rename during translation.
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

/// Properties to strip (layout-only, not needed in schematic).
const stripped_props = std.StaticStringMap(void).initComptime(.{
    .{ "sa", {} },
    .{ "sb", {} },
    .{ "sd", {} },
    .{ "nrd", {} },
    .{ "nrs", {} },
    .{ "topography", {} },
});

/// Translate a Cadence property key to a Schemify key.
/// Returns null if the property should be stripped.
pub fn translatePropKey(key: []const u8, kind: DeviceKind) ?[]const u8 {
    // Strip layout-only props
    if (stripped_props.has(key)) return null;

    // Special case: 'l' is overloaded between MOSFET (channel length) and
    // inductor (inductance value). For inductors, rename to "value".
    if (std.mem.eql(u8, key, "l") and kind == .inductor) return "value";

    // Check for renamed props
    if (renamed_props.get(key)) |new_key| return new_key;

    // Preserved props stay as-is
    if (preserved_props.has(key)) return key;

    // Unknown props: preserve as-is (PDK-specific params users might need)
    return key;
}

// ── Backend Implementation ───────────────────────────────────────────────────

pub const Backend = struct {
    alloc: Allocator,

    pub fn init(alloc: Allocator) Backend {
        return .{ .alloc = alloc };
    }

    pub fn deinit(_: *Backend) void {}

    pub fn label(_: *const Backend) []const u8 {
        return "Cadence Virtuoso";
    }

    /// Detect a Cadence project by looking for `cds.lib` in the project directory.
    pub fn detectProjectRoot(self: *const Backend, project_dir: []const u8) bool {
        const cds = std.fs.path.join(self.alloc, &.{ project_dir, "cds.lib" }) catch return false;
        defer self.alloc.free(cds);
        std.fs.cwd().access(cds, .{}) catch return false;
        return true;
    }

    /// Convert a Cadence project by parsing CDL/Spectre netlists found in the
    /// project directory structure.
    pub fn convertProject(
        self: *const Backend,
        project_dir: []const u8,
    ) !ConvertResultList {
        // Step 1: Parse cds.lib for library definitions
        const cds_path = try std.fs.path.join(self.alloc, &.{ project_dir, "cds.lib" });
        defer self.alloc.free(cds_path);

        const cds_content = std.fs.cwd().readFileAlloc(self.alloc, cds_path, 1 << 20) catch |err| switch (err) {
            error.FileNotFound => return error.NoCdsLib,
            else => return err,
        };
        defer self.alloc.free(cds_content);

        var cds_lib = try parseCdsLib(self.alloc, cds_content, project_dir);
        defer cds_lib.deinit();

        // Step 2: Find CDL and Spectre netlist files in the project
        var netlist_files = try self.findNetlistFiles(project_dir);
        defer {
            for (netlist_files.items) |f| self.alloc.free(f);
            netlist_files.deinit(self.alloc);
        }

        // Step 3: Parse each netlist and convert subcircuits to Schemify
        var list_arena = std.heap.ArenaAllocator.init(self.alloc);
        errdefer list_arena.deinit();
        const la = list_arena.allocator();

        var results: std.ArrayListUnmanaged(ConvertResult) = .{};

        for (netlist_files.items) |netlist_path| {
            const full_path = try std.fs.path.join(self.alloc, &.{ project_dir, netlist_path });
            defer self.alloc.free(full_path);

            const content = std.fs.cwd().readFileAlloc(self.alloc, full_path, 16 << 20) catch continue;
            defer self.alloc.free(content);

            // Detect format and parse
            const is_spectre = isSpectreFormat(content);
            if (is_spectre) {
                try self.parseSpectreNetlist(la, content, &results);
            } else {
                try self.parseCdlNetlist(la, content, &results);
            }
        }

        return .{
            .results = try results.toOwnedSlice(la),
            .arena = list_arena,
        };
    }

    /// Get all CDL/Spectre netlist files and schematic directories in the project.
    pub fn getFiles(
        self: *const Backend,
        project_dir: []const u8,
    ) !FileList {
        var cdl_files: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (cdl_files.items) |f| self.alloc.free(f);
            cdl_files.deinit(self.alloc);
        }

        var dir = std.fs.cwd().openDir(project_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return error.ProjectDirNotFound,
            else => return err,
        };
        defer dir.close();

        var walker = try dir.walk(self.alloc);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            const name = entry.basename;
            if (std.mem.endsWith(u8, name, ".cdl") or
                std.mem.endsWith(u8, name, ".scs") or
                std.mem.endsWith(u8, name, ".sp") or
                std.mem.endsWith(u8, name, ".spice") or
                std.mem.endsWith(u8, name, ".cir"))
            {
                try cdl_files.append(self.alloc, try self.alloc.dupe(u8, entry.path));
            }
        }

        return .{
            .files = try cdl_files.toOwnedSlice(self.alloc),
            .alloc = self.alloc,
        };
    }

    // ── Internal parsing methods ─────────────────────────────────────────────

    fn findNetlistFiles(self: *const Backend, project_dir: []const u8) !std.ArrayListUnmanaged([]const u8) {
        var files: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (files.items) |f| self.alloc.free(f);
            files.deinit(self.alloc);
        }

        var dir = std.fs.cwd().openDir(project_dir, .{ .iterate = true }) catch return files;
        defer dir.close();

        var walker = try dir.walk(self.alloc);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            const name = entry.basename;
            if (std.mem.endsWith(u8, name, ".cdl") or
                std.mem.endsWith(u8, name, ".scs") or
                std.mem.endsWith(u8, name, ".sp") or
                std.mem.endsWith(u8, name, ".spice") or
                std.mem.endsWith(u8, name, ".cir"))
            {
                try files.append(self.alloc, try self.alloc.dupe(u8, entry.path));
            }
        }

        return files;
    }

    /// Parse a CDL netlist and extract .SUBCKT definitions as ConvertResults.
    fn parseCdlNetlist(
        self: *const Backend,
        arena: Allocator,
        content: []const u8,
        results: *std.ArrayListUnmanaged(ConvertResult),
    ) !void {
        var parser = OA.CdlParser.init(content);
        while (parser.nextSubckt()) |subckt| {
            var sfy = convertSubckt(arena, subckt) catch continue;
            _ = self;
            try results.append(arena, .{
                .name = try arena.dupe(u8, subckt.name),
                .sch_path = null,
                .sym_path = null,
                .schemify = sfy,
            });
            _ = &sfy;
        }
    }

    /// Parse a Spectre netlist and extract subckt definitions as ConvertResults.
    fn parseSpectreNetlist(
        self: *const Backend,
        arena: Allocator,
        content: []const u8,
        results: *std.ArrayListUnmanaged(ConvertResult),
    ) !void {
        var parser = OA.SpectreParser.init(content);
        while (parser.nextSubckt()) |subckt| {
            var sfy = convertSubckt(arena, subckt) catch continue;
            _ = self;
            try results.append(arena, .{
                .name = try arena.dupe(u8, subckt.name),
                .sch_path = null,
                .sym_path = null,
                .schemify = sfy,
            });
            _ = &sfy;
        }
    }
};

/// Detect if content is in Spectre format (vs SPICE/CDL).
fn isSpectreFormat(content: []const u8) bool {
    // Spectre uses // comments and instance format: name (terminals) type params
    // CDL/SPICE uses * comments and .SUBCKT
    const check_len = @min(content.len, 2048);
    const header = content[0..check_len];
    if (std.mem.indexOf(u8, header, "//") != null) return true;
    if (std.mem.indexOf(u8, header, "simulator lang=spectre") != null) return true;
    if (std.mem.indexOf(u8, header, "subckt ") != null and
        std.mem.indexOf(u8, header, ".SUBCKT") == null) return true;
    return false;
}

/// Convert a parsed subcircuit (from either CDL or Spectre) into a Schemify object.
fn convertSubckt(arena: Allocator, subckt: OA.Subckt) !Schemify {
    var sfy: Schemify = .{};
    errdefer sfy.deinit(arena);

    sfy.setName(arena, subckt.name);
    sfy.stype = .symbol;

    // Add pins from the subcircuit port list
    for (subckt.ports, 0..) |port_name, idx| {
        const clean_name = if (isGlobalNet(port_name))
            (stripGlobalSuffix(port_name) orelse port_name)
        else
            port_name;

        try sfy.drawPin(arena, .{
            .name = clean_name,
            .x = @as(i32, @intCast(idx)) * 80,
            .y = 0,
            .dir = .inout,
            .num = @intCast(idx),
        });
    }

    // Register global nets
    for (subckt.globals) |global| {
        const clean = stripGlobalSuffix(global) orelse global;
        try sfy.addGlobal(arena, clean);
    }

    // Convert instances
    var inst_counter: u32 = 0;
    for (subckt.instances) |inst| {
        const kind = resolveDeviceKind(inst.cell);
        const ctx = pinContext(kind);

        // Build connections (pin->net mapping)
        var conns_buf: [16]Conn = undefined;
        const conn_count = @min(inst.nets.len, inst.pins.len);
        const conns_used = @min(conn_count, 16);
        for (0..conns_used) |i| {
            const pin_name = translatePin(inst.pins[i], ctx);
            var net = inst.nets[i];
            // Strip global suffix from net connections
            if (isGlobalNet(net)) {
                net = stripGlobalSuffix(net) orelse net;
            }
            conns_buf[i] = .{ .pin = pin_name, .net = net };
        }

        // Build properties
        var props_buf: [32]Property = undefined;
        var prop_count: usize = 0;
        for (inst.params) |param| {
            if (prop_count >= 32) break;
            if (translatePropKey(param.key, kind)) |new_key| {
                props_buf[prop_count] = .{ .key = new_key, .val = param.val };
                prop_count += 1;
            }
        }

        // Generate instance name if not provided
        const name = if (inst.name.len > 0)
            inst.name
        else blk: {
            break :blk try std.fmt.allocPrint(arena, "I{d}", .{inst_counter});
        };
        inst_counter += 1;

        _ = try sfy.addComponent(arena, .{
            .name = name,
            .symbol = inst.cell,
            .kind = kind,
            .x = 0,
            .y = @as(i32, @intCast(inst_counter)) * 100,
            .props = props_buf[0..prop_count],
            .conns = conns_buf[0..conns_used],
        });
    }

    return sfy;
}

// ── FileList for getFiles ────────���────────────────────────────────��──────────

pub const FileList = struct {
    files: []const []const u8,
    alloc: Allocator,

    pub fn deinit(self: *FileList) void {
        for (self.files) |f| self.alloc.free(@constCast(f));
        self.alloc.free(self.files);
    }
};

pub const Converter = Backend;

// ── Tests ────────────────────────────────────────────────────────────────────

test "resolveDeviceKind — analogLib exact matches" {
    const testing = std.testing;
    try testing.expectEqual(DeviceKind.resistor, resolveDeviceKind("res"));
    try testing.expectEqual(DeviceKind.capacitor, resolveDeviceKind("cap"));
    try testing.expectEqual(DeviceKind.inductor, resolveDeviceKind("ind"));
    try testing.expectEqual(DeviceKind.nmos4, resolveDeviceKind("nmos4"));
    try testing.expectEqual(DeviceKind.pmos4, resolveDeviceKind("pmos4"));
    try testing.expectEqual(DeviceKind.nmos3, resolveDeviceKind("nmos"));
    try testing.expectEqual(DeviceKind.pmos3, resolveDeviceKind("pmos"));
    try testing.expectEqual(DeviceKind.npn, resolveDeviceKind("npn"));
    try testing.expectEqual(DeviceKind.pnp, resolveDeviceKind("pnp"));
    try testing.expectEqual(DeviceKind.diode, resolveDeviceKind("diode"));
    try testing.expectEqual(DeviceKind.vsource, resolveDeviceKind("vdc"));
    try testing.expectEqual(DeviceKind.vsource, resolveDeviceKind("vsin"));
    try testing.expectEqual(DeviceKind.isource, resolveDeviceKind("idc"));
    try testing.expectEqual(DeviceKind.vcvs, resolveDeviceKind("vcvs"));
    try testing.expectEqual(DeviceKind.cccs, resolveDeviceKind("cccs"));
    try testing.expectEqual(DeviceKind.ammeter, resolveDeviceKind("iprobe"));
    try testing.expectEqual(DeviceKind.gnd, resolveDeviceKind("gnd"));
    try testing.expectEqual(DeviceKind.noconn, resolveDeviceKind("noConn"));
    try testing.expectEqual(DeviceKind.coupling, resolveDeviceKind("mind"));
    try testing.expectEqual(DeviceKind.behavioral, resolveDeviceKind("bsource"));
}

test "resolveDeviceKind — TSMC PDK cells" {
    const testing = std.testing;
    try testing.expectEqual(DeviceKind.nmos4, resolveDeviceKind("nch"));
    try testing.expectEqual(DeviceKind.pmos4, resolveDeviceKind("pch"));
    try testing.expectEqual(DeviceKind.nmos4, resolveDeviceKind("nch_lvt"));
    try testing.expectEqual(DeviceKind.pmos4, resolveDeviceKind("pch_hvt"));
    try testing.expectEqual(DeviceKind.nmos4, resolveDeviceKind("nch_io"));
}

test "resolveDeviceKind — GF180MCU prefix fallback" {
    const testing = std.testing;
    try testing.expectEqual(DeviceKind.nmos4, resolveDeviceKind("nfet_03v3"));
    try testing.expectEqual(DeviceKind.pmos4, resolveDeviceKind("pfet_06v0"));
    try testing.expectEqual(DeviceKind.npn, resolveDeviceKind("npn_10x10"));
    try testing.expectEqual(DeviceKind.diode, resolveDeviceKind("diode_nd2ps_03v3"));
    try testing.expectEqual(DeviceKind.capacitor, resolveDeviceKind("cap_mim_2f5fF"));
}

test "resolveDeviceKind — unknown cell falls back to .subckt" {
    const testing = std.testing;
    try testing.expectEqual(DeviceKind.subckt, resolveDeviceKind("my_custom_opamp"));
    try testing.expectEqual(DeviceKind.subckt, resolveDeviceKind("inv_x1"));
}

test "translatePin — MOSFET context" {
    const testing = std.testing;
    try testing.expectEqualStrings("drain", translatePin("D", .mosfet));
    try testing.expectEqualStrings("gate", translatePin("G", .mosfet));
    try testing.expectEqualStrings("source", translatePin("S", .mosfet));
    try testing.expectEqualStrings("body", translatePin("B", .mosfet));
}

test "translatePin — BJT context" {
    const testing = std.testing;
    try testing.expectEqualStrings("collector", translatePin("C", .bjt));
    try testing.expectEqualStrings("base", translatePin("B", .bjt));
    try testing.expectEqualStrings("emitter", translatePin("E", .bjt));
    try testing.expectEqualStrings("sub", translatePin("S", .bjt));
}

test "translatePin — passive context" {
    const testing = std.testing;
    try testing.expectEqualStrings("p", translatePin("PLUS", .passive));
    try testing.expectEqualStrings("n", translatePin("MINUS", .passive));
}

test "translatePin — controlled source context" {
    const testing = std.testing;
    try testing.expectEqualStrings("inp", translatePin("inp", .controlled_source));
    try testing.expectEqualStrings("outn", translatePin("outn", .controlled_source));
}

test "stripGlobalSuffix" {
    const testing = std.testing;
    try testing.expectEqualStrings("VDD", stripGlobalSuffix("VDD!").?);
    try testing.expectEqualStrings("gnd", stripGlobalSuffix("gnd!").?);
    try testing.expect(stripGlobalSuffix("normal_net") == null);
    try testing.expect(stripGlobalSuffix("!") == null); // single char: not a valid global
}

test "isGlobalNet" {
    const testing = std.testing;
    try testing.expect(isGlobalNet("VDD!"));
    try testing.expect(isGlobalNet("gnd!"));
    try testing.expect(!isGlobalNet("net1"));
    try testing.expect(!isGlobalNet("!"));
}

test "parseCdsLib — basic DEFINE entries" {
    const testing = std.testing;
    const content =
        \\# Comment line
        \\DEFINE analogLib /tools/cadence/IC23/tools/dfII/etc/cdslib/artist/analogLib
        \\DEFINE basic /tools/cadence/IC23/tools/dfII/etc/cdslib/basic
        \\DEFINE myDesign ./myDesign
        \\
    ;
    var cds = try parseCdsLib(testing.allocator, content, "/home/user/project");
    defer cds.deinit();

    try testing.expectEqual(@as(usize, 3), cds.entries.len);
    try testing.expectEqualStrings("analogLib", cds.entries[0].name);
    try testing.expectEqualStrings("/tools/cadence/IC23/tools/dfII/etc/cdslib/artist/analogLib", cds.entries[0].path);
    try testing.expectEqualStrings("basic", cds.entries[1].name);
    try testing.expectEqualStrings("myDesign", cds.entries[2].name);
    try testing.expectEqualStrings("/home/user/project/myDesign", cds.entries[2].path);
}

test "parseCdsLib — getLibPath" {
    const testing = std.testing;
    const content = "DEFINE myLib /opt/libs/myLib\n";
    var cds = try parseCdsLib(testing.allocator, content, "/tmp");
    defer cds.deinit();

    try testing.expectEqualStrings("/opt/libs/myLib", cds.getLibPath("myLib").?);
    try testing.expect(cds.getLibPath("nonexistent") == null);
}

test "translatePropKey — preserved props" {
    const testing = std.testing;
    try testing.expectEqualStrings("w", translatePropKey("w", .nmos4).?);
    try testing.expectEqualStrings("l", translatePropKey("l", .nmos4).?);
    try testing.expectEqualStrings("m", translatePropKey("m", .resistor).?);
    try testing.expectEqualStrings("nf", translatePropKey("nf", .pmos4).?);
}

test "translatePropKey — renamed props" {
    const testing = std.testing;
    try testing.expectEqualStrings("value", translatePropKey("r", .resistor).?);
    try testing.expectEqualStrings("value", translatePropKey("c", .capacitor).?);
    try testing.expectEqualStrings("dc", translatePropKey("vdc", .vsource).?);
    try testing.expectEqualStrings("gain", translatePropKey("egain", .vcvs).?);
}

test "translatePropKey — inductor 'l' becomes 'value'" {
    const testing = std.testing;
    // For inductors, 'l' means inductance value (not channel length)
    try testing.expectEqualStrings("value", translatePropKey("l", .inductor).?);
}

test "translatePropKey — stripped props" {
    const testing = std.testing;
    try testing.expect(translatePropKey("sa", .nmos4) == null);
    try testing.expect(translatePropKey("sb", .pmos4) == null);
    try testing.expect(translatePropKey("topography", .nmos4) == null);
}

test "Backend.label" {
    const testing = std.testing;
    const backend = Backend.init(testing.allocator);
    try testing.expectEqualStrings("Cadence Virtuoso", backend.label());
}

test "isSpectreFormat detection" {
    const testing = std.testing;
    try testing.expect(isSpectreFormat("// Spectre netlist\nsubckt inv"));
    try testing.expect(isSpectreFormat("simulator lang=spectre\nsubckt foo"));
    try testing.expect(!isSpectreFormat("* SPICE netlist\n.SUBCKT inv"));
    try testing.expect(!isSpectreFormat(".SUBCKT foo a b"));
}

test "convertSubckt — simple resistor subcircuit" {
    const testing = std.testing;
    const subckt = OA.Subckt{
        .name = "my_res",
        .ports = &.{ "A", "B" },
        .instances = &.{
            .{
                .name = "R0",
                .cell = "res",
                .nets = &.{ "A", "B" },
                .pins = &.{ "PLUS", "MINUS" },
                .params = &.{.{ .key = "r", .val = "1k" }},
            },
        },
        .globals = &.{},
    };

    var sfy = try convertSubckt(testing.allocator, subckt);
    defer sfy.deinit(testing.allocator);

    try testing.expectEqualStrings("my_res", sfy.name);
    try testing.expectEqual(@as(usize, 2), sfy.pins.len); // 2 ports
    try testing.expectEqual(@as(usize, 1), sfy.instances.len); // 1 instance
    // Check the instance's kind
    try testing.expectEqual(DeviceKind.resistor, sfy.instances.items(.kind)[0]);
}

test "convertSubckt — MOSFET with global nets" {
    const testing = std.testing;
    const subckt = OA.Subckt{
        .name = "inv",
        .ports = &.{ "in", "out", "VDD!", "GND!" },
        .instances = &.{
            .{
                .name = "M0",
                .cell = "nmos4",
                .nets = &.{ "out", "in", "GND!", "GND!" },
                .pins = &.{ "D", "G", "S", "B" },
                .params = &.{
                    .{ .key = "w", .val = "1u" },
                    .{ .key = "l", .val = "100n" },
                },
            },
            .{
                .name = "M1",
                .cell = "pmos4",
                .nets = &.{ "out", "in", "VDD!", "VDD!" },
                .pins = &.{ "D", "G", "S", "B" },
                .params = &.{
                    .{ .key = "w", .val = "2u" },
                    .{ .key = "l", .val = "100n" },
                },
            },
        },
        .globals = &.{ "VDD!", "GND!" },
    };

    var sfy = try convertSubckt(testing.allocator, subckt);
    defer sfy.deinit(testing.allocator);

    try testing.expectEqualStrings("inv", sfy.name);
    try testing.expectEqual(@as(usize, 4), sfy.pins.len); // 4 ports (including globals as ports)
    try testing.expectEqual(@as(usize, 2), sfy.instances.len);
    try testing.expectEqual(@as(usize, 2), sfy.globals.items.len); // VDD, GND
    try testing.expectEqual(DeviceKind.nmos4, sfy.instances.items(.kind)[0]);
    try testing.expectEqual(DeviceKind.pmos4, sfy.instances.items(.kind)[1]);

    // Verify global names have ! stripped
    try testing.expectEqualStrings("VDD", sfy.globals.items[0]);
    try testing.expectEqualStrings("GND", sfy.globals.items[1]);
}

test "CDL parser — simple MOSFET subcircuit" {
    const testing = std.testing;
    const cdl_content =
        \\.GLOBAL GND! VDD!
        \\*
        \\.SUBCKT inverter in out VDD GND
        \\M0 out in GND GND nch w=1u l=100n
        \\M1 out in VDD VDD pch w=2u l=100n
        \\.ENDS inverter
        \\
    ;

    var parser = OA.CdlParser.init(cdl_content);
    const subckt = parser.nextSubckt();
    try testing.expect(subckt != null);
    const s = subckt.?;
    try testing.expectEqualStrings("inverter", s.name);
    try testing.expectEqual(@as(usize, 4), s.ports.len);
    try testing.expectEqual(@as(usize, 2), s.instances.len);
    try testing.expectEqualStrings("M0", s.instances[0].name);
    try testing.expectEqualStrings("nch", s.instances[0].cell);
    try testing.expectEqual(@as(usize, 4), s.instances[0].nets.len);

    // No more subcircuits
    try testing.expect(parser.nextSubckt() == null);
}

test "CDL parser — continuation lines" {
    const testing = std.testing;
    const cdl_content =
        \\.SUBCKT big_cell a b c d
        \\M0 a b c d nmos4
        \\+ w=1u l=100n m=2
        \\.ENDS big_cell
        \\
    ;

    var parser = OA.CdlParser.init(cdl_content);
    const subckt = parser.nextSubckt();
    try testing.expect(subckt != null);
    const s = subckt.?;
    try testing.expectEqualStrings("big_cell", s.name);
    try testing.expectEqual(@as(usize, 4), s.ports.len);
}

test "CDL parser — resistor and capacitor" {
    const testing = std.testing;
    const cdl_content =
        \\.SUBCKT rc_filter in out gnd
        \\R1 in mid 1k
        \\C1 mid gnd 10p
        \\.ENDS rc_filter
        \\
    ;

    var parser = OA.CdlParser.init(cdl_content);
    const subckt = parser.nextSubckt();
    try testing.expect(subckt != null);
    const s = subckt.?;
    try testing.expectEqualStrings("rc_filter", s.name);
    try testing.expectEqual(@as(usize, 2), s.instances.len);
    try testing.expectEqualStrings("res", s.instances[0].cell);
    try testing.expectEqualStrings("cap", s.instances[1].cell);
}

test "Spectre parser — basic subckt" {
    const testing = std.testing;
    const spectre_content =
        \\// Spectre netlist
        \\subckt amp (inp inn out vdd vss)
        \\M0 (out inp vss vss) nmos4 w=1u l=100n
        \\M1 (out inn vdd vdd) pmos4 w=2u l=100n
        \\ends amp
        \\
    ;

    var parser = OA.SpectreParser.init(spectre_content);
    const subckt = parser.nextSubckt();
    try testing.expect(subckt != null);
    const s = subckt.?;
    try testing.expectEqualStrings("amp", s.name);
    try testing.expectEqual(@as(usize, 5), s.ports.len);
    try testing.expectEqual(@as(usize, 2), s.instances.len);
    try testing.expectEqualStrings("M0", s.instances[0].name);
    try testing.expectEqualStrings("nmos4", s.instances[0].cell);
    try testing.expectEqual(@as(usize, 4), s.instances[0].nets.len);
}
