/**
 * schemify_plugin.h — C99 SDK for Schemify plugins (ABI v6)
 *
 * Header-only library. No shim files needed.
 *
 * Usage:
 *   #include "schemify_plugin.h"
 *
 *   static size_t my_process(const uint8_t* in_ptr, size_t in_len,
 *                            uint8_t* out_ptr, size_t out_cap) {
 *       SpReader r = sp_reader_init(in_ptr, in_len);
 *       SpWriter w = sp_writer_init(out_ptr, out_cap);
 *       SpMsg msg;
 *       while (sp_reader_next(&r, &msg)) {
 *           switch (msg.tag) {
 *           case SP_TAG_LOAD:
 *               sp_write_register_panel(&w, "hello", 5, "Hello", 5, "hello", 5,
 *                                       SP_LAYOUT_LEFT_SIDEBAR, 0);
 *               break;
 *           case SP_TAG_DRAW_PANEL:
 *               sp_write_ui_label(&w, "Hello World", 11, 0);
 *               break;
 *           default: break;
 *           }
 *       }
 *       return sp_writer_overflow(&w) ? (size_t)-1 : w.pos;
 *   }
 *
 *   SCHEMIFY_PLUGIN("my-plugin", "0.1.0", my_process)
 *
 * Works identically compiled to .so (native) and .wasm (WASM).
 */

#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Message tags — Host → Plugin (0x01–0x7F) ─────────────────────────────── */

#define SP_TAG_LOAD              0x01
#define SP_TAG_UNLOAD            0x02
#define SP_TAG_TICK              0x03
#define SP_TAG_DRAW_PANEL        0x04
#define SP_TAG_BUTTON_CLICKED    0x05
#define SP_TAG_SLIDER_CHANGED    0x06
#define SP_TAG_TEXT_CHANGED      0x07
#define SP_TAG_CHECKBOX_CHANGED  0x08
#define SP_TAG_COMMAND           0x09
#define SP_TAG_STATE_RESPONSE    0x0A
#define SP_TAG_CONFIG_RESPONSE   0x0B
#define SP_TAG_SCHEMATIC_CHANGED 0x0C
#define SP_TAG_SELECTION_CHANGED 0x0D
#define SP_TAG_SCHEMATIC_SNAPSHOT 0x0E
#define SP_TAG_INSTANCE_DATA     0x0F
#define SP_TAG_INSTANCE_PROP     0x10
#define SP_TAG_NET_DATA          0x11

/* ── Message tags — Plugin → Host commands (0x80–0x9F) ──────────────────── */

#define SP_TAG_REGISTER_PANEL    0x80
#define SP_TAG_SET_STATUS        0x81
#define SP_TAG_LOG               0x82
#define SP_TAG_PUSH_COMMAND      0x83
#define SP_TAG_SET_STATE         0x84
#define SP_TAG_GET_STATE         0x85
#define SP_TAG_SET_CONFIG        0x86
#define SP_TAG_GET_CONFIG        0x87
#define SP_TAG_REQUEST_REFRESH   0x88
#define SP_TAG_REGISTER_KEYBIND  0x89
#define SP_TAG_PLACE_DEVICE      0x8A
#define SP_TAG_ADD_WIRE          0x8B
#define SP_TAG_SET_INSTANCE_PROP 0x8C
#define SP_TAG_QUERY_INSTANCES   0x8D
#define SP_TAG_QUERY_NETS        0x8E

/* ── Message tags — Plugin → Host UI widgets (0xA0–0xBF) ─────────────────── */

#define SP_TAG_UI_LABEL              0xA0
#define SP_TAG_UI_BUTTON             0xA1
#define SP_TAG_UI_SEPARATOR          0xA2
#define SP_TAG_UI_BEGIN_ROW          0xA3
#define SP_TAG_UI_END_ROW            0xA4
#define SP_TAG_UI_SLIDER             0xA5
#define SP_TAG_UI_CHECKBOX           0xA6
#define SP_TAG_UI_PROGRESS           0xA7
#define SP_TAG_UI_PLOT               0xA8
#define SP_TAG_UI_IMAGE              0xA9
#define SP_TAG_UI_COLLAPSIBLE_START  0xAA
#define SP_TAG_UI_COLLAPSIBLE_END    0xAB

/* ── Enums ────────────────────────────────────────────────────────────────── */

typedef enum {
    SP_LAYOUT_OVERLAY       = 0,
    SP_LAYOUT_LEFT_SIDEBAR  = 1,
    SP_LAYOUT_RIGHT_SIDEBAR = 2,
    SP_LAYOUT_BOTTOM_BAR    = 3,
} SpPanelLayout;

