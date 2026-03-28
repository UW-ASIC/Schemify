// mod.zig - Public API for the XSchem backend.
//
// Exposes the Backend struct (matching the EasyImport interface contract),
// the XSchemFiles container, and re-exports from sub-modules.

const std = @import("std");
const core = @import("core");
const ct = @import("convert_types");
const converter = @import("converter.zig");
const tcl = @import("tcl");

// ── Re-exports from types.zig ────────────────────────────────────────────

const types = @import("types.zig");

pub const PinDirection = types.PinDirection;
pub const pinDirectionFromStr = types.pinDirectionFromStr;
pub const pinDirectionToStr = types.pinDirectionToStr;
pub const Line = types.Line;
pub const Rect = types.Rect;
pub const Arc = types.Arc;
pub const Circle = types.Circle;
pub const Wire = types.Wire;
pub const Text = types.Text;
pub const Pin = types.Pin;
pub const Instance = types.Instance;
pub const Prop = types.Prop;
pub const FileType = types.FileType;
pub const ParseError = types.ParseError;
pub const XSchemFiles = types.XSchemFiles;

// ── Re-exports from props.zig ────────────────────────────────────────────

const props = @import("props.zig");

pub const PropertyTokenizer = props.PropertyTokenizer;
pub const parseProps = props.parseProps;

// ── Re-exports from reader.zig ─────────────────────────────────────────

const reader = @import("reader.zig");

pub const parse = reader.parse;

// ── Re-exports from xschemrc.zig ────────────────────────────────────────

const xschemrc = @import("xschemrc.zig");

pub const RcResult = xschemrc.RcResult;
pub const parseRc = xschemrc.parseRc;

// ── Re-exports from converter.zig ────────────────────────────────────────

pub const convert = converter.convert;

// ── Re-exports from convert_types (shared result types) ─────────────────

pub const ConvertResult = ct.ConvertResult;
pub const ConvertResultList = ct.ConvertResultList;

const StemMaps = struct {
    sch_map: std.StringHashMapUnmanaged([]const u8) = .{},
    sym_map: std.StringHashMapUnmanaged([]const u8) = .{},
    stems: std.StringHashMapUnmanaged(void) = .{},

    fn initFromFiles(alloc: std.mem.Allocator, files: *const FileList) !StemMaps {
        var maps: StemMaps = .{};
        for (files.sch_files) |f| {
            const stem = stemName(f);
            try maps.sch_map.put(alloc, stem, try alloc.dupe(u8, f));
            try maps.stems.put(alloc, stem, {});
        }
        for (files.sym_files) |f| {
            const stem = stemName(f);
            try maps.sym_map.put(alloc, stem, try alloc.dupe(u8, f));
            try maps.stems.put(alloc, stem, {});
        }
        return maps;
    }
};

// ── Symbol resolution context for converter ─────────────────────────────

const SymResolveCtx = struct {
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    sym_map: *const std.StringHashMapUnmanaged([]const u8),
    lib_paths: []const []const u8,

    fn resolveFn(ctx_opaque: *anyopaque, sym_path: []const u8) ?types.XSchemFiles {
        const self: *SymResolveCtx = @ptrCast(@alignCast(ctx_opaque));
        return self.resolveImpl(sym_path);
    }

    fn resolveImpl(self: *SymResolveCtx, sym_path: []const u8) ?types.XSchemFiles {
        const stem = stemName(sym_path);

        // Special case: when sym_path ends with ".sch", XSchem uses the .sch
        // file's ipin/opin/iopin instances as pin positions (not the .sym's B 5
        // pins). Parse the .sch and synthesize pins from its instances, then
        // overlay K-block data from the .sym if available.
        if (std.mem.endsWith(u8, sym_path, ".sch")) {
            if (self.resolveSchAsSymbol(sym_path, stem)) |s| return s;
        }

        // 1. Check project's sym_map (local .sym files)
        if (self.sym_map.get(stem)) |rel| {
            if (self.parseSymFile(self.project_dir, rel)) |s| return s;
        }

        // 2. Search lib_paths for the symbol file
        const sym_file = if (std.mem.endsWith(u8, sym_path, ".sym")) sym_path else blk: {
            break :blk std.fmt.allocPrint(self.alloc, "{s}.sym", .{sym_path}) catch return null;
        };
        defer if (!std.mem.eql(u8, sym_file, sym_path)) self.alloc.free(sym_file);

        for (self.lib_paths) |lib| {
            if (self.parseSymFile(lib, sym_file)) |s| return s;
            // Also try just the basename
            const base = if (std.mem.lastIndexOfScalar(u8, sym_file, '/')) |idx| sym_file[idx + 1 ..] else sym_file;
            if (!std.mem.eql(u8, base, sym_file)) {
                if (self.parseSymFile(lib, base)) |s| return s;
            }
        }

        return null;
    }

    /// When a .sch file is used as a symbol reference (e.g. `C {foo.sch}`),
    /// XSchem derives pin positions from the .sch's ipin/opin/iopin instances
    /// but preserves the pin ORDER from the .sym's B 5 pins.
    /// This function:
    /// 1. Parses the .sch file to get pin positions from ipin/opin/iopin
    /// 2. Resolves the .sym to get pin order and K-block data
    /// 3. Merges: .sym pin order + .sch pin positions
    fn resolveSchAsSymbol(self: *SymResolveCtx, sch_path: []const u8, stem: []const u8) ?types.XSchemFiles {
        // Try to parse the .sch file from the project directory
        var sch = self.parseSymFile(self.project_dir, sch_path) orelse return null;

        // Build a name→position lookup from .sch's ipin/opin/iopin instances
        const inst_sl = sch.instances.slice();
        const inst_syms = inst_sl.items(.symbol);
        const inst_xs = inst_sl.items(.x);
        const inst_ys = inst_sl.items(.y);
        const inst_ps = inst_sl.items(.prop_start);
        const inst_pc = inst_sl.items(.prop_count);

        const arena = sch.arena.allocator();

        const PinPos = struct { x: f64, y: f64, dir: types.PinDirection };
        var pin_pos_map = std.StringHashMapUnmanaged(PinPos){};
        defer pin_pos_map.deinit(self.alloc);

        for (0..sch.instances.len) |i| {
            const isym = stemName(inst_syms[i]);
            const dir: types.PinDirection = if (std.mem.eql(u8, isym, "ipin"))
                .input
            else if (std.mem.eql(u8, isym, "opin"))
                .output
            else if (std.mem.eql(u8, isym, "iopin"))
                .inout
            else
                continue;

            // Find the "lab" property for the pin name
            var pin_name: []const u8 = "";
            const p_start = inst_ps[i];
            const p_count = inst_pc[i];
            for (sch.props.items[p_start..][0..p_count]) |p| {
                if (std.mem.eql(u8, p.key, "lab")) {
                    pin_name = p.value;
                    break;
                }
            }
            if (pin_name.len == 0) continue;

            pin_pos_map.put(self.alloc, pin_name, .{
                .x = inst_xs[i],
                .y = inst_ys[i],
                .dir = dir,
            }) catch continue;
        }

        // Try to resolve the matching .sym file for pin order and K-block
        if (self.sym_map.get(stem)) |rel| {
            if (self.parseSymFile(self.project_dir, rel)) |sym_file| {
                var sf = sym_file;
                defer sf.deinit();

                // Copy K-block data from .sym
                if (sf.k_type) |kt| sch.k_type = arena.dupe(u8, kt) catch null;
                if (sf.k_format) |kf| sch.k_format = arena.dupe(u8, kf) catch null;
                if (sf.k_template) |ktpl| sch.k_template = arena.dupe(u8, ktpl) catch null;
                sch.k_global = sf.k_global;

                // Use .sym pin order but substitute positions from .sch
                if (sf.pins.len > 0) {
                    const sym_pin_sl = sf.pins.slice();
                    for (0..sf.pins.len) |pi| {
                        const pname = sym_pin_sl.items(.name)[pi];
                        const duped_name = arena.dupe(u8, pname) catch continue;
                        if (pin_pos_map.get(pname)) |pos| {
                            // Use .sch position with .sym order
                            sch.pins.append(arena, .{
                                .name = duped_name,
                                .x = pos.x,
                                .y = pos.y,
                                .direction = pos.dir,
                                .number = sym_pin_sl.items(.number)[pi],
                            }) catch continue;
                        } else {
                            // Fallback: use .sym position if no .sch match
                            sch.pins.append(arena, .{
                                .name = duped_name,
                                .x = sym_pin_sl.items(.x)[pi],
                                .y = sym_pin_sl.items(.y)[pi],
                                .direction = sym_pin_sl.items(.direction)[pi],
                                .number = sym_pin_sl.items(.number)[pi],
                            }) catch continue;
                        }
                    }
                    return sch;
                }
            }
        }

        // No .sym found — use .sch pin positions in file order
        var it = pin_pos_map.iterator();
        while (it.next()) |entry| {
            sch.pins.append(arena, .{
                .name = arena.dupe(u8, entry.key_ptr.*) catch continue,
                .x = entry.value_ptr.x,
                .y = entry.value_ptr.y,
                .direction = entry.value_ptr.dir,
            }) catch continue;
        }

        return sch;
    }

    fn parseSymFile(self: *SymResolveCtx, dir: []const u8, rel: []const u8) ?types.XSchemFiles {
        const full = std.fs.path.join(self.alloc, &.{ dir, rel }) catch return null;
        defer self.alloc.free(full);
        const data = std.fs.cwd().readFileAlloc(self.alloc, full, 4 << 20) catch return null;
        defer self.alloc.free(data);
        return reader.parse(self.alloc, data) catch null;
    }
};

