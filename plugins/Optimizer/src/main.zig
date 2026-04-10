//! Optimizer plugin — Schemify ABI v6.
//! Tick-based state machine: no background thread.
//! Drives LHC optimization by requesting simulations from the host.

const std = @import("std");
const P = @import("PluginIF");
const config = @import("config.zig");
const lhc = @import("lhc.zig");
const log_buf = @import("log_buf.zig");
const sim_result = @import("sim_result.zig");

// ── Constants ─────────────────────────────────────────────────────────────── //

const MAX_PARAMS = config.MAX_PARAMS;
const MAX_OBJECTIVES = config.MAX_OBJECTIVES;
const MAX_TBS = config.MAX_TBS;
const MAX_SAMPLES = lhc.MAX_SAMPLES;

// ── Widget IDs ────────────────────────────────────────────────────────────── //

const WID_RUN: u32 = 1;
const WID_STOP: u32 = 2;
const WID_RESET: u32 = 3;
const WID_RESCAN: u32 = 4;
const WID_SEC_TBS: u32 = 10;
const WID_SEC_PARAMS: u32 = 11;
const WID_SEC_OBJS: u32 = 12;
const WID_SEC_SET: u32 = 13;
const WID_SEC_LOG: u32 = 14;
const WID_MAX_ITER: u32 = 20;
const WID_LHC_SMP: u32 = 21;
const WID_PARAM_ENABLE_BASE: u32 = 100;
const WID_OBJ_KIND_BASE: u32 = 200;

// ── Status enum ───────────────────────────────────────────────────────────── //

const OptStatus = enum {
    idle,
    loading,
    ready,
    sim_pending,
    done,
    err,
};

// ── Plugin state ──────────────────────────────────────────────────────────── //

const State = struct {
    status: OptStatus = .idle,
    err_msg: [128]u8 = [_]u8{0} ** 128,
    err_msg_len: u8 = 0,

    active_file: [1024]u8 = [_]u8{0} ** 1024,
    active_file_len: u16 = 0,
    chn_buf: [65536]u8 = [_]u8{0} ** 65536,
    chn_len: usize = 0,

    cfg: config.Config = .{},

    tbs_pending: usize = 0,

    iteration: usize = 0,
    lhc_grid: [MAX_SAMPLES][MAX_PARAMS]f32 = undefined,
    current_sample: usize = 0,
    best_params: [MAX_PARAMS]f32 = [_]f32{0} ** MAX_PARAMS,
    best_score: f32 = std.math.inf(f32),
    stop_requested: bool = false,

    log: log_buf.LogBuf = .{},

    sec_tbs_open: bool = true,
    sec_params_open: bool = true,
    sec_objs_open: bool = true,
    sec_set_open: bool = false,
    sec_log_open: bool = true,

    chn_dirty: bool = false,

    fn activePath(s: *const State) []const u8 {
        return s.active_file[0..s.active_file_len];
    }

    fn setActivePath(s: *State, path: []const u8) void {
        const n = @min(path.len, s.active_file.len - 1);
        @memcpy(s.active_file[0..n], path[0..n]);
        s.active_file_len = @intCast(n);
    }

    fn setErr(s: *State, msg: []const u8) void {
        const n = @min(msg.len, s.err_msg.len - 1);
        @memcpy(s.err_msg[0..n], msg[0..n]);
        s.err_msg_len = @intCast(n);
        s.status = .err;
    }

    fn errText(s: *const State) []const u8 {
        return s.err_msg[0..s.err_msg_len];
    }
};

var state = State{};

// ── Helpers ───────────────────────────────────────────────────────────────── //

fn logLine(s: *State, comptime fmt: []const u8, args: anytype) void {
    var buf: [log_buf.LOG_LINE_LEN]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..buf.len];
    s.log.append(line);
}

fn requestStateAndFile(s: *State, w: *P.Writer) void {
    s.status = .loading;
    s.tbs_pending = 0;
    w.getState("active_file");
}