typedef enum {
    SP_LOG_INFO = 0,
    SP_LOG_WARN = 1,
    SP_LOG_ERR  = 2,
} SpLogLevel;

/* ── String view (zero-copy into input buffer) ────────────────────────────── */

typedef struct {
    const uint8_t* ptr;
    uint16_t       len;
} SpStr;

/**
 * Copy SpStr into a null-terminated C string.
 * Writes at most (buf_len - 1) bytes and appends NUL.
 * Returns buf for convenience.
 */
static inline char* sp_str_cstr(SpStr s, char* buf, size_t buf_len) {
    size_t n = (s.len < (uint16_t)(buf_len - 1)) ? s.len : (buf_len - 1);
    if (n && s.ptr) memcpy(buf, s.ptr, n);
    buf[n] = '\0';
    return buf;
}

/* ── Decoded message structs ──────────────────────────────────────────────── */

typedef struct { float    dt;                                             } SpMsgTick;
typedef struct { uint16_t panel_id;                                       } SpMsgDrawPanel;
typedef struct { uint16_t panel_id; uint32_t widget_id;                   } SpMsgButtonClicked;
typedef struct { uint16_t panel_id; uint32_t widget_id; float val;        } SpMsgSliderChanged;
typedef struct { uint16_t panel_id; uint32_t widget_id; SpStr text;       } SpMsgTextChanged;
typedef struct { uint16_t panel_id; uint32_t widget_id; uint8_t val;      } SpMsgCheckboxChanged;
typedef struct { SpStr tag; SpStr payload;                                 } SpMsgCommand;
typedef struct { SpStr key; SpStr val;                                     } SpMsgStateResponse;
typedef struct { SpStr key; SpStr val;                                     } SpMsgConfigResponse;
typedef struct { int32_t instance_idx;                                    } SpMsgSelectionChanged;
typedef struct { uint32_t instance_count; uint32_t wire_count; uint32_t net_count; } SpMsgSchematicSnapshot;
typedef struct { uint32_t idx; SpStr name; SpStr symbol;                  } SpMsgInstanceData;
typedef struct { uint32_t idx; SpStr key; SpStr val;                      } SpMsgInstanceProp;
typedef struct { uint32_t idx; SpStr name;                                } SpMsgNetData;

typedef struct {
    uint8_t tag;
    union {
        SpMsgTick              tick;
        SpMsgDrawPanel         draw_panel;
        SpMsgButtonClicked     button_clicked;
        SpMsgSliderChanged     slider_changed;
        SpMsgTextChanged       text_changed;
        SpMsgCheckboxChanged   checkbox_changed;
        SpMsgCommand           command;
        SpMsgStateResponse     state_response;
        SpMsgConfigResponse    config_response;
        SpMsgSelectionChanged  selection_changed;
        SpMsgSchematicSnapshot schematic_snapshot;
        SpMsgInstanceData      instance_data;
        SpMsgInstanceProp      instance_prop;
        SpMsgNetData           net_data;
    } u;
} SpMsg;

/* ── Reader ───────────────────────────────────────────────────────────────── */

typedef struct {
    const uint8_t* buf;
    size_t         len;
    size_t         pos;
} SpReader;

static inline SpReader sp_reader_init(const uint8_t* buf, size_t len) {
    SpReader r;
    r.buf = buf;
    r.len = len;
    r.pos = 0;
    return r;
}

/* ── Internal LE read helpers ─────────────────────────────────────────────── */

static inline uint16_t _sp_rd_u16(const uint8_t* b) {
    return (uint16_t)((uint32_t)b[0] | ((uint32_t)b[1] << 8));
}

static inline uint32_t _sp_rd_u32(const uint8_t* b) {
    return (uint32_t)b[0]
         | ((uint32_t)b[1] << 8)
         | ((uint32_t)b[2] << 16)
         | ((uint32_t)b[3] << 24);
}

static inline int32_t _sp_rd_i32(const uint8_t* b) {
    return (int32_t)_sp_rd_u32(b);
}

static inline float _sp_rd_f32(const uint8_t* b) {
    uint32_t bits = _sp_rd_u32(b);
    float    val;
    memcpy(&val, &bits, 4);
    return val;
}

/* Read a length-prefixed string (u16 len + N bytes) from buf[off..].
 * Advances *off by 2+len.  Returns 1 on success, 0 if out-of-bounds. */
