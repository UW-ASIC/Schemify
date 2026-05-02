/**
 * schemify_plugin.hpp — C++17 wrapper (ABI v7)
 *
 * Pulls in the C header then adds:
 *   - Typed Msg variants (std::variant)
 *   - RAII Reader / Writer classes
 *   - Plugin base class with virtual callbacks
 *   - SCHEMIFY_PLUGIN_CPP macro
 *
 * Usage:
 *   #include "lib.h"   // from tools/api/cpp/inc
 *
 *   class MyPlugin : public schemify::Plugin {
 *       void onLoad(schemify::Writer& w) override {
 *           w.registerPanel("hello", "Hello", "hello", SP_LAYOUT_LEFT_SIDEBAR);
 *       }
 *       void onDrawPanel(uint16_t, schemify::Writer& w) override {
 *           w.label("Hello from C++!", 1);
 *       }
 *   };
 *   static MyPlugin g_plugin;
 *   SCHEMIFY_PLUGIN_CPP("my-plugin", "0.1.0", g_plugin)
 */

#pragma once

// ── Pull in C API (extern "C" guards already present) ─────────────────────
// Place the C lib.h (tools/api/c/inc/lib.h) on your include path as well.
#include "schemify_c.h"  // include the C header — rename to lib.h if co-located

#include <cstdint>
#include <cstring>
#include <string_view>
#include <variant>

namespace schemify {

// ── Message variants ──────────────────────────────────────────────────────

struct MsgLoad             {};
struct MsgUnload           {};
struct MsgTick             { float dt; };
struct MsgDrawPanel        { uint16_t panel_id; };
struct MsgButtonClicked    { uint16_t panel_id; uint32_t widget_id; };
struct MsgSliderChanged    { uint16_t panel_id; uint32_t widget_id; float val; };
struct MsgTextChanged      { uint16_t panel_id; uint32_t widget_id; std::string_view text; };
struct MsgCheckboxChanged  { uint16_t panel_id; uint32_t widget_id; bool val; };
struct MsgCommand          { std::string_view tag; std::string_view payload; };
struct MsgStateResponse    { std::string_view key; std::string_view val; };
struct MsgConfigResponse   { std::string_view key; std::string_view val; };
struct MsgSchematicChanged {};
struct MsgSelectionChanged { int32_t instance_idx; };
struct MsgSchematicSnapshot{ uint32_t instance_count; uint32_t wire_count; uint32_t net_count; };
struct MsgInstanceData     { uint32_t idx; std::string_view name; std::string_view symbol; };
struct MsgInstanceProp     { uint32_t idx; std::string_view key;  std::string_view val; };
struct MsgNetData          { uint32_t idx; std::string_view name; };
struct MsgHover            { int32_t world_x; int32_t world_y; uint8_t element_type; int32_t element_idx; std::string_view element_name; };
struct MsgKeyEvent         { uint8_t key; uint8_t mods; uint8_t action; };

using Msg = std::variant<
    MsgLoad, MsgUnload, MsgTick, MsgDrawPanel,
    MsgButtonClicked, MsgSliderChanged, MsgTextChanged, MsgCheckboxChanged,
    MsgCommand, MsgStateResponse, MsgConfigResponse,
    MsgSchematicChanged, MsgSelectionChanged, MsgSchematicSnapshot,
    MsgInstanceData, MsgInstanceProp, MsgNetData,
    MsgHover, MsgKeyEvent
>;

// ── Reader ────────────────────────────────────────────────────────────────

class Reader {
    SpReader r_;
    SpMsg    raw_{};
    static std::string_view sv(SpStr s) noexcept {
        return { reinterpret_cast<const char*>(s.ptr), s.len };
    }
public:
    Reader(const uint8_t* data, size_t len) noexcept
        : r_(sp_reader_init(data, len)) {}

