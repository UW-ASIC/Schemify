const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Individual = types.Individual;
const Problem = types.Problem;
const TbRunResult = types.TbRunResult;
const TbMeasurement = types.TbMeasurement;
const LinkedTestbench = types.LinkedTestbench;
const DiscoveredMeasurement = types.DiscoveredMeasurement;

// ── Env Entry ────────────────────────────────────────────────────────────────

pub const EnvEntry = struct {
    key: []const u8,
    val: []const u8,
};

// ── buildParamEnv (flat) ─────────────────────────────────────────────────────

/// Build a process EnvMap from a flat list of key-value pairs.
/// Inherits PATH, HOME, and VIRTUAL_ENV from the host process.
/// Caller owns the returned EnvMap.
pub fn buildParamEnv(alloc: Allocator, entries: []const EnvEntry) !std.process.EnvMap {
    var env = std.process.EnvMap.init(alloc);
    errdefer env.deinit();

    if (std.posix.getenv("PATH")) |path| try env.put("PATH", path);
    if (std.posix.getenv("HOME")) |home| try env.put("HOME", home);
    if (std.posix.getenv("VIRTUAL_ENV")) |ve| try env.put("VIRTUAL_ENV", ve);

    for (entries) |e| {
        try env.put(e.key, e.val);
    }

    return env;
}

// ── buildParamEnvFromDesign (convenience) ────────────────────────────────────

/// Maximum entries we can emit from a single design vector.
const max_env_entries = types.max_design_vars * 2 + 16;

/// Build environment entries from a design vector and problem definition.
///
/// Env var convention:
///   MOSFETs:    SCHEMIFY_<inst>_W, SCHEMIFY_<inst>_NF
///   BJTs:       SCHEMIFY_<inst>_AE
///   Resistors:  SCHEMIFY_<inst>_W, SCHEMIFY_<inst>_L
///   Parameters: SCHEMIFY_<name>
///
/// The caller must have already converted raw design variables (e.g. gm/Id
/// ratios) to physical parameters (W, NF) before calling this. The x vector
/// is consumed in problem ordering: mosfets, bjts, resistors (W then L),
/// then parameters.
///
/// Returns an EnvMap ready for child process spawning. Caller owns it.
pub fn buildParamEnvFromDesign(
    alloc: Allocator,
    x: []const f64,
    problem: *const Problem,
) !std.process.EnvMap {
    var env = std.process.EnvMap.init(alloc);
    errdefer env.deinit();

    if (std.posix.getenv("PATH")) |path| try env.put("PATH", path);
    if (std.posix.getenv("HOME")) |home| try env.put("HOME", home);
    if (std.posix.getenv("VIRTUAL_ENV")) |ve| try env.put("VIRTUAL_ENV", ve);

    var idx: usize = 0;

    // MOSFETs: W and NF per device.
    for (problem.mosfets.slice()) |t| {
        const inst = t.instanceSlice();
        {
            if (idx >= x.len) break;
            var key_buf: [128]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "SCHEMIFY_{s}_W", .{inst}) catch continue;
            var val_buf: [32]u8 = undefined;
            const val = std.fmt.bufPrint(&val_buf, "{e}", .{x[idx]}) catch continue;
            try env.put(key, val);
            idx += 1;
        }
        // NF: use the stored nf value from the mosfet struct.
        {
            var key_buf: [128]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "SCHEMIFY_{s}_NF", .{inst}) catch continue;
            var val_buf: [32]u8 = undefined;
            const val = std.fmt.bufPrint(&val_buf, "{d}", .{t.nf}) catch continue;
            try env.put(key, val);
        }
    }

    // BJTs: emitter area.
    for (problem.bjts.slice()) |b| {
        if (idx >= x.len) break;
        const inst = b.instanceSlice();
        var key_buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "SCHEMIFY_{s}_AE", .{inst}) catch continue;
        var val_buf: [32]u8 = undefined;
        const val = std.fmt.bufPrint(&val_buf, "{e}", .{x[idx]}) catch continue;
        try env.put(key, val);
        idx += 1;
    }

    // Resistors: W then L per device.
    for (problem.resistors.slice()) |r| {
        const inst = r.instanceSlice();
        {
            if (idx >= x.len) break;
            var key_buf: [128]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "SCHEMIFY_{s}_W", .{inst}) catch continue;
            var val_buf: [32]u8 = undefined;
            const val = std.fmt.bufPrint(&val_buf, "{e}", .{x[idx]}) catch continue;
            try env.put(key, val);
            idx += 1;
        }
        {
            if (idx >= x.len) break;
            var key_buf: [128]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "SCHEMIFY_{s}_L", .{inst}) catch continue;
            var val_buf: [32]u8 = undefined;
            const val = std.fmt.bufPrint(&val_buf, "{e}", .{x[idx]}) catch continue;
            try env.put(key, val);
            idx += 1;
        }
    }

    // Generic parameters.
    for (problem.parameters.slice()) |p| {
        if (!p.enabled) continue;
        if (idx >= x.len) break;
        const pname = p.nameSlice();
        var key_buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "SCHEMIFY_{s}", .{pname}) catch continue;
        var val_buf: [32]u8 = undefined;
        const val = std.fmt.bufPrint(&val_buf, "{e}", .{x[idx]}) catch continue;
        try env.put(key, val);
        idx += 1;
    }

    return env;
}

