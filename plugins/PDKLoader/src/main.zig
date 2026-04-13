//! PDKLoader — Schemify native plugin (ABI v6).
//!
//! Left-sidebar panel for PDK management:
//!   • Detects Volare: bundled dep/volare/ > system CLI > python3 -m volare
//!   • Lists available PDK versions via `volare ls --pdk <family>`
//!   • Fetches a PDK at a chosen version into `~/.volare/`
//!   • Updates the project Config.toml `pdk =` field
//!
//! Works standalone; listed as a `requires` dependency in EasyImport.

const std = @import("std");
const P = @import("PluginIF");
const volare = @import("volare.zig");
const sym_conv = @import("converter.zig");
const lut = @import("lut.zig");
const remap = @import("remap.zig");

const Allocator = std.mem.Allocator;
const pa = std.heap.page_allocator;

// ── Constants ──────────────────────────────────────────────────────────────── //

const MAX_VERS: usize = 20;
const MAX_REMAP_ENTRIES: usize = 64;

// ── Widget IDs ─────────────────────────────────────────────────────────────── //

const WID_TITLE       : u32 = 0;
const WID_SEP1        : u32 = 1;
const WID_PDK_HDR     : u32 = 2;
const WID_PDK_TOGGLE  : u32 = 3;
const WID_PDK_INST    : u32 = 4;
const WID_PDK_PATH    : u32 = 5;
const WID_SEP2        : u32 = 6;
const WID_VER_HDR     : u32 = 7;
const WID_VER_LIST    : u32 = 8;
const WID_VER_CYCLE   : u32 = 9;
const WID_SEP3        : u32 = 10;
const WID_VOL_STAT    : u32 = 11;
const WID_VOL_RECHECK : u32 = 12;
const WID_SEP4        : u32 = 13;
const WID_FETCH       : u32 = 14;
const WID_APPLY       : u32 = 15;
const WID_CONVERT     : u32 = 16;
const WID_CONV_STAT   : u32 = 17;
const WID_SEP5        : u32 = 18;
const WID_CFG_HDR     : u32 = 19;
const WID_CFG_VAL     : u32 = 20;
const WID_SEP6        : u32 = 21;
const WID_GEN_LUT     : u32 = 22;
const WID_LUT_STAT    : u32 = 23;
const WID_NGSPICE_STAT: u32 = 24;
const WID_SEP7        : u32 = 25;
const WID_MSG         : u32 = 26;
const WID_SEP8        : u32 = 27;
const WID_MIGRATE_HDR : u32 = 28;
const WID_MIGRATE_BTN : u32 = 29;
const WID_DIFF_HDR    : u32 = 30;
const WID_DIFF_BASE   : u32 = 31; // rows use 31..31+MAX_DIFF_ROWS
const MAX_DIFF_ROWS   : u32 = 20;
const WID_APPLY_MIG   : u32 = 61; // "Apply Changes" (distinct from WID_APPLY=15)
const WID_CANCEL_BTN  : u32 = 62;
const WID_DIFF_SUMM   : u32 = 63;

// ── PDK catalogue ──────────────────────────────────────────────────────────── //

const PdkEntry = struct {
    /// Value written to Config.toml `pdk =`.
    config_name: []const u8,
    /// Volare PDK family identifier passed to `volare fetch/ls --pdk`.
    volare_id:   []const u8,
    /// Human-readable label shown in the panel.
    display:     []const u8,
};

const PDK_LIST = [_]PdkEntry{
    .{ .config_name = "sky130A",    .volare_id = "sky130",     .display = "sky130A  (SkyWater 130 nm)"   },
    .{ .config_name = "sky130B",    .volare_id = "sky130",     .display = "sky130B  (SkyWater 130 nm B)" },
    .{ .config_name = "gf180mcu",   .volare_id = "gf180mcu",  .display = "GF 180 nm MCU"                },
    .{ .config_name = "gf180mcuA",  .volare_id = "gf180mcu",  .display = "GF 180 nm MCU variant A"      },
    .{ .config_name = "gf180mcuB",  .volare_id = "gf180mcu",  .display = "GF 180 nm MCU variant B"      },
    .{ .config_name = "gf180mcuC",  .volare_id = "gf180mcu",  .display = "GF 180 nm MCU variant C"      },
    // IHP SG13G2 is not yet in volare — listed for forward compatibility.
    .{ .config_name = "ihp-sg13g2", .volare_id = "ihp-sg13g2", .display = "IHP SG13G2 (130 nm SiGe)"   },
};
const PDK_COUNT: u8 = PDK_LIST.len;

// ── Plugin state ───────────────────────────────────────────────────────────── //

const FetchResult = enum { idle, ok, err };