fn pushRunTestbench(s: *State, w: *P.Writer, sample_idx: usize) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();

    if (s.cfg.tb_count == 0) return;
    wr.print("testbench={s}\n", .{s.cfg.tbs[0].getPath()}) catch return;

    var param_idx: usize = 0;
    for (s.cfg.params[0..s.cfg.param_count]) |*p| {
        if (!p.enabled) continue;
        const norm = s.lhc_grid[sample_idx][param_idx];
        const val = lhc.denormalize(p, norm);
        wr.print("{s}.{s}={e}\n", .{ p.instName(), p.propName(), val }) catch {};
        param_idx += 1;
    }

    w.pushCommand("run_testbench", buf[0..fbs.pos]);
    s.status = .sim_pending;
    s.current_sample = sample_idx;
}

fn computeScore(s: *const State, result: *const sim_result.SimResult) f32 {
    var score: f32 = 0;
    for (s.cfg.objs[0..s.cfg.obj_count]) |*o| {
        const val = result.get(o.getName()) orelse continue;
        score += switch (o.kind) {
            .maximize => -val * o.weight,
            .minimize => val * o.weight,
            .geq => if (val >= o.target) 0 else (o.target - val) * 1000,
            .leq => if (val <= o.target) 0 else (val - o.target) * 1000,
        };
    }
    return score;
}

fn saveBestToConfig(s: *State, sample_idx: usize) void {
    var param_idx: usize = 0;
    for (s.cfg.params[0..s.cfg.param_count]) |*p| {
        if (!p.enabled) {
            param_idx += 1;
            continue;
        }
        const norm = s.lhc_grid[sample_idx][param_idx];
        p.best_val = lhc.denormalize(p, norm);
        s.best_params[param_idx] = p.best_val;
        param_idx += 1;
    }
}

fn markDirtyAndPatchChn(s: *State) void {
    var block_buf: [4096]u8 = undefined;
    const block_n = config.buildBlock(&s.cfg, &block_buf);
    if (block_n == 0) return;
    var new_buf: [65536 + 4096]u8 = undefined;
    const new_n = config.patchFile(s.chn_buf[0..s.chn_len], block_buf[0..block_n], &new_buf);
    if (new_n == 0 or new_n > s.chn_buf.len) return;
    @memcpy(s.chn_buf[0..new_n], new_buf[0..new_n]);
    s.chn_len = new_n;
    s.chn_dirty = true;
}

// ── Message handlers ──────────────────────────────────────────────────────── //

fn onLoad(s: *State, w: *P.Writer) void {
    w.registerPanel(.{
        .id = "optimizer",
        .title = "Optimizer",
        .vim_cmd = "opt",
        .layout = .right_sidebar,
        .keybind = 'O',
    });
    w.setStatus("Optimizer ready");
    w.log(.info, "Optimizer", "loaded");
    requestStateAndFile(s, w);
}

fn onUnload(s: *State, _: *P.Writer) void {
    s.status = .idle;
    s.log.clear();
}

fn onTick(s: *State, w: *P.Writer) void {
    if (s.chn_dirty and s.chn_len > 0 and s.active_file_len > 0) {
        w.fileWrite(s.activePath(), s.chn_buf[0..s.chn_len]);
        s.chn_dirty = false;
    }
}

fn onSchematicChanged(s: *State, w: *P.Writer) void {
    s.status = .loading;
    s.cfg = .{};
    s.log.clear();
    requestStateAndFile(s, w);
    w.requestRefresh();
}

fn onStateResponse(s: *State, key: []const u8, val: []const u8, w: *P.Writer) void {
    if (std.mem.eql(u8, key, "active_file")) {
        if (val.len == 0) {
            s.setErr("No active .chn file");
            return;
        }
        s.setActivePath(val);
        w.fileReadRequest(val);
    }
}

fn onFileResponse(s: *State, path: []const u8, data: []const u8, w: *P.Writer) void {
    if (std.mem.eql(u8, path, "__sim_result__")) {
        onSimResult(s, data, w);
        return;
    }

    if (s.active_file_len > 0 and std.mem.eql(u8, path, s.activePath())) {
        const n = @min(data.len, s.chn_buf.len);
        @memcpy(s.chn_buf[0..n], data[0..n]);
        s.chn_len = n;

        const had_plugin = config.parse(data, &s.cfg);
        if (!had_plugin) {
            parseInstancesFromChn(s, data);
        }

        if (s.cfg.tb_count > 0) {
            s.tbs_pending = s.cfg.tb_count;
            for (s.cfg.tbs[0..s.cfg.tb_count]) |*tb| {
                w.fileReadRequest(tb.getPath());
            }
        } else {
            s.status = .ready;
        }
        w.requestRefresh();
        return;
    }

    for (s.cfg.tbs[0..s.cfg.tb_count]) |*tb| {
        if (std.mem.eql(u8, path, tb.getPath())) {
            parseTbMeasures(s, tb, data);
            if (s.tbs_pending > 0) s.tbs_pending -= 1;
            if (s.tbs_pending == 0) {
                s.status = .ready;
                w.requestRefresh();
            }
            return;
        }
    }
}