// ── Backend ──────────────────────────────────────────────────────────────

/// XSchem import backend. Implements the EasyImport backend contract:
/// init, deinit, label, detectProjectRoot, convertProject, getFiles.
pub const Backend = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Backend {
        return .{ .alloc = alloc };
    }

    pub fn deinit(_: *Backend) void {}

    pub fn label(_: *const Backend) []const u8 {
        return "XSchem";
    }

    /// Detect whether `project_dir` looks like an XSchem project
    /// by checking for an xschemrc file at the root.
    pub fn detectProjectRoot(self: *const Backend, project_dir: []const u8) bool {
        const rc = std.fs.path.join(self.alloc, &.{ project_dir, "xschemrc" }) catch return false;
        defer self.alloc.free(rc);
        std.fs.cwd().access(rc, .{}) catch return false;
        return true;
    }

    /// Convert an entire XSchem project into Schemify format.
    ///
    /// Pipeline:
    ///   1. Locate and parse xschemrc -> lib paths + PDK root
    ///   2. Enumerate .sch/.sym files under the project
    ///   3. Pair .sch/.sym by stem name
    ///   4. Parse each file and convert to core.Schemify
    ///
    /// Returns a list of (XSchem source, Schemify output) pairs.
    pub fn convertProject(
        self: *const Backend,
        project_dir: []const u8,
    ) !ConvertResultList {
        // Step 1: parse xschemrc to discover search paths
        const rc_path = try std.fs.path.join(self.alloc, &.{ project_dir, "xschemrc" });
        defer self.alloc.free(rc_path);

        const rc_bytes = std.fs.cwd().readFileAlloc(self.alloc, rc_path, 1 << 20) catch |err| switch (err) {
            error.FileNotFound => return error.NoXschemrc,
            else => return err,
        };
        defer self.alloc.free(rc_bytes);

        var rc = try parseRc(self.alloc, rc_bytes, project_dir, rc_path);
        defer rc.deinit();
        _ = rc.lib_paths;

        // Step 2: enumerate .sch/.sym files
        var files = try self.getFiles(project_dir);
        defer files.deinit();

        // Step 3: pair by stem name
        var list_arena = std.heap.ArenaAllocator.init(self.alloc);
        errdefer list_arena.deinit();
        const la = list_arena.allocator();

        const maps = try StemMaps.initFromFiles(la, &files);

        var resolve_ctx = SymResolveCtx{
            .alloc = self.alloc,
            .project_dir = project_dir,
            .sym_map = &maps.sym_map,
            .lib_paths = rc.lib_paths,
        };
        const sym_resolver = converter.SymResolver{
            .ctx = @ptrCast(&resolve_ctx),
            .resolveFn = &SymResolveCtx.resolveFn,
        };

        // Step 4: parse and convert each pair
        var results: std.ArrayListUnmanaged(ConvertResult) = .{};
        var stem_iter = maps.stems.keyIterator();
        while (stem_iter.next()) |stem_ptr| {
            const stem = stem_ptr.*;
            const sch_rel = maps.sch_map.get(stem);
            const sym_rel = maps.sym_map.get(stem);

            const sch_path = sch_rel orelse continue;
            var schematic = (try self.tryParseProjectFile(project_dir, sch_path, stem)) orelse continue;
            var symbol = if (sym_rel) |rel| try self.tryParseProjectFile(project_dir, rel, null) else null;

            // Convert to Schemify, then discard XSchem intermediates
            const schemify = converter.convert(
                self.alloc,
                &schematic,
                if (symbol) |*s| s else null,
                stem,
                sym_resolver,
            ) catch {
                schematic.deinit();
                if (symbol) |*s| s.deinit();
                continue;
            };
            schematic.deinit();
            if (symbol) |*s| s.deinit();

            try appendResult(&results, la, stem, sch_rel, sym_rel, schemify);
        }

        // Step 5: hierarchical subcircuit resolution — for each schematic,
        // find referenced subcircuits that exist as other results and build
        // inline_spice with their .subckt definitions (bottom-up).
        try resolveHierarchy(self.alloc, results.items);

        return .{
            .results = try results.toOwnedSlice(la),
            .arena = list_arena,
        };
    }

    fn tryParseProjectFile(
        self: *const Backend,
        project_dir: []const u8,
        rel_path: []const u8,
        maybe_name: ?[]const u8,
    ) !?XSchemFiles {
        const full = try std.fs.path.join(self.alloc, &.{ project_dir, rel_path });
        defer self.alloc.free(full);

        const data = std.fs.cwd().readFileAlloc(self.alloc, full, 4 << 20) catch return null;
        defer self.alloc.free(data);

        var parsed = parse(self.alloc, data) catch return null;
        if (maybe_name) |name| {
            parsed.name = try parsed.arena.allocator().dupe(u8, name);
        }
        return parsed;
    }

    /// Enumerate all .sch and .sym files under the project directory.
    pub fn getFiles(
        self: *const Backend,
        project_dir: []const u8,
    ) !FileList {
        var sch_files: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (sch_files.items) |f| self.alloc.free(f);
            sch_files.deinit(self.alloc);
        }
        var sym_files: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (sym_files.items) |f| self.alloc.free(f);
            sym_files.deinit(self.alloc);
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
            if (std.mem.endsWith(u8, name, ".sch")) {
                try sch_files.append(self.alloc, try self.alloc.dupe(u8, entry.path));
            } else if (std.mem.endsWith(u8, name, ".sym")) {
                try sym_files.append(self.alloc, try self.alloc.dupe(u8, entry.path));
            }
        }

        return .{
            .sch_files = try sch_files.toOwnedSlice(self.alloc),
            .sym_files = try sym_files.toOwnedSlice(self.alloc),
            .alloc = self.alloc,
        };
    }
};

