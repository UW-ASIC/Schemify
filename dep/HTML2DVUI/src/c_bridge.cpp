/// c_bridge.cpp — Extern "C" implementation bridging litehtml v0.9 to Zig callbacks.
///
/// Subclasses litehtml::document_container, forwarding all draw and measurement
/// calls to the C callback struct provided by the Zig side.

#include "c_bridge.h"
#include <litehtml.h>

#include <string>
#include <vector>
#include <cstring>
#include <cctype>

// ── Bridge Container ─────────────────────────────────────────────────────────
// Implements litehtml's document_container interface by delegating to C
// function pointers provided by the Zig side.

class BridgeContainer : public litehtml::document_container {
public:
    const lh_callbacks_t* cb;

    explicit BridgeContainer(const lh_callbacks_t* callbacks) : cb(callbacks) {}

    // ── Font management ──────────────────────────────────────────────────────

    litehtml::uint_ptr create_font(const char* faceName, int size, int weight,
                                   litehtml::font_style italic,
                                   unsigned int decoration,
                                   litehtml::font_metrics* fm) override {
        int font_id = 0;
        int out_height = size;
        int out_ascent = static_cast<int>(size * 0.8f);
        int out_descent = static_cast<int>(size * 0.2f);
        int out_x_height = static_cast<int>(size * 0.5f);
        int out_draw_spaces = 1;

        if (cb && cb->create_font) {
            font_id = cb->create_font(cb->user_data, faceName, size, weight,
                                      (italic == litehtml::font_style_italic) ? 1 : 0,
                                      decoration,
                                      &out_height, &out_ascent, &out_descent,
                                      &out_x_height, &out_draw_spaces);
        }

        if (fm) {
            fm->height = out_height;
            fm->ascent = out_ascent;
            fm->descent = out_descent;
            fm->x_height = out_x_height;
            fm->draw_spaces = (out_draw_spaces != 0);
        }

        return static_cast<litehtml::uint_ptr>(font_id);
    }

    void delete_font(litehtml::uint_ptr hFont) override {
        if (cb && cb->delete_font) {
            cb->delete_font(cb->user_data, static_cast<int>(hFont));
        }
    }

    int text_width(const char* text, litehtml::uint_ptr hFont) override {
        if (cb && cb->text_width) {
            return cb->text_width(cb->user_data, text, static_cast<int>(hFont));
        }
        // Fallback: approximate width
        return static_cast<int>(strlen(text)) * 8;
    }

    void draw_text(litehtml::uint_ptr /*hdc*/, const char* text,
                   litehtml::uint_ptr hFont, litehtml::web_color color,
                   const litehtml::position& pos) override {
        if (cb && cb->draw_text) {
            uint32_t rgba = pack_color(color);
            cb->draw_text(cb->user_data, text, static_cast<int>(hFont),
                         rgba, pos.x, pos.y, pos.width, pos.height);
        }
    }

    int pt_to_px(int pt) const override {
        // 96 DPI: 1pt = 4/3 px
        return static_cast<int>(pt * 96.0 / 72.0);
    }

    int get_default_font_size() const override {
        return 14;
    }

    const char* get_default_font_name() const override {
        return "sans-serif";
    }

    // ── Drawing ──────────────────────────────────────────────────────────────

    void draw_list_marker(litehtml::uint_ptr /*hdc*/,
                          const litehtml::list_marker& marker) override {
        if (cb && cb->draw_list_marker) {
            uint32_t rgba = pack_color(marker.color);
            cb->draw_list_marker(cb->user_data, rgba,
                                marker.pos.x, marker.pos.y,
                                marker.pos.width, marker.pos.height);
        }
    }

    void load_image(const char* /*src*/, const char* /*baseurl*/,
                    bool /*redraw_on_ready*/) override {
        // Images loaded synchronously via data URIs only
    }

    void get_image_size(const char* /*src*/, const char* /*baseurl*/,
                        litehtml::size& sz) override {
        sz.width = 0;
        sz.height = 0;
    }

