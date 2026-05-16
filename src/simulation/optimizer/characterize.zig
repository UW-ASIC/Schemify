const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

// ── Characterization Data Structs ────────────────────────────────────────────

pub const MosfetCharData = struct {
    model: [64]u8 = [_]u8{0} ** 64,
    model_len: u8 = 0,
    L: f64 = 0,
    gmid: [1024]f64 = undefined,
    jd: [1024]f64 = undefined,
    vgs: [1024]f64 = undefined,
    av: [1024]f64 = undefined,
    ft: [1024]f64 = undefined,
    n_points: u32 = 0,

    pub fn modelSlice(self: *const MosfetCharData) []const u8 {
        return self.model[0..self.model_len];
    }

    pub fn setModel(self: *MosfetCharData, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, 64));
        @memcpy(self.model[0..len], name[0..len]);
        self.model_len = len;
    }
};

pub const BjtCharData = struct {
    model: [64]u8 = [_]u8{0} ** 64,
    model_len: u8 = 0,
    gmic: [1024]f64 = undefined,
    jc: [1024]f64 = undefined,
    vbe: [1024]f64 = undefined,
    beta: [1024]f64 = undefined,
    ft: [1024]f64 = undefined,
    n_points: u32 = 0,

    pub fn modelSlice(self: *const BjtCharData) []const u8 {
        return self.model[0..self.model_len];
    }

    pub fn setModel(self: *BjtCharData, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, 64));
        @memcpy(self.model[0..len], name[0..len]);
        self.model_len = len;
    }
};

pub const CharacterizationData = struct {
    pdk_name: [64]u8 = [_]u8{0} ** 64,
    pdk_name_len: u8 = 0,
    corner: [8]u8 = [_]u8{0} ** 8,
    corner_len: u8 = 0,
    mosfets: [32]MosfetCharData = undefined,
    n_mosfets: u8 = 0,
    bjts: [16]BjtCharData = undefined,
    n_bjts: u8 = 0,

    pub fn pdkSlice(self: *const CharacterizationData) []const u8 {
        return self.pdk_name[0..self.pdk_name_len];
    }

    pub fn cornerSlice(self: *const CharacterizationData) []const u8 {
        return self.corner[0..self.corner_len];
    }

    fn setPdk(self: *CharacterizationData, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, 64));
        @memcpy(self.pdk_name[0..len], name[0..len]);
        self.pdk_name_len = len;
    }

    fn setCorner(self: *CharacterizationData, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, 8));
        @memcpy(self.corner[0..len], name[0..len]);
        self.corner_len = len;
    }
};

pub const CharConfig = struct {
    n_points: u32 = 200,
    vgs_min: f64 = 0.0,
    vgs_max: f64 = 1.8,
    vbe_min: f64 = 0.5,
    vbe_max: f64 = 0.9,
    vds: f64 = 0.9,
    vce: f64 = 2.0,
};

// ── Cache Directory ──────────────────────────────────────────────────────────

pub fn cacheDir(alloc: Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    return std.fmt.allocPrint(alloc, "{s}/.cache/schemify/pdk/", .{home});
}

// ── Load / Save PDK Data ─────────────────────────────────────────────────────

pub fn loadPdkData(alloc: Allocator, pdk_name: []const u8) !CharacterizationData {
    const dir = try cacheDir(alloc);
    defer alloc.free(dir);

    const path = try std.fmt.allocPrint(alloc, "{s}{s}.json", .{ dir, pdk_name });
    defer alloc.free(path);

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(alloc, 10 * 1024 * 1024);
    defer alloc.free(content);

    return parseCharData(content, pdk_name);
}