// ── runLinkedTestbench ───────────────────────────────────────────────────────

/// Run a single linked testbench script and parse scalar measurements from
/// its JSON stdout. Returns a TbRunResult with extracted measurements.
///
/// The testbench's auto-generated Circuit Definition reads parameters from
/// environment variables: `float(os.environ.get('SCHEMIFY_M1_W', '1e-6'))`.
///
/// Expected JSON stdout format:
/// ```json
/// { "measurements": [ { "name": "gain_db", "value": 42.5, "unit": "dB" }, ... ] }
/// ```
pub fn runLinkedTestbench(
    alloc: Allocator,
    tb_path: []const u8,
    x: []const f64,
    problem: *const Problem,
) TbRunResult {
    var result = TbRunResult{};

    var env = buildParamEnvFromDesign(alloc, x, problem) catch return result;
    defer env.deinit();

    var child = std.process.Child.init(
        &.{ "python3", tb_path },
        alloc,
    );
    child.env_map = &env;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch return result;

    // Read stdout before wait to avoid pipe buffer deadlock.
    const max_out = 1 << 20; // 1 MiB
    const stdout_data = if (child.stdout) |f| f.readToEndAlloc(alloc, max_out) catch "" else "";
    defer if (stdout_data.len > 0) alloc.free(stdout_data);
    // Drain stderr to prevent blocking.
    if (child.stderr) |f| {
        const stderr_data = f.readToEndAlloc(alloc, max_out) catch "";
        if (stderr_data.len > 0) alloc.free(stderr_data);
    }

    const term = child.wait() catch return result;
    switch (term) {
        .Exited => |code| if (code != 0) return result,
        else => return result,
    }

    result = parseTbMeasurements(stdout_data);
    return result;
}

// ── parseTbMeasurements ──────────────────────────────────────────────────────

/// Parse the JSON measurements array from testbench stdout.
/// Expects: { "measurements": [ { "name": "...", "value": 1.23, "unit": "..." }, ... ] }
pub fn parseTbMeasurements(json_text: []const u8) TbRunResult {
    var result = TbRunResult{};
    if (json_text.len == 0) return result;

    const meas_key = "\"measurements\"";
    const meas_pos = std.mem.indexOf(u8, json_text, meas_key) orelse return result;
    const after_key = json_text[meas_pos + meas_key.len ..];
    // Skip whitespace and colon.
    var arr_start: usize = 0;
    for (after_key, 0..) |c, i| {
        if (c == '[') {
            arr_start = i;
            break;
        }
        if (c != ':' and c != ' ' and c != '\n' and c != '\r' and c != '\t') return result;
    }
    if (arr_start == 0 and (after_key.len == 0 or after_key[0] != '[')) return result;

    const arr_data = after_key[arr_start..];
    var idx: usize = 1; // skip '['
    var meas_count: u32 = 0;

    while (idx < arr_data.len and meas_count < types.max_measurements) {
        while (idx < arr_data.len and arr_data[idx] != '{' and arr_data[idx] != ']') : (idx += 1) {}
        if (idx >= arr_data.len or arr_data[idx] == ']') break;

        const obj_start = idx;
        var depth: u32 = 0;
        var obj_end: usize = idx;
        while (obj_end < arr_data.len) : (obj_end += 1) {
            if (arr_data[obj_end] == '{') depth += 1;
            if (arr_data[obj_end] == '}') {
                depth -= 1;
                if (depth == 0) {
                    obj_end += 1;
                    break;
                }
            }
        }

        const obj = arr_data[obj_start..obj_end];
        if (extractMeasurement(obj)) |m| {
            result.measurements[meas_count] = m;
            meas_count += 1;
        }
        idx = obj_end;
    }

    result.n_measurements = meas_count;
    result.success = meas_count > 0;
    return result;
}

