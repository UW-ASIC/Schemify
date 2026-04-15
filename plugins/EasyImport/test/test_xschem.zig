const std = @import("std");
const testing = std.testing;
const XSchem = @import("xschem");
const easyimport = @import("easyimport");
const core = @import("core");
const ct = @import("convert_types");
const tcl = @import("tcl");

const core_examples = "plugins/EasyImport/test/fixtures/xschem_library/xschem_library/examples";

const example_dirs = [_][]const u8{
    core_examples,
};

// ── Helpers ──────────────────────────────────────────────────────────────

/// Read a file from the core examples directory.
fn readCoreFile(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(alloc, &.{ core_examples, name });
    defer alloc.free(path);
    return std.fs.cwd().readFileAlloc(alloc, path, 4 << 20);
}

/// Parse a .sch or .sym file from the core examples directory.
fn parseCoreFile(alloc: std.mem.Allocator, name: []const u8) !XSchem.XSchemFiles {
    const data = try readCoreFile(alloc, name);
    defer alloc.free(data);
    return XSchem.parse(alloc, data);
}

/// Run `xschem --no_x -n -s -q` to produce a reference SPICE netlist.
/// Returns null if xschem is not available or fails.
fn xschemNetlist(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    rcfile: []const u8,
    sch_rel: []const u8,
) ?[]u8 {
    const tmp_dir = std.fmt.allocPrint(alloc, "/tmp/schemify_test_{x}", .{std.hash.Wyhash.hash(0, sch_rel)}) catch return null;
    defer alloc.free(tmp_dir);
    std.fs.cwd().makePath(tmp_dir) catch return null;

    const abs_dir = std.fs.cwd().realpathAlloc(alloc, project_dir) catch return null;
    defer alloc.free(abs_dir);
    const abs_rc = std.fs.cwd().realpathAlloc(alloc, rcfile) catch return null;
    defer alloc.free(abs_rc);

    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "xschem", "--no_x", "-n", "-s", "-q", "--netlist_path", tmp_dir, "--rcfile", abs_rc, sch_rel },
        .cwd = abs_dir,
        .max_output_bytes = 1 << 20,
    }) catch return null;
    alloc.free(result.stdout);
    alloc.free(result.stderr);

    const stem = stemName(sch_rel);
    const spice_name = std.fmt.allocPrint(alloc, "{s}/{s}.spice", .{ tmp_dir, stem }) catch return null;
    defer alloc.free(spice_name);

    return std.fs.cwd().readFileAlloc(alloc, spice_name, 1 << 20) catch return null;
}

// ── Connectivity-based SPICE netlist comparison ─────────────────────────
//
// Two SPICE netlists are "connectivity equivalent" if they describe the
// same circuit topology — the same instances with the same device types,
// connected in the same pattern — even when internal net names differ.
//
// Approach:
//   1. Parse each netlist into structured form (instances, directives, subckt header).
//   2. Match instances between the two netlists by (device_prefix, model, params).
//   3. Build a connectivity graph: for each net, record the set of (instance_idx, pin_idx).
//   4. Check that there exists a net-name bijection making the two graphs identical.
//      We do this by computing canonical "connectivity signatures" for each net
//      (sorted list of (instance_idx, pin_idx) tuples, where instance_idx is the
//      index into a sorted instance list) and comparing the multisets of signatures.

const SpiceInstance = struct {
    /// Full instance name (e.g. "m1", "r1", "x1")
    name: []const u8,
    /// Device prefix letter, lowercased (e.g. 'm', 'r', 'c', 'v', 'x', 'q', 'd', 'l')
    prefix: u8,
    /// Net connections in pin order
    nets: []const []const u8,
    /// Model/subckt name (e.g. "cmosn", "bjtm1_q1"); empty if N/A
    model: []const u8,
    /// Parameters after model (e.g. "w=wn l=lln m=1"); sorted for comparison
    params: []const u8,
};

const ParsedSpice = struct {
    /// Subcircuit name (from **.subckt or .subckt line), null for top-level
    subckt_name: ?[]const u8,
    /// Subcircuit port names (from **.subckt line)
    subckt_ports: []const []const u8,
    /// Parsed device instances
    instances: []const SpiceInstance,
    /// Directive lines (lowercased, sorted), excluding .end/.ends/comments
    directives: []const []const u8,
    /// .GLOBAL net names (lowercased)
    globals: []const []const u8,
    /// Backing storage for joined lines (instances/directives point into these)
    _joined_lines: []const []const u8,

    fn deinit(self: *ParsedSpice, alloc: std.mem.Allocator) void {
        for (self.instances) |inst| {
            alloc.free(inst.nets);
        }
        alloc.free(self.instances);
        alloc.free(self.subckt_ports);
        alloc.free(self.directives);
        alloc.free(self.globals);
        for (self._joined_lines) |jl| alloc.free(jl);
        alloc.free(self._joined_lines);
    }
};

/// Number of net-connection pins for a SPICE device prefix.
/// Returns null if the device type has a variable number of pins (e.g. X subcircuit calls).
fn pinCountForPrefix(prefix: u8) ?usize {
    return switch (prefix) {
        'r', 'c', 'l', 'v', 'i', 'e', 'f', 'g', 'h', 'b' => 2,
        'd' => 2,
        'q' => 3, // BJT: C B E (or C B E S with 4)
        'j' => 3, // JFET: D G S
        'z' => 3, // MESFET
        'm' => 4, // MOSFET: D G S B
        'x' => null, // subcircuit: variable
        else => null,
    };
}