fn appendResult(
    results: *std.ArrayListUnmanaged(ConvertResult),
    alloc: std.mem.Allocator,
    stem: []const u8,
    sch_rel: ?[]const u8,
    sym_rel: ?[]const u8,
    schemify: core.Schemify,
) !void {
    try results.append(alloc, .{
        .name = try alloc.dupe(u8, stem),
        .sch_path = if (sch_rel) |r| try alloc.dupe(u8, r) else null,
        .sym_path = if (sym_rel) |r| try alloc.dupe(u8, r) else null,
        .schemify = schemify,
    });
}

/// Information about a schematic override (instance with `schematic=...` attribute).
const SchematicOverride = struct {
    override_name: []const u8, // stem of schematic attr (e.g. "test_evaluated_param2")
    base_name: []const u8, // base symbol/result name (e.g. "test_evaluated_param")
    params: []const core.Prop, // instance parameter overrides (e.g. DEL=5)
};

/// Resolve hierarchical subcircuit dependencies across results.
/// For each result, find instances that reference other results (by symbol name)
/// and generate inline_spice with .subckt definitions in bottom-up order.
///
/// Also handles XSchem "schematic override" patterns where instances specify
/// `schematic=foo.sch` to create unique subcircuit variants with different
/// parameter values. For each override, a separate .subckt definition is
/// emitted with @PARAM references resolved and expr() expressions evaluated.
fn resolveHierarchy(alloc: std.mem.Allocator, results: []ConvertResult) !void {
    // Build name→index map
    var name_map = std.StringHashMapUnmanaged(usize){};
    defer name_map.deinit(alloc);
    for (results, 0..) |r, i| {
        name_map.put(alloc, r.name, i) catch {};
    }

    // Scan all instances across all results to find schematic overrides.
    // An override occurs when an instance has a `schematic` property whose
    // stem differs from the instance's symbol name, AND the symbol name
    // (base) maps to an existing result.
    var overrides = std.StringHashMapUnmanaged(SchematicOverride){};
    defer overrides.deinit(alloc);

    for (results) |*r| {
        const syms = r.schemify.instances.items(.symbol);
        const kinds = r.schemify.instances.items(.kind);
        const ips = r.schemify.instances.items(.prop_start);
        const ipc = r.schemify.instances.items(.prop_count);
        for (0..r.schemify.instances.len) |i| {
            const k = kinds[i];
            if (k.isNonElectrical() and k != .unknown) continue;
            const sym = syms[i];
            // If this symbol is already a known result, no override needed
            if (name_map.contains(sym)) continue;
            // Check if this instance has parameters that hint at a schematic override
            const inst_props = r.schemify.props.items[ips[i]..][0..ipc[i]];
            // The converter.zig already set the symbol to the schematic override stem.
            // We need to find the base name. Look for a result whose name is a prefix
            // of the override name (e.g. "test_evaluated_param" is a prefix of
            // "test_evaluated_param2").
            if (overrides.contains(sym)) continue;
            const base_idx = findBaseResult(sym, results) orelse continue;
            try overrides.put(alloc, sym, .{
                .override_name = sym,
                .base_name = results[base_idx].name,
                .params = inst_props,
            });
        }
    }

    // For each result, collect subcircuit dependencies (depth-first, bottom-up)
    for (results) |*r| {
        var visited = std.StringHashMapUnmanaged(void){};
        defer visited.deinit(alloc);
        var order: std.ArrayListUnmanaged(usize) = .{};
        defer order.deinit(alloc);
        // Also track override names we need to emit (in order)
        var override_order = std.ArrayListUnmanaged([]const u8){};
        defer override_order.deinit(alloc);

        collectDepsWithOverrides(r.name, results, &name_map, &overrides, alloc, &visited, &order, &override_order);

        if (order.items.len == 0 and override_order.items.len == 0) continue;

        // Emit subcircuit definitions in bottom-up order
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(alloc);
        const w = buf.writer(alloc);

        for (order.items) |dep_idx| {
            var dep = &results[dep_idx];

            // If the symbol has a spice_sym_def, emit that directly instead
            // of expanding the .sch as an inline subcircuit definition.
            if (dep.schemify.spice_sym_def) |ssd| {
                const trimmed_ssd = std.mem.trim(u8, ssd, " \t\r\n");
                if (trimmed_ssd.len > 0) {
                    w.writeAll(trimmed_ssd) catch {};
                    w.writeByte('\n') catch {};
                }
                continue;
            }

            dep.schemify.resolveNets();
            // Mark as inline expansion so code blocks with only_toplevel=true
            // (the default for code.sym) are skipped during emission.
            dep.schemify.skip_toplevel_code = true;
            // If the dependency was classified as a testbench (no .sym file),
            // override to component so it gets .subckt/.ends wrapping.
            const saved_stype = dep.schemify.stype;
            if (dep.schemify.stype == .testbench) {
                dep.schemify.stype = .component;
            }
            const dep_spice = dep.schemify.emitSpice(alloc, .ngspice, null, .sim) catch {
                dep.schemify.skip_toplevel_code = false;
                dep.schemify.stype = saved_stype;
                continue;
            };
            dep.schemify.skip_toplevel_code = false;
            dep.schemify.stype = saved_stype;
            defer alloc.free(dep_spice);

            const stripped = stripSubcktOutput(dep_spice);
            if (stripped.len > 0) {
                const tpl_str = getTemplate(&dep.schemify);
                emitSubcktDef(w, stripped, tpl_str, null, null, r) catch continue;
                w.writeByte('\n') catch {};
            }
        }

        // Emit parameterized subcircuit overrides
        for (override_order.items) |ovr_name| {
            const ovr = overrides.get(ovr_name) orelse continue;
            const base_idx = name_map.get(ovr.base_name) orelse continue;
            var dep = &results[base_idx];

            if (dep.schemify.spice_sym_def) |ssd| {
                const trimmed_ssd = std.mem.trim(u8, ssd, " \t\r\n");
                if (trimmed_ssd.len > 0) {
                    w.writeAll(trimmed_ssd) catch {};
                    w.writeByte('\n') catch {};
                }
                continue;
            }

            dep.schemify.resolveNets();
            dep.schemify.skip_toplevel_code = true;
            const saved_stype = dep.schemify.stype;
            if (dep.schemify.stype == .testbench) {
                dep.schemify.stype = .component;
            }
            const dep_spice = dep.schemify.emitSpice(alloc, .ngspice, null, .sim) catch {
                dep.schemify.skip_toplevel_code = false;
                dep.schemify.stype = saved_stype;
                continue;
            };
            dep.schemify.skip_toplevel_code = false;
            dep.schemify.stype = saved_stype;
            defer alloc.free(dep_spice);

            const stripped = stripSubcktOutput(dep_spice);
            if (stripped.len > 0) {
                // Apply parameter substitution: replace @PARAM with instance values,
                // evaluate expr(...) expressions, and rename the subcircuit.
                const substituted = substituteParamsInSpice(alloc, stripped, ovr.params, ovr.base_name, ovr.override_name) catch {
                    // Fallback: emit unsubstituted
                    emitSubcktDef(w, stripped, null, ovr.base_name, ovr.override_name, r) catch continue;
                    w.writeByte('\n') catch {};
                    continue;
                };
                defer alloc.free(substituted);
                writeSkippingGlobals(w, substituted, r) catch continue;
                w.writeByte('\n') catch {};
            }
        }

        if (buf.items.len > 0) {
            const a = r.schemify.alloc();
            r.schemify.inline_spice = a.dupe(u8, buf.items) catch null;
        }

        // Apply TCL evaluation to the parent result's code block values.
        // This handles tcleval() wrappers, [set VCC 3], and $VCC substitution.
        tclEvalCodeBlocks(alloc, r);
    }
}

