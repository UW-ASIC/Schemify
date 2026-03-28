//! EasyPDKLoader — Schemify native plugin (ABI v6).
//!
//! Scans standard paths for installed PDK variants (sky130, sg13g2,
//! gf180mcu, asap7) and registers a right-sidebar panel.
//!
//! Uses the Framework comptime layer — no manual ABI switch or widget ID math.

const std = @import("std");
const P = @import("PluginIF");
const F = P.Framework;
const volare = @import("volare.zig");

const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

const SLOT_STRIDE = 100;

// ── Constants ─────────────────────────────────────────────────────────────── //

const MAX_PDKS = 8;
const MAX_NAME = 64;
const MAX_PATH = 512;
const MAX_VER = 64;
const MAX_RVERS = 32;
const RVER_LEN = 80;

// ── Slot state ────────────────────────────────────────────────────────────── //

const SlotState = enum(u2) { missing, found, converting, converted };

const PdkSlot = struct {
    name: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    name_len: u8 = 0,
    root: [MAX_PATH]u8 = [_]u8{0} ** MAX_PATH,
    root_len: u16 = 0,
    version: [MAX_VER]u8 = [_]u8{0} ** MAX_VER,
    ver_len: u8 = 0,
    chn_count: u32 = 0,
    has_xschem: bool = false,
    state: SlotState = .missing,
    rvers: [MAX_RVERS][RVER_LEN]u8 = undefined,
    rver_lens: [MAX_RVERS]u8 = [_]u8{0} ** MAX_RVERS,
    rver_count: u8 = 0,
    rvers_loaded: bool = false,
    show_rvers: bool = false,
    sel_ver: [RVER_LEN]u8 = [_]u8{0} ** RVER_LEN,
    sel_ver_len: u8 = 0,

    fn nameSlice(s: *const PdkSlot) []const u8 {
        return s.name[0..s.name_len];
    }
    fn rootSlice(s: *const PdkSlot) []const u8 {
        return s.root[0..s.root_len];
    }
    fn verSlice(s: *const PdkSlot) []const u8 {
        return s.version[0..s.ver_len];
    }
    fn selVerSlice(s: *const PdkSlot) []const u8 {
        return s.sel_ver[0..s.sel_ver_len];
    }
    fn rverAt(s: *const PdkSlot, i: usize) []const u8 {
        return s.rvers[i][0..s.rver_lens[i]];
    }
};

// ── Plugin state ──────────────────────────────────────────────────────────── //

const State = struct {
    slots: [MAX_PDKS]PdkSlot = [_]PdkSlot{.{}} ** MAX_PDKS,
};

var state = State{};

// ── Widget ID layout (per slot, slot index i) ─────────────────────────────── //
//   Base = i * 100
//   Base+0..2  : name label, state badge, row end
//   Base+10..12: version labels, row end
//   Base+20..23: action row + Clone/Convert/Versions buttons
//   Base+50+..  : version item rows/buttons
//   Base+80    : Reload list button
// Global (outside slot range, use high IDs):
//   9000 : Refresh button
//   9001 : Title label
//   9002 : Title separator

const WID_REFRESH = 9000;
const WID_TITLE = 9001;
const WID_TITLE_SEP = 9002;

const OFFSET_CLONE = 21;
const OFFSET_CONVERT = 22;
const OFFSET_TOGGLE_VERS = 23;
const OFFSET_FIRST_VER_USE = 51;
const OFFSET_RELOAD_LIST = 80;

fn wid(slot: usize, offset: u32) u32 {
    return @intCast(slot * SLOT_STRIDE + offset);
}

fn copyTruncated(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len - 1, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

fn setStatusFmt(w: *P.Writer, comptime fmt: []const u8, args: anytype) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "Operation failed";
    w.setStatus(msg);
}

fn resetForRescan(s: *PdkSlot) void {
    const rvers = s.rvers;
    const rver_lens = s.rver_lens;
    const rver_count = s.rver_count;
    const rvers_loaded = s.rvers_loaded;
    const show_rvers = s.show_rvers;
    const sel_ver = s.sel_ver;
    const sel_ver_len = s.sel_ver_len;
    s.* = .{};
    s.rvers = rvers;
    s.rver_lens = rver_lens;
    s.rver_count = rver_count;
    s.rvers_loaded = rvers_loaded;
    s.show_rvers = show_rvers;
    s.sel_ver = sel_ver;
    s.sel_ver_len = sel_ver_len;
}

// ── Discovery ─────────────────────────────────────────────────────────────── //