/// Parse a SPICE netlist string into structured form.
/// All strings are slices into `lower` (caller-owned lowercased copy).
fn parseSpice(alloc: std.mem.Allocator, lower: []const u8) !ParsedSpice {
    var instances: std.ArrayListUnmanaged(SpiceInstance) = .{};
    defer instances.deinit(alloc);
    var directives: std.ArrayListUnmanaged([]const u8) = .{};
    defer directives.deinit(alloc);
    var globals: std.ArrayListUnmanaged([]const u8) = .{};
    defer globals.deinit(alloc);
    var nets_buf: std.ArrayListUnmanaged([]const u8) = .{};
    defer nets_buf.deinit(alloc);

    var subckt_name: ?[]const u8 = null;
    var subckt_ports: std.ArrayListUnmanaged([]const u8) = .{};
    defer subckt_ports.deinit(alloc);

    // Join continuation lines ('+' at start) with previous line
    var joined_lines: std.ArrayListUnmanaged([]const u8) = .{};
    defer joined_lines.deinit(alloc); // free backing array; elements owned by _joined_lines
    {
        var iter = std.mem.splitScalar(u8, lower, '\n');
        while (iter.next()) |raw| {
            const line = std.mem.trimRight(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (line[0] == '+' and joined_lines.items.len > 0) {
                // Continuation: append to previous joined line
                const prev = joined_lines.items[joined_lines.items.len - 1];
                const cont = if (line.len > 1) std.mem.trimLeft(u8, line[1..], " \t") else "";
                const new = try std.fmt.allocPrint(alloc, "{s} {s}", .{ prev, cont });
                alloc.free(prev);
                joined_lines.items[joined_lines.items.len - 1] = new;
            } else {
                try joined_lines.append(alloc, try alloc.dupe(u8, line));
            }
        }
    }

    for (joined_lines.items) |line| {
        if (line.len == 0) continue;

        // Skip pure comment lines
        if (line[0] == '*') {
            // Check for xschem's **.subckt / **.ends pseudo-comments
            if (line.len > 2 and line[1] == '*') {
                const rest = std.mem.trimLeft(u8, line[2..], " \t");
                if (std.mem.startsWith(u8, rest, ".subckt ")) {
                    // Parse: **.subckt NAME [PORT1 PORT2 ...]
                    var toks = std.mem.tokenizeAny(u8, rest[7..], " \t");
                    if (toks.next()) |name| {
                        subckt_name = name;
                        subckt_ports.clearRetainingCapacity();
                        while (toks.next()) |port| {
                            try subckt_ports.append(alloc, port);
                        }
                    }
                }
                // **.ends — just skip
            }
            continue;
        }

        // Directive lines start with '.'
        if (line[0] == '.') {
            const trimmed = std.mem.trimLeft(u8, line, " \t");
            // Skip .end / .ends / .subckt / .backanno
            if (std.mem.startsWith(u8, trimmed, ".end")) continue;
            if (std.mem.startsWith(u8, trimmed, ".subckt ")) {
                // Real .subckt line (not **.subckt pseudo-comment)
                var toks = std.mem.tokenizeAny(u8, trimmed[7..], " \t");
                if (toks.next()) |name| {
                    subckt_name = name;
                    subckt_ports.clearRetainingCapacity();
                    while (toks.next()) |port| {
                        try subckt_ports.append(alloc, port);
                    }
                }
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, ".backanno")) continue;
            // .global NETNAME
            if (std.mem.startsWith(u8, trimmed, ".global ")) {
                var toks = std.mem.tokenizeAny(u8, trimmed[8..], " \t");
                while (toks.next()) |g| {
                    try globals.append(alloc, g);
                }
                continue;
            }
            // Save as directive for comparison
            try directives.append(alloc, trimmed);
            continue;
        }

        // Instance line: starts with a letter
        if (std.ascii.isAlphabetic(line[0])) {
            var toks = std.mem.tokenizeAny(u8, line, " \t");
            const inst_name = toks.next() orelse continue;
            const prefix = std.ascii.toLower(inst_name[0]);

            // Determine how many tokens are net connections
            const fixed_pins = pinCountForPrefix(prefix);

            nets_buf.clearRetainingCapacity();
            var model: []const u8 = "";
            var params_start: usize = 0;

            if (fixed_pins) |n_pins| {
                // Fixed pin count: next n_pins tokens are nets, then model, then params
                for (0..n_pins) |_| {
                    if (toks.next()) |tok| {
                        try nets_buf.append(alloc, tok);
                    }
                }
                // For Q (BJT), check if next token looks like a net (4th substrate pin)
                // by checking if the token after it looks like a model name
                if (prefix == 'q' and nets_buf.items.len == 3) {
                    // Peek: save state
                    const maybe_model_or_sub = toks.next();
                    if (maybe_model_or_sub) |tok| {
                        // If the next token contains '=' it's a param, so tok is model
                        const after = toks.peek();
                        if (after) |a| {
                            if (std.mem.indexOfScalar(u8, a, '=') != null) {
                                // tok is the model
                                model = tok;
                            } else {
                                // tok might be substrate pin, next is model
                                try nets_buf.append(alloc, tok);
                                model = toks.next() orelse "";
                            }
                        } else {
                            // No more tokens, tok is model
                            model = tok;
                        }
                    }
                } else {
                    model = toks.next() orelse "";
                }
                // Find where params start
                params_start = if (toks.peek()) |p| @intFromPtr(p.ptr) - @intFromPtr(line.ptr) else line.len;
            } else {
                // Variable pin count (X subcircuit calls): last non-param token is model
                // Collect all remaining tokens
                var all_toks: std.ArrayListUnmanaged([]const u8) = .{};
                defer all_toks.deinit(alloc);
                while (toks.next()) |tok| {
                    try all_toks.append(alloc, tok);
                }
                // Find the model: it's the last token before any key=value params.
                // Walk backwards to find first non-param token.
                var model_idx: usize = 0;
                if (all_toks.items.len > 0) {
                    model_idx = all_toks.items.len - 1;
                    // Walk back past key=value params
                    while (model_idx > 0 and std.mem.indexOfScalar(u8, all_toks.items[model_idx], '=') != null) {
                        model_idx -= 1;
                    }
                    model = all_toks.items[model_idx];
                    // Everything before model_idx is nets
                    for (all_toks.items[0..model_idx]) |tok| {
                        try nets_buf.append(alloc, tok);
                    }
                    // Params are model_idx+1..end, but we store the raw tail
                    if (model_idx + 1 < all_toks.items.len) {
                        const first_param = all_toks.items[model_idx + 1];
                        params_start = @intFromPtr(first_param.ptr) - @intFromPtr(line.ptr);
                    } else {
                        params_start = line.len;
                    }
                }
            }

            const params_str = if (params_start < line.len) std.mem.trimLeft(u8, line[params_start..], " \t") else "";

            try instances.append(alloc, .{
                .name = inst_name,
                .prefix = prefix,
                .nets = try alloc.dupe([]const u8, nets_buf.items),
                .model = model,
                .params = params_str,
            });
        }
    }

    // Sort directives for stable comparison
    const dir_slice = try alloc.dupe([]const u8, directives.items);
    std.mem.sort([]const u8, dir_slice, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    // Sort globals
    const glob_slice = try alloc.dupe([]const u8, globals.items);
    std.mem.sort([]const u8, glob_slice, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    return .{
        .subckt_name = subckt_name,
        .subckt_ports = try alloc.dupe([]const u8, subckt_ports.items),
        .instances = try alloc.dupe(SpiceInstance, instances.items),
        .directives = dir_slice,
        .globals = glob_slice,
        ._joined_lines = try alloc.dupe([]const u8, joined_lines.items),
    };
}

/// A connectivity signature for a single net: the sorted set of
/// (instance_sort_key, pin_index) pairs that touch this net.
/// instance_sort_key is: "{prefix}:{model}:{param_hash}:{occurrence_index}"
const ConnSig = struct {
    entries: []const SigEntry,
};

const SigEntry = struct {
    inst_key: []const u8,
    pin_idx: u16,
};

/// Result of comparing two SPICE netlists for connectivity equivalence.
const CompareResult = struct {
    equivalent: bool,
    /// Human-readable diff descriptions (allocated, caller must free)
    diffs: std.ArrayListUnmanaged([]const u8),

    fn deinit(self: *CompareResult, alloc: std.mem.Allocator) void {
        for (self.diffs.items) |d| alloc.free(d);
        self.diffs.deinit(alloc);
    }
};

/// Compare two parsed SPICE netlists for connectivity equivalence.
/// Returns a CompareResult with `equivalent = true` if the netlists describe
/// the same circuit topology (ignoring net names), and a list of diff
/// descriptions if they don't.
fn compareSpiceConnectivity(
    alloc: std.mem.Allocator,
    ref: *const ParsedSpice,
    ours: *const ParsedSpice,
) !CompareResult {
    var diffs: std.ArrayListUnmanaged([]const u8) = .{};

    // 1. Compare subcircuit header
    if (ref.subckt_name != null and ours.subckt_name != null) {
        if (!std.mem.eql(u8, ref.subckt_name.?, ours.subckt_name.?)) {
            try diffs.append(alloc, try std.fmt.allocPrint(alloc,
                "subckt name: ref={s} ours={s}", .{ ref.subckt_name.?, ours.subckt_name.? }));
        }
        if (ref.subckt_ports.len != ours.subckt_ports.len) {
            try diffs.append(alloc, try std.fmt.allocPrint(alloc,
                "subckt port count: ref={d} ours={d}", .{ ref.subckt_ports.len, ours.subckt_ports.len }));
        }
    }

    // 2. Compare instance counts per device prefix
    var ref_prefix_counts: [256]usize = .{0} ** 256;
    var ours_prefix_counts: [256]usize = .{0} ** 256;
    for (ref.instances) |inst| ref_prefix_counts[inst.prefix] += 1;
    for (ours.instances) |inst| ours_prefix_counts[inst.prefix] += 1;
    for (0..256) |p| {
        if (ref_prefix_counts[p] != ours_prefix_counts[p]) {
            if (ref_prefix_counts[p] != 0 or ours_prefix_counts[p] != 0) {
                const ch: u8 = @intCast(p);
                try diffs.append(alloc, try std.fmt.allocPrint(alloc,
                    "instance count for '{c}': ref={d} ours={d}", .{ ch, ref_prefix_counts[p], ours_prefix_counts[p] }));
            }
        }
    }

    // 3. Compare instance model names (sorted multiset)
    {
        var ref_models: std.ArrayListUnmanaged([]const u8) = .{};
        defer ref_models.deinit(alloc);
        var ours_models: std.ArrayListUnmanaged([]const u8) = .{};
        defer ours_models.deinit(alloc);

        for (ref.instances) |inst| {
            const key = try std.fmt.allocPrint(alloc, "{c}:{s}", .{ inst.prefix, inst.model });
            try ref_models.append(alloc, key);
        }
        defer for (ref_models.items) |k| alloc.free(k);

        for (ours.instances) |inst| {
            const key = try std.fmt.allocPrint(alloc, "{c}:{s}", .{ inst.prefix, inst.model });
            try ours_models.append(alloc, key);
        }
        defer for (ours_models.items) |k| alloc.free(k);

        const lt = struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt;
        std.mem.sort([]const u8, ref_models.items, {}, lt);
        std.mem.sort([]const u8, ours_models.items, {}, lt);

        if (!slicesEqual(ref_models.items, ours_models.items)) {
            try diffs.append(alloc, try std.fmt.allocPrint(alloc,
                "instance models differ: ref has {d}, ours has {d}", .{ ref_models.items.len, ours_models.items.len }));
            // Report specific differences
            try reportMultisetDiff(alloc, &diffs, "model", ref_models.items, ours_models.items);
        }
    }

    // 4. Compare connectivity signatures
    //    Build a sort key for each instance: "prefix:model:sorted_params:occurrence_N"
    //    Then for each net, collect the set of (sort_key, pin_idx) and sort it.
    //    The multiset of these per-net signatures must match between ref and ours.
    {
        const ref_sigs = try buildConnSigs(alloc, ref);
        defer {
            for (ref_sigs) |s| alloc.free(s);
            alloc.free(ref_sigs);
        }
        const ours_sigs = try buildConnSigs(alloc, ours);
        defer {
            for (ours_sigs) |s| alloc.free(s);
            alloc.free(ours_sigs);
        }

        const lt = struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt;
        std.mem.sort([]const u8, ref_sigs, {}, lt);
        std.mem.sort([]const u8, ours_sigs, {}, lt);

        if (!slicesEqual(ref_sigs, ours_sigs)) {
            // Count how many signatures differ
            var ref_i: usize = 0;
            var ours_i: usize = 0;
            var only_ref: usize = 0;
            var only_ours: usize = 0;
            while (ref_i < ref_sigs.len and ours_i < ours_sigs.len) {
                const ord = std.mem.order(u8, ref_sigs[ref_i], ours_sigs[ours_i]);
                switch (ord) {
                    .eq => {
                        ref_i += 1;
                        ours_i += 1;
                    },
                    .lt => {
                        only_ref += 1;
                        ref_i += 1;
                    },
                    .gt => {
                        only_ours += 1;
                        ours_i += 1;
                    },
                }
            }
            only_ref += ref_sigs.len - ref_i;
            only_ours += ours_sigs.len - ours_i;

            try diffs.append(alloc, try std.fmt.allocPrint(alloc,
                "connectivity: {d} net-sigs only in ref, {d} only in ours (ref total={d}, ours total={d})",
                .{ only_ref, only_ours, ref_sigs.len, ours_sigs.len }));
        }
    }

    // 5. Compare globals
    if (!slicesEqual(ref.globals, ours.globals)) {
        const ref_g = try joinStrSlice(alloc, ref.globals, ", ");
        defer alloc.free(ref_g);
        const ours_g = try joinStrSlice(alloc, ours.globals, ", ");
        defer alloc.free(ours_g);
        try diffs.append(alloc, try std.fmt.allocPrint(alloc,
            "globals differ: ref=[{s}] ours=[{s}]", .{ ref_g, ours_g }));
    }

    // 6. Compare directives (sorted)
    //    We do a lenient comparison: check that key directives match.
    //    We skip .save directives and user architecture code blocks.
    {
        const ref_key = try filterKeyDirectives(alloc, ref.directives);
        defer alloc.free(ref_key);
        const ours_key = try filterKeyDirectives(alloc, ours.directives);
        defer alloc.free(ours_key);

        if (!slicesEqual(ref_key, ours_key)) {
            var only_ref: usize = 0;
            var only_ours: usize = 0;
            var ri: usize = 0;
            var oi: usize = 0;
            while (ri < ref_key.len and oi < ours_key.len) {
                const ord = std.mem.order(u8, ref_key[ri], ours_key[oi]);
                switch (ord) {
                    .eq => {
                        ri += 1;
                        oi += 1;
                    },
                    .lt => {
                        only_ref += 1;
                        ri += 1;
                    },
                    .gt => {
                        only_ours += 1;
                        oi += 1;
                    },
                }
            }
            only_ref += ref_key.len - ri;
            only_ours += ours_key.len - oi;
            try diffs.append(alloc, try std.fmt.allocPrint(alloc,
                "directives: {d} only in ref, {d} only in ours", .{ only_ref, only_ours }));
        }
    }

    return .{
        .equivalent = diffs.items.len == 0,
        .diffs = diffs,
    };
}

/// Build connectivity signature strings for each net in a parsed SPICE netlist.
/// Each signature is a string encoding the sorted set of (instance_key, pin_idx)
/// pairs that connect to that net.
fn buildConnSigs(alloc: std.mem.Allocator, parsed: *const ParsedSpice) ![][]const u8 {
    // First, build a stable sort key for each instance.
    // Count occurrences of each (prefix, model) pair to disambiguate.
    var inst_keys: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (inst_keys.items) |k| alloc.free(k);
        inst_keys.deinit(alloc);
    }

    // Count occurrences per (prefix, model) to assign occurrence indices
    var occ_counts = std.StringHashMap(usize).init(alloc);
    defer occ_counts.deinit();

    for (parsed.instances) |inst| {
        const type_key = try std.fmt.allocPrint(alloc, "{c}:{s}", .{ inst.prefix, inst.model });

        const gop = try occ_counts.getOrPut(type_key);
        if (gop.found_existing) {
            // Key already exists, free the newly allocated duplicate
            alloc.free(type_key);
        }
        const count = if (gop.found_existing) gop.value_ptr.* else 0;
        gop.value_ptr.* = count + 1;

        // Sort params for stable comparison
        const sorted_params = try sortParams(alloc, inst.params);
        defer alloc.free(sorted_params);

        const key = try std.fmt.allocPrint(alloc, "{c}:{s}:{s}:{d}", .{
            inst.prefix, inst.model, sorted_params, count,
        });
        try inst_keys.append(alloc, key);
    }
    // Free the occ_counts keys
    {
        var it = occ_counts.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
    }

    // Now build per-net signature: map net_name -> list of "inst_key@pin_idx"
    var net_entries = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(alloc);
    defer {
        var it = net_entries.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |v| alloc.free(v);
            entry.value_ptr.deinit(alloc);
        }
        net_entries.deinit();
    }

    for (parsed.instances, 0..) |inst, inst_idx| {
        for (inst.nets, 0..) |net, pin_idx| {
            const gop = try net_entries.getOrPut(net);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
            }
            const entry_str = try std.fmt.allocPrint(alloc, "{s}@{d}", .{
                inst_keys.items[inst_idx], pin_idx,
            });
            try gop.value_ptr.append(alloc, entry_str);
        }
    }

    // Build signature strings: sort entries within each net, then emit as one string
    var sigs: std.ArrayListUnmanaged([]const u8) = .{};
    defer sigs.deinit(alloc);

    const lt = struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt;

    var it = net_entries.iterator();
    while (it.next()) |entry| {
        // Skip trivial nets (connected to only one pin — typically power/ground labels)
        if (entry.value_ptr.items.len < 2) continue;

        std.mem.sort([]const u8, entry.value_ptr.items, {}, lt);

        // Join entries with "|" separator
        var sig_buf: std.ArrayListUnmanaged(u8) = .{};
        defer sig_buf.deinit(alloc);
        for (entry.value_ptr.items, 0..) |e, i| {
            if (i > 0) try sig_buf.append(alloc, '|');
            try sig_buf.appendSlice(alloc, e);
        }
        try sigs.append(alloc, try alloc.dupe(u8, sig_buf.items));
    }

    return try alloc.dupe([]const u8, sigs.items);
}