/// Write text to writer, skipping lines starting with ".GLOBAL". For each
/// skipped .GLOBAL line, bubble the global name up to the parent result's
/// Schemify globals list so it gets emitted at the top level.
fn writeSkippingGlobals(w: anytype, text: []const u8, parent: *ConvertResult) !void {
    var rest = text;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line = if (nl) |n| rest[0..n] else rest;
        const trimmed_line = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed_line, ".GLOBAL ")) {
            // Extract global name and bubble up to parent
            const gname = std.mem.trim(u8, trimmed_line[".GLOBAL ".len..], " \t\r\n");
            if (gname.len > 0) {
                parent.schemify.addGlobal(gname) catch {};
            }
        } else {
            try w.writeAll(line);
            if (nl != null) try w.writeByte('\n');
        }
        rest = if (nl) |n| rest[n + 1 ..] else &.{};
    }
}

/// Collect subcircuit dependencies in XSchem order, also handling schematic
/// overrides. Regular dependencies go into `order`, while override dependencies
/// go into `override_order` (they need special parameter substitution).
fn collectDepsWithOverrides(
    name: []const u8,
    results: []const ConvertResult,
    name_map: *const std.StringHashMapUnmanaged(usize),
    override_map: *const std.StringHashMapUnmanaged(SchematicOverride),
    alloc: std.mem.Allocator,
    visited: *std.StringHashMapUnmanaged(void),
    order: *std.ArrayListUnmanaged(usize),
    override_order: *std.ArrayListUnmanaged([]const u8),
) void {
    const idx = name_map.get(name) orelse return;
    const r = &results[idx];
    const syms = r.schemify.instances.items(.symbol);
    const kinds = r.schemify.instances.items(.kind);
    for (0..r.schemify.instances.len) |i| {
        // Only follow subcircuit/unknown instances that reference project schematics
        const k = kinds[i];
        if (k.isNonElectrical() and k != .unknown) continue;
        const sym = syms[i];
        if (visited.contains(sym)) continue;

        // Check if this is a direct result match
        if (name_map.get(sym)) |dep_idx| {
            visited.put(alloc, sym, {}) catch {};
            order.append(alloc, dep_idx) catch {};
            collectDepsWithOverrides(sym, results, name_map, override_map, alloc, visited, order, override_order);
            continue;
        }

        // Check if this is a schematic override
        if (override_map.contains(sym)) {
            visited.put(alloc, sym, {}) catch {};
            override_order.append(alloc, sym) catch {};
            // Also add the base as a visited entry so we don't re-emit it
            // (the override will generate its own .subckt)
            continue;
        }
    }
}

/// Find the base result index for an override name. The base is found by
/// checking if any result's name is a prefix of the override name, or by
/// looking at existing results for the longest matching prefix.
fn findBaseResult(override_name: []const u8, results: []const ConvertResult) ?usize {
    var best_idx: ?usize = null;
    var best_len: usize = 0;
    for (results, 0..) |r, i| {
        if (r.name.len > 0 and r.name.len < override_name.len and
            r.name.len > best_len and
            std.mem.startsWith(u8, override_name, r.name))
        {
            best_idx = i;
            best_len = r.name.len;
        }
    }
    return best_idx;
}

/// Strip the standard subcircuit output boilerplate:
/// - Remove the header comment line ("* Schemify netlist: ...")
/// - Remove trailing ".end" directive
fn stripSubcktOutput(spice: []const u8) []const u8 {
    var content = spice;
    if (std.mem.startsWith(u8, content, "* Schemify netlist:")) {
        if (std.mem.indexOfScalar(u8, content, '\n')) |nl| {
            content = content[nl + 1 ..];
        }
    }
    var trimmed = std.mem.trimRight(u8, content, " \t\r\n");
    if (std.mem.endsWith(u8, trimmed, ".end")) {
        trimmed = trimmed[0 .. trimmed.len - 4];
        trimmed = std.mem.trimRight(u8, trimmed, " \t\r\n");
    }
    return trimmed;
}

/// Emit a subcircuit definition to the writer, optionally injecting template
/// params and renaming the subcircuit.
fn emitSubcktDef(
    w: anytype,
    trimmed: []const u8,
    tpl_str: ?[]const u8,
    rename_from: ?[]const u8,
    rename_to: ?[]const u8,
    parent: *ConvertResult,
) !void {
    if (tpl_str != null and std.mem.startsWith(u8, trimmed, ".subckt ")) {
        if (std.mem.indexOfScalar(u8, trimmed, '\n')) |nl| {
            var header = trimmed[0..nl];
            // Optionally rename the subcircuit in the header
            if (rename_from != null and rename_to != null) {
                header = try renameSubcktHeader(w, header, rename_from.?, rename_to.?);
            } else {
                try w.writeAll(header);
            }
            try emitTemplateParamsToWriter(w, tpl_str.?);
            try writeSkippingGlobals(w, trimmed[nl..], parent);
        } else {
            try w.writeAll(trimmed);
            try emitTemplateParamsToWriter(w, tpl_str.?);
        }
    } else {
        try writeSkippingGlobals(w, trimmed, parent);
    }
}