fn scanIntoSlots(slots: *[MAX_PDKS]PdkSlot, a: Allocator) void {
    for (slots) |*s| resetForRescan(s);

    for (volare.KNOWN_VARIANTS, 0..) |v, i| {
        if (i >= MAX_PDKS) break;
        const s = &slots[i];
        s.name_len = @intCast(copyTruncated(s.name[0..], v));
    }

    var found: List(volare.PdkVariant) = .{};
    defer found.deinit(a);
    volare.discover(a, &found) catch {};

    for (found.items) |pv| {
        const idx = variantIndex(pv.name) orelse continue;
        if (idx >= MAX_PDKS) continue;
        storeVariant(&slots[idx], pv);
    }
}

fn loadPersistedSelections(slots: *[MAX_PDKS]PdkSlot, a: Allocator) void {
    for (slots, 0..) |*s, i| {
        if (i >= volare.KNOWN_VARIANTS.len) break;
        const sel = volare.loadSelectedVersion(a, s.nameSlice()) orelse continue;
        defer a.free(sel);
        s.sel_ver_len = @intCast(copyTruncated(s.sel_ver[0..], sel));
    }
}

fn storeVariant(s: *PdkSlot, pv: volare.PdkVariant) void {
    s.root_len = @intCast(copyTruncated(s.root[0..], pv.root));
    if (pv.version) |ver| {
        s.ver_len = @intCast(copyTruncated(s.version[0..], ver));
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

// ── Panel draw ────────────────────────────────────────────────────────────── //

fn drawPanel(s: *State, w: *P.Writer) void {
    w.label("PDK Loader", WID_TITLE);
    w.separator(WID_TITLE_SEP);

    for (&s.slots, 0..) |*slot, i| {
        if (i >= volare.KNOWN_VARIANTS.len) break;
        drawSlot(w, slot, i);
        w.separator(@intCast(wid(i, 99)));
    }

    w.button("Refresh", WID_REFRESH);
}

fn drawSlot(w: *P.Writer, s: *PdkSlot, slot: usize) void {
    const name = s.nameSlice();

    w.beginRow(wid(slot, 2));
    w.label(name, wid(slot, 0));
    switch (s.state) {
        .missing => w.label("[not found]", wid(slot, 1)),
        .found => w.label("[found]", wid(slot, 1)),
        .converting => w.label("[converting...]", wid(slot, 1)),
        .converted => {
            var buf: [32]u8 = undefined;
            const badge = std.fmt.bufPrint(&buf, "[{d} CHN]", .{s.chn_count}) catch "[done]";
            w.label(badge, wid(slot, 1));
        },
    }
    w.endRow(wid(slot, 2));

    {
        const ver = s.verSlice();
        const sel = s.selVerSlice();
        if (ver.len > 0 or sel.len > 0) {
            w.beginRow(wid(slot, 12));
            if (ver.len > 0) w.label(ver, wid(slot, 10));
            if (sel.len > 0) {
                var buf: [RVER_LEN + 8]u8 = undefined;
                const pinned = std.fmt.bufPrint(&buf, "pin:{s}", .{sel}) catch sel;
                w.label(pinned, wid(slot, 11));
            }
            w.endRow(wid(slot, 12));
        }
    }

    w.beginRow(wid(slot, 20));
    if (s.state == .missing) w.button("Clone", wid(slot, OFFSET_CLONE));
    if (s.has_xschem and (s.state == .found or s.state == .converted)) {
        w.button("Convert", wid(slot, OFFSET_CONVERT));
    }
    const ver_label = if (s.show_rvers) "Versions-" else "Versions+";
    w.button(ver_label, wid(slot, OFFSET_TOGGLE_VERS));
    w.endRow(wid(slot, 20));

    if (s.show_rvers) drawVersionList(w, s, slot);
}

fn drawVersionList(w: *P.Writer, s: *PdkSlot, slot: usize) void {
    if (s.rver_count == 0) {
        w.label("  (no versions — volare ls-remote returned nothing)", wid(slot, 49));
        return;
    }
    for (0..s.rver_count) |i| {
        const ver = s.rverAt(i);
        const is_sel = std.mem.eql(u8, ver, s.selVerSlice());
        w.beginRow(wid(slot, @intCast(50 + i * 2)));
        if (is_sel) {
            var buf: [RVER_LEN + 4]u8 = undefined;
            const marked = std.fmt.bufPrint(&buf, "> {s}", .{ver}) catch ver;
            w.label(marked, wid(slot, @intCast(50 + i * 2)));
        } else {
            w.label(ver, wid(slot, @intCast(50 + i * 2)));
            w.button("Use", wid(slot, @intCast(50 + i * 2 + 1)));
        }
        w.endRow(wid(slot, @intCast(50 + i * 2)));
    }
    w.button("Reload list", wid(slot, OFFSET_RELOAD_LIST));
}

// ── Button routing ────────────────────────────────────────────────────────── //

fn onButton(s: *State, widget_id: u32, w: *P.Writer) void {
    const a = std.heap.page_allocator;

    if (widget_id == WID_REFRESH) {
        scanIntoSlots(&s.slots, a);
        w.requestRefresh();
        return;
    }

    const slot: usize = widget_id / SLOT_STRIDE;
    const offset: u32 = widget_id % SLOT_STRIDE;

    if (slot >= MAX_PDKS or slot >= volare.KNOWN_VARIANTS.len) return;
    const sv = &s.slots[slot];

    if (offset == OFFSET_CLONE) {
        volare.clone(a, sv.nameSlice()) catch |err| {
            setStatusFmt(w, "Clone failed: {}", .{err});
            return;
        };
        scanIntoSlots(&s.slots, a);
        w.requestRefresh();
        return;
    }

    if (offset == OFFSET_CONVERT) {
        const root = sv.rootSlice();
        if (root.len == 0) {
            w.setStatus("Convert: no PDK root path");
            return;
        }
        const out_dir = volare.schemifyDir(a, root) orelse {
            w.setStatus("Convert: cannot determine output directory");
            return;
        };
        defer a.free(out_dir);
        sv.state = .converting;
        const pv = volare.PdkVariant{
            .name = sv.nameSlice(),
            .root = root,
            .version = null,
            .spice_lib = null,
            .has_xschem = sv.has_xschem,
        };
        const n = volare.convertToSchemify(a, pv, out_dir) catch 0;
        sv.chn_count = n;
        sv.state = .converted;
        setStatusFmt(w, "Converted {d} files to {s}", .{ n, out_dir });
        w.requestRefresh();
        return;
    }

    if (offset == OFFSET_TOGGLE_VERS) {
        sv.show_rvers = !sv.show_rvers;
        if (sv.show_rvers and !sv.rvers_loaded) fetchRemoteVersions(a, sv, w);
        w.requestRefresh();
        return;
    }

    if (offset == OFFSET_RELOAD_LIST) {
        sv.rvers_loaded = false;
        fetchRemoteVersions(a, sv, w);
        w.requestRefresh();
        return;
    }

    if (offset >= OFFSET_FIRST_VER_USE and offset < OFFSET_RELOAD_LIST and offset % 2 == 1) {
        const ver_idx = (offset - OFFSET_FIRST_VER_USE) / 2;
        if (ver_idx < sv.rver_count) {
            applyVersion(a, &s.slots, sv, sv.rverAt(ver_idx), w);
        }
        return;
    }
}

fn fetchRemoteVersions(a: Allocator, s: *PdkSlot, w: *P.Writer) void {
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

    if (count == 0) w.setStatus("No remote versions found (is volare installed?)");
}

fn applyVersion(a: Allocator, slots: *[MAX_PDKS]PdkSlot, s: *PdkSlot, ver: []const u8, w: *P.Writer) void {
    volare.saveSelectedVersion(a, s.nameSlice(), ver) catch |err| {
        setStatusFmt(w, "Save version failed: {}", .{err});
        return;
    };

    s.sel_ver_len = @intCast(copyTruncated(s.sel_ver[0..], ver));

    const family = volare.pdkFamily(s.nameSlice());
    const argv = [_][]const u8{ "volare", "enable", "--pdk-family", family, ver };
    var child = std.process.Child.init(&argv, a);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        w.setStatus("Version saved (volare not in PATH — enable manually)");
        w.requestRefresh();
        return;
    };
    _ = child.wait() catch {};

    scanIntoSlots(slots, a);
    setStatusFmt(w, "Enabled {s} @ {s}", .{ s.nameSlice(), ver });
    w.requestRefresh();
}

// ── on_load hook ──────────────────────────────────────────────────────────── //

fn onLoad(s: *State, _: *P.Writer) void {
    const a = std.heap.page_allocator;
    scanIntoSlots(&s.slots, a);
    loadPersistedSelections(&s.slots, a);
}

fn onUnload(s: *State, _: *P.Writer) void {
    for (&s.slots) |*sv| sv.* = .{};
}

// ── Plugin definition ─────────────────────────────────────────────────────── //

const MyPlugin = F.define(State, &state, .{
    .name = "EasyPDKLoader",
    .version = "0.3.0",
    .panels = &.{
        F.PanelSpec{
            .id = "pdk-loader",
            .title = "PDK Loader",
            .vim_cmd = "pdk",
            .layout = .right_sidebar,
            .keybind = 'P',
            .draw_fn = F.wrapDrawFn(State, drawPanel),
            .on_button = F.wrapOnButton(State, onButton),
        },
    },
    .on_load = F.wrapWriterHook(State, onLoad),
    .on_unload = F.wrapWriterHook(State, onUnload),
});

comptime {
    MyPlugin.export_plugin();
}