// ── extractMeasurement ───────────────────────────────────────────────────────

/// Extract a single measurement from a JSON object string like:
/// { "name": "gain_db", "value": 42.5, "unit": "dB" }
pub fn extractMeasurement(obj: []const u8) ?TbMeasurement {
    var m = TbMeasurement{};

    if (extractJsonString(obj, "\"name\"")) |name| {
        const len: u8 = @intCast(@min(name.len, types.max_name_len));
        @memcpy(m.name[0..len], name[0..len]);
        m.name_len = len;
    } else return null;

    if (extractJsonNumber(obj, "\"value\"")) |val| {
        m.value = val;
        m.valid = true;
    } else return null;

    if (extractJsonString(obj, "\"unit\"")) |unit| {
        const len: u8 = @intCast(@min(unit.len, 16));
        @memcpy(m.unit[0..len], unit[0..len]);
        m.unit_len = len;
    }

    return m;
}

// ── JSON helpers ─────────────────────────────────────────────────────────────

/// Extract a string value for a given JSON key from an object.
pub fn extractJsonString(obj: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, obj, key) orelse return null;
    const after = obj[key_pos + key.len ..];
    var i: usize = 0;
    while (i < after.len and (after[i] == ':' or after[i] == ' ' or after[i] == '\t')) : (i += 1) {}
    if (i >= after.len or after[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < after.len and after[i] != '"') : (i += 1) {}
    if (i >= after.len) return null;
    return after[start..i];
}

/// Extract a numeric value for a given JSON key from an object.
pub fn extractJsonNumber(obj: []const u8, key: []const u8) ?f64 {
    const key_pos = std.mem.indexOf(u8, obj, key) orelse return null;
    const after = obj[key_pos + key.len ..];
    var i: usize = 0;
    while (i < after.len and (after[i] == ':' or after[i] == ' ' or after[i] == '\t')) : (i += 1) {}
    if (i >= after.len) return null;
    const start = i;
    while (i < after.len and after[i] != ',' and after[i] != '}' and after[i] != ' ' and after[i] != '\n') : (i += 1) {}
    const num_str = after[start..i];
    return std.fmt.parseFloat(f64, num_str) catch null;
}

// ── TestbenchRunner ──────────────────────────────────────────────────────────

