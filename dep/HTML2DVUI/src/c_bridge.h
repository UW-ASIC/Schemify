/// c_bridge.h — Extern "C" interface to litehtml v0.9 for use from Zig via @cImport.
///
/// This header defines an opaque-handle API around litehtml's C++ classes,
/// making them callable from Zig without any C++ ABI exposure.

#ifndef LITEHTML_C_BRIDGE_H
#define LITEHTML_C_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── Opaque handle ───────────────────────────────────────────────────────────

typedef void* lh_document_t;

// ── Callback struct (Zig provides these function pointers) ──────────────────

typedef struct {
    void* user_data;

    // Font management
    // face: CSS font-family, size: px, weight: CSS 100-900, italic: bool
    // decoration: bitmask (1=underline, 2=linethrough, 4=overline)
    // Returns: opaque font handle integer
    // Must also fill out: height, ascent, descent, x_height, draw_spaces
    int (*create_font)(void* ud, const char* face, int size, int weight,
                       int italic, unsigned int decoration,
                       int* out_height, int* out_ascent, int* out_descent,
                       int* out_x_height, int* out_draw_spaces);
    void (*delete_font)(void* ud, int font_id);
    int (*text_width)(void* ud, const char* text, int font_id);

    // Drawing
    void (*draw_text)(void* ud, const char* text, int font_id,
                      uint32_t color, int x, int y, int w, int h);
    void (*draw_background)(void* ud, uint32_t color,
                            int x, int y, int w, int h,
                            int clip_x, int clip_y, int clip_w, int clip_h);
    void (*draw_borders)(void* ud, uint32_t color_top, int width_top,
                         uint32_t color_right, int width_right,
                         uint32_t color_bottom, int width_bottom,
                         uint32_t color_left, int width_left,
                         int x, int y, int w, int h);
    void (*draw_image)(void* ud, const char* src,
                       int x, int y, int w, int h);
    void (*draw_list_marker)(void* ud, uint32_t color,
                             int x, int y, int w, int h);

    // Clipping
    void (*set_clip)(void* ud, int x, int y, int w, int h);
    void (*del_clip)(void* ud);

    // Client rect (viewport)
    void (*get_client_rect)(void* ud, int* x, int* y, int* w, int* h);

    // Interaction
    void (*on_anchor_click)(void* ud, const char* url);
    void (*set_cursor)(void* ud, const char* cursor);

} lh_callbacks_t;

// ── Lifecycle ───────────────────────────────────────────────────────────────

/// Create a document from HTML + user CSS, using the given callbacks.
/// Uses litehtml's built-in master CSS for default styling.
/// The callbacks struct must remain valid for the lifetime of the document.
lh_document_t lh_create_document(const char* html, const char* user_css,
                                 const lh_callbacks_t* cb);

/// Destroy a document and release all resources.
void lh_destroy_document(lh_document_t doc);

// ── Operations ──────────────────────────────────────────────────────────────

/// Layout the document at the given max width. Returns document height.
int lh_document_render(lh_document_t doc, int max_width);

/// Draw the document. Triggers container draw callbacks.
/// x, y: offset to draw at. clip_x/y/w/h: visible viewport for culling.
void lh_document_draw(lh_document_t doc, int x, int y,
                      int clip_x, int clip_y, int clip_w, int clip_h);

// ── Hit testing / mouse interaction ─────────────────────────────────────────

/// Notify mouse movement. Returns true if redraw is needed.
bool lh_document_on_mouse_move(lh_document_t doc, int x, int y);

/// Notify left button down. Returns true if redraw is needed.
bool lh_document_on_lbutton_down(lh_document_t doc, int x, int y);

/// Notify left button up. Returns true if redraw is needed.
bool lh_document_on_lbutton_up(lh_document_t doc, int x, int y);

/// Notify mouse has left the document area. Returns true if redraw needed.
bool lh_document_on_mouse_leave(lh_document_t doc);

/// Get the document content height after render.
int lh_document_height(lh_document_t doc);

/// Get the document content width after render.
int lh_document_width(lh_document_t doc);

#ifdef __cplusplus
}
#endif

#endif // LITEHTML_C_BRIDGE_H