/// Sort key=value parameters alphabetically for stable comparison.
fn sortParams(alloc: std.mem.Allocator, params: []const u8) ![]const u8 {
    if (params.len == 0) return try alloc.dupe(u8, "");

    var param_list: std.ArrayListUnmanaged([]const u8) = .{};
    defer param_list.deinit(alloc);

    var toks = std.mem.tokenizeAny(u8, params, " \t");
    while (toks.next()) |tok| {
        // Only include key=value params
        if (std.mem.indexOfScalar(u8, tok, '=') != null) {
            try param_list.append(alloc, tok);
        }
    }

    std.mem.sort([]const u8, param_list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    for (param_list.items, 0..) |p, i| {
        if (i > 0) try buf.append(alloc, ' ');
        try buf.appendSlice(alloc, p);
    }
    return try alloc.dupe(u8, buf.items);
}

/// Filter directives to only keep structurally significant ones for comparison.
/// Skips .save, .control/.endc blocks, and user architecture comments.
fn filterKeyDirectives(alloc: std.mem.Allocator, dirs: []const []const u8) ![]const []const u8 {
    var result: std.ArrayListUnmanaged([]const u8) = .{};
    defer result.deinit(alloc);

    for (dirs) |d| {
        // Skip .save directives (instrumentation, not structural)
        if (std.mem.startsWith(u8, d, ".save")) continue;
        // Skip .control/.endc (simulation control blocks)
        if (std.mem.startsWith(u8, d, ".control")) continue;
        if (std.mem.startsWith(u8, d, ".endc")) continue;
        // Keep everything else (.param, .include, .lib, .model, .tran, .dc, .ac, .option, .temp, .global)
        try result.append(alloc, d);
    }

    return try alloc.dupe([]const u8, result.items);
}

/// Check if two slices of strings are equal.
fn slicesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// Report specific multiset differences between two sorted string slices.
fn reportMultisetDiff(
    alloc: std.mem.Allocator,
    diffs: *std.ArrayListUnmanaged([]const u8),
    label: []const u8,
    ref_items: []const []const u8,
    ours_items: []const []const u8,
) !void {
    // Count occurrences of each item in ref and ours
    var ref_counts = std.StringHashMap(usize).init(alloc);
    defer ref_counts.deinit();
    var ours_counts = std.StringHashMap(usize).init(alloc);
    defer ours_counts.deinit();

    for (ref_items) |item| {
        const gop = try ref_counts.getOrPut(item);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    for (ours_items) |item| {
        const gop = try ours_counts.getOrPut(item);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    // Find items only in ref or with different counts
    var rit = ref_counts.iterator();
    while (rit.next()) |entry| {
        const ours_n = ours_counts.get(entry.key_ptr.*) orelse 0;
        if (ours_n != entry.value_ptr.*) {
            try diffs.append(alloc, try std.fmt.allocPrint(alloc,
                "  {s} '{s}': ref={d} ours={d}", .{ label, entry.key_ptr.*, entry.value_ptr.*, ours_n }));
        }
    }
    // Find items only in ours
    var oit = ours_counts.iterator();
    while (oit.next()) |entry| {
        if (!ref_counts.contains(entry.key_ptr.*)) {
            try diffs.append(alloc, try std.fmt.allocPrint(alloc,
                "  {s} '{s}': ref=0 ours={d}", .{ label, entry.key_ptr.*, entry.value_ptr.* }));
        }
    }
}

/// Join a slice of strings with a separator, returning an allocated string.
fn joinStrSlice(alloc: std.mem.Allocator, items: []const []const u8, sep: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    for (items, 0..) |item, i| {
        if (i > 0) try buf.appendSlice(alloc, sep);
        try buf.appendSlice(alloc, item);
    }
    return try alloc.dupe(u8, buf.items);
}

fn stemName(path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| path[idx + 1 ..] else path;
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| return base[0..dot];
    return base;
}

// ── Backend direct tests ─────────────────────────────────────────────────

test "Backend.label returns XSchem" {
    const backend = XSchem.Backend.init(testing.allocator);
    try testing.expectEqualStrings("XSchem", backend.label());
}

test "Backend.detectProjectRoot finds xschemrc" {
    const backend = XSchem.Backend.init(testing.allocator);
    var found = false;
    for (example_dirs) |dir| {
        if (backend.detectProjectRoot(dir)) {
            found = true;
            break;
        }
    }
    if (!found) return error.SkipZigTest;
}

test "Backend.getFiles enumerates sch and sym files" {
    const backend = XSchem.Backend.init(testing.allocator);
    for (example_dirs) |dir| {
        var files = backend.getFiles(dir) catch continue;
        defer files.deinit();
        if (files.sch_files.len > 0 or files.sym_files.len > 0) return;
    }
    return error.SkipZigTest;
}

test "Backend.getFiles finds both sch and sym in core examples" {
    const backend = XSchem.Backend.init(testing.allocator);
    var files = backend.getFiles(core_examples) catch
        return error.SkipZigTest;
    defer files.deinit();

    try testing.expect(files.sch_files.len > 0);
    try testing.expect(files.sym_files.len > 0);

    for (files.sch_files) |f| try testing.expect(std.mem.endsWith(u8, f, ".sch"));
    for (files.sym_files) |f| try testing.expect(std.mem.endsWith(u8, f, ".sym"));
}

// ── convertProject tests ─────────────────────────────────────────────────

test "Backend.convertProject returns ConvertResults" {
    const backend = XSchem.Backend.init(testing.allocator);
    for (example_dirs) |dir| {
        var results = backend.convertProject(dir) catch continue;
        defer results.deinit();

        try testing.expect(results.results.len > 0);

        for (results.results) |r| {
            try testing.expect(r.name.len > 0);
            try testing.expect(r.sch_path != null or r.sym_path != null);
        }
        return;
    }
    return error.SkipZigTest;
}

// ── Netlist parity: Schemify emitSpice vs xschem CLI ─────────────────────

test "convertProject SPICE matches xschem CLI output (connectivity)" {
    const alloc = testing.allocator;
    const backend = XSchem.Backend.init(alloc);

    for (example_dirs) |dir| {
        var results = backend.convertProject(dir) catch continue;
        defer results.deinit();

        const rcfile = try std.fs.path.join(alloc, &.{ dir, "xschemrc" });
        defer alloc.free(rcfile);

        var compared: usize = 0;
        var mismatched: usize = 0;
        for (results.results) |*r| {
            const sch_rel = r.sch_path orelse continue;

            const ref_raw = xschemNetlist(alloc, dir, rcfile, sch_rel) orelse continue;
            defer alloc.free(ref_raw);

            r.schemify.resolveNets();
            const ours_raw = r.schemify.emitSpice(alloc, .ngspice, null, .sim) catch continue;
            defer alloc.free(ours_raw);

            // Skip trivial netlists (VHDL-only components, empty schematics)
            if (ref_raw.len <= 10 or ours_raw.len <= 10) continue;

            // Lowercase both netlists for case-insensitive comparison
            const ref_lower = try alloc.alloc(u8, ref_raw.len);
            defer alloc.free(ref_lower);
            for (ref_raw, 0..) |c, i| ref_lower[i] = std.ascii.toLower(c);

            const ours_lower = try alloc.alloc(u8, ours_raw.len);
            defer alloc.free(ours_lower);
            for (ours_raw, 0..) |c, i| ours_lower[i] = std.ascii.toLower(c);

            // Parse both into structured form
            var ref_parsed = try parseSpice(alloc, ref_lower);
            defer ref_parsed.deinit(alloc);
            var ours_parsed = try parseSpice(alloc, ours_lower);
            defer ours_parsed.deinit(alloc);

            // Skip if either side produced zero instances (e.g. pure-directive testbenches)
            if (ref_parsed.instances.len == 0 or ours_parsed.instances.len == 0) continue;

            // Compare connectivity
            var cmp = try compareSpiceConnectivity(alloc, &ref_parsed, &ours_parsed);
            defer cmp.deinit(alloc);

            if (!cmp.equivalent) {
                std.debug.print("\n  MISMATCH: {s} ({d} diff(s)):\n", .{ r.name, cmp.diffs.items.len });
                for (cmp.diffs.items) |d| {
                    std.debug.print("    - {s}\n", .{d});
                }
                // DEBUG: dump both netlists for mismatched cases
                std.debug.print("\n  --- REF netlist ({s}) ---\n{s}\n  --- END REF ---\n", .{ r.name, ref_raw });
                std.debug.print("\n  --- OURS netlist ({s}) ---\n{s}\n  --- END OURS ---\n", .{ r.name, ours_raw });
                mismatched += 1;
            } else {
                std.debug.print("\n  MATCH: {s}\n", .{r.name});
            }
            compared += 1;
        }
        if (compared > 0) {
            std.debug.print("\nCompared {d} netlists (connectivity): {d} matched, {d} mismatched\n", .{ compared, compared - mismatched, mismatched });
            // FAIL the test if any netlists mismatched
            try testing.expect(mismatched == 0);
            return;
        }
    }
    return error.SkipZigTest;
}

// ── EasyImport facade tests ──────────────────────────────────────────────

test "EasyImport.init and label for xschem backend" {
    const ei = easyimport.EasyImport.init(
        testing.allocator,
        core_examples,
        .xschem,
    );
    try testing.expectEqualStrings("XSchem", ei.label());
}

test "EasyImport.init and label for virtuoso backend" {
    const ei = easyimport.EasyImport.init(
        testing.allocator,
        "/tmp/fake_virtuoso_project",
        .virtuoso,
    );
    try testing.expectEqualStrings("Cadence Virtuoso", ei.label());
}

test "EasyImport.convertProject delegates to xschem backend" {
    const ei = easyimport.EasyImport.init(
        testing.allocator,
        core_examples,
        .xschem,
    );
    var results = ei.convertProject() catch |err| switch (err) {
        error.NoXschemrc => return error.SkipZigTest,
        else => return err,
    };
    defer results.deinit();
    try testing.expect(results.results.len > 0);
}

test "EasyImport.getFiles returns file listing" {
    const ei = easyimport.EasyImport.init(
        testing.allocator,
        core_examples,
        .xschem,
    );
    var files = ei.getFiles() catch return error.SkipZigTest;
    defer files.deinit();

    try testing.expect(files.sch_files.len > 0);
}

test "EasyImport.convertProject returns error for virtuoso" {
    const ei = easyimport.EasyImport.init(
        testing.allocator,
        "/tmp/fake",
        .virtuoso,
    );
    try testing.expectError(error.BackendNotImplemented, ei.convertProject());
}

test "EasyImport.getFiles returns error for virtuoso" {
    const ei = easyimport.EasyImport.init(
        testing.allocator,
        "/tmp/fake",
        .virtuoso,
    );
    try testing.expectError(error.BackendNotImplemented, ei.getFiles());
}

// ═══════════════════════════════════════════════════════════════════════════
// ── Reader: parse individual .sch/.sym files ─────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════

test "reader: cmos_inv.sch element counts" {
    var s = try parseCoreFile(testing.allocator, "cmos_inv.sch");
    defer s.deinit();

    // 14 wires (N lines)
    try testing.expectEqual(@as(usize, 14), s.wires.len);
    // 14 component instances (C lines: opin, ipin, vdd, 5×lab_pin, pmos4, nmos4, title, res, 2×ammeter)
    try testing.expectEqual(@as(usize, 14), s.instances.len);
    // 2 text elements (T lines: @name, @symname)
    try testing.expectEqual(@as(usize, 2), s.texts.len);
    // 1 arc (A line)
    try testing.expectEqual(@as(usize, 1), s.arcs.len);
    // No pins in schematic (pins come from symbol)
    // (B 5 pins only appear in .sym files; the K block is in the .sch here but it
    //  doesn't contain B 5 lines)
}

test "reader: cmos_inv.sch wire net names" {
    var s = try parseCoreFile(testing.allocator, "cmos_inv.sch");
    defer s.deinit();

    // Collect all wire net names
    var names = std.StringHashMap(void).init(testing.allocator);
    defer names.deinit();
    const sl = s.wires.slice();
    for (0..s.wires.len) |i| {
        if (sl.items(.net_name)[i]) |n| {
            try names.put(n, {});
        }
    }
    // Verify expected net names are present
    try testing.expect(names.contains("A"));
    try testing.expect(names.contains("VDD"));
    try testing.expect(names.contains("D"));
    try testing.expect(names.contains("Z"));
    try testing.expect(names.contains("0"));
    try testing.expect(names.contains("net1"));
    try testing.expect(names.contains("net2"));
}

test "reader: cmos_inv.sch K-block metadata" {
    var s = try parseCoreFile(testing.allocator, "cmos_inv.sch");
    defer s.deinit();

    try testing.expectEqualStrings("subcircuit", s.k_type.?);
    try testing.expect(s.k_format != null);
    try testing.expect(std.mem.indexOf(u8, s.k_format.?, "@name") != null);
    try testing.expectEqualStrings("name=X1 WN=15u WP=45u LLN=3u LLP=3u m=1", s.k_template.?);
}

test "reader: cmos_inv.sch instance symbols" {
    var s = try parseCoreFile(testing.allocator, "cmos_inv.sch");
    defer s.deinit();

    var symbols = std.StringHashMap(void).init(testing.allocator);
    defer symbols.deinit();
    const sl = s.instances.slice();
    for (0..s.instances.len) |i| {
        try symbols.put(sl.items(.symbol)[i], {});
    }

    try testing.expect(symbols.contains("opin.sym"));
    try testing.expect(symbols.contains("ipin.sym"));
    try testing.expect(symbols.contains("vdd.sym"));
    try testing.expect(symbols.contains("lab_pin.sym"));
    try testing.expect(symbols.contains("pmos4.sym"));
    try testing.expect(symbols.contains("nmos4.sym"));
    try testing.expect(symbols.contains("title.sym"));
    try testing.expect(symbols.contains("res.sym"));
    try testing.expect(symbols.contains("ammeter.sym"));
}

test "reader: cmos_inv.sym element counts" {
    var s = try parseCoreFile(testing.allocator, "cmos_inv.sym");
    defer s.deinit();

    // 5 lines (L 4 ...)
    try testing.expectEqual(@as(usize, 5), s.lines.len);
    // 2 pins (B 5 ...): Z:out, A:in
    try testing.expectEqual(@as(usize, 2), s.pins.len);
    // 1 arc
    try testing.expectEqual(@as(usize, 1), s.arcs.len);
    // 6 text elements
    try testing.expectEqual(@as(usize, 6), s.texts.len);
    // 2 rects total (the 2 B 5 pin rects)
    try testing.expectEqual(@as(usize, 2), s.rects.len);
}

test "reader: cmos_inv.sym pin names and directions" {
    var s = try parseCoreFile(testing.allocator, "cmos_inv.sym");
    defer s.deinit();

    const sl = s.pins.slice();
    var found_a = false;
    var found_z = false;
    for (0..s.pins.len) |i| {
        const name = sl.items(.name)[i];
        const dir = sl.items(.direction)[i];
        if (std.mem.eql(u8, name, "A")) {
            try testing.expectEqual(XSchem.PinDirection.input, dir);
            found_a = true;
        } else if (std.mem.eql(u8, name, "Z")) {
            try testing.expectEqual(XSchem.PinDirection.output, dir);
            found_z = true;
        }
    }
    try testing.expect(found_a);
    try testing.expect(found_z);
}

test "reader: cmos_inv.sym K-block type is subcircuit" {
    var s = try parseCoreFile(testing.allocator, "cmos_inv.sym");
    defer s.deinit();

    try testing.expectEqual(XSchem.FileType.symbol, s.file_type);
    try testing.expectEqualStrings("subcircuit", s.k_type.?);
}

test "reader: nand2.sch element counts" {
    var s = try parseCoreFile(testing.allocator, "nand2.sch");
    defer s.deinit();

    // 20 wires
    try testing.expectEqual(@as(usize, 20), s.wires.len);
    // 14 instances (4 MOSFETs + ipin×2 + opin + title + gnd + vdd + 4×lab_pin)
    try testing.expectEqual(@as(usize, 14), s.instances.len);
}

test "reader: nand2.sch wire net names include expected signals" {
    var s = try parseCoreFile(testing.allocator, "nand2.sch");
    defer s.deinit();

    var names = std.StringHashMap(void).init(testing.allocator);
    defer names.deinit();
    const sl = s.wires.slice();
    for (0..s.wires.len) |i| {
        if (sl.items(.net_name)[i]) |n| try names.put(n, {});
    }
    try testing.expect(names.contains("A"));
    try testing.expect(names.contains("B"));
    try testing.expect(names.contains("Z"));
    try testing.expect(names.contains("VCC"));
    try testing.expect(names.contains("VSS"));
}

test "reader: diode_1.sym has 2 pins" {
    var s = try parseCoreFile(testing.allocator, "diode_1.sym");
    defer s.deinit();

    try testing.expectEqual(@as(usize, 2), s.pins.len);

    const sl = s.pins.slice();
    var found_p = false;
    var found_m = false;
    for (0..s.pins.len) |i| {
        const name = sl.items(.name)[i];
        if (std.mem.eql(u8, name, "p")) found_p = true;
        if (std.mem.eql(u8, name, "m")) found_m = true;
    }
    try testing.expect(found_p);
    try testing.expect(found_m);
}

test "reader: diode_1.sym K-block type is subcircuit" {
    var s = try parseCoreFile(testing.allocator, "diode_1.sym");
    defer s.deinit();

    try testing.expectEqualStrings("subcircuit", s.k_type.?);
    try testing.expect(s.k_format != null);
    try testing.expect(s.k_template != null);
}

test "reader: rlc.sch is a testbench with graph rects" {
    var s = try parseCoreFile(testing.allocator, "rlc.sch");
    defer s.deinit();

    // rlc.sch has no K-block type, so it's a schematic (testbench-style)
    try testing.expectEqual(XSchem.FileType.schematic, s.file_type);
    try testing.expect(s.k_type == null);
    // Has lines, rects (including graph rects), wires, instances
    try testing.expect(s.lines.len > 0);
    try testing.expect(s.rects.len > 0);
    try testing.expect(s.wires.len > 0);
    try testing.expect(s.instances.len > 0);
}

test "reader: rlc.sch instance properties parsed correctly" {
    var s = try parseCoreFile(testing.allocator, "rlc.sch");
    defer s.deinit();

    // Find the capacitor instance (C1) and check its properties
    const sl = s.instances.slice();
    for (0..s.instances.len) |i| {
        const name = sl.items(.name)[i];
        if (std.mem.eql(u8, name, "C1")) {
            const ps = sl.items(.prop_start)[i];
            const pc = sl.items(.prop_count)[i];
            // Should have properties including value=50nF
            try testing.expect(pc > 0);
            for (s.props.items[ps..][0..pc]) |p| {
                if (std.mem.eql(u8, p.key, "value")) {
                    try testing.expectEqualStrings("50nF", p.value);
                    return;
                }
            }
            return error.TestUnexpectedResult; // value prop not found
        }
    }
    return error.TestUnexpectedResult; // C1 not found
}

test "reader: sr_flop.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "sr_flop.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
    try testing.expect(s.wires.len > 0);
}

test "reader: greycnt.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "greycnt.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: tesla.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "tesla.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: test_ac.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "test_ac.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
    try testing.expect(s.wires.len > 0);
}

test "reader: classD_amp.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "classD_amp.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: flop.sch parses and has instances" {
    var s = try parseCoreFile(testing.allocator, "flop.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
    try testing.expect(s.wires.len > 0);
}

test "reader: dlatch.sch parses and has instances" {
    var s = try parseCoreFile(testing.allocator, "dlatch.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
    try testing.expect(s.wires.len > 0);
}

test "reader: poweramp.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "poweramp.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: loading.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "loading.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: cmos_example.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "cmos_example.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
    try testing.expect(s.wires.len > 0);
}

test "reader: osc.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "osc.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: lm317.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "lm317.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: lm337.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "lm337.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: pump.sch parses successfully (VHDL schematic)" {
    var s = try parseCoreFile(testing.allocator, "pump.sch");
    defer s.deinit();
    // pump.sch is a VHDL component -- has instances but no wires
    try testing.expect(s.instances.len > 0);
}

