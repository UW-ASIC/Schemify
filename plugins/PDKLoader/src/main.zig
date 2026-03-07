//! EasyPDKLoader — Schemify native plugin.
//!
//! On load, scans standard paths for installed PDK variants (sky130, sg13g2,
//! gf180mcu, asap7) and registers a right-sidebar panel.
//!
//! The panel exposes:
//!   - Status of each known PDK variant (installed / not installed).
//!   - [Clone] button: runs `volare enable <variant>` to download it.
//!   - [Convert] button: converts libs.tech/xschem/ symbols to CHN files.
//!   - [Versions] button: fetches available remote commits via `volare ls-remote`
//!     and lets the user pick one; selection is persisted across restarts.
//!
//! Pure Zig, no C or Python runtime dependency at plugin load time.
//! Cloning and version listing require `volare` in PATH (`pip install volare`).

const std    = @import("std");
const Plugin = @import("PluginIF");
const volare = @import("volare.zig");

const Allocator = std.mem.Allocator;
const List      = std.ArrayListUnmanaged;

// ── Constants ─────────────────────────────────────────────────────────────── //

const MAX_PDKS  = 8;
const MAX_NAME  = 64;
const MAX_PATH  = 512;
const MAX_VER   = 64;
/// Max remote versions shown per PDK.
const MAX_RVERS = 32;
/// Max bytes per remote version string.
const RVER_LEN  = 80;

// ── Slot state ────────────────────────────────────────────────────────────── //

const SlotState = enum(u2) { missing, found, converting, converted };