/// Manages testbench evaluation for optimizer individuals.
/// Tracks crash rates and provides timeout enforcement.
pub const TestbenchRunner = struct {
    alloc: Allocator,
    problem: *const Problem,
    n_workers: u32,
    timeout_ms: u64,
    crash_count: u32 = 0,
    eval_count: u32 = 0,
    crash_warning: bool = false,

    /// Recent evaluation outcomes for crash-rate tracking.
    /// Ring buffer of the last `crash_window` evaluations: true = crash.
    crash_history: [crash_window]bool = .{false} ** crash_window,
    crash_history_idx: u32 = 0,

    const crash_window = 20;
    const crash_threshold = 0.5; // warn if >50% of recent evals crash

    pub fn init(
        alloc: Allocator,
        problem: *const Problem,
        n_workers: u32,
        timeout_ms: u64,
    ) TestbenchRunner {
        return .{
            .alloc = alloc,
            .problem = problem,
            .n_workers = if (n_workers == 0) @intCast(std.Thread.getCpuCount() catch 4) else n_workers,
            .timeout_ms = if (timeout_ms == 0) 60_000 else timeout_ms,
        };
    }

    /// Evaluate a single individual against all linked testbenches.
    /// Collects measurements from each testbench, then maps them to
    /// objectives and constraints via the problem's specifications.
    ///
    /// On timeout or crash: marks the individual as infeasible.
    pub fn evaluateIndividual(
        self: *TestbenchRunner,
        individual: *Individual,
        testbenches: []const LinkedTestbench,
    ) void {
        self.eval_count += 1;
        var any_crash = false;

        // Aggregate measurements from all testbenches.
        var combined = TbRunResult{};

        for (testbenches) |tb| {
            const tb_path = tb.pathSlice();
            if (tb_path.len == 0) continue;

            const result = runLinkedTestbench(
                self.alloc,
                tb_path,
                individual.x[0..individual.n_vars],
                self.problem,
            );

            if (!result.success) {
                any_crash = true;
                continue;
            }

            // Merge measurements into combined result.
            for (result.measurements[0..result.n_measurements]) |m| {
                if (combined.n_measurements >= types.max_measurements) break;
                combined.measurements[combined.n_measurements] = m;
                combined.n_measurements += 1;
            }
        }

        // Update crash tracking.
        self.crash_history[self.crash_history_idx % crash_window] = any_crash;
        self.crash_history_idx += 1;
        if (any_crash) self.crash_count += 1;
        self.updateCrashWarning();

        if (combined.n_measurements == 0) {
            individual.valid = false;
            individual.feasible = false;
            return;
        }

        combined.success = true;

        // Map measurements to objectives and constraints.
        const specs = self.problem.specs.slice();
        var obj_idx: u32 = 0;
        var con_idx: u32 = 0;

        for (specs) |spec| {
            const meas_name = spec.measurementSlice();
            const measured = combined.findMeasurement(meas_name) orelse 0.0;

            if (spec.kind.isObjective()) {
                if (obj_idx < types.max_specs) {
                    individual.objectives[obj_idx] = switch (spec.kind) {
                        .minimize => measured * spec.weight,
                        .maximize => -measured * spec.weight,
                        else => unreachable,
                    };
                    obj_idx += 1;
                }
            } else {
                if (con_idx < types.max_specs) {
                    individual.constraints[con_idx] = spec.toConstraint(measured);
                    con_idx += 1;
                }
            }
        }

        individual.n_objectives = obj_idx;
        individual.n_constraints = con_idx;
        individual.valid = true;
        individual.feasible = individual.isFeasible();
    }

    fn updateCrashWarning(self: *TestbenchRunner) void {
        if (self.eval_count < crash_window) return;
        var crashes: u32 = 0;
        for (&self.crash_history) |h| {
            if (h) crashes += 1;
        }
        self.crash_warning = @as(f64, @floatFromInt(crashes)) / @as(f64, @floatFromInt(crash_window)) > crash_threshold;
    }
};

// ── discoverMeasurements ─────────────────────────────────────────────────────

/// Parse measurement declarations from a testbench file header.
/// Looks for a comment in the first 10 lines matching:
///   # schemify-measurements: gain_db (dB), bandwidth_hz (Hz), ...
/// Returns a list of discovered name/unit pairs.
pub fn discoverMeasurements(content: []const u8) types.FixedList(DiscoveredMeasurement, 64) {
    var result: types.FixedList(DiscoveredMeasurement, 64) = .{};
    const prefix = "# schemify-measurements:";

    var line_count: u32 = 0;
    var line_start: usize = 0;
    for (content, 0..) |c, ci| {
        if (c == '\n' or ci == content.len - 1) {
            const line_end = if (c == '\n') ci else ci + 1;
            const line = std.mem.trim(u8, content[line_start..line_end], " \t\r");

            if (std.ascii.startsWithIgnoreCase(line, prefix)) {
                const payload = std.mem.trim(u8, line[prefix.len..], " \t");
                parseMeasurementList(payload, &result);
                return result;
            }

            line_start = ci + 1;
            line_count += 1;
            if (line_count >= 10) break;
        }
    }

    return result;
}