fn onSimResult(s: *State, data: []const u8, w: *P.Writer) void {
    if (s.stop_requested) {
        s.stop_requested = false;
        s.status = .idle;
        w.setStatus("Optimizer: stopped");
        w.requestRefresh();
        return;
    }
    if (s.status != .sim_pending) return;

    var result: sim_result.SimResult = undefined;
    sim_result.parse(data, &result);

    if (!result.valid) {
        logLine(s, "Iter {d}: sim failed", .{s.iteration + 1});
    } else {
        const score = computeScore(s, &result);
        const is_best = score < s.best_score;
        if (is_best) {
            s.best_score = score;
            saveBestToConfig(s, s.current_sample);
            markDirtyAndPatchChn(s);
        }

        var log_line_buf: [log_buf.LOG_LINE_LEN]u8 = undefined;
        var lfbs = std.io.fixedBufferStream(&log_line_buf);
        const lw = lfbs.writer();
        lw.print("Iter {d}:", .{s.iteration + 1}) catch {};
        for (s.cfg.params[0..s.cfg.param_count]) |*p| {
            if (!p.enabled) continue;
            lw.print(" {s}={e}", .{ p.propName(), p.best_val }) catch {};
        }
        for (s.cfg.objs[0..s.cfg.obj_count]) |*o| {
            const val = result.get(o.getName()) orelse continue;
            const sat = switch (o.kind) {
                .maximize, .minimize => true,
                .geq => val >= o.target,
                .leq => val <= o.target,
            };
            lw.print(" {s}={e}{s}", .{ o.getName(), val, if (sat) "+" else "x" }) catch {};
        }
        if (is_best) lw.writeAll("*") catch {};
        s.log.append(log_line_buf[0..lfbs.pos]);
    }

    s.iteration += 1;

    const next = s.current_sample + 1;
    if (next < s.cfg.lhc_samples and s.iteration < s.cfg.max_iter) {
        pushRunTestbench(s, w, next);
    } else {
        s.status = .done;
        w.setStatus("Optimizer: done");
        markDirtyAndPatchChn(s);
    }
    w.requestRefresh();
}

fn onButton(s: *State, widget_id: u32, w: *P.Writer) void {
    switch (widget_id) {
        WID_RUN => {
            if (s.status != .ready and s.status != .done and s.status != .idle) return;
            if (s.cfg.param_count == 0 or s.cfg.obj_count == 0) {
                s.setErr("Configure params and objectives first");
                w.requestRefresh();
                return;
            }
            var n_enabled: usize = 0;
            for (s.cfg.params[0..s.cfg.param_count]) |*p| {
                if (p.enabled) n_enabled += 1;
            }
            if (n_enabled == 0) {
                s.setErr("No enabled parameters");
                w.requestRefresh();
                return;
            }

            lhc.generate(n_enabled, s.cfg.lhc_samples, &s.lhc_grid, @intCast(std.time.milliTimestamp()));
            s.iteration = 0;
            s.best_score = std.math.inf(f32);
            s.stop_requested = false;
            s.log.clear();
            logLine(s, "Starting: {d} params, {d} samples", .{ n_enabled, s.cfg.lhc_samples });
            pushRunTestbench(s, w, 0);
            w.setStatus("Optimizer: running");
            w.requestRefresh();
        },
        WID_STOP => {
            s.stop_requested = true;
            w.setStatus("Optimizer: stopping...");
        },
        WID_RESET => {
            s.status = .ready;
            s.iteration = 0;
            s.best_score = std.math.inf(f32);
            s.log.clear();
            s.stop_requested = false;
            w.setStatus("Optimizer: reset");
            w.requestRefresh();
        },
        WID_RESCAN => {
            if (s.cfg.tb_count > 0) {
                s.tbs_pending = s.cfg.tb_count;
                s.status = .loading;
                for (s.cfg.tbs[0..s.cfg.tb_count]) |*tb| {
                    w.fileReadRequest(tb.getPath());
                }
            }
        },
        else => {
            if (widget_id >= WID_PARAM_ENABLE_BASE and
                widget_id < WID_PARAM_ENABLE_BASE + MAX_PARAMS)
            {
                const idx = widget_id - WID_PARAM_ENABLE_BASE;
                if (idx < s.cfg.param_count) {
                    s.cfg.params[idx].enabled = !s.cfg.params[idx].enabled;
                    markDirtyAndPatchChn(s);
                    w.requestRefresh();
                }
            } else if (widget_id >= WID_OBJ_KIND_BASE and
                widget_id < WID_OBJ_KIND_BASE + MAX_OBJECTIVES)
            {
                const idx = widget_id - WID_OBJ_KIND_BASE;
                if (idx < s.cfg.obj_count) {
                    s.cfg.objs[idx].kind = switch (s.cfg.objs[idx].kind) {
                        .maximize => .minimize,
                        .minimize => .geq,
                        .geq => .leq,
                        .leq => .maximize,
                    };
                    markDirtyAndPatchChn(s);
                    w.requestRefresh();
                }
            }
        },
    }
}