const State = struct {
    volare_kind:   volare.Kind = .none,
    pdk_idx:       u8          = 0,
    fetch_res:     FetchResult = .idle,
    version_count: u8          = 0,
    version_idx:   u8          = 0,
    conv_total:    u32         = 0,
    conv_done:     u32         = 0,
    lut_generated: bool        = false,
    ngspice:       lut.NgspiceStatus = .{},

    home:         [256]u8 = [_]u8{0} ** 256,
    home_len:     u16     = 0,

    cfg_path:     [512]u8 = [_]u8{0} ** 512,
    cfg_path_len: u16     = 0,

    cur_pdk:      [64]u8  = [_]u8{0} ** 64,
    cur_pdk_len:  u8      = 0,

    msg:          [256]u8 = [_]u8{0} ** 256,
    msg_len:      u16     = 0,

    // Flat byte pool for version strings: MAX_VERS slots of 80 bytes each.
    ver_pool: [MAX_VERS * 80]u8 = [_]u8{0} ** (MAX_VERS * 80),
    ver_lens: [MAX_VERS]u8      = [_]u8{0} ** MAX_VERS,

    // ── Remap / migration state ─────────────────────────────────────────── //
    remap_entries: [MAX_REMAP_ENTRIES]remap.RemapEntry = [_]remap.RemapEntry{.{}} ** MAX_REMAP_ENTRIES,
    remap_count:   u16 = 0,
    remap_active:  bool = false, // true while diff table is displayed

    // Summary counts (cached after computeRemap)
    remap_ok:          u16 = 0,
    remap_warnings:    u16 = 0, // no_match + no_bias + unresizable
    remap_unchanged:   u16 = 0, // passthrough + skipped

    fn entry(s: *const State) *const PdkEntry  { return &PDK_LIST[s.pdk_idx]; }
    fn homeSlice(s: *const State)   []const u8 { return s.home[0..s.home_len]; }
    fn cfgSlice(s: *const State)    []const u8 { return s.cfg_path[0..s.cfg_path_len]; }
    fn curPdkSlice(s: *const State) []const u8 { return s.cur_pdk[0..s.cur_pdk_len]; }
    fn msgSlice(s: *const State)    []const u8 { return s.msg[0..s.msg_len]; }

    fn verSlice(s: *const State, i: usize) []const u8 {
        return s.ver_pool[i * 80 ..][0..s.ver_lens[i]];
    }
    fn selectedVer(s: *const State) []const u8 {
        if (s.version_count == 0) return "latest";
        return s.verSlice(s.version_idx);
    }

    fn setHome(s: *State, h: []const u8) void {
        const n: u16 = @intCast(@min(h.len, s.home.len));
        @memcpy(s.home[0..n], h[0..n]);
        s.home_len = n;
    }
    fn setCfgPath(s: *State, p: []const u8) void {
        const n: u16 = @intCast(@min(p.len, s.cfg_path.len));
        @memcpy(s.cfg_path[0..n], p[0..n]);
        s.cfg_path_len = n;
    }
    fn setCurPdk(s: *State, v: []const u8) void {
        const n: u8 = @intCast(@min(v.len, s.cur_pdk.len));
        @memcpy(s.cur_pdk[0..n], v[0..n]);
        s.cur_pdk_len = n;
    }
    fn setMsg(s: *State, m: []const u8) void {
        const n: u16 = @intCast(@min(m.len, s.msg.len));
        @memcpy(s.msg[0..n], m[0..n]);
        s.msg_len = n;
    }
    fn setMsgFmt(s: *State, comptime fmt: []const u8, args: anytype) void {
        const m = std.fmt.bufPrint(&s.msg, fmt, args) catch { s.msg_len = 0; return; };
        s.msg_len = @intCast(m.len);
    }

    fn storeVersions(s: *State, data: [][80]u8, lens: []const u8, count: u8) void {
        s.version_count = @intCast(@min(count, MAX_VERS));
        s.version_idx   = 0;
        for (0..s.version_count) |i| {
            const n = lens[i];
            @memcpy(s.ver_pool[i * 80 ..][0..n], data[i][0..n]);
            s.ver_lens[i] = n;
        }
    }

    fn resetVersions(s: *State) void {
        s.version_count = 0;
        s.version_idx   = 0;
    }

    fn storeRemapResult(s: *State, result: *remap.RemapResult) void {
        const n: u16 = @intCast(@min(result.entries.len, MAX_REMAP_ENTRIES));
        for (0..n) |i| {
            s.remap_entries[i] = result.entries[i];
        }
        s.remap_count  = n;
        s.remap_active = true;

        // Cache summary counts
        s.remap_ok        = 0;
        s.remap_warnings  = 0;
        s.remap_unchanged = 0;
        for (0..n) |i| {
            switch (s.remap_entries[i].status) {
                .ok          => s.remap_ok += 1,
                .no_match    => s.remap_warnings += 1,
                .no_bias     => s.remap_warnings += 1,
                .unresizable => s.remap_warnings += 1,
                .passthrough => s.remap_unchanged += 1,
                .skipped     => s.remap_unchanged += 1,
            }
        }
    }

    fn clearRemap(s: *State) void {
        s.remap_count    = 0;
        s.remap_active   = false;
        s.remap_ok       = 0;
        s.remap_warnings = 0;
        s.remap_unchanged = 0;
    }
};

var state = State{};

// ── Config.toml path resolution ────────────────────────────────────────────── //

fn findConfigToml(start_dir: []const u8, buf: []u8) ?[]const u8 {
    var dir = start_dir;
    for (0..7) |_| {
        const candidate = std.fmt.bufPrint(buf, "{s}/Config.toml", .{dir}) catch return null;
        std.fs.cwd().access(candidate, .{}) catch {
            const parent = std.fs.path.dirname(dir) orelse break;
            if (std.mem.eql(u8, parent, dir)) break;
            dir = parent;
            continue;
        };
        return candidate;
    }
    std.fs.cwd().access("Config.toml", .{}) catch return null;
    return std.fmt.bufPrint(buf, "Config.toml", .{}) catch null;
}

// ── Config.toml helpers ────────────────────────────────────────────────────── //

fn isPdkLine(t: []const u8) bool {
    if (!std.mem.startsWith(u8, t, "pdk")) return false;
    return std.mem.trimLeft(u8, t[3..], " \t").len > 0 and
        std.mem.trimLeft(u8, t[3..], " \t")[0] == '=';
}

fn isNameLine(t: []const u8) bool {
    if (!std.mem.startsWith(u8, t, "name")) return false;
    return std.mem.trimLeft(u8, t[4..], " \t").len > 0 and
        std.mem.trimLeft(u8, t[4..], " \t")[0] == '=';
}