    bool next(Msg& msg) noexcept {
        if (!sp_reader_next(&r_, &raw_)) return false;
        switch (raw_.tag) {
        case SP_TAG_LOAD:              msg = MsgLoad{}; break;
        case SP_TAG_UNLOAD:            msg = MsgUnload{}; break;
        case SP_TAG_TICK:              msg = MsgTick{ raw_.u.tick.dt }; break;
        case SP_TAG_DRAW_PANEL:        msg = MsgDrawPanel{ raw_.u.draw_panel.panel_id }; break;
        case SP_TAG_BUTTON_CLICKED:    msg = MsgButtonClicked{ raw_.u.button_clicked.panel_id,  raw_.u.button_clicked.widget_id }; break;
        case SP_TAG_SLIDER_CHANGED:    msg = MsgSliderChanged{ raw_.u.slider_changed.panel_id,  raw_.u.slider_changed.widget_id, raw_.u.slider_changed.val }; break;
        case SP_TAG_TEXT_CHANGED:      msg = MsgTextChanged{ raw_.u.text_changed.panel_id, raw_.u.text_changed.widget_id, sv(raw_.u.text_changed.text) }; break;
        case SP_TAG_CHECKBOX_CHANGED:  msg = MsgCheckboxChanged{ raw_.u.checkbox_changed.panel_id, raw_.u.checkbox_changed.widget_id, raw_.u.checkbox_changed.val != 0 }; break;
        case SP_TAG_COMMAND:           msg = MsgCommand{ sv(raw_.u.command.tag), sv(raw_.u.command.payload) }; break;
        case SP_TAG_STATE_RESPONSE:    msg = MsgStateResponse{ sv(raw_.u.state_response.key), sv(raw_.u.state_response.val) }; break;
        case SP_TAG_CONFIG_RESPONSE:   msg = MsgConfigResponse{ sv(raw_.u.config_response.key), sv(raw_.u.config_response.val) }; break;
        case SP_TAG_SCHEMATIC_CHANGED: msg = MsgSchematicChanged{}; break;
        case SP_TAG_SELECTION_CHANGED: msg = MsgSelectionChanged{ raw_.u.selection_changed.instance_idx }; break;
        case SP_TAG_SCHEMATIC_SNAPSHOT:msg = MsgSchematicSnapshot{ raw_.u.schematic_snapshot.instance_count, raw_.u.schematic_snapshot.wire_count, raw_.u.schematic_snapshot.net_count }; break;
        case SP_TAG_INSTANCE_DATA:     msg = MsgInstanceData{ raw_.u.instance_data.idx, sv(raw_.u.instance_data.name), sv(raw_.u.instance_data.symbol) }; break;
        case SP_TAG_INSTANCE_PROP:     msg = MsgInstanceProp{ raw_.u.instance_prop.idx, sv(raw_.u.instance_prop.key),  sv(raw_.u.instance_prop.val) }; break;
        case SP_TAG_NET_DATA:          msg = MsgNetData{ raw_.u.net_data.idx, sv(raw_.u.net_data.name) }; break;
        case SP_TAG_HOVER:             msg = MsgHover{ raw_.u.hover.world_x, raw_.u.hover.world_y, raw_.u.hover.element_type, raw_.u.hover.element_idx, sv(raw_.u.hover.element_name) }; break;
        case SP_TAG_KEY_EVENT:         msg = MsgKeyEvent{ raw_.u.key_event.key, raw_.u.key_event.mods, raw_.u.key_event.action }; break;
        default: return false;
        }
        return true;
    }
};

// ── Writer ────────────────────────────────────────────────────────────────

class Writer {
    SpWriter w_;
public:
    Writer(uint8_t* buf, size_t cap) noexcept : w_(sp_writer_init(buf, cap)) {}

    bool   overflow() const noexcept { return sp_writer_overflow(&w_) != 0; }
    size_t pos()      const noexcept { return w_.pos; }