pub fn savePdkData(alloc: Allocator, pdk_name: []const u8, data: *const CharacterizationData) !void {
    const dir = try cacheDir(alloc);
    defer alloc.free(dir);

    // Ensure directory exists.
    // Strip the trailing slash for makePath.
    if (dir.len > 0 and dir[dir.len - 1] == '/') {
        std.fs.makeDirAbsolute(dir[0 .. dir.len - 1]) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => {
                // Try creating parents
                std.fs.makePath(std.fs.cwd(), dir[0 .. dir.len - 1]) catch {};
            },
        };
    }

    const path = try std.fmt.allocPrint(alloc, "{s}{s}.json", .{ dir, pdk_name });
    defer alloc.free(path);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);
    const w = out.writer(alloc);

    try w.writeAll("{");
    try w.print("\"pdk\":\"{s}\",", .{data.pdkSlice()});
    try w.print("\"corner\":\"{s}\",", .{data.cornerSlice()});

    // Mosfets
    try w.writeAll("\"mosfets\":[");
    for (data.mosfets[0..data.n_mosfets], 0..) |mos, mi| {
        if (mi > 0) try w.writeAll(",");
        try w.writeAll("{");
        try w.print("\"model\":\"{s}\",", .{mos.modelSlice()});
        try w.print("\"L\":{e},", .{mos.L});
        try writeF64Array(w, "gmid", mos.gmid[0..mos.n_points]);
        try w.writeAll(",");
        try writeF64Array(w, "jd", mos.jd[0..mos.n_points]);
        try w.writeAll(",");
        try writeF64Array(w, "vgs", mos.vgs[0..mos.n_points]);
        try w.writeAll(",");
        try writeF64Array(w, "av", mos.av[0..mos.n_points]);
        try w.writeAll(",");
        try writeF64Array(w, "ft", mos.ft[0..mos.n_points]);
        try w.writeAll("}");
    }
    try w.writeAll("],");

    // BJTs
    try w.writeAll("\"bjts\":[");
    for (data.bjts[0..data.n_bjts], 0..) |bjt, bi| {
        if (bi > 0) try w.writeAll(",");
        try w.writeAll("{");
        try w.print("\"model\":\"{s}\",", .{bjt.modelSlice()});
        try writeF64Array(w, "gmic", bjt.gmic[0..bjt.n_points]);
        try w.writeAll(",");
        try writeF64Array(w, "jc", bjt.jc[0..bjt.n_points]);
        try w.writeAll(",");
        try writeF64Array(w, "vbe", bjt.vbe[0..bjt.n_points]);
        try w.writeAll(",");
        try writeF64Array(w, "beta", bjt.beta[0..bjt.n_points]);
        try w.writeAll(",");
        try writeF64Array(w, "ft", bjt.ft[0..bjt.n_points]);
        try w.writeAll("}");
    }
    try w.writeAll("]");

    try w.writeAll("}");

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(out.items);
}

fn writeF64Array(w: anytype, key: []const u8, arr: []const f64) !void {
    try w.print("\"{s}\":[", .{key});
    for (arr, 0..) |v, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{e}", .{v});
    }
    try w.writeAll("]");
}

// ── JSON Parsing (string-based, same pattern as sweep.zig) ───────────────────

fn parseCharData(json: []const u8, pdk_name: []const u8) CharacterizationData {
    var data = CharacterizationData{};

    // Set PDK name from argument (canonical source).
    data.setPdk(pdk_name);

    // Parse corner.
    if (extractJsonString(json, "\"corner\"")) |corner| {
        data.setCorner(corner);
    }

    // Parse mosfets array.
    if (findArrayBounds(json, "\"mosfets\"")) |bounds| {
        const arr = json[bounds[0]..bounds[1]];
        var pos: usize = 0;
        while (data.n_mosfets < 32) {
            const obj = nextObject(arr, &pos) orelse break;
            var mos = MosfetCharData{};
            if (extractJsonString(obj, "\"model\"")) |m| mos.setModel(m);
            if (extractJsonNumber(obj, "\"L\"")) |l| mos.L = l;
            mos.n_points = parseF64Array(obj, "\"gmid\"", &mos.gmid);
            _ = parseF64Array(obj, "\"jd\"", &mos.jd);
            _ = parseF64Array(obj, "\"vgs\"", &mos.vgs);
            _ = parseF64Array(obj, "\"av\"", &mos.av);
            _ = parseF64Array(obj, "\"ft\"", &mos.ft);
            data.mosfets[data.n_mosfets] = mos;
            data.n_mosfets += 1;
        }
    }

    // Parse bjts array.
    if (findArrayBounds(json, "\"bjts\"")) |bounds| {
        const arr = json[bounds[0]..bounds[1]];
        var pos: usize = 0;
        while (data.n_bjts < 16) {
            const obj = nextObject(arr, &pos) orelse break;
            var bjt = BjtCharData{};
            if (extractJsonString(obj, "\"model\"")) |m| bjt.setModel(m);
            bjt.n_points = parseF64Array(obj, "\"gmic\"", &bjt.gmic);
            _ = parseF64Array(obj, "\"jc\"", &bjt.jc);
            _ = parseF64Array(obj, "\"vbe\"", &bjt.vbe);
            _ = parseF64Array(obj, "\"beta\"", &bjt.beta);
            _ = parseF64Array(obj, "\"ft\"", &bjt.ft);
            data.bjts[data.n_bjts] = bjt;
            data.n_bjts += 1;
        }
    }

    return data;
}