fn readPdkFromConfig(config_path: []const u8, out: []u8) ?usize {
    const content = std.fs.cwd().readFileAlloc(pa, config_path, 65536) catch return null;
    defer pa.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const t = std.mem.trim(u8, std.mem.trimRight(u8, raw, "\r"), " \t");
        if (!isPdkLine(t)) continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        const val = std.mem.trim(u8, t[eq + 1 ..], " \t\"");
        if (val.len == 0) continue;
        const n = @min(val.len, out.len);
        @memcpy(out[0..n], val[0..n]);
        return n;
    }
    return null;
}

fn writePdkToConfig(config_path: []const u8, new_pdk: []const u8) bool {
    const content = std.fs.cwd().readFileAlloc(pa, config_path, 65536) catch return false;
    defer pa.free(content);

    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(pa);
    out.ensureTotalCapacity(pa, content.len + 64) catch return false;

    var pdk_written = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        const t    = std.mem.trim(u8, line, " \t");

        if (!pdk_written and isPdkLine(t)) {
            out.writer(pa).print("pdk = \"{s}\"\n", .{new_pdk}) catch return false;
            pdk_written = true;
            continue;
        }
        out.appendSlice(pa, line) catch return false;
        out.append(pa, '\n') catch return false;
        if (!pdk_written and isNameLine(t)) {
            out.writer(pa).print("pdk = \"{s}\"\n", .{new_pdk}) catch return false;
            pdk_written = true;
        }
    }
    if (!pdk_written) {
        out.writer(pa).print("pdk = \"{s}\"\n", .{new_pdk}) catch return false;
    }

    const trimmed = std.mem.trimRight(u8, out.items, "\n");
    var final = std.ArrayListUnmanaged(u8){};
    defer final.deinit(pa);
    final.appendSlice(pa, trimmed) catch return false;
    final.append(pa, '\n') catch return false;

    std.fs.cwd().writeFile(.{ .sub_path = config_path, .data = final.items }) catch return false;
    return true;
}

/// Append a chn_prim glob for the converted PDK symbols to Config.toml,
/// e.g. `chn_prim = ["~/.config/Schemify/PDKLoader/sky130A/prims/**"]`.
/// If the glob is already present, this is a no-op.
fn appendChnPrimGlob(config_path: []const u8, home: []const u8, config_name: []const u8) void {
    const content = std.fs.cwd().readFileAlloc(pa, config_path, 65536) catch return;
    defer pa.free(content);

    // Build the glob string
    var glob_buf: [256]u8 = undefined;
    const glob = std.fmt.bufPrint(
        &glob_buf, "{s}/.config/Schemify/PDKLoader/{s}/prims/**", .{ home, config_name },
    ) catch return;

    // Check if already present
    if (std.mem.indexOf(u8, content, glob) != null) return;

    // Find existing chn_prim line or insert after [paths]
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(pa);
    out.ensureTotalCapacity(pa, content.len + 128) catch return;

    var chn_prim_written = false;
    var in_paths = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        const t = std.mem.trim(u8, line, " \t");

        if (std.mem.eql(u8, t, "[paths]")) in_paths = true;
        if (t.len > 0 and t[0] == '[' and !std.mem.eql(u8, t, "[paths]")) in_paths = false;

        // If we find an existing chn_prim line, append our glob to it
        if (!chn_prim_written and std.mem.startsWith(u8, t, "chn_prim")) {
            if (std.mem.indexOfScalar(u8, t, '=') != null) {
                // Find the closing bracket and insert before it
                if (std.mem.lastIndexOfScalar(u8, line, ']')) |close| {
                    out.appendSlice(pa, line[0..close]) catch return;
                    out.writer(pa).print(", \"{s}\"]", .{glob}) catch return;
                    out.append(pa, '\n') catch return;
                    chn_prim_written = true;
                    continue;
                }
            }
        }

        out.appendSlice(pa, line) catch return;
        out.append(pa, '\n') catch return;

        // Insert after [paths] section header if no chn_prim line found
        if (!chn_prim_written and in_paths and std.mem.eql(u8, t, "[paths]")) {
            out.writer(pa).print("chn_prim = [\"{s}\"]\n", .{glob}) catch return;
            chn_prim_written = true;
        }
    }

    if (!chn_prim_written) {
        out.writer(pa).print("\n[paths]\nchn_prim = [\"{s}\"]\n", .{glob}) catch return;
    }

    const trimmed = std.mem.trimRight(u8, out.items, "\n");
    var final = std.ArrayListUnmanaged(u8){};
    defer final.deinit(pa);
    final.appendSlice(pa, trimmed) catch return;
    final.append(pa, '\n') catch return;
    std.fs.cwd().writeFile(.{ .sub_path = config_path, .data = final.items }) catch return;
}

// ── Panel draw ─────────────────────────────────────────────────────────────── //

