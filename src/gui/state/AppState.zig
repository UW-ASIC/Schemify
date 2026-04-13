//! Top-level application state.
//! One `pub` struct per file — AppState aggregates all sub-states.

const std = @import("std");
const toml = @import("core").Toml;
const cmd = @import("commands");
const core = @import("core");
const utility = @import("utility");
const types = @import("types.zig");
const Document = @import("Document.zig");

const ToolState = types.ToolState;
const GuiState = types.GuiState;
const Clipboard = types.Clipboard;
const ClosedTabs = types.ClosedTabs;
const CommandFlags = types.CommandFlags;
const HierEntry = types.HierEntry;
const PluginPanelMeta = types.PluginPanelMeta;
const PluginPanelState = types.PluginPanelState;
const PluginPanelLayout = types.PluginPanelLayout;
const ProjectConfig = toml.ProjectConfig;

const TbIndex = @import("TbIndex.zig");

const AppState = @This();

// ── Fields (ordered by alignment: 8-byte, 4-byte, 1-byte) ───────────────────

// Hot: read every frame — 8-byte aligned
gpa: std.heap.GeneralPurposeAllocator(.{}),
documents: std.ArrayListUnmanaged(Document) = .{},
gui: GuiState = .{},
tool: ToolState = .{},
status_msg: []const u8 = "Ready",

// Warm: project config and command processing — 8-byte aligned
project_dir: []const u8 = ".",
config: ProjectConfig = undefined,
queue: cmd.CommandQueue = .{},
clipboard: Clipboard = .{},
highlighted_nets: std.DynamicBitSetUnmanaged = .{},
log: utility.Logger = undefined,

// Cold: infrequently-accessed — 8-byte aligned
tb_index: TbIndex = undefined,
hierarchy_stack: std.ArrayListUnmanaged(HierEntry) = .{},
plugin_runtime_ptr: ?*anyopaque = null,
last_netlist: []u8 = &.{},

// Hot: 4-byte aligned
canvas_w: f32 = 800.0,
canvas_h: f32 = 600.0,
active_idx: u32 = 0,

// Warm: 4-byte aligned
cmd_flags: CommandFlags = .{},

// Cold: 4-byte / 2-byte / 1-byte
last_netlist_len: usize = 0,
closed_tabs: ClosedTabs = .{},

// Hot: 1-byte arrays
status_buf: [256]u8 = [_]u8{0} ** 256,

// Hot/Warm: 1-byte
show_grid: bool = true,

// Cold: 1-byte
plugin_refresh_requested: bool = false,
open_library_browser: bool = false,
rescan_library_browser: bool = false,
open_file_explorer: bool = false,

// ── Lifecycle ────────────────────────────────────────────────────────────────

pub fn init(self: *AppState, project_dir: []const u8) void {
    self.* = .{ .gpa = .{}, .project_dir = project_dir };
    self.config = ProjectConfig.init(self.gpa.allocator());
    self.tb_index = TbIndex.init(self.gpa.allocator());
}

pub fn deinit(self: *AppState) void {
    const a = self.gpa.allocator();
    for (self.documents.items) |*doc| doc.deinit();
    self.documents.deinit(a);
    self.hierarchy_stack.deinit(a);
    self.gui.cold.plugin_panels_meta.deinit(a);
    self.gui.cold.plugin_panels_state.deinit(a);
    self.gui.cold.plugin_keybinds.deinit(a);
    self.gui.cold.plugin_commands.deinit(a);
    self.gui.cold.marketplace.deinit(a);
    self.clipboard.instances.deinit(a);
    self.clipboard.wires.deinit(a);
    self.highlighted_nets.deinit(a);
    if (self.last_netlist.len > 0) a.free(self.last_netlist);
    self.tb_index.deinit();
    self.config.deinit();
    self.queue.deinit(a);
    _ = self.gpa.deinit();
}

pub fn allocator(self: *AppState) std.mem.Allocator {
    return self.gpa.allocator();
}

// ── Config / Logger ──────────────────────────────────────────────────────────

pub fn loadConfig(self: *AppState) !void {
    self.config = ProjectConfig.parseFromPath(self.allocator(), self.project_dir) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    self.buildTbIndex();
}

fn buildTbIndex(self: *AppState) void {
    const a = self.allocator();
    for (self.config.paths.chn_tb) |tb_path| {
        const data = utility.Vfs.readAlloc(a, tb_path) catch continue;
        defer a.free(data);
        var sch = core.Schemify.readFile(data, a, null);
        defer sch.deinit();
        self.tb_index.indexTb(tb_path, &sch);
    }
}