static inline int _sp_rd_str(const uint8_t* buf, size_t payload_end,
                             size_t* off, SpStr* out) {
    if (*off + 2 > payload_end) return 0;
    uint16_t slen = _sp_rd_u16(buf + *off);
    *off += 2;
    if (*off + slen > payload_end) return 0;
    out->ptr = buf + *off;
    out->len = slen;
    *off += slen;
    return 1;
}

/**
 * Decode the next message from the reader into *msg.
 *
 * Returns 1 if a message was successfully decoded.
 * Returns 0 at end-of-buffer or on malformed input.
 * Unknown tags are skipped transparently.
 */
static int sp_reader_next(SpReader* r, SpMsg* msg) {
    for (;;) {
        /* Need at least 3 bytes for header (tag + u16 payload_sz). */
        if (r->pos + 3 > r->len) return 0;

        uint8_t  tag        = r->buf[r->pos];
        uint16_t payload_sz = _sp_rd_u16(r->buf + r->pos + 1);
        size_t   hdr_end    = r->pos + 3;
        size_t   payload_end = hdr_end + payload_sz;

        /* Payload must fit in buffer. */
        if (payload_end > r->len) return 0;

        /* Pointer into payload for field-by-field decoding. */
        const uint8_t* p = r->buf + hdr_end;
        size_t off = 0; /* offset relative to p */

#define _SP_NEED(n) do { if (off + (n) > payload_sz) goto skip; } while (0)

        msg->tag = tag;

        switch (tag) {
        /* ── Host → Plugin ─────────────────────────────────────────────── */
        case SP_TAG_LOAD:
        case SP_TAG_UNLOAD:
        case SP_TAG_SCHEMATIC_CHANGED:
            /* No payload fields. */
            r->pos = payload_end;
            return 1;

        case SP_TAG_TICK:
            _SP_NEED(4);
            msg->u.tick.dt = _sp_rd_f32(p + off);
            r->pos = payload_end;
            return 1;

        case SP_TAG_DRAW_PANEL:
            _SP_NEED(2);
            msg->u.draw_panel.panel_id = _sp_rd_u16(p + off);
            r->pos = payload_end;
            return 1;

        case SP_TAG_BUTTON_CLICKED:
            _SP_NEED(6);
            msg->u.button_clicked.panel_id  = _sp_rd_u16(p + off);     off += 2;
            msg->u.button_clicked.widget_id = _sp_rd_u32(p + off);
            r->pos = payload_end;
            return 1;

        case SP_TAG_SLIDER_CHANGED:
            _SP_NEED(10);
            msg->u.slider_changed.panel_id  = _sp_rd_u16(p + off);     off += 2;
            msg->u.slider_changed.widget_id = _sp_rd_u32(p + off);     off += 4;
            msg->u.slider_changed.val       = _sp_rd_f32(p + off);
            r->pos = payload_end;
            return 1;

        case SP_TAG_TEXT_CHANGED:
            _SP_NEED(6);
            msg->u.text_changed.panel_id  = _sp_rd_u16(p + off);       off += 2;
            msg->u.text_changed.widget_id = _sp_rd_u32(p + off);       off += 4;
            if (!_sp_rd_str(p, payload_sz, &off, &msg->u.text_changed.text)) goto skip;
            r->pos = payload_end;
            return 1;

        case SP_TAG_CHECKBOX_CHANGED:
            _SP_NEED(7);
            msg->u.checkbox_changed.panel_id  = _sp_rd_u16(p + off);   off += 2;
            msg->u.checkbox_changed.widget_id = _sp_rd_u32(p + off);   off += 4;
            msg->u.checkbox_changed.val       = p[off];
            r->pos = payload_end;
            return 1;

        case SP_TAG_COMMAND:
            off = 0;
            if (!_sp_rd_str(p, payload_sz, &off, &msg->u.command.tag))     goto skip;
            if (!_sp_rd_str(p, payload_sz, &off, &msg->u.command.payload)) goto skip;
            r->pos = payload_end;
            return 1;

        case SP_TAG_STATE_RESPONSE:
            off = 0;
            if (!_sp_rd_str(p, payload_sz, &off, &msg->u.state_response.key)) goto skip;
            if (!_sp_rd_str(p, payload_sz, &off, &msg->u.state_response.val)) goto skip;
            r->pos = payload_end;
            return 1;

        case SP_TAG_CONFIG_RESPONSE:
            off = 0;
            if (!_sp_rd_str(p, payload_sz, &off, &msg->u.config_response.key)) goto skip;
            if (!_sp_rd_str(p, payload_sz, &off, &msg->u.config_response.val)) goto skip;
            r->pos = payload_end;
            return 1;

        case SP_TAG_SELECTION_CHANGED:
            _SP_NEED(4);
            msg->u.selection_changed.instance_idx = _sp_rd_i32(p + off);
            r->pos = payload_end;
            return 1;

        case SP_TAG_SCHEMATIC_SNAPSHOT:
            _SP_NEED(12);
            msg->u.schematic_snapshot.instance_count = _sp_rd_u32(p + off); off += 4;
            msg->u.schematic_snapshot.wire_count     = _sp_rd_u32(p + off); off += 4;
            msg->u.schematic_snapshot.net_count      = _sp_rd_u32(p + off);
            r->pos = payload_end;
            return 1;

        case SP_TAG_INSTANCE_DATA:
            _SP_NEED(4);
            off = 0;
            msg->u.instance_data.idx = _sp_rd_u32(p + off);                off += 4;
            if (!_sp_rd_str(p, payload_sz, &off, &msg->u.instance_data.name))   goto skip;
            if (!_sp_rd_str(p, payload_sz, &off, &msg->u.instance_data.symbol)) goto skip;
            r->pos = payload_end;
            return 1;

        case SP_TAG_INSTANCE_PROP:
            _SP_NEED(4);
            off = 0;
            msg->u.instance_prop.idx = _sp_rd_u32(p + off);                off += 4;
            if (!_sp_rd_str(p, payload_sz, &off, &msg->u.instance_prop.key)) goto skip;
            if (!_sp_rd_str(p, payload_sz, &off, &msg->u.instance_prop.val)) goto skip;
            r->pos = payload_end;
            return 1;

        case SP_TAG_NET_DATA:
            _SP_NEED(4);
            off = 0;
            msg->u.net_data.idx = _sp_rd_u32(p + off);                     off += 4;
            if (!_sp_rd_str(p, payload_sz, &off, &msg->u.net_data.name)) goto skip;
            r->pos = payload_end;
            return 1;

        default:
            /* Unknown tag — skip entire message and continue. */
            goto skip;
        }

#undef _SP_NEED

skip:
        r->pos = payload_end;
        /* Loop and try the next message. */
    }
}