    void draw_background(litehtml::uint_ptr /*hdc*/,
                         const std::vector<litehtml::background_paint>& bg) override {
        if (!cb) return;

        // Process backgrounds in reverse order (CSS stacking: last = furthest)
        for (int i = static_cast<int>(bg.size()) - 1; i >= 0; i--) {
            const auto& paint = bg[static_cast<size_t>(i)];

            // Draw image if present
            if (!paint.image.empty() && cb->draw_image) {
                cb->draw_image(cb->user_data, paint.image.c_str(),
                              paint.border_box.x, paint.border_box.y,
                              paint.border_box.width, paint.border_box.height);
            }

            // Draw solid color (only the last background has valid color)
            if (i == static_cast<int>(bg.size()) - 1 &&
                paint.color.alpha > 0 && cb->draw_background) {
                uint32_t rgba = pack_color(paint.color);
                cb->draw_background(cb->user_data, rgba,
                                   paint.border_box.x, paint.border_box.y,
                                   paint.border_box.width, paint.border_box.height,
                                   paint.clip_box.x, paint.clip_box.y,
                                   paint.clip_box.width, paint.clip_box.height);
            }
        }
    }

    void draw_borders(litehtml::uint_ptr /*hdc*/,
                      const litehtml::borders& borders,
                      const litehtml::position& draw_pos,
                      bool /*root*/) override {
        if (cb && cb->draw_borders) {
            cb->draw_borders(cb->user_data,
                            pack_color(borders.top.color), borders.top.width,
                            pack_color(borders.right.color), borders.right.width,
                            pack_color(borders.bottom.color), borders.bottom.width,
                            pack_color(borders.left.color), borders.left.width,
                            draw_pos.x, draw_pos.y,
                            draw_pos.width, draw_pos.height);
        }
    }

    // ── Document management ──────────────────────────────────────────────────

    void set_caption(const char* /*caption*/) override {}
    void set_base_url(const char* /*base_url*/) override {}

    void link(const std::shared_ptr<litehtml::document>& /*doc*/,
              const litehtml::element::ptr& /*el*/) override {}

    void on_anchor_click(const char* url,
                         const litehtml::element::ptr& /*el*/) override {
        if (cb && cb->on_anchor_click && url) {
            cb->on_anchor_click(cb->user_data, url);
        }
    }

    void set_cursor(const char* cursor) override {
        if (cb && cb->set_cursor) {
            cb->set_cursor(cb->user_data, cursor);
        }
    }

    void transform_text(litehtml::string& text,
                        litehtml::text_transform tt) override {
        switch (tt) {
            case litehtml::text_transform_capitalize:
                if (!text.empty()) {
                    text[0] = static_cast<char>(toupper(
                        static_cast<unsigned char>(text[0])));
                }
                break;
            case litehtml::text_transform_uppercase:
                for (auto& c : text) {
                    c = static_cast<char>(toupper(static_cast<unsigned char>(c)));
                }
                break;
            case litehtml::text_transform_lowercase:
                for (auto& c : text) {
                    c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
                }
                break;
            default:
                break;
        }
    }

    void import_css(litehtml::string& /*text*/, const litehtml::string& /*url*/,
                    litehtml::string& /*baseurl*/) override {
        // No external CSS imports supported in plugin panels
    }

    void set_clip(const litehtml::position& pos,
                  const litehtml::border_radiuses& /*bdr_radius*/) override {
        if (cb && cb->set_clip) {
            cb->set_clip(cb->user_data, pos.x, pos.y, pos.width, pos.height);
        }
    }

    void del_clip() override {
        if (cb && cb->del_clip) {
            cb->del_clip(cb->user_data);
        }
    }

    void get_client_rect(litehtml::position& client) const override {
        int x = 0, y = 0, w = 800, h = 600;
        if (cb && cb->get_client_rect) {
            cb->get_client_rect(cb->user_data, &x, &y, &w, &h);
        }
        client.x = x;
        client.y = y;
        client.width = w;
        client.height = h;
    }

    litehtml::element::ptr create_element(
        const char* /*tag_name*/,
        const litehtml::string_map& /*attributes*/,
        const std::shared_ptr<litehtml::document>& /*doc*/) override {
        return nullptr;
    }