    void setStatus(std::string_view m)  { sp_write_set_status(&w_, m.data(), m.size()); }
    void registerPanel(std::string_view id, std::string_view title,
                       std::string_view vim, uint8_t layout, uint8_t keybind = 0) {
        sp_write_register_panel(&w_, id.data(), id.size(), title.data(), title.size(),
                                vim.data(), vim.size(), layout, keybind);
    }
    void requestRefresh()   { sp_write_request_refresh(&w_); }
    void getState(std::string_view k) { sp_write_get_state(&w_, k.data(), k.size()); }
    void setState(std::string_view k, std::string_view v) { sp_write_set_state(&w_, k.data(), k.size(), v.data(), v.size()); }
    void getConfig(std::string_view id, std::string_view k) { sp_write_get_config(&w_, id.data(), id.size(), k.data(), k.size()); }
    void setConfig(std::string_view id, std::string_view k, std::string_view v) { sp_write_set_config(&w_, id.data(), id.size(), k.data(), k.size(), v.data(), v.size()); }
    void queryInstances() { sp_write_query_instances(&w_); }
    void queryNets()      { sp_write_query_nets(&w_); }
    void placeDevice(std::string_view sym, std::string_view name, int32_t x, int32_t y) {
        sp_write_place_device(&w_, sym.data(), sym.size(), name.data(), name.size(), x, y);
    }
    void addWire(int32_t x0, int32_t y0, int32_t x1, int32_t y1) { sp_write_add_wire(&w_, x0, y0, x1, y1); }
    void setInstanceProp(uint32_t idx, std::string_view k, std::string_view v) {
        sp_write_set_instance_prop(&w_, idx, k.data(), k.size(), v.data(), v.size());
    }
    // UI
    void label(std::string_view t, uint32_t id = 0)   { sp_write_ui_label(&w_, t.data(), t.size(), id); }
    void button(std::string_view t, uint32_t id)        { sp_write_ui_button(&w_, t.data(), t.size(), id); }
    void separator(uint32_t id = 0)                     { sp_write_ui_separator(&w_, id); }
    void beginRow(uint32_t id = 0)                      { sp_write_ui_begin_row(&w_, id); }
    void endRow(uint32_t id = 0)                        { sp_write_ui_end_row(&w_, id); }
    void slider(float val, float min, float max, uint32_t id) { sp_write_ui_slider(&w_, val, min, max, id); }
    void checkbox(bool val, std::string_view t, uint32_t id) { sp_write_ui_checkbox(&w_, val ? 1 : 0, t.data(), t.size(), id); }
    void progress(float f, uint32_t id = 0)             { sp_write_ui_progress(&w_, f, id); }
    void collapsibleStart(std::string_view lbl, bool open, uint32_t id) { sp_write_ui_collapsible_start(&w_, lbl.data(), lbl.size(), open ? 1 : 0, id); }
    void collapsibleEnd(uint32_t id)                    { sp_write_ui_collapsible_end(&w_, id); }
    void tooltip(std::string_view t, uint32_t id = 0)   { sp_write_ui_tooltip(&w_, t.data(), t.size(), id); }
    void subscribeEvents(uint8_t mask)                  { sp_write_subscribe_events(&w_, mask); }
    void consumeEvent()                                 { sp_write_consume_event(&w_); }
    void overrideKeybind(uint8_t key, uint8_t mods, std::string_view cmd) {
        sp_write_override_keybind(&w_, key, mods, cmd.data(), cmd.size());
    }
};

// ── Plugin base class ──────────────────────────────────────────────────────

class Plugin {
public:
    virtual ~Plugin() = default;
    virtual void onLoad(Writer&) {}
    virtual void onUnload(Writer&) {}
    virtual void onTick(float, Writer&) {}
    virtual void onDrawPanel(uint16_t, Writer&) {}
    virtual void onButtonClicked(uint16_t, uint32_t, Writer&) {}
    virtual void onSliderChanged(uint16_t, uint32_t, float, Writer&) {}
    virtual void onCheckboxChanged(uint16_t, uint32_t, bool, Writer&) {}
    virtual void onCommand(std::string_view, std::string_view, Writer&) {}
    virtual void onStateResponse(std::string_view, std::string_view, Writer&) {}
    virtual void onSelectionChanged(int32_t, Writer&) {}
    virtual void onSchematicChanged(Writer&) {}
    virtual void onInstanceData(uint32_t, std::string_view, std::string_view, Writer&) {}
    virtual void onHover(int32_t, int32_t, uint8_t, int32_t, std::string_view, Writer&) {}
    virtual void onKeyEvent(uint8_t, uint8_t, uint8_t, Writer&) {}

