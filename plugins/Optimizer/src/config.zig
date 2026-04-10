//! PLUGIN block parser and serializer for the Optimizer plugin.
//! Reads/writes the PLUGIN Optimizer section of .chn files.
//! No allocator — all fixed-size arrays.

const std = @import("std");

pub const MAX_PARAMS = 32;
pub const MAX_OBJECTIVES = 16;
pub const MAX_TBS = 8;
pub const MAX_NAME = 64;
pub const MAX_PATH = 256;

pub const SpecKind = enum {
    maximize,
    minimize,
    geq, // >=
    leq, // <=

    pub fn fromStr(s: []const u8) SpecKind {
        if (std.mem.eql(u8, s, "maximize")) return .maximize;
        if (std.mem.eql(u8, s, "minimize")) return .minimize;
        if (std.mem.eql(u8, s, "geq")) return .geq;
        return .leq;
    }

    pub fn toStr(self: SpecKind) []const u8 {
        return switch (self) {
            .maximize => "maximize",
            .minimize => "minimize",
            .geq => "geq",
            .leq => "leq",
        };
    }

    pub fn label(self: SpecKind) []const u8 {
        return switch (self) {
            .maximize => "maximize",
            .minimize => "minimize",
            .geq => ">= target",
            .leq => "<= target",
        };
    }
};

pub const ParamEntry = struct {
    inst: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    inst_len: u8 = 0,
    prop: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    prop_len: u8 = 0,
    min: f32 = 0,
    max: f32 = 1,
    step: f32 = 0, // 0 = continuous
    enabled: bool = true,
    best_val: f32 = 0,

    pub fn instName(self: *const ParamEntry) []const u8 {
        return self.inst[0..self.inst_len];
    }
    pub fn propName(self: *const ParamEntry) []const u8 {
        return self.prop[0..self.prop_len];
    }
    pub fn setInst(self: *ParamEntry, s: []const u8) void {
        const n = @min(s.len, MAX_NAME - 1);
        @memcpy(self.inst[0..n], s[0..n]);
        self.inst_len = @intCast(n);
    }
    pub fn setProp(self: *ParamEntry, s: []const u8) void {
        const n = @min(s.len, MAX_NAME - 1);
        @memcpy(self.prop[0..n], s[0..n]);
        self.prop_len = @intCast(n);
    }
};

pub const ObjEntry = struct {
    name: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    name_len: u8 = 0,
    kind: SpecKind = .maximize,
    target: f32 = 0,
    weight: f32 = 1.0,
    last_val: f32 = 0,
    satisfied: bool = false,

    pub fn getName(self: *const ObjEntry) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn setName(self: *ObjEntry, s: []const u8) void {
        const n = @min(s.len, MAX_NAME - 1);
        @memcpy(self.name[0..n], s[0..n]);
        self.name_len = @intCast(n);
    }
};

pub const TbEntry = struct {
    path: [MAX_PATH]u8 = [_]u8{0} ** MAX_PATH,
    path_len: u16 = 0,
    measure_count: u8 = 0,

    pub fn getPath(self: *const TbEntry) []const u8 {
        return self.path[0..self.path_len];
    }
    pub fn setPath(self: *TbEntry, s: []const u8) void {
        const n = @min(s.len, MAX_PATH - 1);
        @memcpy(self.path[0..n], s[0..n]);
        self.path_len = @intCast(n);
    }
};

pub const Config = struct {
    params: [MAX_PARAMS]ParamEntry = [_]ParamEntry{.{}} ** MAX_PARAMS,
    param_count: usize = 0,
    objs: [MAX_OBJECTIVES]ObjEntry = [_]ObjEntry{.{}} ** MAX_OBJECTIVES,
    obj_count: usize = 0,
    tbs: [MAX_TBS]TbEntry = [_]TbEntry{.{}} ** MAX_TBS,
    tb_count: usize = 0,
    max_iter: u16 = 50,
    lhc_samples: u16 = 20,
    version: u8 = 1,
};