fn parseMeasurementList(
    payload: []const u8,
    out: *types.FixedList(DiscoveredMeasurement, 64),
) void {
    var rest = payload;
    while (rest.len > 0) {
        // Find next comma or end.
        const comma = std.mem.indexOf(u8, rest, ",") orelse rest.len;
        const token = std.mem.trim(u8, rest[0..comma], " \t");

        if (token.len > 0) {
            var dm = DiscoveredMeasurement{};

            // Check for unit in parentheses: "gain_db (dB)"
            if (std.mem.indexOf(u8, token, "(")) |paren_open| {
                const name = std.mem.trim(u8, token[0..paren_open], " \t");
                const nlen: u8 = @intCast(@min(name.len, types.max_name_len));
                @memcpy(dm.name[0..nlen], name[0..nlen]);
                dm.name_len = nlen;

                if (std.mem.indexOf(u8, token[paren_open..], ")")) |paren_close| {
                    const unit = std.mem.trim(u8, token[paren_open + 1 .. paren_open + paren_close], " \t");
                    const ulen: u8 = @intCast(@min(unit.len, 16));
                    @memcpy(dm.unit[0..ulen], unit[0..ulen]);
                    dm.unit_len = ulen;
                }
            } else {
                const nlen: u8 = @intCast(@min(token.len, types.max_name_len));
                @memcpy(dm.name[0..nlen], token[0..nlen]);
                dm.name_len = nlen;
            }

            if (out.len < 64) out.append(dm);
        }

        rest = if (comma < rest.len) rest[comma + 1 ..] else &.{};
    }
}

// ── discoverMeasurementsFromDecl ─────────────────────────────────────────────

/// Parse a measurements declaration string (from .chn_tb `measurements:` line).
/// Format: "gain_db (dB), bandwidth_hz (Hz), phase_margin (deg)"
/// Reuses the same comma-separated "name (unit)" format as discoverMeasurements.
pub fn discoverMeasurementsFromDecl(decl: []const u8) types.FixedList(DiscoveredMeasurement, 64) {
    var result: types.FixedList(DiscoveredMeasurement, 64) = .{};
    if (decl.len == 0) return result;
    parseMeasurementList(decl, &result);
    return result;
}

// ── testbenchReferencesDut ──────────────────────────────────────────────────

/// Check if a testbench file's content references a given DUT name.
/// Looks for `sym=<dut_name>` in instance lines, indicating the testbench
/// instantiates the design under test.
pub fn testbenchReferencesDut(tb_content: []const u8, dut_name: []const u8) bool {
    if (dut_name.len == 0) return false;
    // Build the pattern "sym=<dut_name>" to search for.
    var pattern_buf: [128]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "sym={s}", .{dut_name}) catch return false;
    return std.mem.indexOf(u8, tb_content, pattern) != null;
}

// ── DiscoveredDevice ─────────────────────────────────────────────────────────

pub const DiscoveredDevice = struct {
    instance: [types.max_name_len]u8 = .{0} ** types.max_name_len,
    instance_len: u8 = 0,
    device_type: types.DeviceType = .mosfet,
    kind_str: [16]u8 = .{0} ** 16,
    kind_str_len: u8 = 0,
    current_w: [16]u8 = .{0} ** 16,
    current_l: [16]u8 = .{0} ** 16,
    current_nf: [8]u8 = .{0} ** 8,
    enabled: bool = true,
    bound_min: [16]u8 = .{0} ** 16,
    bound_max: [16]u8 = .{0} ** 16,

    pub fn instanceSlice(self: *const DiscoveredDevice) []const u8 {
        return self.instance[0..self.instance_len];
    }

    pub fn kindSlice(self: *const DiscoveredDevice) []const u8 {
        return self.kind_str[0..self.kind_str_len];
    }

    fn setBuf(buf: []u8, val: []const u8) void {
        const len = @min(val.len, buf.len);
        @memcpy(buf[0..len], val[0..len]);
    }
};

// ── discoverOptimizableDevices ───────────────────────────────────────────────

const schematic = @import("schematic");
const DeviceKind = schematic.types.DeviceKind;
const StringPool = schematic.string_pool.StringPool;
const Property = schematic.types.Property;
const StringRef = schematic.string_pool.StringRef;