    size_t process(const uint8_t* in_ptr, size_t in_len,
                   uint8_t* out_ptr, size_t out_cap) noexcept {
        Reader r(in_ptr, in_len);
        Writer w(out_ptr, out_cap);
        Msg msg;
        while (r.next(msg)) {
            std::visit([&](auto&& m) {
                using T = std::decay_t<decltype(m)>;
                if      constexpr (std::is_same_v<T, MsgLoad>)             onLoad(w);
                else if constexpr (std::is_same_v<T, MsgUnload>)           onUnload(w);
                else if constexpr (std::is_same_v<T, MsgTick>)             onTick(m.dt, w);
                else if constexpr (std::is_same_v<T, MsgDrawPanel>)        onDrawPanel(m.panel_id, w);
                else if constexpr (std::is_same_v<T, MsgButtonClicked>)    onButtonClicked(m.panel_id, m.widget_id, w);
                else if constexpr (std::is_same_v<T, MsgSliderChanged>)    onSliderChanged(m.panel_id, m.widget_id, m.val, w);
                else if constexpr (std::is_same_v<T, MsgCheckboxChanged>)  onCheckboxChanged(m.panel_id, m.widget_id, m.val, w);
                else if constexpr (std::is_same_v<T, MsgCommand>)          onCommand(m.tag, m.payload, w);
                else if constexpr (std::is_same_v<T, MsgStateResponse>)    onStateResponse(m.key, m.val, w);
                else if constexpr (std::is_same_v<T, MsgSelectionChanged>) onSelectionChanged(m.instance_idx, w);
                else if constexpr (std::is_same_v<T, MsgSchematicChanged>) onSchematicChanged(w);
                else if constexpr (std::is_same_v<T, MsgInstanceData>)     onInstanceData(m.idx, m.name, m.symbol, w);
                else if constexpr (std::is_same_v<T, MsgHover>)            onHover(m.world_x, m.world_y, m.element_type, m.element_idx, m.element_name, w);
                else if constexpr (std::is_same_v<T, MsgKeyEvent>)         onKeyEvent(m.key, m.mods, m.action, w);
            }, msg);
        }
        return w.overflow() ? static_cast<size_t>(-1) : w.pos();
    }
};

} // namespace schemify

// ── Registration macro ─────────────────────────────────────────────────────

/**
 * SCHEMIFY_PLUGIN_CPP(name, version, plugin_instance)
 *
 * `plugin_instance` must be a static schemify::Plugin subclass instance.
 *
 * Example:
 *   static MyPlugin g_plugin;
 *   SCHEMIFY_PLUGIN_CPP("my-plugin", "0.1.0", g_plugin)
 */
#define SCHEMIFY_PLUGIN_CPP(name, version, plugin_instance)                       \
    extern "C" {                                                                  \
    static size_t _sp_cpp_process(const uint8_t* ip, size_t il,                  \
                                   uint8_t* op, size_t oc) {                      \
        return (plugin_instance).process(ip, il, op, oc);                        \
    }                                                                             \
    SCHEMIFY_PLUGIN(name, version, _sp_cpp_process)                               \
    }