fn findArrayBounds(json: []const u8, key: []const u8) ?[2]usize {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after = json[key_pos + key.len ..];
    // Skip whitespace and colon, find '['
    for (after, 0..) |c, i| {
        if (c == '[') {
            const abs_start = key_pos + key.len + i;
            // Find matching ']'
            var depth: u32 = 0;
            var j: usize = abs_start;
            while (j < json.len) : (j += 1) {
                if (json[j] == '[') depth += 1;
                if (json[j] == ']') {
                    depth -= 1;
                    if (depth == 0) return .{ abs_start, j + 1 };
                }
            }
            return null;
        }
        if (c != ':' and c != ' ' and c != '\n' and c != '\r' and c != '\t') return null;
    }
    return null;
}

fn nextObject(arr: []const u8, pos: *usize) ?[]const u8 {
    // Find next '{'
    while (pos.* < arr.len and arr[pos.*] != '{') : (pos.* += 1) {
        if (arr[pos.*] == ']') return null;
    }
    if (pos.* >= arr.len) return null;

    const start = pos.*;
    var depth: u32 = 0;
    while (pos.* < arr.len) : (pos.* += 1) {
        if (arr[pos.*] == '{') depth += 1;
        if (arr[pos.*] == '}') {
            depth -= 1;
            if (depth == 0) {
                pos.* += 1;
                return arr[start..pos.*];
            }
        }
    }
    return null;
}

fn parseF64Array(obj: []const u8, key: []const u8, out: *[1024]f64) u32 {
    const bounds = findArrayBounds(obj, key) orelse return 0;
    const arr_text = obj[bounds[0]..bounds[1]];
    var count: u32 = 0;

    // Walk the array text, extract numbers between '[' and ']'
    var i: usize = 1; // skip '['
    while (i < arr_text.len and count < 1024) {
        // Skip whitespace and commas
        while (i < arr_text.len and (arr_text[i] == ' ' or arr_text[i] == ',' or
            arr_text[i] == '\n' or arr_text[i] == '\r' or arr_text[i] == '\t')) : (i += 1)
        {}
        if (i >= arr_text.len or arr_text[i] == ']') break;

        // Find end of number
        const start = i;
        while (i < arr_text.len and arr_text[i] != ',' and arr_text[i] != ']' and
            arr_text[i] != ' ' and arr_text[i] != '\n') : (i += 1)
        {}
        const num_str = arr_text[start..i];
        if (std.fmt.parseFloat(f64, num_str)) |val| {
            out[count] = val;
            count += 1;
        } else |_| {}
    }

    return count;
}