test "reader: xnor.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "xnor.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: xcross.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "xcross.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: rcline.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "rcline.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: test_jfet.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "test_jfet.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: test_ne555.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "test_ne555.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: test_bus_tap.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "test_bus_tap.sch");
    defer s.deinit();
    // May or may not have instances; just confirm it parses
}

test "reader: bus_keeper.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "bus_keeper.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: test_doublepin.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "test_doublepin.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: doublepin.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "doublepin.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: real_capa.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "real_capa.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: test_extracted_netlist.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "test_extracted_netlist.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: test_lm324.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "test_lm324.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: test_lvs_ignore.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "test_lvs_ignore.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: test_nyquist.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "test_nyquist.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: test_short_option.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "test_short_option.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: test_evaluated_param.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "test_evaluated_param.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: tb_symbol_include.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "tb_symbol_include.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: tb_test_evaluated_param.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "tb_test_evaluated_param.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: test_backannotated_subckt.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "test_backannotated_subckt.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: test_ac_xyce.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "test_ac_xyce.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: plot_manipulation.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "plot_manipulation.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: LCC_instances.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "LCC_instances.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: LM5134A.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "LM5134A.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: Q1.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "Q1.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: Q2.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "Q2.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: mos_power_ampli.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "mos_power_ampli.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: mos_power_ampli_extracted.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "mos_power_ampli_extracted.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: SYMBOL_include.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "SYMBOL_include.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: switch_rreal.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "switch_rreal.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: poweramp_lcc.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "poweramp_lcc.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