/// Parse raw .chn file content and extract the PLUGIN Optimizer block into `out`.
/// Returns true if a PLUGIN Optimizer block was found.
pub fn parse(data: []const u8, out: *Config) bool {
    out.* = .{};
    var found = false;
    var in_optimizer = false;
    var line_it = std.mem.splitScalar(u8, data, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "PLUGIN ")) {
            const plugin_name = std.mem.trim(u8, line[7..], " \t");
            in_optimizer = std.mem.eql(u8, plugin_name, "Optimizer");
            if (in_optimizer) found = true;
            continue;
        }
        // End of our PLUGIN section when we hit another top-level section
        if (in_optimizer and line.len > 0 and line[0] != ' ') {
            in_optimizer = false;
        }
        if (!in_optimizer) continue;

        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        // Format: "key: value" (single space after colon)
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");

        if (std.mem.startsWith(u8, key, "tb.")) {
            if (out.tb_count < MAX_TBS) {
                out.tbs[out.tb_count].setPath(val);
                out.tb_count += 1;
            }
        } else if (std.mem.startsWith(u8, key, "param.")) {
            // key = "param.M1.W", val = "enabled=1 min=120e-9 max=10e-6 step=10e-9"
            const rest = key[6..];
            const last_dot = std.mem.lastIndexOfScalar(u8, rest, '.') orelse continue;
            const inst_name = rest[0..last_dot];
            const prop_name = rest[last_dot + 1 ..];
            // Find or create param entry for this inst.prop
            var found_p: ?*ParamEntry = null;
            for (out.params[0..out.param_count]) |*p| {
                if (std.mem.eql(u8, p.instName(), inst_name) and
                    std.mem.eql(u8, p.propName(), prop_name))
                {
                    found_p = p;
                    break;
                }
            }
            if (found_p == null and out.param_count < MAX_PARAMS) {
                out.params[out.param_count].setInst(inst_name);
                out.params[out.param_count].setProp(prop_name);
                found_p = &out.params[out.param_count];
                out.param_count += 1;
            }
            if (found_p) |p| parseParamFields(p, val);
        } else if (std.mem.startsWith(u8, key, "obj.")) {
            // key = "obj.gain_dB", val = "kind=maximize weight=1.0"
            const name = key[4..];
            var found_o: ?*ObjEntry = null;
            for (out.objs[0..out.obj_count]) |*o| {
                if (std.mem.eql(u8, o.getName(), name)) { found_o = o; break; }
            }
            if (found_o == null and out.obj_count < MAX_OBJECTIVES) {
                out.objs[out.obj_count].setName(name);
                found_o = &out.objs[out.obj_count];
                out.obj_count += 1;
            }
            if (found_o) |o| parseObjFields(o, val);
        } else if (std.mem.startsWith(u8, key, "best.")) {
            const name = key[5..];
            for (out.params[0..out.param_count]) |*p| {
                // Match "inst.prop"
                var name_buf: [MAX_NAME * 2 + 1]u8 = undefined;
                const full = std.fmt.bufPrint(&name_buf, "{s}.{s}", .{ p.instName(), p.propName() }) catch continue;
                if (std.mem.eql(u8, full, name)) {
                    p.best_val = parseF32(val);
                    break;
                }
            }
        } else if (std.mem.eql(u8, key, "settings.max_iter")) {
            out.max_iter = @intFromFloat(@min(parseF32(val), 9999));
        } else if (std.mem.eql(u8, key, "settings.lhc_samples")) {
            out.lhc_samples = @intFromFloat(@min(parseF32(val), 200));
        }
    }
    return found;
}