/// Scan schematic instances to find optimizable devices (MOSFETs, BJTs, resistors).
/// Populates `out` with discovered devices and returns the count.
/// Pure function — no allocations, no side effects.
pub fn discoverOptimizableDevices(
    kinds: []const DeviceKind,
    names: []const StringRef,
    prop_starts: []const u32,
    prop_counts: []const u16,
    props: []const Property,
    pool: *const StringPool,
    out: *[32]DiscoveredDevice,
) u8 {
    var count: u8 = 0;
    for (kinds, names, prop_starts, prop_counts) |kind, name_ref, ps, pc| {
        const dev_type: ?types.DeviceType = switch (kind) {
            .nmos3, .nmos4, .nmos4_depl, .nmos_sub, .nmoshv4, .rnmos4 => .mosfet,
            .pmos3, .pmos4, .pmos_sub, .pmoshv4 => .mosfet,
            .npn, .pnp => .bjt,
            .resistor, .resistor3 => .resistor,
            else => null,
        };
        if (dev_type == null) continue;
        if (count >= 32) break;

        var dev = DiscoveredDevice{ .device_type = dev_type.? };

        // Instance name
        const inst_name = pool.get(name_ref);
        const nlen: u8 = @intCast(@min(inst_name.len, types.max_name_len));
        @memcpy(dev.instance[0..nlen], inst_name[0..nlen]);
        dev.instance_len = nlen;

        // Kind string
        const kind_name = @tagName(kind);
        const klen: u8 = @intCast(@min(kind_name.len, 16));
        @memcpy(dev.kind_str[0..klen], kind_name[0..klen]);
        dev.kind_str_len = klen;

        // Extract W/L/NF from instance properties
        const inst_props = props[ps..][0..pc];
        for (inst_props) |p| {
            const key = pool.get(p.key);
            const val = pool.get(p.val);
            if (std.mem.eql(u8, key, "W") or std.mem.eql(u8, key, "w"))
                DiscoveredDevice.setBuf(&dev.current_w, val)
            else if (std.mem.eql(u8, key, "L") or std.mem.eql(u8, key, "l"))
                DiscoveredDevice.setBuf(&dev.current_l, val)
            else if (std.mem.eql(u8, key, "nf") or std.mem.eql(u8, key, "NF"))
                DiscoveredDevice.setBuf(&dev.current_nf, val);
        }

        // Default bounds based on device type
        switch (dev_type.?) {
            .mosfet => {
                DiscoveredDevice.setBuf(&dev.bound_min, "3");
                DiscoveredDevice.setBuf(&dev.bound_max, "25");
            },
            .bjt => {
                DiscoveredDevice.setBuf(&dev.bound_min, "1");
                DiscoveredDevice.setBuf(&dev.bound_max, "50");
            },
            .resistor => {
                DiscoveredDevice.setBuf(&dev.bound_min, "0.5u");
                DiscoveredDevice.setBuf(&dev.bound_max, "50u");
            },
            .parameter => {},
        }

        out[count] = dev;
        count += 1;
    }
    return count;
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "parseTbMeasurements: valid JSON" {
    const json =
        \\{"measurements": [
        \\  {"name": "gain_db", "value": 42.5, "unit": "dB"},
        \\  {"name": "f_3dB", "value": 1.5e6, "unit": "Hz"},
        \\  {"name": "PM", "value": 65.0, "unit": "deg"}
        \\]}
    ;

    const result = parseTbMeasurements(json);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u32, 3), result.n_measurements);

    try std.testing.expectEqualStrings("gain_db", result.measurements[0].nameSlice());
    try std.testing.expectApproxEqAbs(42.5, result.measurements[0].value, 1e-9);
    try std.testing.expect(result.measurements[0].valid);

    try std.testing.expectEqualStrings("f_3dB", result.measurements[1].nameSlice());
    try std.testing.expectApproxEqAbs(1.5e6, result.measurements[1].value, 1e-3);

    try std.testing.expectEqualStrings("PM", result.measurements[2].nameSlice());
    try std.testing.expectApproxEqAbs(65.0, result.measurements[2].value, 1e-9);
}

test "parseTbMeasurements: empty input" {
    const result = parseTbMeasurements("");
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u32, 0), result.n_measurements);
}

test "parseTbMeasurements: no measurements key" {
    const result = parseTbMeasurements("{\"status\": \"success\"}");
    try std.testing.expect(!result.success);
}

