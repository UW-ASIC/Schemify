const std = @import("std");
const core = @import("schematic");
const platform = @import("utility").platform;
const ct = @import("../types.zig");
const PdkMap = @import("../PdkMap.zig");

pub const ConvertResult = ct.ConvertResult;
pub const ConvertResultList = ct.ConvertResultList;
pub const OA = @import("oa.zig");

const Allocator = std.mem.Allocator;
const Schemify = core.Schemify;
const DeviceKind = core.types.DeviceKind;
const Property = core.types.Property;
const Conn = core.types.Conn;

// ── Device resolution (delegated to PdkMap) ─────────────────────────────────

pub fn resolveDeviceKind(cell: []const u8) DeviceKind {
    return PdkMap.resolveKind(&PdkMap.pdk_table, cell);
}

// ── Pin / net / property translation (re-exported from PdkMap) ──────────────

pub const PinContext = PdkMap.PinContext;
pub const pinContext = PdkMap.pinContext;
pub const translatePin = PdkMap.translatePin;
pub const stripGlobalSuffix = PdkMap.stripGlobalSuffix;
pub const isGlobalNet = PdkMap.isGlobalNet;
pub const translatePropKey = PdkMap.translatePropKey;

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
        platform.fs.cwd().access(cds, .{}) catch return false;
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

        const cds_content = platform.fs.cwd().readFileAlloc(self.alloc, cds_path, 1 << 20) catch |err| switch (err) {
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

            const content = platform.fs.cwd().readFileAlloc(self.alloc, full_path, 16 << 20) catch continue;
            defer self.alloc.free(content);

            // Detect format and parse
            const is_spectre = isSpectreFormat(content, std.fs.path.basename(netlist_path));
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

        var dir = platform.fs.cwd().openDir(project_dir, .{ .iterate = true }) catch |err| switch (err) {
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

        var dir = platform.fs.cwd().openDir(project_dir, .{ .iterate = true }) catch return files;
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            const name = entry.name;
            if (std.mem.endsWith(u8, name, ".cdl") or
                std.mem.endsWith(u8, name, ".scs") or
                std.mem.endsWith(u8, name, ".sp") or
                std.mem.endsWith(u8, name, ".spice") or
                std.mem.endsWith(u8, name, ".cir"))
            {
                try files.append(self.alloc, try self.alloc.dupe(u8, name));
            }
        }

        return files;
    }

    /// Parse a CDL netlist and extract .SUBCKT definitions as ConvertResults.
    fn parseCdlNetlist(
        _: *const Backend,
        arena: Allocator,
        content: []const u8,
        results: *std.ArrayListUnmanaged(ConvertResult),
    ) !void {
        var parser = OA.CdlParser.init(content);
        while (parser.nextSubckt()) |subckt| {
            const sfy = convertSubckt(arena, subckt) catch continue;
            try results.append(arena, .{
                .name = try arena.dupe(u8, subckt.name),
                .sch_path = null,
                .sym_path = null,
                .schemify = sfy,
            });
        }
    }

    /// Parse a Spectre netlist and extract subckt definitions as ConvertResults.
    fn parseSpectreNetlist(
        _: *const Backend,
        arena: Allocator,
        content: []const u8,
        results: *std.ArrayListUnmanaged(ConvertResult),
    ) !void {
        var parser = OA.SpectreParser.init(content);
        while (parser.nextSubckt()) |subckt| {
            const sfy = convertSubckt(arena, subckt) catch continue;
            try results.append(arena, .{
                .name = try arena.dupe(u8, subckt.name),
                .sch_path = null,
                .sym_path = null,
                .schemify = sfy,
            });
        }
    }
};

/// Detect if content is in Spectre format (vs SPICE/CDL).
/// Multi-level strategy: extension > directive > keyword analysis > comment style.
fn isSpectreFormat(content: []const u8, filename: ?[]const u8) bool {
    // Level 1: File extension (definitive)
    if (filename) |name| {
        if (std.mem.endsWith(u8, name, ".scs")) return true;
        if (std.mem.endsWith(u8, name, ".cdl")) return false;
    }

    const check_len = @min(content.len, 4096);
    const header = content[0..check_len];

    // Level 2: Definitive directive
    if (std.mem.indexOf(u8, header, "simulator lang=spectre") != null) return true;

    // Level 3: Keyword analysis
    // .SUBCKT (with dot, case-insensitive) is definitively CDL/SPICE
    if (hasDotSubckt(header)) return false;

    // subckt without dot prefix at line start → Spectre
    if (hasSpectreSubckt(header)) return true;

    // Level 4: Comment style — only // at line start (not in URLs)
    if (hasLineStartComment(header)) return true;

    return false; // Default: CDL
}

