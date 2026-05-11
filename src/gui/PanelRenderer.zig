//! Panel Renderer SDK — bridges plugin HTML output to dvui rendering.
//!
//! Wraps html2dvui's Document API with per-panel caching, theme injection,
//! and dirty tracking. Each plugin panel gets its own Document instance that
//! is only re-parsed when the HTML content actually changes (hash-based
//! change detection).
//!
//! Theme integration: call `syncThemeFromPalette()` once per frame (or on
//! theme change) to update CSS variables from the current `theme.Palette`.
//! This ensures panels always match the application color scheme.
//!
//! Usage:
//!   var renderer = PanelRenderer.init(allocator);
//!   defer renderer.deinit();
//!   renderer.syncThemeFromPalette();
//!   renderer.setHtml("my_panel", "<p>Hello</p>");
//!   const cmds = renderer.render("my_panel", 400, 600);

const std = @import("std");
const html2dvui = @import("html2dvui");
const theme = @import("theme_config");
const Allocator = std.mem.Allocator;

pub const Rect = html2dvui.Rect;
pub const Color = html2dvui.Color;
pub const DrawCommand = html2dvui.DrawCommand;
pub const HitResult = html2dvui.HitResult;

// ── Default CSS ──────────────────────────────────────────────────────────────

const default_css =
    \\:root { --bg: #1e1e2e; --fg: #cdd6f4; --accent: #89b4fa; --border: #45475a; }
    \\* { margin: 0; padding: 0; box-sizing: border-box; }
    \\body { font-family: sans-serif; font-size: 14px; color: var(--fg); background: var(--bg); padding: 8px; }
    \\h1, h2, h3 { margin-bottom: 8px; }
    \\p { margin-bottom: 6px; line-height: 1.4; }
    \\button { padding: 4px 12px; background: var(--accent); color: #000; border: none; border-radius: 4px; cursor: pointer; }
    \\button:hover { opacity: 0.8; }
    \\input, select, textarea { padding: 4px 8px; background: var(--bg); color: var(--fg); border: 1px solid var(--border); border-radius: 4px; }
    \\pre, code { font-family: monospace; background: rgba(0,0,0,0.3); padding: 2px 4px; border-radius: 2px; }
    \\pre { padding: 8px; overflow-x: auto; }
    \\table { border-collapse: collapse; width: 100%; }
    \\th, td { padding: 4px 8px; border: 1px solid var(--border); text-align: left; }
    \\.row { display: flex; gap: 8px; }
    \\.col { flex: 1; }
;

// ── PanelState ───────────────────────────────────────────────────────────────

const PanelState = struct {
    document: html2dvui.Document,
    html_hash: u64,
    dirty: bool,
    last_width: f32,
    /// Owned copy of the HTML source (Document references this).
    html_owned: []const u8,
    /// Owned copy of the combined CSS (theme + default).
    css_owned: []const u8,

    fn deinitAndFree(self: *PanelState, alloc: Allocator) void {
        self.document.destroy();
        alloc.free(self.html_owned);
        alloc.free(self.css_owned);
    }
};

// ── PanelRenderer ────────────────────────────────────────────────────────────

pub const PanelRenderer = struct {
    alloc: Allocator,
    panels: std.StringHashMapUnmanaged(PanelState),
    /// User-provided theme CSS (overrides :root vars). Empty string means use defaults.
    theme_css: []const u8,
    /// Combined CSS: theme_css + default_css. Rebuilt on setTheme().
    combined_css: []const u8,

    pub fn init(alloc: Allocator) PanelRenderer {
        const combined = buildCss(alloc, "");
        return .{
            .alloc = alloc,
            .panels = .{},
            .theme_css = "",
            .combined_css = combined,
        };
    }

    pub fn deinit(self: *PanelRenderer) void {
        var it = self.panels.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinitAndFree(self.alloc);
            self.alloc.free(entry.key_ptr.*);
        }
        self.panels.deinit(self.alloc);
        if (self.combined_css.len > 0) {
            self.alloc.free(self.combined_css);
        }
        if (self.theme_css.len > 0) {
            self.alloc.free(self.theme_css);
        }
    }

    /// Update HTML content for a panel. Only re-parses if content changed.
    pub fn setHtml(self: *PanelRenderer, panel_id: []const u8, html: []const u8) void {
        const hash = std.hash.Wyhash.hash(0, html);

        if (self.panels.getPtr(panel_id)) |state| {
            // Content unchanged — skip re-parse.
            if (state.html_hash == hash) return;

            // Content changed — destroy old document, create new one.
            state.document.destroy();
            self.alloc.free(state.html_owned);
            self.alloc.free(state.css_owned);

            const html_copy = self.alloc.dupe(u8, html) catch return;
            const css_copy = self.alloc.dupe(u8, self.combined_css) catch {
                self.alloc.free(html_copy);
                return;
            };

            state.document = html2dvui.Document.create(self.alloc, html_copy, css_copy);
            state.html_owned = html_copy;
            state.css_owned = css_copy;
            state.html_hash = hash;
            state.dirty = true;
        } else {
            // New panel — create fresh state.
            const html_copy = self.alloc.dupe(u8, html) catch return;
            const css_copy = self.alloc.dupe(u8, self.combined_css) catch {
                self.alloc.free(html_copy);
                return;
            };
            const key_copy = self.alloc.dupe(u8, panel_id) catch {
                self.alloc.free(html_copy);
                self.alloc.free(css_copy);
                return;
            };

            const doc = html2dvui.Document.create(self.alloc, html_copy, css_copy);
            const state = PanelState{
                .document = doc,
                .html_hash = hash,
                .dirty = true,
                .last_width = 0,
                .html_owned = html_copy,
                .css_owned = css_copy,
            };
            self.panels.put(self.alloc, key_copy, state) catch {
                self.alloc.free(key_copy);
                self.alloc.free(html_copy);
                self.alloc.free(css_copy);
                return;
            };
        }
    }

    /// Render the panel's HTML into draw commands for the given viewport.
    /// Returns the draw commands to be consumed by the dvui integration.
    pub fn render(self: *PanelRenderer, panel_id: []const u8, viewport_width: f32, viewport_height: f32) []const DrawCommand {
        const state = self.panels.getPtr(panel_id) orelse return &.{};

        // Re-layout if dirty or width changed.
        if (state.dirty or state.last_width != viewport_width) {
            state.document.layout(viewport_width);
            state.last_width = viewport_width;
        }

        const clip = Rect{ .x = 0, .y = 0, .w = viewport_width, .h = viewport_height };
        return state.document.draw(clip);
    }

    /// Forward a mouse event to the panel. Returns hit result if interactive element found.
    pub fn onMouse(self: *PanelRenderer, panel_id: []const u8, x: f32, y: f32, clicked: bool) ?HitResult {
        const state = self.panels.getPtr(panel_id) orelse return null;
        if (clicked) {
            return state.document.onMouseClick(x, y);
        } else {
            return state.document.onMouseMove(x, y);
        }
    }

    /// Inject theme CSS variables before rendering.
    /// The theme string should be a valid CSS block, e.g.:
    ///   ":root { --bg: #000; --fg: #fff; }"
    /// This replaces the default :root variables.
    pub fn setTheme(self: *PanelRenderer, theme_css_arg: []const u8) void {
        // Free old theme if it was allocated.
        if (self.theme_css.len > 0) {
            self.alloc.free(self.theme_css);
        }
        self.theme_css = self.alloc.dupe(u8, theme_css_arg) catch {
            self.theme_css = "";
            return;
        };

        // Rebuild combined CSS.
        if (self.combined_css.len > 0) {
            self.alloc.free(self.combined_css);
        }
        self.combined_css = buildCss(self.alloc, self.theme_css);

        // Mark all panels dirty so they pick up the new theme.
        var it = self.panels.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.dirty = true;
        }
    }

    /// Synchronize panel CSS variables from the current application theme.
    /// Reads `theme.Palette.dark()` (which incorporates plugin overrides) and
    /// maps canvas/UI colors to CSS custom properties. Call once per frame or
    /// when the theme changes.
    ///
    /// This replaces any previous `:root` theme block and marks all panels dirty
    /// only when the generated CSS differs from the current one.
    pub fn syncThemeFromPalette(self: *PanelRenderer) void {
        const pal = theme.Palette.dark();

        // Map palette colors to CSS variables:
        //   --bg      : canvas background
        //   --fg      : symbol line color (readable text)
        //   --accent  : wire color (interactive elements)
        //   --border  : grid dot / subtle borders
        //   --bg-alt  : sidebar background (cards, panels)
        //   --success : wire endpoint (positive feedback)
        //   --warning : selection color (attention)
        var buf: [256]u8 = undefined;
        const css = std.fmt.bufPrint(&buf,
            \\:root {{ --bg: #{x:0>2}{x:0>2}{x:0>2}; --fg: #{x:0>2}{x:0>2}{x:0>2}; --accent: #{x:0>2}{x:0>2}{x:0>2}; --border: #{x:0>2}{x:0>2}{x:0>2}; --bg-alt: #{x:0>2}{x:0>2}{x:0>2}; --success: #{x:0>2}{x:0>2}{x:0>2}; --warning: #{x:0>2}{x:0>2}{x:0>2}; }}
        , .{
            pal.canvas_bg.r,  pal.canvas_bg.g,  pal.canvas_bg.b,
            pal.symbol_line.r, pal.symbol_line.g, pal.symbol_line.b,
            pal.wire.r,        pal.wire.g,        pal.wire.b,
            pal.grid_dot.r,    pal.grid_dot.g,    pal.grid_dot.b,
            pal.inst_body.r,   pal.inst_body.g,   pal.inst_body.b,
            pal.wire_endpoint.r, pal.wire_endpoint.g, pal.wire_endpoint.b,
            pal.wire_sel.r,    pal.wire_sel.g,    pal.wire_sel.b,
        }) catch return;

        // Only update if the generated CSS is different from what we have.
        const hash = std.hash.Wyhash.hash(0, css);
        const current_hash = std.hash.Wyhash.hash(0, self.theme_css);
        if (hash == current_hash) return;

        self.setTheme(css);
    }

    /// Check if a panel needs redraw (HTML changed or layout invalidated).
    pub fn isDirty(self: *PanelRenderer, panel_id: []const u8) bool {
        const state = self.panels.getPtr(panel_id) orelse return false;
        return state.dirty;
    }

    /// Mark panel as clean after rendering.
    pub fn markClean(self: *PanelRenderer, panel_id: []const u8) void {
        const state = self.panels.getPtr(panel_id) orelse return;
        state.dirty = false;
    }

    /// Remove a panel and free its resources.
    pub fn removePanel(self: *PanelRenderer, panel_id: []const u8) void {
        const kv = self.panels.fetchRemove(panel_id) orelse return;
        var state = kv.value;
        state.deinitAndFree(self.alloc);
        self.alloc.free(kv.key);
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    fn buildCss(alloc: Allocator, theme_block: []const u8) []const u8 {
        if (theme_block.len == 0) {
            return alloc.dupe(u8, default_css) catch "";
        }
        // Theme CSS takes precedence — prepend it before the default CSS
        // so that any :root overrides land first in the cascade.
        const total = theme_block.len + 1 + default_css.len;
        const buf = alloc.alloc(u8, total) catch return alloc.dupe(u8, default_css) catch "";
        @memcpy(buf[0..theme_block.len], theme_block);
        buf[theme_block.len] = '\n';
        @memcpy(buf[theme_block.len + 1 ..], default_css);
        return buf;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "PanelRenderer init and deinit" {
    const alloc = std.testing.allocator;
    var renderer = PanelRenderer.init(alloc);
    defer renderer.deinit();

    try std.testing.expect(renderer.combined_css.len > 0);
}

test "PanelRenderer setHtml creates panel" {
    const alloc = std.testing.allocator;
    var renderer = PanelRenderer.init(alloc);
    defer renderer.deinit();

    renderer.setHtml("test_panel", "<p>Hello</p>");
    try std.testing.expect(renderer.isDirty("test_panel"));
}

test "PanelRenderer setHtml deduplicates same content" {
    const alloc = std.testing.allocator;
    var renderer = PanelRenderer.init(alloc);
    defer renderer.deinit();

    renderer.setHtml("test_panel", "<p>Hello</p>");
    renderer.markClean("test_panel");
    try std.testing.expect(!renderer.isDirty("test_panel"));

    // Same content again — should not mark dirty.
    renderer.setHtml("test_panel", "<p>Hello</p>");
    try std.testing.expect(!renderer.isDirty("test_panel"));
}

test "PanelRenderer setHtml marks dirty on change" {
    const alloc = std.testing.allocator;
    var renderer = PanelRenderer.init(alloc);
    defer renderer.deinit();

    renderer.setHtml("test_panel", "<p>Hello</p>");
    renderer.markClean("test_panel");

    renderer.setHtml("test_panel", "<p>World</p>");
    try std.testing.expect(renderer.isDirty("test_panel"));
}

test "PanelRenderer render returns commands" {
    const alloc = std.testing.allocator;
    var renderer = PanelRenderer.init(alloc);
    defer renderer.deinit();

    renderer.setHtml("test_panel", "<p>Hello</p>");
    const cmds = renderer.render("test_panel", 400, 300);
    try std.testing.expect(cmds.len > 0);
}

test "PanelRenderer render for unknown panel returns empty" {
    const alloc = std.testing.allocator;
    var renderer = PanelRenderer.init(alloc);
    defer renderer.deinit();

    const cmds = renderer.render("nonexistent", 400, 300);
    try std.testing.expectEqual(@as(usize, 0), cmds.len);
}

test "PanelRenderer setTheme marks all dirty" {
    const alloc = std.testing.allocator;
    var renderer = PanelRenderer.init(alloc);
    defer renderer.deinit();

    renderer.setHtml("panel_a", "<p>A</p>");
    renderer.setHtml("panel_b", "<p>B</p>");
    renderer.markClean("panel_a");
    renderer.markClean("panel_b");

    renderer.setTheme(":root { --bg: #000; --fg: #fff; }");
    try std.testing.expect(renderer.isDirty("panel_a"));
    try std.testing.expect(renderer.isDirty("panel_b"));
}

test "PanelRenderer removePanel cleans up" {
    const alloc = std.testing.allocator;
    var renderer = PanelRenderer.init(alloc);
    defer renderer.deinit();

    renderer.setHtml("temp", "<p>Temp</p>");
    renderer.removePanel("temp");
    try std.testing.expect(!renderer.isDirty("temp"));
}

test "PanelRenderer onMouse returns null for stub" {
    const alloc = std.testing.allocator;
    var renderer = PanelRenderer.init(alloc);
    defer renderer.deinit();

    renderer.setHtml("panel", "<button id=\"btn\">Click</button>");
    _ = renderer.render("panel", 400, 300);
    try std.testing.expectEqual(@as(?HitResult, null), renderer.onMouse("panel", 10, 10, true));
}

test "PanelRenderer syncThemeFromPalette generates CSS and marks dirty" {
    const alloc = std.testing.allocator;
    var renderer = PanelRenderer.init(alloc);
    defer renderer.deinit();

    renderer.setHtml("panel_x", "<p>X</p>");
    renderer.markClean("panel_x");
    try std.testing.expect(!renderer.isDirty("panel_x"));

    // Sync from palette — should generate a :root block and mark dirty.
    renderer.syncThemeFromPalette();
    try std.testing.expect(renderer.isDirty("panel_x"));
    try std.testing.expect(renderer.theme_css.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, renderer.theme_css, ":root {"));
}

test "PanelRenderer syncThemeFromPalette is idempotent" {
    const alloc = std.testing.allocator;
    var renderer = PanelRenderer.init(alloc);
    defer renderer.deinit();

    renderer.setHtml("panel_y", "<p>Y</p>");

    // First sync — marks dirty.
    renderer.syncThemeFromPalette();
    renderer.markClean("panel_y");

    // Second sync with same palette — should NOT mark dirty again.
    renderer.syncThemeFromPalette();
    try std.testing.expect(!renderer.isDirty("panel_y"));
}

test "PanelRenderer responsive layout re-layouts on width change" {
    const alloc = std.testing.allocator;
    var renderer = PanelRenderer.init(alloc);
    defer renderer.deinit();

    renderer.setHtml("responsive", "<p>Content</p>");

    // First render at width 400.
    _ = renderer.render("responsive", 400, 300);
    renderer.markClean("responsive");

    // Render at different width — should still work (dirty via width change).
    const state = renderer.panels.getPtr("responsive").?;
    try std.testing.expectEqual(@as(f32, 400), state.last_width);

    // Render at new width triggers re-layout automatically inside render().
    _ = renderer.render("responsive", 600, 300);
    try std.testing.expectEqual(@as(f32, 600), state.last_width);
}