/// Rename the subcircuit in a .subckt header line, writing the modified
/// header to the writer. Returns an empty slice (the content is already written).
fn renameSubcktHeader(w: anytype, header: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    // Find the subcircuit name in ".subckt <name> <ports...>"
    const after_prefix = header[".subckt ".len..];
    if (std.mem.startsWith(u8, after_prefix, from)) {
        try w.writeAll(".subckt ");
        try w.writeAll(to);
        try w.writeAll(after_prefix[from.len..]);
    } else {
        try w.writeAll(header);
    }
    return "";
}

/// Substitute @PARAM references in a SPICE subcircuit definition with
/// instance-specific parameter values, evaluate expr() expressions,
/// and rename the subcircuit header.
fn substituteParamsInSpice(
    alloc: std.mem.Allocator,
    spice: []const u8,
    inst_props: []const core.Prop,
    base_name: []const u8,
    override_name: []const u8,
) ![]u8 {
    // Build param map from instance properties (skip meta keys)
    var param_map = std.StringHashMapUnmanaged([]const u8){};
    defer param_map.deinit(alloc);
    const meta_keys = std.StaticStringMap(void).initComptime(.{
        .{ "name", {} },     .{ "schematic", {} }, .{ "m", {} },
        .{ "spice_ignore", {} }, .{ "verilog_ignore", {} },
        .{ "vhdl_ignore", {} }, .{ "device", {} },   .{ "footprint", {} },
        .{ "sig_type", {} }, .{ "lab", {} },         .{ "extra", {} },
        .{ "savecurrent", {} }, .{ "class", {} },
    });
    for (inst_props) |p| {
        if (meta_keys.has(p.key)) continue;
        if (p.key.len == 0 or p.val.len == 0) continue;
        try param_map.put(alloc, p.key, p.val);
    }

    // Process line by line
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(alloc);
    const w = out.writer(alloc);

    var lines_iter = std.mem.splitScalar(u8, spice, '\n');
    var first_line = true;
    while (lines_iter.next()) |line| {
        if (!first_line) try w.writeByte('\n');
        first_line = false;

        const trimmed_line = std.mem.trimLeft(u8, line, " \t");

        // Rename .subckt header
        if (std.mem.startsWith(u8, trimmed_line, ".subckt ")) {
            const after = trimmed_line[".subckt ".len..];
            if (std.mem.startsWith(u8, after, base_name)) {
                const rest = after[base_name.len..];
                // Only rename if the name ends at a word boundary
                if (rest.len == 0 or rest[0] == ' ' or rest[0] == '\t' or rest[0] == '\n') {
                    try w.writeAll(".subckt ");
                    try w.writeAll(override_name);
                    // Emit remaining ports, but strip template params from header
                    // (they will be resolved in the body)
                    const ports_etc = rest;
                    // Write ports but stop before any KEY=VAL params
                    try emitPortsOnly(w, ports_etc);
                    continue;
                }
            }
            // Fallback: write line with @PARAM substitution
            try substituteAtParams(w, alloc, line, &param_map);
            continue;
        }

        // Rename .ends header
        if (std.mem.startsWith(u8, trimmed_line, ".ends")) {
            const after = std.mem.trim(u8, trimmed_line[".ends".len..], " \t\r");
            if (after.len == 0 or std.mem.eql(u8, after, base_name)) {
                try w.writeAll(".ends");
                continue;
            }
        }

        // For all other lines, substitute @PARAM and evaluate expr()
        try substituteAtParams(w, alloc, line, &param_map);
    }

    return out.toOwnedSlice(alloc);
}

/// Write only the port names from a .subckt header's remaining text,
/// stopping before KEY=VAL parameter assignments.
fn emitPortsOnly(w: anytype, text: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, text, " \t");
    while (it.next()) |tok| {
        // Stop at KEY=VAL tokens (parameter defaults)
        if (std.mem.indexOfScalar(u8, tok, '=') != null) break;
        try w.writeByte(' ');
        try w.writeAll(tok);
    }
}

/// Substitute @PARAM references in a single line with values from param_map.
/// Also evaluates `expr(...)` and `SPICE_expr * @PARAM` patterns.
fn substituteAtParams(
    w: anytype,
    alloc: std.mem.Allocator,
    line: []const u8,
    param_map: *const std.StringHashMapUnmanaged([]const u8),
) !void {
    // First pass: replace @PARAM tokens with their values
    var substituted = std.ArrayListUnmanaged(u8){};
    defer substituted.deinit(alloc);
    const sw = substituted.writer(alloc);

    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '@' and i + 1 < line.len and
            (std.ascii.isAlphabetic(line[i + 1]) or line[i + 1] == '_'))
        {
            const start = i + 1;
            var end = start;
            while (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '_'))
                end += 1;
            const param_name = line[start..end];
            if (param_map.get(param_name)) |val| {
                try sw.writeAll(val);
            } else {
                // Keep the @PARAM as-is if not in the map
                try sw.writeByte('@');
                try sw.writeAll(param_name);
            }
            i = end;
        } else {
            try sw.writeByte(line[i]);
            i += 1;
        }
    }

    // Second pass: evaluate expr(...) wrappers in the substituted line
    const result = substituted.items;
    try evaluateExprsInLine(w, alloc, result);
}

/// Evaluate `expr(...)` patterns in a line, writing the result.
/// Also handles bare `NUMBER * NUMBER` SPICE expression patterns that
/// result from @PARAM substitution (e.g. "2500 * 5" → "12500").
fn evaluateExprsInLine(w: anytype, alloc: std.mem.Allocator, line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        // Look for "expr(" or "expr ("
        if (i + 5 <= line.len and std.mem.eql(u8, line[i..][0..5], "expr(")) {
            const expr_start = i + 5;
            if (findMatchingParen(line, i + 4)) |end| {
                const expr_body = line[expr_start..end];
                const evaluated = evaluateSimpleExpr(alloc, expr_body);
                try w.writeAll(evaluated);
                i = end + 1;
                // Skip trailing space if next char is also space-separated
                continue;
            }
        }
        if (i + 6 <= line.len and std.mem.eql(u8, line[i..][0..6], "expr (")) {
            const expr_start = i + 6;
            if (findMatchingParen(line, i + 5)) |end| {
                const expr_body = line[expr_start..end];
                const evaluated = evaluateSimpleExpr(alloc, expr_body);
                try w.writeAll(evaluated);
                i = end + 1;
                continue;
            }
        }
        // Check for bare "NUMBER * NUMBER" patterns (from @PARAM substitution)
        // This handles cases like "2500 * 5" that appear after expr() unwrapping
        // in SPICE value fields.
        if (isDigitOrDot(line, i)) {
            const num_result = tryEvalInlineMultiply(line, i);
            if (num_result.evaluated) |ev| {
                try w.writeAll(ev);
                i = num_result.end;
                continue;
            }
        }
        try w.writeByte(line[i]);
        i += 1;
    }
}