fn drawPanel(w: *P.Writer) void {
    w.label("PDK Loader", WID_TITLE);
    w.separator(WID_SEP1);

    // ── PDK selection ────────────────────────────────────────────────────── //
    w.label("Select PDK:", WID_PDK_HDR);
    w.button(state.entry().display, WID_PDK_TOGGLE);

    var path_buf: [512]u8 = undefined;
    const root = if (state.home_len > 0)
        volare.pdkRoot(state.homeSlice(), state.entry().volare_id, &path_buf)
    else
        null;
    w.label(if (root != null) "  installed" else "  not installed", WID_PDK_INST);
    if (root) |p| w.label(p, WID_PDK_PATH);
    w.separator(WID_SEP2);

    // ── Version picker ───────────────────────────────────────────────────── //
    w.label("Version:", WID_VER_HDR);
    if (state.version_count == 0) {
        w.button("List Available Versions", WID_VER_LIST);
    } else {
        var refresh_buf: [64]u8 = undefined;
        const refresh_lbl = std.fmt.bufPrint(
            &refresh_buf, "Refresh  ({d} available)", .{state.version_count},
        ) catch "Refresh";
        w.button(refresh_lbl, WID_VER_LIST);

        var ver_buf: [128]u8 = undefined;
        const ver_lbl = std.fmt.bufPrint(
            &ver_buf, "  {s}  ({d}/{d})", .{
                state.selectedVer(),
                state.version_idx + 1,
                state.version_count,
            },
        ) catch state.selectedVer();
        w.button(ver_lbl, WID_VER_CYCLE);
    }
    w.separator(WID_SEP3);

    // ── Volare detection status ──────────────────────────────────────────── //
    w.label(switch (state.volare_kind) {
        .none          => "Volare: not found",
        .local         => "Volare: bundled dep",
        .cli           => "Volare: system CLI",
        .python_module => "Volare: python3 -m volare",
    }, WID_VOL_STAT);
    w.button("Re-detect", WID_VOL_RECHECK);
    w.separator(WID_SEP4);

    // ── Actions ──────────────────────────────────────────────────────────── //
    if (state.volare_kind != .none) {
        var fetch_buf: [128]u8 = undefined;
        const fetch_lbl: []const u8 = switch (state.fetch_res) {
            .idle => blk: {
                break :blk std.fmt.bufPrint(
                    &fetch_buf, "Fetch PDK  ({s})", .{state.selectedVer()},
                ) catch "Fetch PDK";
            },
            .ok   => "Re-fetch PDK",
            .err  => "Retry Fetch",
        };
        w.button(fetch_lbl, WID_FETCH);
    } else {
        w.label("Install Volare to fetch PDKs", WID_FETCH);
    }

    if (state.cfg_path_len > 0)
        w.button("Apply pdk to Config.toml", WID_APPLY)
    else
        w.label("Open a project to apply pdk", WID_APPLY);

    // ── Symbol conversion (Phase 2) ──────────────────────────────────────── //
    if (root != null) {
        w.button("Convert PDK Symbols to .chn_prim", WID_CONVERT);
        if (state.conv_total > 0) {
            var conv_buf: [80]u8 = undefined;
            const conv_lbl = std.fmt.bufPrint(
                &conv_buf, "  {d}/{d} symbols converted", .{ state.conv_done, state.conv_total },
            ) catch "  converted";
            w.label(conv_lbl, WID_CONV_STAT);
        }
    }
    w.separator(WID_SEP5);

    // ── Current config value ─────────────────────────────────────────────── //
    w.label("Config.toml pdk:", WID_CFG_HDR);
    w.label(if (state.cur_pdk_len > 0) state.curPdkSlice() else "(not set)", WID_CFG_VAL);

    // ── LUT generation (Phase 3) ─────────────────────────────────────────── //
    if (root != null) {
        w.separator(WID_SEP6);

        // ngspice status
        var ngspice_lbl_buf: [80]u8 = undefined;
        w.label(state.ngspice.label(&ngspice_lbl_buf), WID_NGSPICE_STAT);

        if (state.lut_generated)
            w.button("Re-generate Gm/ID LUTs (ngspice)", WID_GEN_LUT)
        else
            w.button("Generate Gm/ID LUTs (ngspice)", WID_GEN_LUT);
        if (state.lut_generated)
            w.label("  LUTs ready", WID_LUT_STAT);
    }

    // ── Migration / Remap (Phase 4) ─────────────────────────────────────── //
    drawMigrateSection(w);

    if (state.msg_len > 0) {
        w.separator(WID_SEP7);
        w.label(state.msgSlice(), WID_MSG);
    }
}

// ── Migration section draw ──────────────────────────────────────────────────── //

fn drawMigrateSection(w: *P.Writer) void {
    const src_pdk = if (state.cur_pdk_len > 0) state.curPdkSlice() else return;
    const dst_pdk = state.entry().config_name;

    // Only show when source and target differ
    if (std.mem.eql(u8, src_pdk, dst_pdk)) return;

    // Check both LUTs are available (files exist on disk)
    const home = state.homeSlice();
    if (home.len == 0) return;

    const src_has_luts = hasLutsOnDisk(home, src_pdk);
    const dst_has_luts = hasLutsOnDisk(home, dst_pdk);
    if (!src_has_luts or !dst_has_luts) return;

    w.separator(WID_SEP8);
    w.label("Design Migration", WID_MIGRATE_HDR);

    if (!state.remap_active) {
        // Show "Migrate: src -> dst" button
        var mig_buf: [128]u8 = undefined;
        const mig_lbl = std.fmt.bufPrint(
            &mig_buf, "Migrate: {s} -> {s}", .{ src_pdk, dst_pdk },
        ) catch "Switch PDK";
        w.button(mig_lbl, WID_MIGRATE_BTN);
    } else {
        // Show diff table
        drawDiffTable(w);
    }
}

fn hasLutsOnDisk(home: []const u8, config_name: []const u8) bool {
    var n_buf: [512]u8 = undefined;
    var p_buf: [512]u8 = undefined;
    const n_path = std.fmt.bufPrint(&n_buf, "{s}/.config/Schemify/PDKLoader/{s}/lut_nmos.tsv", .{ home, config_name }) catch return false;
    const p_path = std.fmt.bufPrint(&p_buf, "{s}/.config/Schemify/PDKLoader/{s}/lut_pmos.tsv", .{ home, config_name }) catch return false;
    std.fs.cwd().access(n_path, .{}) catch return false;
    std.fs.cwd().access(p_path, .{}) catch return false;
    return true;
}