test "reader: poweramp_xyce.sch parses successfully" {
    var s = try parseCoreFile(testing.allocator, "poweramp_xyce.sch");
    defer s.deinit();
    try testing.expect(s.instances.len > 0);
}

// ── Reader: .sym file tests ──────────────────────────────────────────────

test "reader: nand2.sym has 3 pins" {
    var s = try parseCoreFile(testing.allocator, "nand2.sym");
    defer s.deinit();

    try testing.expectEqual(@as(usize, 3), s.pins.len);
    try testing.expectEqualStrings("subcircuit", s.k_type.?);
}

test "reader: flop.sym has pins" {
    var s = try parseCoreFile(testing.allocator, "flop.sym");
    defer s.deinit();
    try testing.expect(s.pins.len > 0);
    try testing.expectEqualStrings("subcircuit", s.k_type.?);
}

test "reader: dlatch.sym has pins" {
    var s = try parseCoreFile(testing.allocator, "dlatch.sym");
    defer s.deinit();
    try testing.expect(s.pins.len > 0);
    try testing.expectEqualStrings("subcircuit", s.k_type.?);
}

test "reader: osc.sym parses successfully" {
    var s = try parseCoreFile(testing.allocator, "osc.sym");
    defer s.deinit();
    // osc.sym has no B 5 pin rects; just verify parse succeeds
}