/* ── Writer ───────────────────────────────────────────────────────────────── */

typedef struct {
    uint8_t* buf;
    size_t   cap;
    size_t   pos;
    int      overflow;
} SpWriter;

static inline SpWriter sp_writer_init(uint8_t* buf, size_t cap) {
    SpWriter w;
    w.buf      = buf;
    w.cap      = cap;
    w.pos      = 0;
    w.overflow = 0;
    return w;
}

static inline int sp_writer_overflow(const SpWriter* w) {
    return w->overflow;
}

/* ── Internal writer helpers ──────────────────────────────────────────────── */

/* Check there is room for `need` more bytes; set overflow and return 0 if not. */
static inline int _sp_wr_room(SpWriter* w, size_t need) {
    if (w->overflow) return 0;
    if (w->pos + need > w->cap) { w->overflow = 1; return 0; }
    return 1;
}

/* Write 3-byte message header: [u8 tag][u16 payload_sz LE]. */
static inline void _sp_wr_hdr(SpWriter* w, uint8_t tag, uint16_t payload_sz) {
    w->buf[w->pos]     = tag;
    w->buf[w->pos + 1] = (uint8_t)(payload_sz & 0xFF);
    w->buf[w->pos + 2] = (uint8_t)((payload_sz >> 8) & 0xFF);
    w->pos += 3;
}

static inline void _sp_wr_u8(SpWriter* w, uint8_t v) {
    w->buf[w->pos++] = v;
}

static inline void _sp_wr_u16(SpWriter* w, uint16_t v) {
    w->buf[w->pos]     = (uint8_t)(v & 0xFF);
    w->buf[w->pos + 1] = (uint8_t)((v >> 8) & 0xFF);
    w->pos += 2;
}

static inline void _sp_wr_u32(SpWriter* w, uint32_t v) {
    w->buf[w->pos]     = (uint8_t)(v & 0xFF);
    w->buf[w->pos + 1] = (uint8_t)((v >> 8) & 0xFF);
    w->buf[w->pos + 2] = (uint8_t)((v >> 16) & 0xFF);
    w->buf[w->pos + 3] = (uint8_t)((v >> 24) & 0xFF);
    w->pos += 4;
}

static inline void _sp_wr_i32(SpWriter* w, int32_t v) {
    _sp_wr_u32(w, (uint32_t)v);
}