fn onSlider(s: *State, widget_id: u32, val: f32, _: *P.Writer) void {
    switch (widget_id) {
        WID_MAX_ITER => {
            s.cfg.max_iter = @intFromFloat(@max(1.0, @min(val, 200.0)));
            markDirtyAndPatchChn(s);
        },
        WID_LHC_SMP => {
            s.cfg.lhc_samples = @intFromFloat(@max(5.0, @min(val, @as(f32, @floatFromInt(MAX_SAMPLES)))));
            markDirtyAndPatchChn(s);
        },
        else => {},
    }
}

// ── .chn parsing helpers ──────────────────────────────────────────────────── //

fn parseInstancesFromChn(s: *State, data: []const u8) void {
    var line_it = std.mem.splitScalar(u8, data, '\n');
    var in_group: bool = false;
    var group_kind: enum { nmos, pmos, resistor, capacitor, other } = .other;

    while (line_it.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (line.len > 2 and line[0] == ' ' and line[1] == ' ' and line[2] != ' ') {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "nmos")) {
                in_group = true;
                group_kind = .nmos;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "pmos")) {
                in_group = true;
                group_kind = .pmos;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "resistor")) {
                in_group = true;
                group_kind = .resistor;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "capacitor")) {
                in_group = true;
                group_kind = .capacitor;
                continue;
            }
            in_group = false;
            continue;
        }

        if (!in_group) continue;
        if (line.len < 5 or line[0] != ' ' or line[1] != ' ' or line[2] != ' ' or line[3] != ' ') continue;
        const row = std.mem.trim(u8, line, " \t");
        const name_end = std.mem.indexOfAnyPos(u8, row, 0, " \t") orelse continue;
        const inst_name = row[0..name_end];

        const PropDef = struct { name: []const u8, min: f32, max: f32, step: f32 };
        const nmos_props = [_]PropDef{
            .{ .name = "W", .min = 1.2e-7, .max = 1e-5, .step = 1e-8 },
            .{ .name = "L", .min = 6e-8, .max = 1e-6, .step = 1e-8 },
            .{ .name = "nf", .min = 1, .max = 20, .step = 1 },
        };
        const pmos_props = [_]PropDef{
            .{ .name = "W", .min = 1.2e-7, .max = 1e-5, .step = 1e-8 },
            .{ .name = "L", .min = 6e-8, .max = 1e-6, .step = 1e-8 },
            .{ .name = "nf", .min = 1, .max = 20, .step = 1 },
        };
        const res_props = [_]PropDef{
            .{ .name = "R", .min = 100, .max = 100e3, .step = 100 },
        };
        const cap_props = [_]PropDef{
            .{ .name = "C", .min = 1e-15, .max = 10e-12, .step = 1e-15 },
        };
        const empty_props = [_]PropDef{};

        const props: []const PropDef = switch (group_kind) {
            .nmos => &nmos_props,
            .pmos => &pmos_props,
            .resistor => &res_props,
            .capacitor => &cap_props,
            .other => &empty_props,
        };

        for (props) |prop| {
            if (s.cfg.param_count >= MAX_PARAMS) break;
            s.cfg.params[s.cfg.param_count].setInst(inst_name);
            s.cfg.params[s.cfg.param_count].setProp(prop.name);
            s.cfg.params[s.cfg.param_count].min = prop.min;
            s.cfg.params[s.cfg.param_count].max = prop.max;
            s.cfg.params[s.cfg.param_count].step = prop.step;
            s.cfg.params[s.cfg.param_count].enabled = true;
            s.cfg.param_count += 1;
        }
    }
}