fn parseParamFields(p: *ParamEntry, val: []const u8) void {
    var it = std.mem.splitScalar(u8, val, ' ');
    while (it.next()) |field| {
        if (field.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const k = field[0..eq];
        const v = field[eq + 1 ..];
        if (std.mem.eql(u8, k, "enabled")) p.enabled = !std.mem.eql(u8, v, "0");
        if (std.mem.eql(u8, k, "min")) p.min = parseF32(v);
        if (std.mem.eql(u8, k, "max")) p.max = parseF32(v);
        if (std.mem.eql(u8, k, "step")) p.step = parseF32(v);
    }
}

fn parseObjFields(o: *ObjEntry, val: []const u8) void {
    var it = std.mem.splitScalar(u8, val, ' ');
    while (it.next()) |field| {
        if (field.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const k = field[0..eq];
        const v = field[eq + 1 ..];
        if (std.mem.eql(u8, k, "kind")) o.kind = SpecKind.fromStr(v);
        if (std.mem.eql(u8, k, "target")) o.target = parseF32(v);
        if (std.mem.eql(u8, k, "weight")) o.weight = parseF32(v);
    }
}

fn parseF32(s: []const u8) f32 {
    return @floatCast(std.fmt.parseFloat(f64, s) catch 0.0);
}

/// Write the PLUGIN Optimizer block text into `buf`. Returns bytes written.
pub fn buildBlock(cfg: *const Config, buf: []u8) usize {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.writeAll("\nPLUGIN Optimizer\n") catch return 0;
    w.writeAll("  version: 1\n") catch return 0;
    for (cfg.tbs[0..cfg.tb_count], 0..) |*tb, i| {
        w.print("  tb.{d}: {s}\n", .{ i, tb.getPath() }) catch return 0;
    }
    for (cfg.params[0..cfg.param_count]) |*p| {
        w.print("  param.{s}.{s}: enabled={d} min={e} max={e} step={e}\n", .{
            p.instName(), p.propName(),
            @as(u8, if (p.enabled) 1 else 0),
            p.min, p.max, p.step,
        }) catch return 0;
    }
    for (cfg.objs[0..cfg.obj_count]) |*o| {
        w.print("  obj.{s}: kind={s} target={e} weight={e}\n", .{
            o.getName(), o.kind.toStr(), o.target, o.weight,
        }) catch return 0;
    }
    for (cfg.params[0..cfg.param_count]) |*p| {
        if (p.best_val != 0) {
            w.print("  best.{s}.{s}: {e}\n", .{
                p.instName(), p.propName(), p.best_val,
            }) catch return 0;
        }
    }
    w.print("  settings.max_iter: {d}\n", .{cfg.max_iter}) catch return 0;
    w.print("  settings.lhc_samples: {d}\n", .{cfg.lhc_samples}) catch return 0;
    return fbs.pos;
}

/// Produce updated .chn content with the PLUGIN Optimizer block replaced (or appended).
pub fn patchFile(file_data: []const u8, block_text: []const u8, out_buf: []u8) usize {
    const marker = "\nPLUGIN Optimizer\n";
    const start = std.mem.indexOf(u8, file_data, marker);

    if (start) |s| {
        const after_marker = s + marker.len;
        var end = file_data.len;
        const search_pos: usize = after_marker;
        while (std.mem.indexOf(u8, file_data[search_pos..], "\nPLUGIN ")) |rel| {
            end = search_pos + rel;
            break;
        }
        const before = file_data[0..s];
        const after = file_data[end..];
        const total = before.len + block_text.len + after.len;
        if (total > out_buf.len) return 0;
        @memcpy(out_buf[0..before.len], before);
        @memcpy(out_buf[before.len .. before.len + block_text.len], block_text);
        @memcpy(out_buf[before.len + block_text.len ..][0..after.len], after);
        return total;
    } else {
        const total = file_data.len + block_text.len;
        if (total > out_buf.len) return 0;
        @memcpy(out_buf[0..file_data.len], file_data);
        @memcpy(out_buf[file_data.len..][0..block_text.len], block_text);
        return total;
    }
}

test "parse empty file returns no config" {
    var cfg: Config = undefined;
    const found = parse("chn 1.0\n", &cfg);
    try std.testing.expect(!found);
    try std.testing.expectEqual(@as(usize, 0), cfg.param_count);
}

test "parse PLUGIN Optimizer block" {
    const data =
        \\chn 1.0
        \\
        \\PLUGIN Optimizer
        \\  version: 1
        \\  tb.0: ../tb/tb_gain.chn_tb
        \\  param.M1.W: enabled=1 min=1.2e-7 max=1e-5 step=1e-8
        \\  obj.gain_dB: kind=maximize target=0 weight=1.0
        \\  settings.max_iter: 30
        \\
    ;
    var cfg: Config = undefined;
    const found = parse(data, &cfg);
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 1), cfg.tb_count);
    try std.testing.expectEqualStrings("../tb/tb_gain.chn_tb", cfg.tbs[0].getPath());
    try std.testing.expectEqual(@as(usize, 1), cfg.param_count);
    try std.testing.expectEqualStrings("M1", cfg.params[0].instName());
    try std.testing.expectEqualStrings("W", cfg.params[0].propName());
    try std.testing.expect(cfg.params[0].enabled);
    try std.testing.expectEqual(@as(usize, 1), cfg.obj_count);
    try std.testing.expectEqualStrings("gain_dB", cfg.objs[0].getName());
    try std.testing.expectEqual(SpecKind.maximize, cfg.objs[0].kind);
    try std.testing.expectEqual(@as(u16, 30), cfg.max_iter);
}

test "buildBlock round-trips" {
    var cfg = Config{};
    cfg.tbs[0].setPath("../tb/tb.chn_tb");
    cfg.tb_count = 1;
    cfg.params[0].setInst("M1");
    cfg.params[0].setProp("W");
    cfg.params[0].min = 1e-7;
    cfg.params[0].max = 1e-5;
    cfg.params[0].enabled = true;
    cfg.param_count = 1;
    cfg.max_iter = 40;

    var block_buf: [4096]u8 = undefined;
    const n = buildBlock(&cfg, &block_buf);
    try std.testing.expect(n > 0);

    var file_data: [8192]u8 = undefined;
    const file_n = std.fmt.bufPrint(&file_data, "chn 1.0\n", .{}) catch unreachable;
    var out_buf: [16384]u8 = undefined;
    const patched_n = patchFile(file_data[0..file_n.len], block_buf[0..n], &out_buf);
    try std.testing.expect(patched_n > 0);

    var cfg2: Config = undefined;
    _ = parse(out_buf[0..patched_n], &cfg2);
    try std.testing.expectEqual(@as(usize, 1), cfg2.tb_count);
    try std.testing.expectEqual(@as(u16, 40), cfg2.max_iter);
}