static inline void _sp_wr_f32(SpWriter* w, float v) {
    uint32_t bits;
    memcpy(&bits, &v, 4);
    _sp_wr_u32(w, bits);
}

/* Write a length-prefixed string: [u16 len][N bytes]. */
static inline void _sp_wr_str(SpWriter* w, const char* s, size_t slen) {
    _sp_wr_u16(w, (uint16_t)slen);
    if (slen) {
        memcpy(w->buf + w->pos, s, slen);
        w->pos += slen;
    }
}

/* Write a f32 array: [u32 count][count * 4 bytes]. */
static inline void _sp_wr_f32arr(SpWriter* w, const float* arr, uint32_t count) {
    _sp_wr_u32(w, count);
    for (uint32_t i = 0; i < count; i++) _sp_wr_f32(w, arr[i]);
}

/* Write a u8 array: [u32 count][count bytes]. */
static inline void _sp_wr_u8arr(SpWriter* w, const uint8_t* arr, uint32_t count) {
    _sp_wr_u32(w, count);
    if (count) {
        memcpy(w->buf + w->pos, arr, count);
        w->pos += count;
    }
}

/* ── Writer public API ────────────────────────────────────────────────────── */

/* SP_TAG_SET_STATUS: msg:[str] */
static inline void sp_write_set_status(SpWriter* w, const char* msg, size_t msg_len) {
    uint16_t psz = (uint16_t)(2 + msg_len);
    if (!_sp_wr_room(w, 3 + psz)) return;
    _sp_wr_hdr(w, SP_TAG_SET_STATUS, psz);
    _sp_wr_str(w, msg, msg_len);
}

/* SP_TAG_LOG: level:u8, tag:[str], msg:[str] */
static inline void sp_write_log(SpWriter* w,
                                 uint8_t level,
                                 const char* tag, size_t tag_len,
                                 const char* msg, size_t msg_len) {
    uint16_t psz = (uint16_t)(1 + 2 + tag_len + 2 + msg_len);
    if (!_sp_wr_room(w, 3 + psz)) return;
    _sp_wr_hdr(w, SP_TAG_LOG, psz);
    _sp_wr_u8(w, level);
    _sp_wr_str(w, tag, tag_len);
    _sp_wr_str(w, msg, msg_len);
}

/* SP_TAG_REGISTER_PANEL: id:[str], title:[str], vim_cmd:[str], layout:u8, keybind:u8 */
static inline void sp_write_register_panel(SpWriter* w,
                                            const char* id,      size_t id_len,
                                            const char* title,   size_t title_len,
                                            const char* vim_cmd, size_t vim_len,
                                            uint8_t layout,
                                            uint8_t keybind) {
    uint16_t psz = (uint16_t)(2 + id_len + 2 + title_len + 2 + vim_len + 1 + 1);
    if (!_sp_wr_room(w, 3 + psz)) return;
    _sp_wr_hdr(w, SP_TAG_REGISTER_PANEL, psz);
    _sp_wr_str(w, id,      id_len);
    _sp_wr_str(w, title,   title_len);
    _sp_wr_str(w, vim_cmd, vim_len);
    _sp_wr_u8(w, layout);
    _sp_wr_u8(w, keybind);
}

/* SP_TAG_PUSH_COMMAND: tag:[str], payload:[str] */
static inline void sp_write_push_command(SpWriter* w,
                                          const char* tag,     size_t tag_len,
                                          const char* payload, size_t payload_len) {
    uint16_t psz = (uint16_t)(2 + tag_len + 2 + payload_len);
    if (!_sp_wr_room(w, 3 + psz)) return;
    _sp_wr_hdr(w, SP_TAG_PUSH_COMMAND, psz);
    _sp_wr_str(w, tag,     tag_len);
    _sp_wr_str(w, payload, payload_len);
}

/* SP_TAG_SET_STATE: key:[str], val:[str] */
static inline void sp_write_set_state(SpWriter* w,
                                       const char* key, size_t key_len,
                                       const char* val, size_t val_len) {
    uint16_t psz = (uint16_t)(2 + key_len + 2 + val_len);
    if (!_sp_wr_room(w, 3 + psz)) return;
    _sp_wr_hdr(w, SP_TAG_SET_STATE, psz);
    _sp_wr_str(w, key, key_len);
    _sp_wr_str(w, val, val_len);
}

/* SP_TAG_GET_STATE: key:[str] */
static inline void sp_write_get_state(SpWriter* w,
                                       const char* key, size_t key_len) {
    uint16_t psz = (uint16_t)(2 + key_len);
    if (!_sp_wr_room(w, 3 + psz)) return;
    _sp_wr_hdr(w, SP_TAG_GET_STATE, psz);
    _sp_wr_str(w, key, key_len);
}