/// Check for .SUBCKT or .subckt (dot-prefixed, any case).
fn hasDotSubckt(content: []const u8) bool {
    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '.' and i + 7 <= content.len) {
            if (std.ascii.eqlIgnoreCase(content[i .. i + 7], ".subckt")) return true;
        }
        // Skip to next line
        while (i < content.len and content[i] != '\n') : (i += 1) {}
        i += 1; // skip newline
    }
    return false;
}

/// Check for `subckt ` at line start (no dot prefix) — Spectre keyword.
fn hasSpectreSubckt(content: []const u8) bool {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "subckt ") or
            std.mem.startsWith(u8, trimmed, "subckt\t"))
        {
            return true;
        }
    }
    return false;
}

/// Check for `//` at start of line (Spectre comment), not embedded in URLs.
fn hasLineStartComment(content: []const u8) bool {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//")) return true;
    }
    return false;
}

/// Convert a parsed subcircuit (from either CDL or Spectre) into a Schemify object.
fn convertSubckt(arena: Allocator, subckt: OA.Subckt) !Schemify {
    var sfy: Schemify = .{};
    errdefer sfy.deinit(arena);

    try sfy.setName(arena, subckt.name);
    sfy.stype = .symbol;

    // Add pins from the subcircuit port list
    for (subckt.ports, 0..) |port_name, idx| {
        const clean_name = if (isGlobalNet(port_name))
            (stripGlobalSuffix(port_name) orelse port_name)
        else
            port_name;

        try sfy.drawPinStr(arena, clean_name, @as(i32, @intCast(idx)) * 80, 0, .inout);
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
        const ConnElem = std.meta.Elem(@TypeOf(@as(Schemify.ComponentDesc, undefined).conns));
        var conns_buf: [16]ConnElem = undefined;
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
        const PropElem = std.meta.Elem(@TypeOf(@as(Schemify.ComponentDesc, undefined).props));
        var props_buf: [32]PropElem = undefined;
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

// ── FileList for getFiles ────────────────────────────────────────────────────

pub const FileList = struct {
    files: []const []const u8,
    alloc: Allocator,

    pub fn deinit(self: *FileList) void {
        for (self.files) |f| self.alloc.free(@constCast(f));
        self.alloc.free(self.files);
    }
};


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
    // Definitive: file extension
    try testing.expect(isSpectreFormat("anything", "amp.scs"));
    try testing.expect(!isSpectreFormat("anything", "amp.cdl"));

    // Definitive: simulator directive
    try testing.expect(isSpectreFormat("simulator lang=spectre\nsubckt foo", null));

    // .SUBCKT → CDL (even with // in content)
    try testing.expect(!isSpectreFormat(".SUBCKT inv a b\n// some comment", null));

    // subckt (no dot) → Spectre
    try testing.expect(isSpectreFormat("subckt inv (a b)\nends inv", null));

    // // at line start → Spectre
    try testing.expect(isSpectreFormat("// Spectre netlist\nsubckt inv", null));

    // // NOT at line start (URL in SPICE comment) → NOT Spectre
    try testing.expect(!isSpectreFormat("* See http://example.com\n.SUBCKT foo a b", null));

    // Pure SPICE with * comments → CDL (default)
    try testing.expect(!isSpectreFormat("* SPICE netlist\n.SUBCKT inv a b\n.ENDS inv", null));

    // Empty content → default CDL
    try testing.expect(!isSpectreFormat("", null));
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

    try testing.expectEqualStrings("my_res", sfy.str(sfy.name));
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

    try testing.expectEqualStrings("inv", sfy.str(sfy.name));
    try testing.expectEqual(@as(usize, 4), sfy.pins.len); // 4 ports (including globals as ports)
    try testing.expectEqual(@as(usize, 2), sfy.instances.len);
    try testing.expectEqual(@as(usize, 2), sfy.globals.items.len); // VDD, GND
    try testing.expectEqual(DeviceKind.nmos4, sfy.instances.items(.kind)[0]);
    try testing.expectEqual(DeviceKind.pmos4, sfy.instances.items(.kind)[1]);

    // Verify global names have ! stripped
    try testing.expectEqualStrings("VDD", sfy.str(sfy.globals.items[0]));
    try testing.expectEqualStrings("GND", sfy.str(sfy.globals.items[1]));
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