fn isDigitOrDot(s: []const u8, pos: usize) bool {
    if (pos >= s.len) return false;
    return std.ascii.isDigit(s[pos]) or s[pos] == '.';
}

const InlineEvalResult = struct {
    evaluated: ?[]const u8 = null,
    end: usize = 0,
};

/// Try to evaluate an inline "NUM * NUM" or "NUMe-N * NUM" pattern starting
/// at position `start`. Returns the evaluated string and end position, or null.
fn tryEvalInlineMultiply(line: []const u8, start: usize) InlineEvalResult {
    // Parse first number (may include scientific notation like "100f", "2.5e-3")
    var pos = start;
    while (pos < line.len and (std.ascii.isDigit(line[pos]) or line[pos] == '.' or
        line[pos] == 'e' or line[pos] == 'E' or
        ((line[pos] == '-' or line[pos] == '+') and pos > start and
        (line[pos - 1] == 'e' or line[pos - 1] == 'E'))))
    {
        pos += 1;
    }
    // Check for SPICE suffix (f, p, n, u, m, k, meg, g, t)
    const num1_end = pos;
    var suffix1: []const u8 = "";
    if (pos < line.len and isSpiceSuffix(line[pos])) {
        const suf_start = pos;
        // Handle "meg" specially
        if (pos + 3 <= line.len and std.ascii.eqlIgnoreCase(line[pos..][0..3], "meg")) {
            pos += 3;
        } else {
            pos += 1;
        }
        suffix1 = line[suf_start..pos];
    }
    if (num1_end == start) return .{};

    // Check for " * " pattern
    var after_num1 = pos;
    while (after_num1 < line.len and line[after_num1] == ' ') after_num1 += 1;
    if (after_num1 >= line.len or line[after_num1] != '*') return .{};
    var after_star = after_num1 + 1;
    while (after_star < line.len and line[after_star] == ' ') after_star += 1;

    // Parse second number
    const num2_start = after_star;
    var num2_end = num2_start;
    while (num2_end < line.len and (std.ascii.isDigit(line[num2_end]) or line[num2_end] == '.' or
        line[num2_end] == 'e' or line[num2_end] == 'E' or
        ((line[num2_end] == '-' or line[num2_end] == '+') and num2_end > num2_start and
        (line[num2_end - 1] == 'e' or line[num2_end - 1] == 'E'))))
    {
        num2_end += 1;
    }
    // Check for suffix on second number
    if (num2_end < line.len and isSpiceSuffix(line[num2_end])) {
        if (num2_end + 3 <= line.len and std.ascii.eqlIgnoreCase(line[num2_end..][0..3], "meg")) {
            num2_end += 3;
        } else {
            num2_end += 1;
        }
    }
    if (num2_end == num2_start) return .{};

    // Make sure we're at a word boundary
    if (num2_end < line.len and !isWordBoundary(line[num2_end])) return .{};

    // Build the full expression and evaluate
    const expr_str = line[start..num2_end];
    const evaluated = evaluateSimpleExpr(std.heap.page_allocator, expr_str);
    if (!std.mem.eql(u8, evaluated, expr_str)) {
        return .{ .evaluated = evaluated, .end = num2_end };
    }
    return .{};
}

fn isSpiceSuffix(c: u8) bool {
    return switch (std.ascii.toLower(c)) {
        'f', 'p', 'n', 'u', 'm', 'k', 'g', 't' => true,
        else => false,
    };
}

fn isWordBoundary(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ')' or c == ',' or c == ';';
}

/// Find the matching closing paren for an opening paren at position `open_pos`.
fn findMatchingParen(s: []const u8, open_pos: usize) ?usize {
    if (open_pos >= s.len or s[open_pos] != '(') return null;
    var depth: usize = 1;
    var pos = open_pos + 1;
    while (pos < s.len and depth > 0) {
        if (s[pos] == '(') depth += 1;
        if (s[pos] == ')') depth -= 1;
        if (depth > 0) pos += 1;
    }
    return if (depth == 0) pos else null;
}

/// Evaluate a simple arithmetic expression (from expr() body or inline multiply).
/// Handles: numbers, SPICE suffixes (f,p,n,u,m,k,meg,g,t), and * + - / operators.
/// Returns the evaluated result as a string, or the original if evaluation fails.
fn evaluateSimpleExpr(alloc: std.mem.Allocator, expr: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, expr, " \t\r\n");
    if (trimmed.len == 0) return expr;

    // Use a simple built-in SPICE expression evaluator that understands
    // SPICE engineering suffixes (f, p, n, u, m, k, meg, g, t).
    const result = evalSpiceExpr(trimmed) orelse return expr;
    const formatted = formatSpiceFloat(alloc, result) catch expr;
    return formatted;
}

/// Evaluate a simple SPICE arithmetic expression with engineering suffixes.
/// Supports: +, -, *, / operators, parentheses, and SPICE suffixes.
fn evalSpiceExpr(expr: []const u8) ?f64 {
    var parser = SpiceExprParser{ .src = expr, .pos = 0 };
    const result = parser.parseAddSub() orelse return null;
    // Make sure we consumed all input (ignoring trailing whitespace)
    parser.skipWs();
    if (parser.pos < parser.src.len) return null;
    return result;
}