fn extractJsonString(obj: []const u8, key: []const u8) ?[]const u8 {
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

fn extractJsonNumber(obj: []const u8, key: []const u8) ?f64 {
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

// ── Testbench Generation ─────────────────────────────────────────────────────

pub fn generateMosfetTestbench(alloc: Allocator, model_name: []const u8, L: f64, config: CharConfig) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(alloc);
    const w = out.writer(alloc);

    try w.writeAll("#!/usr/bin/env python3\n");
    try w.writeAll("import json\n");
    try w.writeAll("import math\n");
    try w.writeAll("import numpy as np\n");
    try w.writeAll("from pyspice_rs import Circuit\n");
    try w.writeAll("from pyspice_rs.unit import *\n\n");

    try w.print("MODEL = '{s}'\n", .{model_name});
    try w.print("L = {e}\n", .{L});
    try w.print("W = 1e-6  # reference width for normalization\n", .{});
    try w.print("N_POINTS = {d}\n", .{config.n_points});
    try w.print("VGS_MIN = {e}\n", .{config.vgs_min});
    try w.print("VGS_MAX = {e}\n", .{config.vgs_max});
    try w.print("VDS = {e}\n\n", .{config.vds});

    try w.writeAll("circuit = Circuit('MOSFET Characterization')\n");
    try w.writeAll("circuit.V('gs', 'gate', circuit.gnd, 0@u_V)\n");
    try w.writeAll("circuit.V('ds', 'drain', circuit.gnd, VDS@u_V)\n");
    try w.writeAll("circuit.M('dut', 'drain', 'gate', circuit.gnd, circuit.gnd,\n");
    try w.writeAll("          model=MODEL, l=L, w=W)\n\n");

    try w.writeAll("vgs_sweep = np.linspace(VGS_MIN, VGS_MAX, N_POINTS)\n\n");

    try w.writeAll("gmid_arr = []\n");
    try w.writeAll("jd_arr = []\n");
    try w.writeAll("vgs_arr = []\n");
    try w.writeAll("av_arr = []\n");
    try w.writeAll("ft_arr = []\n\n");

    try w.writeAll("for vgs_val in vgs_sweep:\n");
    try w.writeAll("    circuit['Vgs'].dc_value = vgs_val\n");
    try w.writeAll("    simulator = circuit.simulator()\n");
    try w.writeAll("    analysis = simulator.operating_point()\n\n");

    try w.writeAll("    Id = float(analysis['drain'])\n");
    try w.writeAll("    gm = float(analysis.nodes.get('gm', 0))\n");
    try w.writeAll("    gds = float(analysis.nodes.get('gds', 1e-15))\n");
    try w.writeAll("    Cgg = float(analysis.nodes.get('cgg', 1e-18))\n\n");

    try w.writeAll("    gmid = gm / Id if abs(Id) > 1e-15 else 0.0\n");
    try w.writeAll("    jd = Id / W\n");
    try w.writeAll("    av = gm / gds if abs(gds) > 1e-18 else 0.0\n");
    try w.writeAll("    ft_val = gm / (2 * math.pi * Cgg) if abs(Cgg) > 1e-21 else 0.0\n\n");

    try w.writeAll("    gmid_arr.append(gmid)\n");
    try w.writeAll("    jd_arr.append(jd)\n");
    try w.writeAll("    vgs_arr.append(vgs_val)\n");
    try w.writeAll("    av_arr.append(av)\n");
    try w.writeAll("    ft_arr.append(ft_val)\n\n");

    try w.writeAll("result = {\n");
    try w.writeAll("    'measurements': [{\n");
    try w.writeAll("        'gmid': gmid_arr,\n");
    try w.writeAll("        'jd': jd_arr,\n");
    try w.writeAll("        'vgs': vgs_arr,\n");
    try w.writeAll("        'av': av_arr,\n");
    try w.writeAll("        'ft': ft_arr\n");
    try w.writeAll("    }]\n");
    try w.writeAll("}\n");
    try w.writeAll("print(json.dumps(result))\n");

    return out.toOwnedSlice(alloc);
}

pub fn generateBjtTestbench(alloc: Allocator, model_name: []const u8, config: CharConfig) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(alloc);
    const w = out.writer(alloc);

    try w.writeAll("#!/usr/bin/env python3\n");
    try w.writeAll("import json\n");
    try w.writeAll("import math\n");
    try w.writeAll("import numpy as np\n");
    try w.writeAll("from pyspice_rs import Circuit\n");
    try w.writeAll("from pyspice_rs.unit import *\n\n");

    try w.print("MODEL = '{s}'\n", .{model_name});
    try w.print("N_POINTS = {d}\n", .{config.n_points});
    try w.print("VBE_MIN = {e}\n", .{config.vbe_min});
    try w.print("VBE_MAX = {e}\n", .{config.vbe_max});
    try w.print("VCE = {e}\n\n", .{config.vce});

    try w.writeAll("circuit = Circuit('BJT Characterization')\n");
    try w.writeAll("circuit.V('be', 'base', circuit.gnd, 0@u_V)\n");
    try w.writeAll("circuit.V('ce', 'collector', circuit.gnd, VCE@u_V)\n");
    try w.writeAll("circuit.Q('dut', 'collector', 'base', circuit.gnd,\n");
    try w.writeAll("          model=MODEL)\n\n");

    try w.writeAll("vbe_sweep = np.linspace(VBE_MIN, VBE_MAX, N_POINTS)\n\n");

    try w.writeAll("gmic_arr = []\n");
    try w.writeAll("jc_arr = []\n");
    try w.writeAll("vbe_arr = []\n");
    try w.writeAll("beta_arr = []\n");
    try w.writeAll("ft_arr = []\n\n");

    try w.writeAll("for vbe_val in vbe_sweep:\n");
    try w.writeAll("    circuit['Vbe'].dc_value = vbe_val\n");
    try w.writeAll("    simulator = circuit.simulator()\n");
    try w.writeAll("    analysis = simulator.operating_point()\n\n");

    try w.writeAll("    Ic = float(analysis['collector'])\n");
    try w.writeAll("    Ib = float(analysis['base'])\n");
    try w.writeAll("    gm = float(analysis.nodes.get('gm', 0))\n");
    try w.writeAll("    Cpi = float(analysis.nodes.get('cpi', 1e-18))\n\n");

    try w.writeAll("    gmic = gm / Ic if abs(Ic) > 1e-15 else 0.0\n");
    try w.writeAll("    jc = Ic  # collector current density\n");
    try w.writeAll("    beta_val = Ic / Ib if abs(Ib) > 1e-18 else 0.0\n");
    try w.writeAll("    ft_val = gm / (2 * math.pi * Cpi) if abs(Cpi) > 1e-21 else 0.0\n\n");

    try w.writeAll("    gmic_arr.append(gmic)\n");
    try w.writeAll("    jc_arr.append(jc)\n");
    try w.writeAll("    vbe_arr.append(vbe_val)\n");
    try w.writeAll("    beta_arr.append(beta_val)\n");
    try w.writeAll("    ft_arr.append(ft_val)\n\n");

    try w.writeAll("result = {\n");
    try w.writeAll("    'measurements': [{\n");
    try w.writeAll("        'gmic': gmic_arr,\n");
    try w.writeAll("        'jc': jc_arr,\n");
    try w.writeAll("        'vbe': vbe_arr,\n");
    try w.writeAll("        'beta': beta_arr,\n");
    try w.writeAll("        'ft': ft_arr\n");
    try w.writeAll("    }]\n");
    try w.writeAll("}\n");
    try w.writeAll("print(json.dumps(result))\n");

    return out.toOwnedSlice(alloc);
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "generateMosfetTestbench: produces valid Python" {
    const alloc = std.testing.allocator;
    const script = try generateMosfetTestbench(alloc, "nmos_1v8", 180e-9, .{});
    defer alloc.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "import json") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "nmos_1v8") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "json.dumps") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "pyspice_rs") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "gmid") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "np.linspace") != null);
}