/* SP_TAG_SET_CONFIG: plugin_id:[str], key:[str], val:[str] */
static inline void sp_write_set_config(SpWriter* w,
                                        const char* plugin_id, size_t id_len,
                                        const char* key,       size_t key_len,
                                        const char* val,       size_t val_len) {
    uint16_t psz = (uint16_t)(2 + id_len + 2 + key_len + 2 + val_len);
    if (!_sp_wr_room(w, 3 + psz)) return;
    _sp_wr_hdr(w, SP_TAG_SET_CONFIG, psz);
    _sp_wr_str(w, plugin_id, id_len);
    _sp_wr_str(w, key,       key_len);
    _sp_wr_str(w, val,       val_len);
}

/* SP_TAG_GET_CONFIG: plugin_id:[str], key:[str] */
static inline void sp_write_get_config(SpWriter* w,
                                        const char* plugin_id, size_t id_len,
                                        const char* key,       size_t key_len) {
    uint16_t psz = (uint16_t)(2 + id_len + 2 + key_len);
    if (!_sp_wr_room(w, 3 + psz)) return;
    _sp_wr_hdr(w, SP_TAG_GET_CONFIG, psz);
    _sp_wr_str(w, plugin_id, id_len);
    _sp_wr_str(w, key,       key_len);
}

/* SP_TAG_REQUEST_REFRESH: no payload */
static inline void sp_write_request_refresh(SpWriter* w) {
    if (!_sp_wr_room(w, 3)) return;
    _sp_wr_hdr(w, SP_TAG_REQUEST_REFRESH, 0);
}

/* SP_TAG_REGISTER_KEYBIND: key:u8, mods:u8, cmd_tag:[str] */
static inline void sp_write_register_keybind(SpWriter* w,
                                              uint8_t key,
                                              uint8_t mods,
                                              const char* cmd_tag, size_t tag_len) {
    uint16_t psz = (uint16_t)(1 + 1 + 2 + tag_len);
    if (!_sp_wr_room(w, 3 + psz)) return;
    _sp_wr_hdr(w, SP_TAG_REGISTER_KEYBIND, psz);
    _sp_wr_u8(w, key);
    _sp_wr_u8(w, mods);
    _sp_wr_str(w, cmd_tag, tag_len);
}

/* SP_TAG_PLACE_DEVICE: sym:[str], name:[str], x:i32, y:i32 */
static inline void sp_write_place_device(SpWriter* w,
                                          const char* sym,  size_t sym_len,
                                          const char* name, size_t name_len,
                                          int32_t x, int32_t y) {
    uint16_t psz = (uint16_t)(2 + sym_len + 2 + name_len + 4 + 4);
    if (!_sp_wr_room(w, 3 + psz)) return;
    _sp_wr_hdr(w, SP_TAG_PLACE_DEVICE, psz);
    _sp_wr_str(w, sym,  sym_len);
    _sp_wr_str(w, name, name_len);
    _sp_wr_i32(w, x);
    _sp_wr_i32(w, y);
}

/* SP_TAG_ADD_WIRE: x0:i32, y0:i32, x1:i32, y1:i32 */
static inline void sp_write_add_wire(SpWriter* w,
                                      int32_t x0, int32_t y0,
                                      int32_t x1, int32_t y1) {
    if (!_sp_wr_room(w, 3 + 16)) return;
    _sp_wr_hdr(w, SP_TAG_ADD_WIRE, 16);
    _sp_wr_i32(w, x0);
    _sp_wr_i32(w, y0);
    _sp_wr_i32(w, x1);
    _sp_wr_i32(w, y1);
}

/* SP_TAG_SET_INSTANCE_PROP: idx:u32, key:[str], val:[str] */
static inline void sp_write_set_instance_prop(SpWriter* w,
                                               uint32_t    idx,
                                               const char* key, size_t key_len,
                                               const char* val, size_t val_len) {
    uint16_t psz = (uint16_t)(4 + 2 + key_len + 2 + val_len);
    if (!_sp_wr_room(w, 3 + psz)) return;
    _sp_wr_hdr(w, SP_TAG_SET_INSTANCE_PROP, psz);
    _sp_wr_u32(w, idx);
    _sp_wr_str(w, key, key_len);
    _sp_wr_str(w, val, val_len);
}