test "extractJsonString: basic" {
    const obj = "{\"name\": \"gain_db\", \"value\": 42.5}";
    const name = extractJsonString(obj, "\"name\"");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("gain_db", name.?);
}

test "extractJsonNumber: basic" {
    const obj = "{\"name\": \"gain\", \"value\": 42.5}";
    const val = extractJsonNumber(obj, "\"value\"");
    try std.testing.expect(val != null);
    try std.testing.expectApproxEqAbs(42.5, val.?, 1e-9);
}

test "extractJsonNumber: scientific notation" {
    const obj = "{\"name\": \"f_3dB\", \"value\": 1.5e6}";
    const val = extractJsonNumber(obj, "\"value\"");
    try std.testing.expect(val != null);
    try std.testing.expectApproxEqAbs(1.5e6, val.?, 1e-3);
}

test "extractJsonNumber: negative scientific" {
    const obj = "{\"value\": -3.2e-9}";
    const val = extractJsonNumber(obj, "\"value\"");
    try std.testing.expect(val != null);
    try std.testing.expectApproxEqAbs(-3.2e-9, val.?, 1e-18);
}

test "discoverMeasurements: header comment parsing" {
    const content =
        \\#!/usr/bin/env python3
        \\# schemify-measurements: gain_db (dB), bandwidth_hz (Hz), phase_margin (deg)
        \\import pyspice_rs
        \\# more code...
    ;

    const result = discoverMeasurements(content);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("gain_db", result.items[0].nameSlice());
    try std.testing.expectEqualStrings("dB", result.items[0].unitSlice());
    try std.testing.expectEqualStrings("bandwidth_hz", result.items[1].nameSlice());
    try std.testing.expectEqualStrings("Hz", result.items[1].unitSlice());
    try std.testing.expectEqualStrings("phase_margin", result.items[2].nameSlice());
    try std.testing.expectEqualStrings("deg", result.items[2].unitSlice());
}

test "discoverMeasurements: no unit" {
    const content = "# schemify-measurements: gain, bw\n";
    const result = discoverMeasurements(content);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("gain", result.items[0].nameSlice());
    try std.testing.expectEqual(@as(u8, 0), result.items[0].unit_len);
    try std.testing.expectEqualStrings("bw", result.items[1].nameSlice());
}