const SpiceExprParser = struct {
    src: []const u8,
    pos: usize,

    fn parseAddSub(self: *SpiceExprParser) ?f64 {
        var lhs = self.parseMulDiv() orelse return null;
        while (true) {
            self.skipWs();
            if (self.pos < self.src.len and self.src[self.pos] == '+') {
                self.pos += 1;
                const rhs = self.parseMulDiv() orelse return null;
                lhs += rhs;
            } else if (self.pos < self.src.len and self.src[self.pos] == '-') {
                self.pos += 1;
                const rhs = self.parseMulDiv() orelse return null;
                lhs -= rhs;
            } else break;
        }
        return lhs;
    }

    fn parseMulDiv(self: *SpiceExprParser) ?f64 {
        var lhs = self.parseUnary() orelse return null;
        while (true) {
            self.skipWs();
            if (self.pos < self.src.len and self.src[self.pos] == '*') {
                self.pos += 1;
                const rhs = self.parseUnary() orelse return null;
                lhs *= rhs;
            } else if (self.pos < self.src.len and self.src[self.pos] == '/') {
                self.pos += 1;
                const rhs = self.parseUnary() orelse return null;
                if (rhs == 0.0) return null;
                lhs /= rhs;
            } else break;
        }
        return lhs;
    }

    fn parseUnary(self: *SpiceExprParser) ?f64 {
        self.skipWs();
        if (self.pos < self.src.len and self.src[self.pos] == '-') {
            self.pos += 1;
            const v = self.parseUnary() orelse return null;
            return -v;
        }
        if (self.pos < self.src.len and self.src[self.pos] == '+') {
            self.pos += 1;
            return self.parseUnary();
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *SpiceExprParser) ?f64 {
        self.skipWs();
        if (self.pos >= self.src.len) return null;
        if (self.src[self.pos] == '(') {
            self.pos += 1;
            const v = self.parseAddSub() orelse return null;
            self.skipWs();
            if (self.pos < self.src.len and self.src[self.pos] == ')') self.pos += 1;
            return v;
        }
        return self.parseNumber();
    }

    fn parseNumber(self: *SpiceExprParser) ?f64 {
        self.skipWs();
        const start = self.pos;
        // Parse numeric part (digits, '.', 'e', 'E', and sign after e/E)
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isDigit(c) or c == '.') {
                self.pos += 1;
            } else if ((c == 'e' or c == 'E') and self.pos > start) {
                // Check if this is scientific notation or a SPICE suffix
                // If followed by digit, +, or -, it's scientific notation
                if (self.pos + 1 < self.src.len) {
                    const next = self.src[self.pos + 1];
                    if (std.ascii.isDigit(next) or next == '+' or next == '-') {
                        self.pos += 1;
                        if (self.src[self.pos] == '+' or self.src[self.pos] == '-')
                            self.pos += 1;
                        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos]))
                            self.pos += 1;
                        break;
                    }
                }
                break; // It's a SPICE suffix, don't consume
            } else break;
        }
        if (self.pos == start) return null;
        const num_str = self.src[start..self.pos];
        const base_val = std.fmt.parseFloat(f64, num_str) catch return null;

        // Check for SPICE engineering suffix
        if (self.pos < self.src.len) {
            const suffix_start = self.pos;
            const c = std.ascii.toLower(self.src[self.pos]);
            if (c == 'm' and self.pos + 2 < self.src.len and
                std.ascii.toLower(self.src[self.pos + 1]) == 'e' and
                std.ascii.toLower(self.src[self.pos + 2]) == 'g')
            {
                self.pos += 3;
                // Make sure it's at a boundary
                if (self.pos < self.src.len and std.ascii.isAlphanumeric(self.src[self.pos])) {
                    self.pos = suffix_start; // not a suffix
                    return base_val;
                }
                return base_val * 1e6;
            }
            const multiplier: ?f64 = switch (c) {
                'f' => 1e-15, 'p' => 1e-12, 'n' => 1e-9,
                'u' => 1e-6, 'm' => 1e-3, 'k' => 1e3,
                'g' => 1e9, 't' => 1e12,
                else => null,
            };
            if (multiplier) |m| {
                // Make sure the suffix is at a word boundary
                if (self.pos + 1 < self.src.len and std.ascii.isAlphanumeric(self.src[self.pos + 1])) {
                    return base_val;
                }
                self.pos += 1;
                return base_val * m;
            }
        }

        return base_val;
    }

    fn skipWs(self: *SpiceExprParser) void {
        while (self.pos < self.src.len and
            (self.src[self.pos] == ' ' or self.src[self.pos] == '\t'))
        {
            self.pos += 1;
        }
    }
};

// (preprocessSpiceSuffixes removed — SpiceExprParser handles suffixes natively)

/// Format a float as xschem does: plain integer when exact, otherwise
/// scientific notation (e.g. "5e-13"). No SPICE suffixes.
fn formatSpiceFloat(alloc: std.mem.Allocator, val: f64) ![]const u8 {
    if (val == 0.0) return "0";

    const abs_val = @abs(val);
    const sign: []const u8 = if (val < 0) "-" else "";

    // If the value is an exact integer >= 1, emit without decimal point
    if (abs_val >= 1.0) {
        const rounded = @round(abs_val);
        if (@abs(abs_val - rounded) < 1e-9 * rounded and rounded < 1e15) {
            const int_val: i64 = @intFromFloat(rounded);
            return std.fmt.allocPrint(alloc, "{s}{d}", .{ sign, int_val });
        }
    }

    // Use scientific notation matching xschem's output style.
    // Try to find a clean mantissa * 10^exp with the smallest mantissa
    // (prefer 5e-13 over 500e-15).
    const exponents = [_]i32{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, -1, -2, -3, -4, -5, -6, -7, -8, -9, -10, -11, -12, -13, -14, -15 };
    for (exponents) |exp| {
        const power = std.math.pow(f64, 10.0, @floatFromInt(exp));
        const mantissa = abs_val / power;
        const mant_rounded = @round(mantissa);
        if (mant_rounded >= 1.0 and mant_rounded < 10.0 and
            @abs(mantissa - mant_rounded) < 1e-6 * mant_rounded)
        {
            const mant_int: i64 = @intFromFloat(mant_rounded);
            if (exp == 0) {
                return std.fmt.allocPrint(alloc, "{s}{d}", .{ sign, mant_int });
            }
            return std.fmt.allocPrint(alloc, "{s}{d}e{d}", .{ sign, mant_int, exp });
        }
    }
    // Also try mantissa in [1, 1000) for cases that don't fit [1, 10)
    for (exponents) |exp| {
        const power = std.math.pow(f64, 10.0, @floatFromInt(exp));
        const mantissa = abs_val / power;
        const mant_rounded = @round(mantissa);
        if (mant_rounded >= 1.0 and mant_rounded < 1000.0 and
            @abs(mantissa - mant_rounded) < 1e-6 * mant_rounded)
        {
            const mant_int: i64 = @intFromFloat(mant_rounded);
            if (exp == 0) {
                return std.fmt.allocPrint(alloc, "{s}{d}", .{ sign, mant_int });
            }
            return std.fmt.allocPrint(alloc, "{s}{d}e{d}", .{ sign, mant_int, exp });
        }
    }

    // Fallback: use Zig's default float formatting
    return std.fmt.allocPrint(alloc, "{d}", .{val});
}

/// Apply TCL evaluation to code block values in a result's Schemify.
/// Handles tcleval() wrappers, [set VCC 3] commands, and $VCC substitution.
fn tclEvalCodeBlocks(alloc: std.mem.Allocator, r: *ConvertResult) void {
    // Initialize a TCL evaluator to track variable state across code blocks
    var tcl_eval = tcl.Tcl.init(alloc);
    defer tcl_eval.deinit();

    // First pass: scan code block values for [set ...] commands to build
    // the TCL variable state.
    const kinds = r.schemify.instances.items(.kind);
    const ips = r.schemify.instances.items(.prop_start);
    const ipc = r.schemify.instances.items(.prop_count);

    for (0..r.schemify.instances.len) |i| {
        if (kinds[i] != .code and kinds[i] != .param) continue;
        const inst_props = r.schemify.props.items[ips[i]..][0..ipc[i]];
        for (inst_props) |p| {
            if (!std.mem.eql(u8, p.key, "value") or p.val.len == 0) continue;
            // Strip tcleval() wrapper if present
            var content = p.val;
            if (std.mem.startsWith(u8, content, "tcleval(") and
                content.len > "tcleval()".len and content[content.len - 1] == ')')
            {
                content = content["tcleval(".len .. content.len - 1];
            }
            // Scan for [set ...] commands and evaluate them
            scanAndEvalTclCommands(&tcl_eval, content);
        }
    }

    // Second pass: substitute $VAR references and strip tcleval() in all
    // property values throughout the result.
    const sa = r.schemify.alloc();
    for (r.schemify.props.items) |*p| {
        if (p.val.len == 0) continue;
        const new_val = tclSubstituteValue(sa, &tcl_eval, p.val) catch continue;
        if (!std.mem.eql(u8, new_val, p.val)) {
            p.val = new_val;
        }
    }
}