/* SP_TAG_QUERY_INSTANCES: no payload */
static inline void sp_write_query_instances(SpWriter* w) {
    if (!_sp_wr_room(w, 3)) return;
    _sp_wr_hdr(w, SP_TAG_QUERY_INSTANCES, 0);
}

/* SP_TAG_QUERY_NETS: no payload */
static inline void sp_write_query_nets(SpWriter* w) {
    if (!_sp_wr_room(w, 3)) return;
    _sp_wr_hdr(w, SP_TAG_QUERY_NETS, 0);
}

/* ── UI widget writers ────────────────────────────────────────────────────── */

/* SP_TAG_UI_LABEL: text:[str], id:u32 */
static inline void sp_write_ui_label(SpWriter* w,
                                      const char* text, size_t len,
                                      uint32_t id) {
    uint16_t psz = (uint16_t)(2 + len + 4);
    if (!_sp_wr_room(w, 3 + psz)) return;
    _sp_wr_hdr(w, SP_TAG_UI_LABEL, psz);
    _sp_wr_str(w, text, len);
    _sp_wr_u32(w, id);
}

/* SP_TAG_UI_BUTTON: text:[str], id:u32 */
static inline void sp_write_ui_button(SpWriter* w,
                                       const char* text, size_t len,
                                       uint32_t id) {
    uint16_t psz = (uint16_t)(2 + len + 4);
    if (!_sp_wr_room(w, 3 + psz)) return;
    _sp_wr_hdr(w, SP_TAG_UI_BUTTON, psz);
    _sp_wr_str(w, text, len);
    _sp_wr_u32(w, id);
}

/* SP_TAG_UI_SEPARATOR: id:u32 */
static inline void sp_write_ui_separator(SpWriter* w, uint32_t id) {
    if (!_sp_wr_room(w, 3 + 4)) return;
    _sp_wr_hdr(w, SP_TAG_UI_SEPARATOR, 4);
    _sp_wr_u32(w, id);
}

/* SP_TAG_UI_BEGIN_ROW: id:u32 */
static inline void sp_write_ui_begin_row(SpWriter* w, uint32_t id) {
    if (!_sp_wr_room(w, 3 + 4)) return;
    _sp_wr_hdr(w, SP_TAG_UI_BEGIN_ROW, 4);
    _sp_wr_u32(w, id);
}

/* SP_TAG_UI_END_ROW: id:u32 */
static inline void sp_write_ui_end_row(SpWriter* w, uint32_t id) {
    if (!_sp_wr_room(w, 3 + 4)) return;
    _sp_wr_hdr(w, SP_TAG_UI_END_ROW, 4);
    _sp_wr_u32(w, id);
}

/* SP_TAG_UI_SLIDER: val:f32, min:f32, max:f32, id:u32 */
static inline void sp_write_ui_slider(SpWriter* w,
                                       float val, float min, float max,
                                       uint32_t id) {
    if (!_sp_wr_room(w, 3 + 16)) return;
    _sp_wr_hdr(w, SP_TAG_UI_SLIDER, 16);
    _sp_wr_f32(w, val);
    _sp_wr_f32(w, min);
    _sp_wr_f32(w, max);
    _sp_wr_u32(w, id);
}

/* SP_TAG_UI_CHECKBOX: val:u8, text:[str], id:u32 */
static inline void sp_write_ui_checkbox(SpWriter* w,
                                         uint8_t val,
                                         const char* text, size_t len,
                                         uint32_t id) {
    uint16_t psz = (uint16_t)(1 + 2 + len + 4);
    if (!_sp_wr_room(w, 3 + psz)) return;
    _sp_wr_hdr(w, SP_TAG_UI_CHECKBOX, psz);
    _sp_wr_u8(w, val);
    _sp_wr_str(w, text, len);
    _sp_wr_u32(w, id);
}

/* SP_TAG_UI_PROGRESS: fraction:f32, id:u32 */
static inline void sp_write_ui_progress(SpWriter* w, float fraction, uint32_t id) {
    if (!_sp_wr_room(w, 3 + 8)) return;
    _sp_wr_hdr(w, SP_TAG_UI_PROGRESS, 8);
    _sp_wr_f32(w, fraction);
    _sp_wr_u32(w, id);
}