fn parseTbMeasures(s: *State, tb: *config.TbEntry, data: []const u8) void {
    var count: u8 = 0;
    var line_it = std.mem.splitScalar(u8, data, '\n');
    var in_measures = false;
    while (line_it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "  measures [")) {
            in_measures = true;
            continue;
        }
        if (in_measures) {
            if (line.len == 0 or (line.len > 0 and line[0] != ' ')) {
                in_measures = false;
                continue;
            }
            const trimmed = std.mem.trim(u8, line, " \t");
            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
            const name = std.mem.trim(u8, trimmed[0..colon], " \t");
            if (name.len == 0) continue;
            var already = false;
            for (s.cfg.objs[0..s.cfg.obj_count]) |*o| {
                if (std.mem.eql(u8, o.getName(), name)) {
                    already = true;
                    break;
                }
            }
            if (!already and s.cfg.obj_count < MAX_OBJECTIVES) {
                s.cfg.objs[s.cfg.obj_count].setName(name);
                s.cfg.objs[s.cfg.obj_count].kind = .maximize;
                s.cfg.obj_count += 1;
                count += 1;
            }
        }
    }
    tb.measure_count = count;
}

// ── Panel draw ────────────────────────────────────────────────────────────── //

fn drawPanel(s: *State, w: *P.Writer) void {
    w.label("Circuit Optimizer", 0);
    var hdr_buf: [64]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "Status: {s}  Iter: {d}/{d}", .{
        @tagName(s.status), s.iteration, s.cfg.max_iter,
    }) catch "...";
    w.label(hdr, 1);

    w.beginRow(2);
    switch (s.status) {
        .ready, .done, .idle => w.button("Run", WID_RUN),
        .sim_pending => w.button("Stop", WID_STOP),
        else => {},
    }
    w.button("Reset", WID_RESET);
    w.endRow(3);

    w.separator(4);

    if (s.status == .err) {
        w.label(s.errText(), 5);
        w.separator(6);
    }

    // Testbenches section
    w.collapsibleStart("Testbenches", s.sec_tbs_open, WID_SEC_TBS);
    if (s.sec_tbs_open) {
        if (s.cfg.tb_count == 0) {
            w.label("No testbenches configured", 30);
        } else {
            for (s.cfg.tbs[0..s.cfg.tb_count], 0..) |*tb, i| {
                var tb_buf: [300]u8 = undefined;
                const tb_lbl = std.fmt.bufPrint(&tb_buf, "{s} ({d} measures)", .{
                    tb.getPath(), tb.measure_count,
                }) catch "...";
                w.label(tb_lbl, @intCast(30 + i));
            }
        }
        w.button("Rescan", WID_RESCAN);
    }
    w.collapsibleEnd(WID_SEC_TBS + 1);

    // Parameters section
    w.collapsibleStart("Parameters", s.sec_params_open, WID_SEC_PARAMS);
    if (s.sec_params_open) {
        var last_inst: [config.MAX_NAME]u8 = [_]u8{0} ** config.MAX_NAME;
        var last_inst_len: usize = 0;
        for (s.cfg.params[0..s.cfg.param_count], 0..) |*p, i| {
            if (!std.mem.eql(u8, p.instName(), last_inst[0..last_inst_len])) {
                w.label(p.instName(), @intCast(50 + i * 4));
                const n = @min(p.instName().len, config.MAX_NAME);
                @memcpy(last_inst[0..n], p.instName()[0..n]);
                last_inst_len = n;
            }
            var row_buf: [128]u8 = undefined;
            const row = std.fmt.bufPrint(&row_buf, "  {s}  {e}~{e}", .{
                p.propName(), p.min, p.max,
            }) catch "...";
            w.beginRow(@intCast(51 + i * 4));
            w.checkbox(p.enabled, row, WID_PARAM_ENABLE_BASE + @as(u32, @intCast(i)));
            w.endRow(@intCast(52 + i * 4));
        }
        if (s.cfg.param_count == 0) w.label("No parameters found", 99);

        var has_best = false;
        for (s.cfg.params[0..s.cfg.param_count]) |*p| {
            if (p.best_val != 0) {
                has_best = true;
                break;
            }
        }
        if (has_best) {
            w.separator(199);
            var best_buf: [256]u8 = undefined;
            var bfbs = std.io.fixedBufferStream(&best_buf);
            const bw = bfbs.writer();
            bw.writeAll("Best: ") catch {};
            for (s.cfg.params[0..s.cfg.param_count]) |*p| {
                if (p.best_val == 0) continue;
                bw.print("{s}={e} ", .{ p.propName(), p.best_val }) catch {};
            }
            w.label(best_buf[0..bfbs.pos], 200);
        }
    }
    w.collapsibleEnd(WID_SEC_PARAMS + 1);

    // Objectives section
    w.collapsibleStart("Objectives", s.sec_objs_open, WID_SEC_OBJS);
    if (s.sec_objs_open) {
        for (s.cfg.objs[0..s.cfg.obj_count], 0..) |*o, i| {
            var obj_buf: [128]u8 = undefined;
            const obj_row = std.fmt.bufPrint(&obj_buf, "{s}", .{o.getName()}) catch "...";
            w.beginRow(@intCast(210 + i * 3));
            w.label(obj_row, @intCast(211 + i * 3));
            w.button(o.kind.label(), WID_OBJ_KIND_BASE + @as(u32, @intCast(i)));
            w.endRow(@intCast(212 + i * 3));
        }
        if (s.cfg.obj_count == 0) w.label("No objectives (rescan testbenches)", 299);
    }
    w.collapsibleEnd(WID_SEC_OBJS + 1);

    // Settings section
    w.collapsibleStart("Settings", s.sec_set_open, WID_SEC_SET);
    if (s.sec_set_open) {
        w.beginRow(300);
        w.label("Max iters", 301);
        w.slider(@floatFromInt(s.cfg.max_iter), 10, 200, WID_MAX_ITER);
        w.endRow(302);
        w.beginRow(303);
        w.label("LHC samples", 304);
        w.slider(@floatFromInt(s.cfg.lhc_samples), 5, @floatFromInt(MAX_SAMPLES), WID_LHC_SMP);
        w.endRow(305);
    }
    w.collapsibleEnd(WID_SEC_SET + 1);

    // Log section
    w.collapsibleStart("Log", s.sec_log_open, WID_SEC_LOG);
    if (s.sec_log_open) {
        if (s.log.len() == 0) {
            w.label("No log entries yet", 400);
        } else {
            const n = s.log.len();
            const start = if (n > 30) n - 30 else 0;
            for (start..n) |i| {
                w.label(s.log.get(i), @intCast(400 + i));
            }
        }
    }
    w.collapsibleEnd(WID_SEC_LOG + 1);
}