const PdkSlot = struct {
    // ── identity ──
    name:     [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    name_len: u8           = 0,
    // ── local install info ──
    root:     [MAX_PATH]u8 = [_]u8{0} ** MAX_PATH,
    root_len: u16          = 0,
    version:  [MAX_VER]u8  = [_]u8{0} ** MAX_VER,
    ver_len:  u8           = 0,
    chn_count:  u32        = 0,
    has_xschem: bool       = false,
    state:      SlotState  = .missing,
    // ── remote versions ──
    rvers:      [MAX_RVERS][RVER_LEN]u8 = undefined,
    rver_lens:  [MAX_RVERS]u8           = [_]u8{0} ** MAX_RVERS,
    rver_count: u8                      = 0,
    rvers_loaded: bool                  = false,
    show_rvers:   bool                  = false,
    // ── selected (persisted) version ──
    sel_ver:    [RVER_LEN]u8 = [_]u8{0} ** RVER_LEN,
    sel_ver_len: u8          = 0,

    fn nameSlice(self: *const PdkSlot) []const u8 { return self.name[0..self.name_len]; }
    fn rootSlice(self: *const PdkSlot) []const u8 { return self.root[0..self.root_len]; }
    fn verSlice (self: *const PdkSlot) []const u8 { return self.version[0..self.ver_len]; }
    fn selVerSlice(self: *const PdkSlot) []const u8 { return self.sel_ver[0..self.sel_ver_len]; }
    fn rverAt(self: *const PdkSlot, i: usize) []const u8 { return self.rvers[i][0..self.rver_lens[i]]; }
};

var g_slots: [MAX_PDKS]PdkSlot = [_]PdkSlot{.{}} ** MAX_PDKS;
var g_uid: u32 = 0;

fn uid() u32 { g_uid += 1; return g_uid; }

// ── Discovery ─────────────────────────────────────────────────────────────── //

fn scanIntoSlots(a: Allocator) void {
    for (&g_slots) |*s| {
        // Preserve version list and selection across rescans.
        const rvers      = s.rvers;
        const rver_lens  = s.rver_lens;
        const rver_count = s.rver_count;
        const rvers_loaded = s.rvers_loaded;
        const show_rvers = s.show_rvers;
        const sel_ver    = s.sel_ver;
        const sel_ver_len = s.sel_ver_len;
        s.* = .{};
        s.rvers       = rvers;
        s.rver_lens   = rver_lens;
        s.rver_count  = rver_count;
        s.rvers_loaded = rvers_loaded;
        s.show_rvers  = show_rvers;
        s.sel_ver     = sel_ver;
        s.sel_ver_len = sel_ver_len;
    }

    for (volare.KNOWN_VARIANTS, 0..) |v, i| {
        if (i >= MAX_PDKS) break;
        const s = &g_slots[i];
        const nn = @min(v.len, MAX_NAME - 1);
        @memcpy(s.name[0..nn], v[0..nn]);
        s.name_len = @intCast(nn);
    }

    var found: List(volare.PdkVariant) = .{};
    defer found.deinit(a);
    volare.discover(a, &found) catch {};

    for (found.items) |pv| {
        const idx = variantIndex(pv.name) orelse continue;
        if (idx >= MAX_PDKS) continue;
        storeVariant(&g_slots[idx], pv);
    }
}

fn loadPersistedSelections(a: Allocator) void {
    for (&g_slots, 0..) |*s, i| {
        if (i >= volare.KNOWN_VARIANTS.len) break;
        const sel = volare.loadSelectedVersion(a, s.nameSlice()) orelse continue;
        defer a.free(sel);
        const n = @min(sel.len, RVER_LEN - 1);
        @memcpy(s.sel_ver[0..n], sel[0..n]);
        s.sel_ver_len = @intCast(n);
    }
}

fn storeVariant(s: *PdkSlot, pv: volare.PdkVariant) void {
    const rn = @min(pv.root.len, MAX_PATH - 1);
    @memcpy(s.root[0..rn], pv.root[0..rn]);
    s.root_len = @intCast(rn);
    if (pv.version) |ver| {
        const vn = @min(ver.len, MAX_VER - 1);
        @memcpy(s.version[0..vn], ver[0..vn]);
        s.ver_len = @intCast(vn);
    }
    s.has_xschem = pv.has_xschem;
    s.state = .found;
}

fn variantIndex(name: []const u8) ?usize {
    for (volare.KNOWN_VARIANTS, 0..) |v, i| {
        if (std.mem.eql(u8, v, name)) return i;
    }
    return null;
}

// ── Lifecycle ─────────────────────────────────────────────────────────────── //

fn onLoad() callconv(.c) void {
    const a = Plugin.allocator();
    scanIntoSlots(a);
    loadPersistedSelections(a);
    registerPanel();
}

fn onUnload() callconv(.c) void {
    for (&g_slots) |*s| s.* = .{};
}

fn registerPanel() void {
    const def: Plugin.PanelDef = .{
        .id      = "pdk-loader",
        .title   = "PDK Loader",
        .vim_cmd = "pdk",
        .layout  = .right_sidebar,
        .keybind = 'P',
        .draw_fn = &drawPanel,
    };
    _ = Plugin.registerPanel(&def);
}

// ── Panel draw ────────────────────────────────────────────────────────────── //

fn lbl(ctx: *const Plugin.UiCtx, comptime text: []const u8) void {
    ctx.label(text.ptr, text.len, uid());
}

fn drawPanel(ctx: *const Plugin.UiCtx) callconv(.c) void {
    g_uid = 0;
    const a = Plugin.allocator();

    lbl(ctx, "PDK Loader");
    ctx.separator(uid());

    for (&g_slots, 0..) |*s, i| {
        if (i >= volare.KNOWN_VARIANTS.len) break;
        drawSlot(ctx, a, s);
        ctx.separator(uid());
    }

    if (ctx.button("Refresh".ptr, "Refresh".len, uid())) {
        scanIntoSlots(a);
        Plugin.requestRefresh();
    }
}

fn drawSlot(ctx: *const Plugin.UiCtx, a: Allocator, s: *PdkSlot) void {
    const name = s.nameSlice();

    // Row 1: name + state badge
    ctx.begin_row(uid());
    ctx.label(name.ptr, name.len, uid());
    switch (s.state) {
        .missing    => lbl(ctx, "[not found]"),
        .found      => lbl(ctx, "[found]"),
        .converting => lbl(ctx, "[converting...]"),
        .converted  => {
            var buf: [32]u8 = undefined;
            const badge = std.fmt.bufPrint(&buf, "[{d} CHN]", .{s.chn_count}) catch "[done]";
            ctx.label(badge.ptr, badge.len, uid());
        },
    }
    ctx.end_row(uid());

    // Row 2: installed version + selected pinned version
    {
        const ver = s.verSlice();
        const sel = s.selVerSlice();
        if (ver.len > 0 or sel.len > 0) {
            ctx.begin_row(uid());
            if (ver.len > 0) ctx.label(ver.ptr, ver.len, uid());
            if (sel.len > 0) {
                var buf: [RVER_LEN + 8]u8 = undefined;
                const pinned = std.fmt.bufPrint(&buf, "pin:{s}", .{sel}) catch sel;
                ctx.label(pinned.ptr, pinned.len, uid());
            }
            ctx.end_row(uid());
        }
    }

    // Row 3: action buttons
    ctx.begin_row(uid());
    if (s.state == .missing) drawCloneButton(ctx, a, s);
    if (s.has_xschem and (s.state == .found or s.state == .converted)) {
        drawConvertButton(ctx, a, s);
    }
    drawVersionsToggle(ctx, a, s);
    ctx.end_row(uid());

    // Version list (expanded)
    if (s.show_rvers) drawVersionList(ctx, a, s);
}

fn drawCloneButton(ctx: *const Plugin.UiCtx, a: Allocator, s: *PdkSlot) void {
    if (ctx.button("Clone".ptr, "Clone".len, uid())) {
        volare.clone(a, s.nameSlice()) catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Clone failed: {}", .{err}) catch "Clone failed";
            Plugin.setStatus(msg);
            return;
        };
        scanIntoSlots(a);
        Plugin.requestRefresh();
    }
}