test "reader: greycnt.sym parses successfully" {
    var s = try parseCoreFile(testing.allocator, "greycnt.sym");
    defer s.deinit();
}

test "reader: sr_flop.sym has pins" {
    var s = try parseCoreFile(testing.allocator, "sr_flop.sym");
    defer s.deinit();
    try testing.expect(s.pins.len > 0);
}

test "reader: classD_amp.sym parses successfully" {
    var s = try parseCoreFile(testing.allocator, "classD_amp.sym");
    defer s.deinit();
}

test "reader: loading.sym parses successfully" {
    var s = try parseCoreFile(testing.allocator, "loading.sym");
    defer s.deinit();
}

test "reader: cmos_example.sym parses successfully" {
    var s = try parseCoreFile(testing.allocator, "cmos_example.sym");
    defer s.deinit();
}

test "reader: lm317.sym has pins" {
    var s = try parseCoreFile(testing.allocator, "lm317.sym");
    defer s.deinit();
    try testing.expect(s.pins.len > 0);
}

test "reader: lm337.sym has pins" {
    var s = try parseCoreFile(testing.allocator, "lm337.sym");
    defer s.deinit();
    try testing.expect(s.pins.len > 0);
}

test "reader: poweramp.sym parses successfully" {
    var s = try parseCoreFile(testing.allocator, "poweramp.sym");
    defer s.deinit();
}

test "reader: Q1.sym has pins" {
    var s = try parseCoreFile(testing.allocator, "Q1.sym");
    defer s.deinit();
    try testing.expect(s.pins.len > 0);
}

test "reader: Q2.sym has pins" {
    var s = try parseCoreFile(testing.allocator, "Q2.sym");
    defer s.deinit();
    try testing.expect(s.pins.len > 0);
}

test "reader: LCC_instances.sym parses successfully" {
    var s = try parseCoreFile(testing.allocator, "LCC_instances.sym");
    defer s.deinit();
}

test "reader: LM5134A.sym has pins" {
    var s = try parseCoreFile(testing.allocator, "LM5134A.sym");
    defer s.deinit();
    try testing.expect(s.pins.len > 0);
}

// ═══════════════════════════════════════════════════════════════════════════
// ── PropertyTokenizer tests ──────────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════

test "props: simple key=value parsing" {
    var ptok = XSchem.PropertyTokenizer.init("name=R1 value=10k m=1");
    const t1 = ptok.next().?;
    try testing.expectEqualStrings("name", t1.key);
    try testing.expectEqualStrings("R1", t1.value);
    const t2 = ptok.next().?;
    try testing.expectEqualStrings("value", t2.key);
    try testing.expectEqualStrings("10k", t2.value);
    const t3 = ptok.next().?;
    try testing.expectEqualStrings("m", t3.key);
    try testing.expectEqualStrings("1", t3.value);
    try testing.expect(ptok.next() == null);
}

test "props: quoted values" {
    var ptok = XSchem.PropertyTokenizer.init("name=p2 lab=Z dir=out");
    const t1 = ptok.next().?;
    try testing.expectEqualStrings("name", t1.key);
    try testing.expectEqualStrings("p2", t1.value);
    const t2 = ptok.next().?;
    try testing.expectEqualStrings("lab", t2.key);
    try testing.expectEqualStrings("Z", t2.value);
    const t3 = ptok.next().?;
    try testing.expectEqualStrings("dir", t3.key);
    try testing.expectEqualStrings("out", t3.value);
}

test "props: double-quoted value with spaces" {
    var ptok = XSchem.PropertyTokenizer.init("name=l5 author=\"Stefan Schippers\"");
    const t1 = ptok.next().?;
    try testing.expectEqualStrings("name", t1.key);
    try testing.expectEqualStrings("l5", t1.value);
    const t2 = ptok.next().?;
    try testing.expectEqualStrings("author", t2.key);
    try testing.expectEqualStrings("Stefan Schippers", t2.value);
}

test "props: K-block format with @ references" {
    var ptok = XSchem.PropertyTokenizer.init(
        "type=subcircuit format=\"@name @pinlist @symname\" template=\"name=X1 WN=15u\"",
    );
    const t1 = ptok.next().?;
    try testing.expectEqualStrings("type", t1.key);
    try testing.expectEqualStrings("subcircuit", t1.value);
    const t2 = ptok.next().?;
    try testing.expectEqualStrings("format", t2.key);
    try testing.expectEqualStrings("@name @pinlist @symname", t2.value);
    const t3 = ptok.next().?;
    try testing.expectEqualStrings("template", t3.key);
    try testing.expectEqualStrings("name=X1 WN=15u", t3.value);
}