fn drawDiffTable(w: *P.Writer) void {
    // Header row
    w.label("Device      | Old W/L     | New W/L     | dft%  | Status", WID_DIFF_HDR);

    const display_count = @min(state.remap_count, MAX_DIFF_ROWS);
    for (0..display_count) |i| {
        const e = &state.remap_entries[i];
        var row_buf: [128]u8 = undefined;
        const row_text = formatDiffRow(e, &row_buf) catch "...";
        w.label(row_text, WID_DIFF_BASE + @as(u32, @intCast(i)));
    }

    // Truncation notice
    if (state.remap_count > MAX_DIFF_ROWS) {
        var trunc_buf: [64]u8 = undefined;
        const trunc_lbl = std.fmt.bufPrint(
            &trunc_buf, "...and {d} more", .{state.remap_count - MAX_DIFF_ROWS},
        ) catch "...and more";
        w.label(trunc_lbl, WID_DIFF_BASE + MAX_DIFF_ROWS);
    }

    // Summary line
    var summ_buf: [80]u8 = undefined;
    const summ_lbl = std.fmt.bufPrint(
        &summ_buf, "{d} ok, {d} warning, {d} unchanged",
        .{ state.remap_ok, state.remap_warnings, state.remap_unchanged },
    ) catch "summary";
    w.label(summ_lbl, WID_DIFF_SUMM);

    // Confirm / cancel buttons
    w.button("Apply Changes", WID_APPLY_MIG);
    w.button("Cancel", WID_CANCEL_BTN);
}

fn formatDiffRow(e: *const remap.RemapEntry, buf: []u8) ![]const u8 {
    const name = e.nameSlice();
    const name_display = if (name.len > 10) name[0..10] else name;
    // Pad name to 10 chars
    var name_pad: [10]u8 = [_]u8{' '} ** 10;
    @memcpy(name_pad[0..name_display.len], name_display);

    const status_str = statusLabel(e);

    switch (e.dev_type) {
        .nmos, .pmos => {
            // Format W/L in microns
            var old_wl_buf: [24]u8 = undefined;
            var new_wl_buf: [24]u8 = undefined;
            const old_wl = formatWL(e.old_w, e.old_l, &old_wl_buf);
            const new_wl = formatWL(e.new_w, e.new_l, &new_wl_buf);

            // ft ratio as percentage change: (ratio - 1) * 100
            const dft_pct = (e.ft_ratio - 1.0) * 100.0;

            return std.fmt.bufPrint(buf, "{s} | {s} | {s} | {d:5.1}% | {s}", .{
                @as([]const u8, &name_pad), old_wl, new_wl, dft_pct, status_str,
            });
        },
        .npn, .pnp => {
            return std.fmt.bufPrint(buf, "{s} | area={d:.2}  | area={d:.2}  |       | {s}", .{
                @as([]const u8, &name_pad), e.old_area, e.new_area, status_str,
            });
        },
        .resistor, .capacitor, .inductor => {
            return std.fmt.bufPrint(buf, "{s} | unchanged                       | {s}", .{
                @as([]const u8, &name_pad), status_str,
            });
        },
        .other => {
            return std.fmt.bufPrint(buf, "{s} |                                 | {s}", .{
                @as([]const u8, &name_pad), status_str,
            });
        },
    }
}

fn formatWL(w_m: f64, l_m: f64, buf: []u8) []const u8 {
    // Convert to microns and display compactly
    const w_u = w_m * 1.0e6;
    const l_u = l_m * 1.0e6;
    return std.fmt.bufPrint(buf, "{d:.2}u/{d:.2}u", .{ w_u, l_u }) catch "?/?";
}

fn statusLabel(e: *const remap.RemapEntry) []const u8 {
    return switch (e.status) {
        .ok          => "ok",
        .no_match    => "[x] no LUT match",
        .no_bias     => "[?] no bias data",
        .unresizable => "[!] unresizable",
        .passthrough => "unchanged",
        .skipped     => "skipped",
    };
}

// ── Button dispatch ────────────────────────────────────────────────────────── //