test "generateBjtTestbench: produces valid Python" {
    const alloc = std.testing.allocator;
    const script = try generateBjtTestbench(alloc, "npn_5v", .{});
    defer alloc.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "import json") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "npn_5v") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "json.dumps") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "pyspice_rs") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "gmic") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "beta") != null);
}

test "cacheDir: returns valid path" {
    const alloc = std.testing.allocator;
    const dir = try cacheDir(alloc);
    defer alloc.free(dir);

    try std.testing.expect(std.mem.endsWith(u8, dir, "/schemify/pdk/"));
}

test "parseCharData: round-trip JSON" {
    const json =
        \\{"pdk":"sky130","corner":"tt","mosfets":[{"model":"nmos_1v8","L":1.8e-7,"gmid":[10.0,15.0,20.0],"jd":[1e-4,5e-4,1e-3],"vgs":[0.4,0.6,0.8],"av":[30.0,20.0,10.0],"ft":[1e9,5e9,1e10]}],"bjts":[{"model":"npn_5v","gmic":[38.0,39.0,40.0],"jc":[1e-4,5e-4,1e-3],"vbe":[0.6,0.7,0.8],"beta":[100.0,120.0,80.0],"ft":[5e9,1e10,2e10]}]}
    ;

    const data = parseCharData(json, "sky130");

    try std.testing.expectEqualStrings("sky130", data.pdkSlice());
    try std.testing.expectEqualStrings("tt", data.cornerSlice());
    try std.testing.expectEqual(@as(u8, 1), data.n_mosfets);
    try std.testing.expectEqual(@as(u8, 1), data.n_bjts);

    const mos = data.mosfets[0];
    try std.testing.expectEqualStrings("nmos_1v8", mos.modelSlice());
    try std.testing.expectEqual(@as(u32, 3), mos.n_points);
    try std.testing.expectApproxEqAbs(10.0, mos.gmid[0], 1e-9);
    try std.testing.expectApproxEqAbs(20.0, mos.gmid[2], 1e-9);
    try std.testing.expectApproxEqRel(1.8e-7, mos.L, 1e-6);

    const bjt = data.bjts[0];
    try std.testing.expectEqualStrings("npn_5v", bjt.modelSlice());
    try std.testing.expectEqual(@as(u32, 3), bjt.n_points);
    try std.testing.expectApproxEqAbs(38.0, bjt.gmic[0], 1e-9);
    try std.testing.expectApproxEqAbs(100.0, bjt.beta[0], 1e-9);
}
