//! State module — re-exports public types and holds the global app singleton.
//!
//! Internal layout:
//!   types.zig     — shared/simple data types
//!   Document.zig  — single open schematic document
//!   AppState.zig  — top-level application state

const std = @import("std");
const core = @import("core");
const toml = @import("core").Toml;
const types = @import("types.zig");

// ── Re-exports (external API surface) ────────────────────────────────────────

pub const AppState = @import("AppState.zig");
pub const Document = @import("Document.zig");
pub const TbIndex = @import("TbIndex.zig");
pub const SubcktSymbol = @import("Document.zig").SubcktSymbol;
pub const SubcktCache = @import("Document.zig").SubcktCache;

pub const ProjectConfig = toml.ProjectConfig;
pub const Point = types.Point;
pub const Instance = core.Instance;
pub const Wire = core.Wire;
pub const Sim = core.SpiceBackend;

pub const Origin = types.Origin;
pub const Viewport = types.Viewport;
pub const Selection = types.Selection;
pub const Clipboard = types.Clipboard;
pub const ClosedTabs = types.ClosedTabs;
pub const Tool = types.Tool;
pub const CommandFlags = types.CommandFlags;
pub const ToolState = types.ToolState;
pub const GuiViewMode = types.GuiViewMode;
pub const PluginPanelLayout = types.PluginPanelLayout;
pub const PanelLoadState = types.PanelLoadState;
pub const PluginKeybind = types.PluginKeybind;
pub const PluginCommand = types.PluginCommand;
pub const PluginPanelMeta = types.PluginPanelMeta;
pub const PluginPanelState = types.PluginPanelState;
pub const CtxMenu = types.CtxMenu;
pub const GuiStateHot = types.GuiStateHot;
pub const GuiStateCold = types.GuiStateCold;
pub const GuiState = types.GuiState;
pub const HierEntry = types.HierEntry;
pub const MarketplaceEntry = types.MarketplaceEntry;
pub const MktStatus = types.MktStatus;
pub const MarketplaceState = types.MarketplaceState;
pub const WinRect = types.WinRect;
pub const CanvasState = types.CanvasState;
pub const PanMode = types.PanMode;
pub const FileExplorerState = types.FileExplorerState;
pub const LibraryBrowserState = types.LibraryBrowserState;
pub const FindDialogState = types.FindDialogState;
pub const PropsDialogState = types.PropsDialogState;
pub const KeybindsDialogState = types.KeybindsDialogState;
pub const MarketplaceWinState = types.MarketplaceWinState;

// ── Global singleton ─────────────────────────────────────────────────────────

pub var app: AppState = undefined;

// ── Tests ────────────────────────────────────────────────────────────────────

test "Viewport zoom clamps" {
    var vp = Viewport{};
    vp.zoomIn();
    try std.testing.expect(vp.zoom > 1.0);
    vp.zoomReset();
    try std.testing.expectEqual(@as(f32, 1.0), vp.zoom);
    vp.zoomOut();
    try std.testing.expect(vp.zoom < 1.0);

    // Clamp high
    vp.zoom = 50.0;
    vp.zoomIn();
    try std.testing.expectEqual(@as(f32, 50.0), vp.zoom);

    // Clamp low
    vp.zoom = 0.01;
    vp.zoomOut();
    try std.testing.expectEqual(@as(f32, 0.01), vp.zoom);
}

test "Selection clear and isEmpty" {
    var sel = Selection{};
    try std.testing.expect(sel.isEmpty());
    sel.clear(); // no-op on empty
    try std.testing.expect(sel.isEmpty());
}

test "Clipboard clear" {
    var cb = Clipboard{};
    cb.clear();
    try std.testing.expectEqual(@as(usize, 0), cb.instances.items.len);
    try std.testing.expectEqual(@as(usize, 0), cb.wires.items.len);
}

test "ClosedTabs ring buffer" {
    var tabs = ClosedTabs{};
    try std.testing.expectEqual(@as(?[]const u8, null), tabs.popLast());

    // Push and pop with testing allocator
    const a = std.testing.allocator;
    tabs.push(a, "a.chn");
    tabs.push(a, "b.chn");
    try std.testing.expectEqual(@as(u8, 2), tabs.len);

    const last = tabs.popLast().?;
    try std.testing.expectEqualStrings("b.chn", last);
    a.free(last);
    try std.testing.expectEqual(@as(u8, 1), tabs.len);

    const first = tabs.popLast().?;
    try std.testing.expectEqualStrings("a.chn", first);
    a.free(first);
    try std.testing.expectEqual(@as(u8, 0), tabs.len);
}

test "Tool label" {
    try std.testing.expectEqualStrings("SELECT", Tool.select.label());
    try std.testing.expectEqualStrings("WIRE", Tool.wire.label());
    try std.testing.expectEqualStrings("TEXT", Tool.text.label());
}

test "CtxMenu defaults" {
    const m = CtxMenu{};
    try std.testing.expect(!m.open);
    try std.testing.expectEqual(@as(i32, -1), m.inst_idx);
    try std.testing.expectEqual(@as(i32, -1), m.wire_idx);
}

test "MarketplaceState deinit on fresh" {
    var ms = MarketplaceState{};
    ms.deinit(std.testing.allocator);
    try std.testing.expect(!ms.visible);
}

test "CommandFlags defaults" {
    const flags = CommandFlags{};
    try std.testing.expect(!flags.fullscreen);
    try std.testing.expect(flags.show_all_layers);
    try std.testing.expectEqual(@as(i16, 1), flags.line_width);
}