pub fn initLogger(self: *AppState) void {
    self.log = utility.Logger.init(.info);
}

// ── Document management ──────────────────────────────────────────────────────

pub fn active(self: *AppState) ?*Document {
    if (self.documents.items.len == 0) return null;
    const idx = @min(self.active_idx, @as(u32, @intCast(self.documents.items.len - 1)));
    return &self.documents.items[idx];
}

pub fn newFile(self: *AppState, name: []const u8) !void {
    const a = self.allocator();
    const owned_name = try a.dupe(u8, name);
    errdefer a.free(owned_name);
    try self.documents.append(a, .{
        .alloc = a,
        .name = owned_name,
        .sch = core.Schemify.init(a),
    });
    self.active_idx = @intCast(self.documents.items.len - 1);
}

pub fn openPath(self: *AppState, path: []const u8) !void {
    const a = self.allocator();
    const doc = try Document.open(a, &self.log, path);
    try self.documents.append(a, doc);
    self.active_idx = @intCast(self.documents.items.len - 1);
    const stored = &self.documents.items[self.documents.items.len - 1];
    if (stored.sch.stype == .testbench) {
        if (stored.origin == .chn_file) self.tb_index.indexTb(stored.origin.chn_file, &stored.sch);
    }
}

pub fn saveActiveTo(self: *AppState, path: []const u8) !void {
    const doc = self.active() orelse return;
    if (doc.sch.stype == .testbench) {
        if (doc.origin == .chn_file) self.tb_index.deindexTb(doc.origin.chn_file);
    }
    const out = doc.sch.writeFile(self.allocator(), &self.log) orelse return;
    try utility.Vfs.writeAll(path, out);
    doc.origin = .{ .chn_file = path };
    doc.dirty = false;
    if (doc.sch.stype == .testbench) self.tb_index.indexTb(path, &doc.sch);
}

// ── Status ───────────────────────────────────────────────────────────────────

pub fn setStatus(self: *AppState, msg: []const u8) void {
    self.status_msg = msg;
}

/// Copy `msg` into an owned buffer so the slice doesn't dangle.
/// Use this when the source data may be freed (e.g. plugin output buffers).
pub fn setStatusBuf(self: *AppState, msg: []const u8) void {
    const n = @min(msg.len, self.status_buf.len);
    @memcpy(self.status_buf[0..n], msg[0..n]);
    self.status_msg = self.status_buf[0..n];
}

/// Alias for setStatus -- kept for call-site clarity (error vs info).
pub const setStatusErr = setStatus;

// ── Selection helpers ────────────────────────────────────────────────────────

pub fn selectAll(self: *AppState) void {
    const doc = self.active() orelse return;
    const a = self.allocator();
    doc.selection.instances.resize(a, doc.sch.instances.len, true) catch return;
    doc.selection.wires.resize(a, doc.sch.wires.len, true) catch return;
    doc.selection.instances.setAll();
    doc.selection.wires.setAll();
}

// ── Plugin helpers ───────────────────────────────────────────────────────────

pub fn clearPluginCommands(self: *AppState) void {
    self.gui.cold.plugin_commands.clearRetainingCapacity();
    self.gui.cold.plugin_keybinds.clearRetainingCapacity();
    self.gui.cold.key_to_panel = [_]i8{-1} ** 256;
}

pub fn registerPluginPanelEx(self: *AppState, id: []const u8, title: []const u8, vim_cmd: []const u8, layout: PluginPanelLayout, keybind: u8, panel_id: u16) u16 {
    const a = self.allocator();
    self.gui.cold.plugin_panels_meta.append(a, .{ .id = id, .title = title, .vim_cmd = vim_cmd }) catch return 0;
    self.gui.cold.plugin_panels_state.append(a, .{ .layout = layout, .keybind = keybind, .panel_id = panel_id }) catch {
        _ = self.gui.cold.plugin_panels_meta.pop();
        return 0;
    };
    if (keybind > 0) self.gui.cold.key_to_panel[keybind] = @intCast(self.gui.cold.plugin_panels_state.items.len - 1);
    return panel_id;
}

pub fn registerPluginCommand(self: *AppState, id: []const u8, display_name: []const u8, description: []const u8) void {
    const a = self.allocator();
    self.gui.cold.plugin_commands.append(a, .{
        .id = id,
        .display_name = display_name,
        .description = description,
    }) catch {};
}

pub fn setActiveIdx(self: *AppState, idx: u32) void {
    if (idx == self.active_idx) return;
    // selection now lives on Document (Phase 4); this only needed during transition
    self.active_idx = idx;
}