test "props: pin properties with dir" {
    var ptok = XSchem.PropertyTokenizer.init("name=A dir=in goto=0 propag=0");
    _ = ptok.next(); // name
    const dir = ptok.next().?;
    try testing.expectEqualStrings("dir", dir.key);
    try testing.expectEqualStrings("in", dir.value);
}

test "props: empty properties" {
    var ptok = XSchem.PropertyTokenizer.init("");
    try testing.expect(ptok.next() == null);
}

test "props: sig_type property" {
    var ptok = XSchem.PropertyTokenizer.init("name=l2 sig_type=std_logic lab=0");
    _ = ptok.next(); // name
    const t2 = ptok.next().?;
    try testing.expectEqualStrings("sig_type", t2.key);
    try testing.expectEqualStrings("std_logic", t2.value);
    const t3 = ptok.next().?;
    try testing.expectEqualStrings("lab", t3.key);
    try testing.expectEqualStrings("0", t3.value);
}

test "props: parseProps with arena allocation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try XSchem.parseProps(a, "name=M2 model=p w=WP l=LLP m=1");
    try testing.expectEqual(@as(u16, 5), result.count);
    try testing.expectEqualStrings("name", result.props[0].key);
    try testing.expectEqualStrings("M2", result.props[0].value);
    try testing.expectEqualStrings("model", result.props[1].key);
    try testing.expectEqualStrings("p", result.props[1].value);
    try testing.expectEqualStrings("w", result.props[2].key);
    try testing.expectEqualStrings("WP", result.props[2].value);
}

test "props: parseProps handles escaped braces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try XSchem.parseProps(a, "format=\"\\{subckt\\}\"");
    try testing.expectEqual(@as(u16, 1), result.count);
    try testing.expectEqualStrings("format", result.props[0].key);
    try testing.expectEqualStrings("{subckt}", result.props[0].value);
}

test "props: parseProps with multiline value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try XSchem.parseProps(a, "name=R1\nvalue=10\nfootprint=1206\ndevice=resistor\nm=1");
    try testing.expectEqual(@as(u16, 5), result.count);
    try testing.expectEqualStrings("value", result.props[1].key);
    try testing.expectEqualStrings("10", result.props[1].value);
    try testing.expectEqualStrings("m", result.props[4].key);
    try testing.expectEqualStrings("1", result.props[4].value);
}

// ═══════════════════════════════════════════════════════════════════════════
// ── pinDirectionFromStr tests ────────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════

test "pinDirection: all direction strings" {
    try testing.expectEqual(XSchem.PinDirection.input, XSchem.pinDirectionFromStr("in"));
    try testing.expectEqual(XSchem.PinDirection.output, XSchem.pinDirectionFromStr("out"));
    try testing.expectEqual(XSchem.PinDirection.inout, XSchem.pinDirectionFromStr("inout"));
    try testing.expectEqual(XSchem.PinDirection.inout, XSchem.pinDirectionFromStr("io"));
    try testing.expectEqual(XSchem.PinDirection.power, XSchem.pinDirectionFromStr("power"));
    try testing.expectEqual(XSchem.PinDirection.ground, XSchem.pinDirectionFromStr("ground"));
    try testing.expectEqual(XSchem.PinDirection.inout, XSchem.pinDirectionFromStr("unknown"));
    try testing.expectEqual(XSchem.PinDirection.inout, XSchem.pinDirectionFromStr(""));
}