// ── ABI export ────────────────────────────────────────────────────────────── //

export fn schemify_process(
    in_ptr: [*]const u8,
    in_len: usize,
    out_ptr: [*]u8,
    out_cap: usize,
) callconv(.c) usize {
    var r = P.Reader.init(in_ptr[0..in_len]);
    var w = P.Writer.init(out_ptr[0..out_cap]);

    while (r.next()) |msg| switch (msg) {
        .load => onLoad(&state, &w),
        .unload => onUnload(&state, &w),
        .tick => onTick(&state, &w),
        .draw_panel => drawPanel(&state, &w),
        .button_clicked => |ev| onButton(&state, ev.widget_id, &w),
        .slider_changed => |ev| onSlider(&state, ev.widget_id, ev.val, &w),
        .schematic_changed => onSchematicChanged(&state, &w),
        .state_response => |ev| onStateResponse(&state, ev.key, ev.val, &w),
        .file_response => |ev| onFileResponse(&state, ev.path, ev.data, &w),
        else => {},
    };

    return if (w.overflow()) std.math.maxInt(usize) else w.pos;
}

export const schemify_plugin: P.Descriptor = .{
    .abi_version = P.ABI_VERSION,
    .name = "Optimizer",
    .version_str = "0.2.0",
    .process = &schemify_process,
};