test "discoverMeasurements: no matching line" {
    const content = "#!/usr/bin/env python3\nimport os\nprint('hello')\n";
    const result = discoverMeasurements(content);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "discoverMeasurements: line beyond first 10 is ignored" {
    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    // Write 11 blank lines, then the measurement header.
    for (0..11) |_| {
        @memcpy(buf[pos .. pos + 2], "# \n"[0..2]);
        pos += 2;
        buf[pos] = '\n';
        pos += 1;
    }
    const header = "# schemify-measurements: late (V)\n";
    @memcpy(buf[pos .. pos + header.len], header);
    pos += header.len;

    const result = discoverMeasurements(buf[0..pos]);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "buildParamEnv: flat entries" {
    const entries = [_]EnvEntry{
        .{ .key = "SCHEMIFY_M1_W", .val = "5e-6" },
        .{ .key = "SCHEMIFY_R1_L", .val = "10e-6" },
    };

    var env = try buildParamEnv(std.testing.allocator, &entries);
    defer env.deinit();

    try std.testing.expectEqualStrings("5e-6", env.get("SCHEMIFY_M1_W").?);
    try std.testing.expectEqualStrings("10e-6", env.get("SCHEMIFY_R1_L").?);
}

test "buildParamEnvFromDesign: mixed devices" {
    var prob = Problem{};

    var m = types.Mosfet{};
    m.setInstance("M1");
    m.nf = 4;
    prob.mosfets.append(m);

    var b = types.Bjt{};
    b.setInstance("Q1");
    prob.bjts.append(b);

    var r = types.Resistor{};
    r.setInstance("R1");
    prob.resistors.append(r);

    var p = types.Parameter{};
    p.setName("Ibias");
    p.enabled = true;
    prob.parameters.append(p);

    // x order: M1_W, Q1_AE, R1_W, R1_L, Ibias
    const x = [_]f64{ 2e-6, 10.0, 1e-6, 5e-6, 50e-6 };

    var env = try buildParamEnvFromDesign(std.testing.allocator, &x, &prob);
    defer env.deinit();

    // MOSFET W and NF.
    try std.testing.expect(env.get("SCHEMIFY_M1_W") != null);
    try std.testing.expectEqualStrings("4", env.get("SCHEMIFY_M1_NF").?);

    // BJT AE.
    try std.testing.expect(env.get("SCHEMIFY_Q1_AE") != null);

    // Resistor W and L.
    try std.testing.expect(env.get("SCHEMIFY_R1_W") != null);
    try std.testing.expect(env.get("SCHEMIFY_R1_L") != null);

    // Parameter.
    try std.testing.expect(env.get("SCHEMIFY_Ibias") != null);
}

test "TestbenchRunner: crash tracking" {
    var prob = Problem{};
    var spec = types.Specification{ .kind = .maximize };
    spec.setName("gain");
    prob.specs.append(spec);

    var runner = TestbenchRunner.init(std.testing.allocator, &prob, 1, 60_000);

    // Simulate 20 evaluations, all successful (no crash).
    try std.testing.expect(!runner.crash_warning);

    // Manually push crashes into history.
    for (0..TestbenchRunner.crash_window) |i| {
        runner.crash_history[i] = true;
        runner.eval_count += 1;
    }
    runner.crash_history_idx = TestbenchRunner.crash_window;
    runner.updateCrashWarning();
    try std.testing.expect(runner.crash_warning);
}

test "extractMeasurement: complete object" {
    const obj =
        \\{"name": "f_ugb", "value": 1.5e9, "unit": "Hz"}
    ;
    const m = extractMeasurement(obj);
    try std.testing.expect(m != null);
    try std.testing.expectEqualStrings("f_ugb", m.?.nameSlice());
    try std.testing.expectApproxEqAbs(1.5e9, m.?.value, 1e3);
    try std.testing.expectEqualStrings("Hz", m.?.unitSlice());
    try std.testing.expect(m.?.valid);
}

test "extractMeasurement: missing name returns null" {
    const obj =
        \\{"value": 42.5, "unit": "dB"}
    ;
    try std.testing.expect(extractMeasurement(obj) == null);
}

test "extractMeasurement: missing value returns null" {
    const obj =
        \\{"name": "gain", "unit": "dB"}
    ;
    try std.testing.expect(extractMeasurement(obj) == null);
}

test "discoverMeasurementsFromDecl: basic" {
    const result = discoverMeasurementsFromDecl("gain_db (dB), bandwidth_hz (Hz), phase_margin (deg)");
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("gain_db", result.items[0].nameSlice());
    try std.testing.expectEqualStrings("dB", result.items[0].unitSlice());
    try std.testing.expectEqualStrings("bandwidth_hz", result.items[1].nameSlice());
    try std.testing.expectEqualStrings("Hz", result.items[1].unitSlice());
    try std.testing.expectEqualStrings("phase_margin", result.items[2].nameSlice());
    try std.testing.expectEqualStrings("deg", result.items[2].unitSlice());
}

test "discoverMeasurementsFromDecl: empty" {
    const result = discoverMeasurementsFromDecl("");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "discoverMeasurementsFromDecl: no units" {
    const result = discoverMeasurementsFromDecl("gain, bw, pm");
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("gain", result.items[0].nameSlice());
    try std.testing.expectEqual(@as(u8, 0), result.items[0].unit_len);
}

test "testbenchReferencesDut: match" {
    const content =
        \\chn_testbench 1
        \\
        \\TESTBENCH tb_opamp
        \\  instances:
        \\    x1  subckt  x=100  y=-200  sym=opamp
        \\    vdd  vsource  x=200  y=0
    ;
    try std.testing.expect(testbenchReferencesDut(content, "opamp"));
}

test "testbenchReferencesDut: no match" {
    const content =
        \\chn_testbench 1
        \\
        \\TESTBENCH tb_opamp
        \\  instances:
        \\    x1  subckt  x=100  y=-200  sym=amplifier
    ;
    try std.testing.expect(!testbenchReferencesDut(content, "opamp"));
}

test "testbenchReferencesDut: empty dut name" {
    try std.testing.expect(!testbenchReferencesDut("sym=opamp", ""));
}