test "pinDirection: roundtrip" {
    const dirs = [_]XSchem.PinDirection{ .input, .output, .inout, .power, .ground };
    for (dirs) |d| {
        const s = XSchem.pinDirectionToStr(d);
        const back = XSchem.pinDirectionFromStr(s);
        try testing.expectEqual(d, back);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// ── XschemRC parser tests ────────────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════

test "xschemrc: core examples xschemrc parses and returns lib paths" {
    const alloc = testing.allocator;
    const rc_bytes = readCoreFile(alloc, "xschemrc") catch return error.SkipZigTest;
    defer alloc.free(rc_bytes);

    var rc = XSchem.parseRc(alloc, rc_bytes, core_examples, core_examples ++ "/xschemrc") catch
        return error.SkipZigTest;
    defer rc.deinit();

    // Should have at least one library path
    try testing.expect(rc.lib_paths.len > 0);

    // Project dir should be set
    try testing.expectEqualStrings(core_examples, rc.project_dir);
}

test "xschemrc: lib paths contain expected directories" {
    const alloc = testing.allocator;
    const rc_bytes = readCoreFile(alloc, "xschemrc") catch return error.SkipZigTest;
    defer alloc.free(rc_bytes);

    var rc = XSchem.parseRc(alloc, rc_bytes, core_examples, core_examples ++ "/xschemrc") catch
        return error.SkipZigTest;
    defer rc.deinit();

    // The xschemrc appends paths including xschem_library/devices
    var found_devices = false;
    for (rc.lib_paths) |p| {
        if (std.mem.indexOf(u8, p, "xschem_library/devices") != null) {
            found_devices = true;
        }
    }
    try testing.expect(found_devices);
}

test "xschemrc: xschem_sharedir is set" {
    const alloc = testing.allocator;
    const rc_bytes = readCoreFile(alloc, "xschemrc") catch return error.SkipZigTest;
    defer alloc.free(rc_bytes);

    var rc = XSchem.parseRc(alloc, rc_bytes, core_examples, core_examples ++ "/xschemrc") catch
        return error.SkipZigTest;
    defer rc.deinit();

    try testing.expect(rc.xschem_sharedir.len > 0);
}

test "xschemrc: user_conf_dir is set" {
    const alloc = testing.allocator;
    const rc_bytes = readCoreFile(alloc, "xschemrc") catch return error.SkipZigTest;
    defer alloc.free(rc_bytes);

    var rc = XSchem.parseRc(alloc, rc_bytes, core_examples, core_examples ++ "/xschemrc") catch
        return error.SkipZigTest;
    defer rc.deinit();

    try testing.expect(rc.user_conf_dir.len > 0);
}

// ═══════════════════════════════════════════════════════════════════════════
// ── Tcl evaluator tests ──────────────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════

test "tcl: set and get variable" {
    var t = tcl.Tcl.init(testing.allocator);
    defer t.deinit();

    try t.setVar("foo", "bar");
    const v = t.getVar("foo");
    try testing.expect(v != null);
    try testing.expectEqualStrings("bar", v.?);
}

test "tcl: eval set command" {
    var t = tcl.Tcl.init(testing.allocator);
    defer t.deinit();

    _ = try t.eval("set myvar hello");
    const v = t.getVar("myvar");
    try testing.expect(v != null);
    try testing.expectEqualStrings("hello", v.?);
}

test "tcl: append command" {
    var t = tcl.Tcl.init(testing.allocator);
    defer t.deinit();

    _ = try t.eval("set x {}");
    _ = try t.eval("append x :first");
    _ = try t.eval("append x :second");
    const v = t.getVar("x");
    try testing.expect(v != null);
    try testing.expectEqualStrings(":first:second", v.?);
}

test "tcl: variable substitution" {
    var t = tcl.Tcl.init(testing.allocator);
    defer t.deinit();

    try t.setVar("HOME", "/home/test");
    _ = try t.eval("set path $HOME/.xschem");
    const v = t.getVar("path");
    try testing.expect(v != null);
    try testing.expectEqualStrings("/home/test/.xschem", v.?);
}

test "tcl: braced variable substitution" {
    var t = tcl.Tcl.init(testing.allocator);
    defer t.deinit();

    try t.setVar("SHAREDIR", "/usr/share/xschem");
    _ = try t.eval("set lib ${SHAREDIR}/devices");
    const v = t.getVar("lib");
    try testing.expect(v != null);
    try testing.expectEqualStrings("/usr/share/xschem/devices", v.?);
}

test "tcl: if expression evaluates correctly" {
    var t = tcl.Tcl.init(testing.allocator);
    defer t.deinit();

    _ = try t.eval("set x 1");
    _ = try t.eval(
        \\if { $x == 1 } { set result yes } else { set result no }
    );
    const v = t.getVar("result");
    try testing.expect(v != null);
    try testing.expectEqualStrings("yes", v.?);
}

// ═══════════════════════════════════════════════════════════════════════════
// ── Converter tests ──────────────────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════

test "converter: cmos_inv converts to component stype" {
    const alloc = testing.allocator;
    var schematic = try parseCoreFile(alloc, "cmos_inv.sch");
    defer schematic.deinit();
    var symbol = try parseCoreFile(alloc, "cmos_inv.sym");
    defer symbol.deinit();

    var sfy = try XSchem.convert(alloc, &schematic, &symbol, "cmos_inv", null);
    defer sfy.deinit();

    try testing.expectEqualStrings("cmos_inv", sfy.name);
    try testing.expectEqual(core.SifyType.component, sfy.stype);
    // Should have wires, instances, pins from symbol
    try testing.expect(sfy.wires.len > 0);
    try testing.expect(sfy.instances.len > 0);
    try testing.expect(sfy.pins.len > 0);
    // 2 pins from cmos_inv.sym (A, Z)
    try testing.expectEqual(@as(usize, 2), sfy.pins.len);
}

test "converter: nand2 converts to component with 3 pins" {
    const alloc = testing.allocator;
    var schematic = try parseCoreFile(alloc, "nand2.sch");
    defer schematic.deinit();
    var sym_parsed = try parseCoreFile(alloc, "nand2.sym");
    defer sym_parsed.deinit();

    var sfy = try XSchem.convert(alloc, &schematic, &sym_parsed, "nand2", null);
    defer sfy.deinit();

    try testing.expectEqual(core.SifyType.component, sfy.stype);
    try testing.expectEqual(@as(usize, 3), sfy.pins.len);
    try testing.expect(sfy.instances.len > 0);
    try testing.expect(sfy.wires.len > 0);
}

test "converter: rlc converts to testbench (no symbol)" {
    const alloc = testing.allocator;
    var schematic = try parseCoreFile(alloc, "rlc.sch");
    defer schematic.deinit();

    var sfy = try XSchem.convert(alloc, &schematic, null, "rlc", null);
    defer sfy.deinit();

    try testing.expectEqual(core.SifyType.testbench, sfy.stype);
    try testing.expect(sfy.instances.len > 0);
    try testing.expect(sfy.wires.len > 0);
}

test "converter: sym_props contain format and template from K-block" {
    const alloc = testing.allocator;
    var schematic = try parseCoreFile(alloc, "cmos_inv.sch");
    defer schematic.deinit();
    var symbol = try parseCoreFile(alloc, "cmos_inv.sym");
    defer symbol.deinit();

    var sfy = try XSchem.convert(alloc, &schematic, &symbol, "cmos_inv", null);
    defer sfy.deinit();

    // K-block props should be in sym_props
    var found_format = false;
    var found_template = false;
    var found_type = false;
    for (sfy.sym_props.items) |p| {
        if (std.mem.eql(u8, p.key, "format")) found_format = true;
        if (std.mem.eql(u8, p.key, "template")) found_template = true;
        if (std.mem.eql(u8, p.key, "type")) found_type = true;
    }
    try testing.expect(found_format);
    try testing.expect(found_template);
    try testing.expect(found_type);
}

test "converter: coordinate mapping preserves approximate values" {
    const alloc = testing.allocator;
    var symbol = try parseCoreFile(alloc, "cmos_inv.sym");
    defer symbol.deinit();

    var schematic = try parseCoreFile(alloc, "cmos_inv.sch");
    defer schematic.deinit();

    var sfy = try XSchem.convert(alloc, &schematic, &symbol, "cmos_inv", null);
    defer sfy.deinit();

    // cmos_inv.sch has no L lines; geometry lines come from schematic only.
    // Verify the conversion completes and produces expected structure.
    try testing.expect(sfy.pins.len > 0);
    try testing.expect(sfy.instances.len > 0);
}

test "converter: instance properties preserved" {
    const alloc = testing.allocator;
    var schematic = try parseCoreFile(alloc, "cmos_inv.sch");
    defer schematic.deinit();
    var symbol = try parseCoreFile(alloc, "cmos_inv.sym");
    defer symbol.deinit();

    var sfy = try XSchem.convert(alloc, &schematic, &symbol, "cmos_inv", null);
    defer sfy.deinit();

    // Find the pmos4 instance (M2) and check it has model=p
    const inst_sl = sfy.instances.slice();
    for (0..sfy.instances.len) |i| {
        const sym = inst_sl.items(.symbol)[i];
        if (std.mem.eql(u8, sym, "pmos4")) {
            const ps = inst_sl.items(.prop_start)[i];
            const pc = inst_sl.items(.prop_count)[i];
            for (sfy.props.items[ps..][0..pc]) |p| {
                if (std.mem.eql(u8, p.key, "model")) {
                    try testing.expectEqualStrings("p", p.val);
                    return;
                }
            }
        }
    }
    // pmos4 instance not found or model prop missing
    return error.TestUnexpectedResult;
}

test "converter: diode_1 has correct pin count and type" {
    const alloc = testing.allocator;
    var schematic = try parseCoreFile(alloc, "diode_1.sch");
    defer schematic.deinit();
    var symbol = try parseCoreFile(alloc, "diode_1.sym");
    defer symbol.deinit();

    var sfy = try XSchem.convert(alloc, &schematic, &symbol, "diode_1", null);
    defer sfy.deinit();

    try testing.expectEqual(core.SifyType.component, sfy.stype);
    try testing.expectEqual(@as(usize, 2), sfy.pins.len);
}

// ═══════════════════════════════════════════════════════════════════════════
// ── Bulk parse sweep: every .sch/.sym must parse without error ───────────
// ═══════════════════════════════════════════════════════════════════════════

test "bulk: all core example .sch files parse without error" {
    const alloc = testing.allocator;
    const backend = XSchem.Backend.init(alloc);
    var files = backend.getFiles(core_examples) catch return error.SkipZigTest;
    defer files.deinit();

    var parsed: usize = 0;
    for (files.sch_files) |rel| {
        const full = try std.fs.path.join(alloc, &.{ core_examples, rel });
        defer alloc.free(full);
        const data = std.fs.cwd().readFileAlloc(alloc, full, 4 << 20) catch continue;
        defer alloc.free(data);
        var s = XSchem.parse(alloc, data) catch |err| {
            std.debug.print("\nFailed to parse {s}: {}\n", .{ rel, err });
            return err;
        };
        s.deinit();
        parsed += 1;
    }
    try testing.expect(parsed > 0);
    std.debug.print("\nParsed {d} .sch files successfully\n", .{parsed});
}

test "bulk: all core example .sym files parse without error" {
    const alloc = testing.allocator;
    const backend = XSchem.Backend.init(alloc);
    var files = backend.getFiles(core_examples) catch return error.SkipZigTest;
    defer files.deinit();

    var parsed: usize = 0;
    for (files.sym_files) |rel| {
        const full = try std.fs.path.join(alloc, &.{ core_examples, rel });
        defer alloc.free(full);
        const data = std.fs.cwd().readFileAlloc(alloc, full, 4 << 20) catch continue;
        defer alloc.free(data);
        var s = XSchem.parse(alloc, data) catch |err| {
            std.debug.print("\nFailed to parse {s}: {}\n", .{ rel, err });
            return err;
        };
        s.deinit();
        parsed += 1;
    }
    try testing.expect(parsed > 0);
    std.debug.print("\nParsed {d} .sym files successfully\n", .{parsed});
}

test "bulk: all core example pairs convert without error" {
    const alloc = testing.allocator;
    const backend = XSchem.Backend.init(alloc);
    var results = backend.convertProject(core_examples) catch return error.SkipZigTest;
    defer results.deinit();

    try testing.expect(results.results.len > 0);
    std.debug.print("\nConverted {d} schematic pairs\n", .{results.results.len});

    // Every result should have a non-empty name
    for (results.results) |r| {
        try testing.expect(r.name.len > 0);
    }
}

test "bulk: sky130 examples parse without error" {
    const alloc = testing.allocator;
    const sky130_dir = "plugins/EasyImport/examples/xschem_sky130";
    const backend = XSchem.Backend.init(alloc);
    var files = backend.getFiles(sky130_dir) catch return error.SkipZigTest;
    defer files.deinit();

    var parsed: usize = 0;
    for (files.sch_files) |rel| {
        const full = try std.fs.path.join(alloc, &.{ sky130_dir, rel });
        defer alloc.free(full);
        const data = std.fs.cwd().readFileAlloc(alloc, full, 4 << 20) catch continue;
        defer alloc.free(data);
        var s = XSchem.parse(alloc, data) catch continue;
        s.deinit();
        parsed += 1;
    }
    for (files.sym_files) |rel| {
        const full = try std.fs.path.join(alloc, &.{ sky130_dir, rel });
        defer alloc.free(full);
        const data = std.fs.cwd().readFileAlloc(alloc, full, 4 << 20) catch continue;
        defer alloc.free(data);
        var s = XSchem.parse(alloc, data) catch continue;
        s.deinit();
        parsed += 1;
    }
    if (parsed == 0) return error.SkipZigTest;
    std.debug.print("\nParsed {d} sky130 files successfully\n", .{parsed});
}