fn drawConvertButton(ctx: *const Plugin.UiCtx, a: Allocator, s: *PdkSlot) void {
    if (!ctx.button("Convert".ptr, "Convert".len, uid())) return;
    const out_dir = volare.chnOutDir(a, s.nameSlice()) orelse {
        Plugin.setStatus("Convert: cannot determine output directory");
        return;
    };
    defer a.free(out_dir);
    s.state = .converting;
    const pv = volare.PdkVariant{
        .name = s.nameSlice(), .root = s.rootSlice(),
        .version = null, .spice_lib = null, .has_xschem = s.has_xschem,
    };
    const n = volare.convertToSchemify(a, pv, out_dir) catch 0;
    s.chn_count = n;
    s.state = .converted;
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Converted {d} files to {s}", .{ n, out_dir }) catch "Converted";
    Plugin.setStatus(msg);
    Plugin.requestRefresh();
}

// ── Version list ──────────────────────────────────────────────────────────── //

fn drawVersionsToggle(ctx: *const Plugin.UiCtx, a: Allocator, s: *PdkSlot) void {
    const label_str = if (s.show_rvers) "Versions-" else "Versions+";
    if (!ctx.button(label_str.ptr, label_str.len, uid())) return;

    s.show_rvers = !s.show_rvers;
    if (s.show_rvers and !s.rvers_loaded) fetchRemoteVersions(a, s);
}

fn fetchRemoteVersions(a: Allocator, s: *PdkSlot) void {
    s.rver_count = 0;
    s.rvers_loaded = true;

    var list: List([]const u8) = .{};
    defer {
        for (list.items) |v| a.free(v);
        list.deinit(a);
    }
    volare.listRemoteVersions(a, s.nameSlice(), &list) catch {};

    const count = @min(list.items.len, MAX_RVERS);
    for (list.items[0..count], 0..count) |ver, i| {
        const n = @min(ver.len, RVER_LEN - 1);
        @memcpy(s.rvers[i][0..n], ver[0..n]);
        s.rver_lens[i] = @intCast(n);
    }
    s.rver_count = @intCast(count);

    if (count == 0) Plugin.setStatus("No remote versions found (is volare installed?)");
}

fn drawVersionList(ctx: *const Plugin.UiCtx, a: Allocator, s: *PdkSlot) void {
    if (s.rver_count == 0) {
        lbl(ctx, "  (no versions — volare ls-remote returned nothing)");
        return;
    }

    for (0..s.rver_count) |i| {
        const ver = s.rverAt(i);
        const is_sel = std.mem.eql(u8, ver, s.selVerSlice());

        ctx.begin_row(uid());

        // Version label — mark the currently pinned one
        if (is_sel) {
            var buf: [RVER_LEN + 4]u8 = undefined;
            const marked = std.fmt.bufPrint(&buf, "> {s}", .{ver}) catch ver;
            ctx.label(marked.ptr, marked.len, uid());
        } else {
            ctx.label(ver.ptr, ver.len, uid());
        }

        // "Use" button — sets selection and persists
        if (!is_sel and ctx.button("Use".ptr, "Use".len, uid())) {
            applyVersion(a, s, ver);
        }

        ctx.end_row(uid());
    }

    // "Refresh list" button
    if (ctx.button("Reload list".ptr, "Reload list".len, uid())) {
        s.rvers_loaded = false;
        fetchRemoteVersions(a, s);
        Plugin.requestRefresh();
    }
}

fn applyVersion(a: Allocator, s: *PdkSlot, ver: []const u8) void {
    // Persist selection
    volare.saveSelectedVersion(a, s.nameSlice(), ver) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Save version failed: {}", .{err}) catch "Save failed";
        Plugin.setStatus(msg);
        return;
    };

    // Store in slot
    const n = @min(ver.len, RVER_LEN - 1);
    @memcpy(s.sel_ver[0..n], ver[0..n]);
    s.sel_ver_len = @intCast(n);

    // Attempt to enable the selected version via volare
    const family = volare.pdkFamily(s.nameSlice());
    const argv = [_][]const u8{ "volare", "enable", "--pdk-family", family, ver };
    var child = std.process.Child.init(&argv, a);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        Plugin.setStatus("Version saved (volare not in PATH — enable manually)");
        Plugin.requestRefresh();
        return;
    };
    _ = child.wait() catch {};

    scanIntoSlots(a);
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Enabled {s} @ {s}", .{ s.nameSlice(), ver }) catch "Enabled";
    Plugin.setStatus(msg);
    Plugin.requestRefresh();
}

// ── Plugin descriptor ─────────────────────────────────────────────────────── //

export const schemify_plugin: Plugin.Descriptor = .{
    .abi_version = Plugin.ABI_VERSION,
    .name        = "EasyPDKLoader",
    .version_str = "0.3.0",
    .set_ctx     = Plugin.setCtx,
    .on_load     = &onLoad,
    .on_unload   = &onUnload,
    .on_tick     = null,
    .on_command  = null,
};