    void get_media_features(litehtml::media_features& media) const override {
        int x = 0, y = 0, w = 800, h = 600;
        if (cb && cb->get_client_rect) {
            cb->get_client_rect(cb->user_data, &x, &y, &w, &h);
        }
        media.type = litehtml::media_type_screen;
        media.width = w;
        media.height = h;
        media.device_width = w;
        media.device_height = h;
        media.color = 8;
        media.color_index = 256;
        media.monochrome = 0;
        media.resolution = 96;
    }

    void get_language(litehtml::string& language,
                      litehtml::string& culture) const override {
        language = "en";
        culture = "";
    }

private:
    static uint32_t pack_color(const litehtml::web_color& c) {
        return (static_cast<uint32_t>(c.red) << 24) |
               (static_cast<uint32_t>(c.green) << 16) |
               (static_cast<uint32_t>(c.blue) << 8) |
               (static_cast<uint32_t>(c.alpha));
    }
};

// ── Document wrapper ─────────────────────────────────────────────────────────

struct LhDocument {
    BridgeContainer container;
    litehtml::document::ptr doc;

    explicit LhDocument(const lh_callbacks_t* cb) : container(cb) {}
};

// ── Extern "C" API implementation ────────────────────────────────────────────

extern "C" {

lh_document_t lh_create_document(const char* html, const char* user_css,
                                 const lh_callbacks_t* cb) {
    auto* wrapper = new LhDocument(cb);

    const char* html_str = html ? html : "";
    const char* css_str = user_css ? user_css : "";

    // createFromString uses litehtml::master_css by default for base styling
    wrapper->doc = litehtml::document::createFromString(
        html_str, &wrapper->container, litehtml::master_css, css_str);

    return static_cast<lh_document_t>(wrapper);
}

void lh_destroy_document(lh_document_t doc) {
    delete static_cast<LhDocument*>(doc);
}

int lh_document_render(lh_document_t doc, int max_width) {
    auto* wrapper = static_cast<LhDocument*>(doc);
    if (!wrapper || !wrapper->doc) return 0;
    return wrapper->doc->render(max_width);
}

void lh_document_draw(lh_document_t doc, int x, int y,
                      int clip_x, int clip_y, int clip_w, int clip_h) {
    auto* wrapper = static_cast<LhDocument*>(doc);
    if (!wrapper || !wrapper->doc) return;
    litehtml::position clip(clip_x, clip_y, clip_w, clip_h);
    wrapper->doc->draw(0, x, y, &clip);
}

bool lh_document_on_mouse_move(lh_document_t doc, int x, int y) {
    auto* wrapper = static_cast<LhDocument*>(doc);
    if (!wrapper || !wrapper->doc) return false;
    litehtml::position::vector redraw_boxes;
    return wrapper->doc->on_mouse_over(x, y, x, y, redraw_boxes);
}

bool lh_document_on_lbutton_down(lh_document_t doc, int x, int y) {
    auto* wrapper = static_cast<LhDocument*>(doc);
    if (!wrapper || !wrapper->doc) return false;
    litehtml::position::vector redraw_boxes;
    return wrapper->doc->on_lbutton_down(x, y, x, y, redraw_boxes);
}

bool lh_document_on_lbutton_up(lh_document_t doc, int x, int y) {
    auto* wrapper = static_cast<LhDocument*>(doc);
    if (!wrapper || !wrapper->doc) return false;
    litehtml::position::vector redraw_boxes;
    return wrapper->doc->on_lbutton_up(x, y, x, y, redraw_boxes);
}

bool lh_document_on_mouse_leave(lh_document_t doc) {
    auto* wrapper = static_cast<LhDocument*>(doc);
    if (!wrapper || !wrapper->doc) return false;
    litehtml::position::vector redraw_boxes;
    return wrapper->doc->on_mouse_leave(redraw_boxes);
}

int lh_document_height(lh_document_t doc) {
    auto* wrapper = static_cast<LhDocument*>(doc);
    if (!wrapper || !wrapper->doc) return 0;
    return wrapper->doc->height();
}

int lh_document_width(lh_document_t doc) {
    auto* wrapper = static_cast<LhDocument*>(doc);
    if (!wrapper || !wrapper->doc) return 0;
    return wrapper->doc->width();
}

} // extern "C"
