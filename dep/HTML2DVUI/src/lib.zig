//! html2dvui — HTML/CSS to dvui draw command bridge.
//!
//! This module provides the public API for parsing HTML+CSS content and
//! producing a list of draw commands that can be consumed by dvui's
//! rendering layer.
//!
//! Uses litehtml (C++ HTML/CSS engine) via a C bridge for real HTML parsing,
//! CSS cascade, and box layout. All draw operations are captured as
//! DrawCommands in a flat array for the renderer to consume.

const std = @import("std");

pub const types = @import("types.zig");
pub const container = @import("container.zig");

pub const Rect = types.Rect;
pub const Color = types.Color;
pub const FontHandle = types.FontHandle;
pub const DrawCommand = types.DrawCommand;
pub const Container = container.Container;

const c = @import("c.zig").bridge;

/// Result of a hit-test (mouse interaction) on a rendered document.
pub const HitResult = struct {
    element_id: []const u8,
    tag: []const u8,
    href: []const u8,
};

/// A parsed and laid-out HTML document.
///
/// Wraps a litehtml document handle via the C bridge. On draw(), litehtml
/// traverses its render tree and fires callbacks into our Container, which
/// collects DrawCommands into a flat array.
///
/// IMPORTANT: The litehtml document is created lazily on the first layout()
/// call. This avoids pointer invalidation from Zig's value semantics — the
/// C bridge stores a pointer to our Container, so the Document must be at
/// its final memory location before we hand that pointer to C.
pub const Document = struct {
    html: []const u8,
    css: []const u8,
    alloc: std.mem.Allocator,
    needs_layout: bool,
    width: f32,
    height: f32,
    container_impl: Container,
    callbacks: c.lh_callbacks_t,
    lh_doc: c.lh_document_t,
    initialized: bool,

    /// Create a new document from HTML and CSS source strings.
    /// The caller retains ownership of the source strings (they must remain
    /// valid for the lifetime of the Document).
    pub fn create(alloc: std.mem.Allocator, html: []const u8, css: []const u8) Document {
        return .{
            .html = html,
            .css = css,
            .alloc = alloc,
            .needs_layout = true,
            .width = 0,
            .height = 0,
            .container_impl = Container.init(alloc),
            .callbacks = std.mem.zeroes(c.lh_callbacks_t),
            .lh_doc = null,
            .initialized = false,
        };
    }

    /// Release resources held by this document.
    pub fn destroy(self: *Document) void {
        if (self.lh_doc != null) {
            c.lh_destroy_document(self.lh_doc);
            self.lh_doc = null;
        }
        self.container_impl.deinit();
        self.* = undefined;
    }

    /// Initialize the litehtml document (called lazily on first use).
    /// At this point `self` is at its final memory location so pointers are stable.
    fn ensureInitialized(self: *Document) void {
        if (self.initialized) return;
        self.initialized = true;

        // Build callbacks pointing at our container (now at stable address)
        self.callbacks = self.container_impl.getCallbacks();

        // Create litehtml document via C bridge
        const html_z = toNullTerminated(self.alloc, self.html);
        const css_z = toNullTerminated(self.alloc, self.css);
        defer if (html_z) |z| self.alloc.free(z);
        defer if (css_z) |z| self.alloc.free(z);

        self.lh_doc = c.lh_create_document(
            if (html_z) |z| z.ptr else "",
            if (css_z) |z| z.ptr else "",
            &self.callbacks,
        );
    }

    /// Lay out the document at the given maximum width.
    /// If width hasn't changed and layout is clean, this is a no-op.
    pub fn layout(self: *Document, max_width: f32) void {
        self.ensureInitialized();
        if (!self.needs_layout and self.width == max_width) return;
        self.width = max_width;
        self.needs_layout = false;

        if (self.lh_doc != null) {
            self.container_impl.viewport.w = max_width;
            const h = c.lh_document_render(self.lh_doc, @intFromFloat(max_width));
            self.height = @floatFromInt(h);
        }
    }

    /// Produce draw commands for the visible portion of the document.
    /// The returned slice is valid until the next call to draw() or destroy().
    pub fn draw(self: *Document, clip: Rect) []const DrawCommand {
        self.ensureInitialized();
        self.container_impl.reset();

        if (self.lh_doc != null) {
            c.lh_document_draw(
                self.lh_doc,
                0,
                0,
                @intFromFloat(clip.x),
                @intFromFloat(clip.y),
                @intFromFloat(clip.w),
                @intFromFloat(clip.h),
            );
        } else {
            // Fallback stub if document creation failed
            self.container_impl.drawBackground(
                .{ .x = 0, .y = 0, .w = self.width, .h = 100 },
                Color.white,
            );
        }

        return self.container_impl.getCommands();
    }

    /// Hit-test at the given coordinates for hover effects.
    /// Returns element info if cursor style changed (indicating interactive element).
    pub fn onMouseMove(self: *Document, x: f32, y: f32) ?HitResult {
        self.ensureInitialized();
        if (self.lh_doc == null) return null;
        self.container_impl.cursor = null;
        _ = c.lh_document_on_mouse_move(self.lh_doc, @intFromFloat(x), @intFromFloat(y));
        if (self.container_impl.cursor) |cur| {
            if (std.mem.eql(u8, cur, "pointer")) {
                return HitResult{
                    .element_id = "",
                    .tag = "a",
                    .href = self.container_impl.last_anchor_url orelse "",
                };
            }
        }
        return null;
    }

    /// Handle a click at the given coordinates.
    pub fn onMouseClick(self: *Document, x: f32, y: f32) ?HitResult {
        self.ensureInitialized();
        if (self.lh_doc == null) return null;
        self.container_impl.last_anchor_url = null;
        _ = c.lh_document_on_lbutton_down(self.lh_doc, @intFromFloat(x), @intFromFloat(y));
        _ = c.lh_document_on_lbutton_up(self.lh_doc, @intFromFloat(x), @intFromFloat(y));
        if (self.container_impl.last_anchor_url) |url| {
            return HitResult{
                .element_id = "",
                .tag = "a",
                .href = url,
            };
        }
        return null;
    }

    /// Notify that the mouse has left the document area.
    pub fn onMouseLeave(self: *Document) void {
        if (self.lh_doc != null) {
            _ = c.lh_document_on_mouse_leave(self.lh_doc);
        }
    }

    /// Get document content height after layout.
    pub fn getHeight(self: *const Document) f32 {
        return self.height;
    }

    /// Mark that the document needs re-layout (e.g. after HTML change).
    pub fn invalidateLayout(self: *Document) void {
        self.needs_layout = true;
    }

    /// Allocate a null-terminated copy for C interop. Returns null on empty input.
    fn toNullTerminated(alloc: std.mem.Allocator, s: []const u8) ?[:0]const u8 {
        if (s.len == 0) return null;
        return alloc.dupeZ(u8, s) catch null;
    }
};