fn onButton(widget_id: u32, w: *P.Writer) void {
    switch (widget_id) {
        WID_PDK_TOGGLE => {
            state.pdk_idx  = (state.pdk_idx + 1) % PDK_COUNT;
            state.fetch_res = .idle;
            state.resetVersions();
            state.msg_len  = 0;
            w.requestRefresh();
        },

        WID_VER_LIST => {
            if (state.volare_kind == .none) {
                state.setMsg("Volare not found — run: zig build clone-volare");
                w.requestRefresh();
                return;
            }
            w.setStatus("PDKLoader: listing versions...");
            var lm_buf: [512]u8 = undefined;
            const lm = volare.localMainPath(state.homeSlice(), &lm_buf) orelse "";
            var vd: [MAX_VERS][80]u8 = undefined;
            var vl: [MAX_VERS]u8 = [_]u8{0} ** MAX_VERS;
            const count = volare.listVersions(
                pa, state.volare_kind, lm, state.entry().volare_id, &vd, &vl,
            );
            state.storeVersions(&vd, &vl, count);
            if (count > 0) {
                state.setMsgFmt("{d} versions for {s}", .{ count, state.entry().volare_id });
                w.setStatus("PDKLoader: versions loaded");
            } else {
                state.setMsg("No versions found — check volare / network");
                w.setStatus("PDKLoader: version list empty");
            }
            w.requestRefresh();
        },

        WID_VER_CYCLE => {
            if (state.version_count > 0) {
                state.version_idx = (state.version_idx + 1) % state.version_count;
                w.requestRefresh();
            }
        },

        WID_VOL_RECHECK => {
            state.volare_kind = volare.detect(pa, state.homeSlice());
            state.ngspice = lut.detectNgspice(pa);
            state.setMsg(switch (state.volare_kind) {
                .none          => "Volare not found",
                .local         => "Found: bundled dep/volare",
                .cli           => "Found: volare CLI",
                .python_module => "Found: python3 -m volare",
            });
            w.requestRefresh();
        },

        WID_FETCH => {
            if (state.volare_kind == .none) {
                state.setMsg("Volare not found");
                w.requestRefresh();
                return;
            }
            var lm_buf: [512]u8 = undefined;
            const lm = volare.localMainPath(state.homeSlice(), &lm_buf) orelse "";
            const ver: ?[]const u8 = if (state.version_count > 0) state.selectedVer() else null;
            w.setStatus("PDKLoader: fetching PDK (may take several minutes)...");
            const ok = volare.fetchPdk(pa, state.volare_kind, lm, state.entry().volare_id, ver);
            if (ok) {
                state.fetch_res = .ok;
                state.setMsgFmt("Fetched {s} successfully", .{state.entry().config_name});
                w.setStatus("PDKLoader: PDK ready");
            } else {
                state.fetch_res = .err;
                state.setMsgFmt("Fetch failed for {s}", .{state.entry().config_name});
                w.setStatus("PDKLoader: fetch failed");
            }
            w.requestRefresh();
        },

        WID_GEN_LUT => {
            const home = state.homeSlice();
            if (home.len == 0) { state.setMsg("HOME not set"); w.requestRefresh(); return; }
            // Re-check ngspice availability before starting
            if (!state.ngspice.found) {
                state.ngspice = lut.detectNgspice(pa);
            }
            if (!state.ngspice.found) {
                state.setMsg("ngspice not found. Install: sudo apt install ngspice (Debian/Ubuntu) or brew install ngspice (macOS)");
                w.requestRefresh();
                return;
            }
            const defaults = lut.paramsForPdk(state.entry().config_name) orelse {
                state.setMsg("No LUT params known for this PDK");
                w.requestRefresh();
                return;
            };
            // Apply user overrides from ~/.config/Schemify/PDKLoader/<pdk>/params.toml
            const params = lut.loadParamsOverride(pa, home, state.entry().config_name, defaults);
            const pdk_root = sym_conv.findPdkVariantRoot(pa, home, state.entry().volare_id, state.entry().config_name);
            if (pdk_root == null) {
                state.setMsg("PDK not found under ~/.volare — fetch first");
                w.requestRefresh();
                return;
            }
            defer pa.free(pdk_root.?);
            const lut_dir = std.fmt.allocPrint(pa, "{s}/.config/Schemify/PDKLoader/{s}", .{ home, state.entry().config_name }) catch {
                state.setMsg("Path error"); w.requestRefresh(); return;
            };
            defer pa.free(lut_dir);
            w.setStatus("PDKLoader: generating NMOS LUT (may take minutes)...");
            const nok = lut.generateLut(pa, pdk_root.?, lut_dir, params, .nmos);
            w.setStatus("PDKLoader: generating PMOS LUT...");
            const pok = lut.generateLut(pa, pdk_root.?, lut_dir, params, .pmos);
            if (nok and pok) {
                state.lut_generated = true;
                state.setMsg("NMOS + PMOS LUTs generated");
                w.setStatus("PDKLoader: LUTs ready");
            } else if (nok or pok) {
                state.lut_generated = true;
                state.setMsg("Partial LUT generation (check ngspice)");
                w.setStatus("PDKLoader: partial LUT");
            } else {
                state.setMsg("LUT generation failed — check ngspice output");
                w.setStatus("PDKLoader: LUT failed");
            }
            w.requestRefresh();
        },

        WID_CONVERT => {
            const home = state.homeSlice();
            if (home.len == 0) { state.setMsg("HOME not set"); w.requestRefresh(); return; }
            const pdk_root = sym_conv.findPdkVariantRoot(pa, home, state.entry().volare_id, state.entry().config_name);
            if (pdk_root == null) {
                state.setMsg("PDK not found under ~/.volare — fetch first");
                w.requestRefresh();
                return;
            }
            defer pa.free(pdk_root.?);
            const out_dir = sym_conv.primsOutputDir(pa, home, state.entry().config_name);
            if (out_dir == null) { state.setMsg("Could not build output path"); w.requestRefresh(); return; }
            defer pa.free(out_dir.?);
            w.setStatus("PDKLoader: converting PDK symbols...");
            const stats = sym_conv.convertPdkSymbols(pa, pdk_root.?, out_dir.?);
            state.conv_total = stats.total;
            state.conv_done  = stats.converted;
            state.setMsgFmt("Converted {d}/{d} symbols to .chn_prim", .{ stats.converted, stats.total });
            w.setStatus("PDKLoader: symbol conversion complete");
            // Auto-update Config.toml chn_prim if config is available
            if (state.cfg_path_len > 0) {
                appendChnPrimGlob(state.cfgSlice(), home, state.entry().config_name);
            }
            w.requestRefresh();
        },

        WID_APPLY => {
            if (state.cfg_path_len == 0) {
                state.setMsg("No Config.toml found — open a schematic first");
                w.requestRefresh();
                return;
            }
            if (writePdkToConfig(state.cfgSlice(), state.entry().config_name)) {
                state.setCurPdk(state.entry().config_name);
                state.setMsgFmt("Set pdk = \"{s}\" in Config.toml", .{state.entry().config_name});
                w.setStatus("PDKLoader: Config.toml updated");
            } else {
                state.setMsg("Could not write Config.toml");
            }
            w.requestRefresh();
        },

        WID_MIGRATE_BTN => onMigrateClicked(w),
        WID_APPLY_MIG   => onApplyMigration(w),
        WID_CANCEL_BTN  => {
            state.clearRemap();
            state.setMsg("Migration cancelled");
            w.requestRefresh();
        },

        else => {},
    }
}