/// Scan text for TCL [set ...] commands and evaluate them to build variable state.
fn scanAndEvalTclCommands(tcl_eval: *tcl.Tcl, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '[') {
            // Find matching ]
            var depth: usize = 1;
            var j = i + 1;
            while (j < text.len and depth > 0) {
                if (text[j] == '[') depth += 1;
                if (text[j] == ']') depth -= 1;
                if (depth > 0) j += 1;
            }
            if (depth == 0) {
                const cmd = text[i + 1 .. j];
                // Only evaluate safe commands (set, expr)
                const trimmed_cmd = std.mem.trimLeft(u8, cmd, " \t");
                if (std.mem.startsWith(u8, trimmed_cmd, "set ") or
                    std.mem.startsWith(u8, trimmed_cmd, "expr "))
                {
                    _ = tcl_eval.eval(cmd) catch {};
                }
            }
            i = j + 1;
        } else {
            i += 1;
        }
    }
}

/// Substitute TCL variables ($VAR) and evaluate [cmd] in a property value.
/// Also strips tcleval() wrappers.
fn tclSubstituteValue(
    arena: std.mem.Allocator,
    tcl_eval: *tcl.Tcl,
    val: []const u8,
) ![]const u8 {
    var content = val;
    var stripped_tcleval = false;

    // Strip tcleval() wrapper
    if (std.mem.startsWith(u8, content, "tcleval(") and
        content.len > "tcleval()".len and content[content.len - 1] == ')')
    {
        content = content["tcleval(".len .. content.len - 1];
        stripped_tcleval = true;
    }

    // Check if there's anything to substitute.
    // Only look for $VAR substitutions; [cmd] evaluation is only done when
    // the value was originally wrapped in tcleval().
    const has_dollar = std.mem.indexOfScalar(u8, content, '$') != null;
    const has_bracket = stripped_tcleval and std.mem.indexOfScalar(u8, content, '[') != null;
    if (!has_dollar and !has_bracket) {
        return if (stripped_tcleval) try arena.dupe(u8, content) else val;
    }

    // Substitute $VAR and [cmd] references
    var out = std.ArrayListUnmanaged(u8){};
    const w = out.writer(arena);

    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '$' and i + 1 < content.len and
            (std.ascii.isAlphabetic(content[i + 1]) or content[i + 1] == '_'))
        {
            // Variable reference
            const name_start = i + 1;
            var name_end = name_start;
            while (name_end < content.len and
                (std.ascii.isAlphanumeric(content[name_end]) or content[name_end] == '_'))
            {
                name_end += 1;
            }
            const name = content[name_start..name_end];
            if (tcl_eval.getVar(name)) |var_val| {
                try w.writeAll(var_val);
            } else {
                try w.writeByte('$');
                try w.writeAll(name);
            }
            i = name_end;
        } else if (content[i] == '[' and stripped_tcleval) {
            // Command substitution — only for tcleval()-wrapped values.
            // Bare [brackets] in SPICE code blocks are SPICE syntax, not TCL.
            var depth: usize = 1;
            var j = i + 1;
            while (j < content.len and depth > 0) {
                if (content[j] == '[') depth += 1;
                if (content[j] == ']') depth -= 1;
                if (depth > 0) j += 1;
            }
            if (depth == 0) {
                const cmd = content[i + 1 .. j];
                const result = tcl_eval.eval(cmd) catch cmd;
                try w.writeAll(result);
                i = j + 1;
            } else {
                try w.writeByte('[');
                i += 1;
            }
        } else {
            try w.writeByte(content[i]);
            i += 1;
        }
    }

    return out.items;
}

/// Get the template string from a Schemify's sym_props.
fn getTemplate(sfy: *const core.Schemify) ?[]const u8 {
    for (sfy.sym_props.items) |sp| {
        if (std.mem.eql(u8, sp.key, "template") and sp.val.len > 0) return sp.val;
    }
    return null;
}

/// Emit template parameters (key=value) to a writer, for inclusion in .subckt headers.
/// Skips "name" and other non-parameter meta keys.
fn emitTemplateParamsToWriter(w: anytype, template: []const u8) !void {
    const skip_keys = std.StaticStringMap(void).initComptime(.{
        .{ "name", {} },
        .{ "m", {} },
        .{ "spice_ignore", {} },
        .{ "verilog_ignore", {} },
        .{ "vhdl_ignore", {} },
        .{ "device", {} },
        .{ "footprint", {} },
        .{ "sig_type", {} },
        .{ "lab", {} },
        .{ "extra", {} },
        .{ "extra_pinnumber", {} },
        .{ "savecurrent", {} },
        .{ "generic_type", {} },
        .{ "class", {} },
    });

    var pos: usize = 0;
    const s = template;
    while (pos < s.len) {
        // Skip whitespace
        while (pos < s.len and (s[pos] == ' ' or s[pos] == '\t' or s[pos] == '\n' or s[pos] == '\r'))
            pos += 1;
        if (pos >= s.len) break;

        // Find key (up to '=')
        const key_start = pos;
        while (pos < s.len and s[pos] != '=' and s[pos] != ' ' and s[pos] != '\t' and s[pos] != '\n')
            pos += 1;
        if (pos >= s.len or s[pos] != '=') continue;
        const key = s[key_start..pos];
        pos += 1; // skip '='

        // Parse value (quoted or bare)
        var val_start = pos;
        var val_end = pos;
        if (pos < s.len and (s[pos] == '"' or s[pos] == '\'')) {
            const q = s[pos];
            pos += 1;
            val_start = pos;
            while (pos < s.len and s[pos] != q) {
                if (s[pos] == '\\' and pos + 1 < s.len) pos += 1;
                pos += 1;
            }
            val_end = pos;
            if (pos < s.len) pos += 1;
        } else {
            while (pos < s.len and s[pos] != ' ' and s[pos] != '\t' and s[pos] != '\n' and s[pos] != '\r')
                pos += 1;
            val_end = pos;
        }
        const val = s[val_start..val_end];

        // Skip meta keys
        if (skip_keys.has(key)) continue;
        if (key.len == 0) continue;

        try w.print(" {s}={s}", .{ key, val });
    }
}

/// Extract stem name from a relative path: "path/to/cmos_inv.sch" -> "cmos_inv"
fn stemName(path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| path[idx + 1 ..] else path;
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| return base[0..dot];
    return base;
}

/// Result of getFiles -- owns the path slices.
pub const FileList = struct {
    sch_files: []const []const u8,
    sym_files: []const []const u8,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *FileList) void {
        for (self.sch_files) |f| self.alloc.free(f);
        self.alloc.free(self.sch_files);
        for (self.sym_files) |f| self.alloc.free(f);
        self.alloc.free(self.sym_files);
    }
};