/// High-level render function (convenience).
/// Parses HTML+CSS, lays out at the viewport width, returns draw commands.
///
/// The returned slice is backed by the document's container and is valid
/// until the next call to render(). For persistent documents, use the
/// Document API directly.
pub fn render(alloc: std.mem.Allocator, html: []const u8, css: []const u8, viewport: Rect) []const DrawCommand {
    var doc = Document.create(alloc, html, css);
    defer doc.destroy();
    doc.layout(viewport.w);
    return doc.draw(viewport);
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "Document create and destroy" {
    const alloc = std.testing.allocator;
    var doc = Document.create(alloc, "<p>hello</p>", "");
    defer doc.destroy();
    try std.testing.expect(doc.needs_layout);
}

test "Document layout clears dirty flag" {
    const alloc = std.testing.allocator;
    var doc = Document.create(alloc, "<p>hello</p>", "");
    defer doc.destroy();
    doc.layout(800);
    try std.testing.expect(!doc.needs_layout);
    try std.testing.expectEqual(@as(f32, 800), doc.width);
}

test "Document draw returns commands" {
    const alloc = std.testing.allocator;
    var doc = Document.create(alloc, "<p>hello</p>", "");
    defer doc.destroy();
    doc.layout(600);
    const cmds = doc.draw(.{ .x = 0, .y = 0, .w = 600, .h = 400 });
    try std.testing.expect(cmds.len > 0);
}

test "Empty HTML does not crash" {
    const alloc = std.testing.allocator;
    var doc = Document.create(alloc, "", "");
    defer doc.destroy();
    doc.layout(400);
    _ = doc.draw(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
}