/* SP_TAG_UI_PLOT: title:[str], x_data:[f32arr], y_data:[f32arr], id:u32 */
static inline void sp_write_ui_plot(SpWriter* w,
                                     const char* title, size_t title_len,
                                     const float* xs, const float* ys,
                                     uint32_t count,
                                     uint32_t id) {
    /* payload: 2+title_len + (4+count*4) + (4+count*4) + 4 */
    size_t psz_big = 2 + title_len + 4 + (size_t)count * 4 + 4 + (size_t)count * 4 + 4;
    if (psz_big > 0xFFFF) { w->overflow = 1; return; }
    uint16_t psz = (uint16_t)psz_big;
    if (!_sp_wr_room(w, 3 + psz)) return;
    _sp_wr_hdr(w, SP_TAG_UI_PLOT, psz);
    _sp_wr_str(w, title, title_len);
    _sp_wr_f32arr(w, xs, count);
    _sp_wr_f32arr(w, ys, count);
    _sp_wr_u32(w, id);
}

/* SP_TAG_UI_IMAGE: width:u32, height:u32, pixels:[u8arr], id:u32 */
static inline void sp_write_ui_image(SpWriter* w,
                                      uint32_t width, uint32_t height,
                                      const uint8_t* pixels, uint32_t pixel_count,
                                      uint32_t id) {
    /* payload: 4 + 4 + (4+pixel_count) + 4 */
    size_t psz_big = 4 + 4 + 4 + (size_t)pixel_count + 4;
    if (psz_big > 0xFFFF) { w->overflow = 1; return; }
    uint16_t psz = (uint16_t)psz_big;
    if (!_sp_wr_room(w, 3 + psz)) return;
    _sp_wr_hdr(w, SP_TAG_UI_IMAGE, psz);
    _sp_wr_u32(w, width);
    _sp_wr_u32(w, height);
    _sp_wr_u8arr(w, pixels, pixel_count);
    _sp_wr_u32(w, id);
}

/* SP_TAG_UI_COLLAPSIBLE_START: label:[str], open:u8, id:u32 */
static inline void sp_write_ui_collapsible_start(SpWriter* w,
                                                   const char* label, size_t label_len,
                                                   uint8_t open,
                                                   uint32_t id) {
    uint16_t psz = (uint16_t)(2 + label_len + 1 + 4);
    if (!_sp_wr_room(w, 3 + psz)) return;
    _sp_wr_hdr(w, SP_TAG_UI_COLLAPSIBLE_START, psz);
    _sp_wr_str(w, label, label_len);
    _sp_wr_u8(w, open);
    _sp_wr_u32(w, id);
}

/* SP_TAG_UI_COLLAPSIBLE_END: id:u32 */
static inline void sp_write_ui_collapsible_end(SpWriter* w, uint32_t id) {
    if (!_sp_wr_room(w, 3 + 4)) return;
    _sp_wr_hdr(w, SP_TAG_UI_COLLAPSIBLE_END, 4);
    _sp_wr_u32(w, id);
}

/* ── Descriptor and SCHEMIFY_PLUGIN macro ─────────────────────────────────── */

/**
 * Type of the plugin's single process entry point.
 *
 * in_ptr / in_len  — host→plugin message batch (read-only, valid for call duration)
 * out_ptr / out_cap — plugin→host output buffer
 *
 * Returns bytes written to out_ptr, or (size_t)-1 if out_cap was too small
 * (host will double the buffer and retry).
 */
typedef size_t (*SchemifyProcessFn)(
    const uint8_t* in_ptr,  size_t in_len,
    uint8_t*       out_ptr, size_t out_cap
);

#define SCHEMIFY_ABI_VERSION 6

/**
 * Every plugin must export a symbol named `schemify_plugin` of this type.
 * Use the SCHEMIFY_PLUGIN() macro below.
 */
typedef struct {
    uint32_t          abi_version;
    const char*       name;
    const char*       version_str;
    SchemifyProcessFn process;
} SchemifyDescriptor;

/**
 * SCHEMIFY_PLUGIN(name, version, process_fn)
 *
 * Declares the `schemify_plugin` export symbol.
 *
 * Example:
 *   SCHEMIFY_PLUGIN("my-plugin", "0.1.0", my_process)
 */
/* In C++, namespace-scope `const` has internal linkage by default, so we
 * must add `extern` to force external linkage before the visibility attribute
 * can take effect.  In C, `extern const` is also valid and harmless. */
#define SCHEMIFY_PLUGIN(plugin_name, plugin_version, process_fn)  \
    __attribute__((visibility("default")))                         \
    extern const SchemifyDescriptor schemify_plugin;              \
    const SchemifyDescriptor schemify_plugin = {                  \
        .abi_version = SCHEMIFY_ABI_VERSION,                      \
        .name        = (plugin_name),                             \
        .version_str = (plugin_version),                          \
        .process     = (process_fn),                              \
    };

#ifdef __cplusplus
} /* extern "C" */
#endif