// ── Migration handlers ─────────────────────────────────────────────────────── //

fn onMigrateClicked(w: *P.Writer) void {
    const home = state.homeSlice();
    if (home.len == 0) { state.setMsg("HOME not set"); w.requestRefresh(); return; }

    const src_pdk = if (state.cur_pdk_len > 0) state.curPdkSlice() else {
        state.setMsg("No source PDK in Config.toml");
        w.requestRefresh();
        return;
    };
    const dst_pdk = state.entry().config_name;

    // Load PDK params
    const src_params = lut.paramsForPdk(src_pdk) orelse {
        state.setMsgFmt("No LUT params known for source PDK: {s}", .{src_pdk});
        w.requestRefresh();
        return;
    };
    const dst_params = lut.paramsForPdk(dst_pdk) orelse {
        state.setMsgFmt("No LUT params known for target PDK: {s}", .{dst_pdk});
        w.requestRefresh();
        return;
    };

    // Load source LUTs
    const src_nmos_path = lut.lutPath(pa, home, src_pdk, .nmos) orelse {
        state.setMsg("Could not build source NMOS LUT path");
        w.requestRefresh();
        return;
    };
    defer pa.free(src_nmos_path);
    const src_pmos_path = lut.lutPath(pa, home, src_pdk, .pmos) orelse {
        state.setMsg("Could not build source PMOS LUT path");
        w.requestRefresh();
        return;
    };
    defer pa.free(src_pmos_path);

    var src_nmos = lut.loadLut(pa, src_nmos_path) orelse {
        state.setMsgFmt("Could not load source NMOS LUT: {s}", .{src_pdk});
        w.requestRefresh();
        return;
    };
    defer src_nmos.deinit();
    var src_pmos = lut.loadLut(pa, src_pmos_path) orelse {
        state.setMsgFmt("Could not load source PMOS LUT: {s}", .{src_pdk});
        w.requestRefresh();
        return;
    };
    defer src_pmos.deinit();

    // Load target LUTs
    const dst_nmos_path = lut.lutPath(pa, home, dst_pdk, .nmos) orelse {
        state.setMsg("Could not build target NMOS LUT path");
        w.requestRefresh();
        return;
    };
    defer pa.free(dst_nmos_path);
    const dst_pmos_path = lut.lutPath(pa, home, dst_pdk, .pmos) orelse {
        state.setMsg("Could not build target PMOS LUT path");
        w.requestRefresh();
        return;
    };
    defer pa.free(dst_pmos_path);

    var dst_nmos = lut.loadLut(pa, dst_nmos_path) orelse {
        state.setMsgFmt("Could not load target NMOS LUT: {s}", .{dst_pdk});
        w.requestRefresh();
        return;
    };
    defer dst_nmos.deinit();
    var dst_pmos = lut.loadLut(pa, dst_pmos_path) orelse {
        state.setMsgFmt("Could not load target PMOS LUT: {s}", .{dst_pdk});
        w.requestRefresh();
        return;
    };
    defer dst_pmos.deinit();

    // TODO: Read actual device instances from schematic via ABI queryInstances.
    // The ABI v6 queryInstances message is defined but the host does not yet
    // populate instance properties in the response. For now we use placeholder
    // mock data to exercise the remap pipeline end-to-end. Once the host sends
    // real instance data, replace this block with parsed DeviceInstance values.
    const mock_instances = [_]remap.DeviceInstance{
        .{ .name = "M1", .dev_type = .nmos, .w = 1.0e-6, .l = 0.15e-6, .nf = 2,
           .vgs = 0.6, .vds = 0.9, .id = 100.0e-6, .gm = 1.0e-3, .gds = 10.0e-6,
           .ft = 5.0e9, .bias_valid = true },
        .{ .name = "M2", .dev_type = .pmos, .w = 2.0e-6, .l = 0.15e-6, .nf = 2,
           .vgs = -0.5, .vds = -0.9, .id = -80.0e-6, .gm = 0.8e-3, .gds = 8.0e-6,
           .ft = 3.0e9, .bias_valid = true },
        .{ .name = "R1", .dev_type = .resistor, .value = 10.0e3 },
        .{ .name = "C1", .dev_type = .capacitor, .value = 1.0e-12 },
    };

    w.setStatus("PDKLoader: computing remap...");

    // Determine if target PDK has BJT models
    const dst_has_bjt = dst_params.bjt_is_npn > 0 or dst_params.bjt_is_pnp > 0;

    // Determine target VT availability
    const dst_vt = vtAvailForPdk(dst_pdk);

    var result = remap.computeRemap(
        pa,
        &mock_instances,
        src_params,
        dst_params,
        &src_nmos,
        &src_pmos,
        &dst_nmos,
        &dst_pmos,
        dst_has_bjt,
        dst_vt,
    ) orelse {
        state.setMsg("Remap computation failed (out of memory)");
        w.requestRefresh();
        return;
    };
    defer result.deinit();

    state.storeRemapResult(&result);
    state.setMsgFmt("Remap: {d} devices analyzed", .{state.remap_count});
    w.setStatus("PDKLoader: remap complete — review changes");
    w.requestRefresh();
}

/// Look up VT flavor availability for a known PDK name.
fn vtAvailForPdk(pdk_name: []const u8) remap.VtAvailability {
    if (std.mem.startsWith(u8, pdk_name, "sky130")) return remap.SKY130_VT;
    if (std.mem.startsWith(u8, pdk_name, "gf180"))  return remap.GF180_VT;
    // Unknown PDK — assume only standard VT is available
    return .{};
}

fn onApplyMigration(w: *P.Writer) void {
    if (!state.remap_active or state.remap_count == 0) {
        state.setMsg("No remap to apply");
        w.requestRefresh();
        return;
    }

    // Emit property changes through the ABI command queue.
    // For each remapped MOSFET, push setInstanceProp commands for W and L.
    // TODO: Map device names to instance indices. The ABI setInstanceProp
    // requires an instance index (u32), but we only have device names from
    // the remap result. Once queryInstances returns name→index mapping,
    // replace the name-based lookup with proper index resolution.
    // For now, we emit pushCommand with a serialized property-change payload
    // that the host can parse and apply as an undoable batch edit.
    var applied: u16 = 0;
    for (0..state.remap_count) |i| {
        const e = &state.remap_entries[i];
        if (e.status != .ok) continue;

        switch (e.dev_type) {
            .nmos, .pmos => {
                // Emit W change
                var w_buf: [64]u8 = undefined;
                const w_val = std.fmt.bufPrint(&w_buf, "{e}", .{e.new_w}) catch continue;
                var cmd_buf: [128]u8 = undefined;
                const w_cmd = std.fmt.bufPrint(&cmd_buf, "set_prop:{s}:W:{s}", .{
                    e.nameSlice(), w_val,
                }) catch continue;
                w.pushCommand("pdk_remap", w_cmd);

                // Emit L change
                var l_buf: [64]u8 = undefined;
                const l_val = std.fmt.bufPrint(&l_buf, "{e}", .{e.new_l}) catch continue;
                var l_cmd_buf: [128]u8 = undefined;
                const l_cmd = std.fmt.bufPrint(&l_cmd_buf, "set_prop:{s}:L:{s}", .{
                    e.nameSlice(), l_val,
                }) catch continue;
                w.pushCommand("pdk_remap", l_cmd);
                applied += 1;
            },
            .npn, .pnp => {
                // Emit area change
                var a_buf: [64]u8 = undefined;
                const a_val = std.fmt.bufPrint(&a_buf, "{d:.4}", .{e.new_area}) catch continue;
                var a_cmd_buf: [128]u8 = undefined;
                const a_cmd = std.fmt.bufPrint(&a_cmd_buf, "set_prop:{s}:area:{s}", .{
                    e.nameSlice(), a_val,
                }) catch continue;
                w.pushCommand("pdk_remap", a_cmd);
                applied += 1;
            },
            else => {},
        }
    }

    // Also update Config.toml to the target PDK
    if (state.cfg_path_len > 0) {
        if (writePdkToConfig(state.cfgSlice(), state.entry().config_name)) {
            state.setCurPdk(state.entry().config_name);
        }
    }

    state.setMsgFmt("Applied {d} device changes, pdk -> {s}", .{ applied, state.entry().config_name });
    w.setStatus("PDKLoader: migration applied");
    state.clearRemap();
    w.requestRefresh();
}

// ── Lifecycle ──────────────────────────────────────────────────────────────── //

fn onLoad(w: *P.Writer) void {
    w.registerPanel(.{
        .id      = "pdkloader",
        .title   = "PDK Loader",
        .vim_cmd = "pdk",
        .layout  = .left_sidebar,
        .keybind = 'K',
    });
    if (std.process.getEnvVarOwned(pa, "HOME") catch null) |h| {
        state.setHome(h);
        pa.free(h);
    }
    state.volare_kind = volare.detect(pa, state.homeSlice());
    state.ngspice = lut.detectNgspice(pa);
    w.getState("active_file");
    w.setStatus("PDKLoader ready");
    w.log(.info, "PDKLoader", "loaded");
}

fn onUnload() void {
    state = .{};
}

fn onStateResponse(key: []const u8, val: []const u8, w: *P.Writer) void {
    if (!std.mem.eql(u8, key, "active_file") or val.len == 0) return;
    const start = std.fs.path.dirname(val) orelse ".";
    var path_buf: [512]u8 = undefined;
    const cfg = findConfigToml(start, &path_buf) orelse return;
    state.setCfgPath(cfg);
    if (readPdkFromConfig(state.cfgSlice(), &state.cur_pdk)) |n| {
        state.cur_pdk_len = @intCast(n);
    }
    w.requestRefresh();
}

fn onSchematicChanged(w: *P.Writer) void {
    w.getState("active_file");
}

// ── ABI entry point ────────────────────────────────────────────────────────── //

export fn schemify_process(
    in_ptr:  [*]const u8,
    in_len:  usize,
    out_ptr: [*]u8,
    out_cap: usize,
) callconv(.c) usize {
    var r = P.Reader.init(in_ptr[0..in_len]);
    var w = P.Writer.init(out_ptr[0..out_cap]);

    while (r.next()) |msg| switch (msg) {
        .load              => onLoad(&w),
        .unload            => onUnload(),
        .draw_panel        => drawPanel(&w),
        .button_clicked    => |ev| onButton(ev.widget_id, &w),
        .schematic_changed => onSchematicChanged(&w),
        .state_response    => |ev| onStateResponse(ev.key, ev.val, &w),
        else               => {},
    };

    return if (w.overflow()) std.math.maxInt(usize) else w.pos;
}

export const schemify_plugin: P.Descriptor = .{
    .abi_version = P.ABI_VERSION,
    .name        = "PDKLoader",
    .version_str = "0.2.0",
    .process     = &schemify_process,
};
