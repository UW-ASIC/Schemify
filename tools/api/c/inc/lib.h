/**
 * schemify_plugin.h — C99 SDK for Schemify plugins (ABI v6)
 *
 * Header-only. Copy this file into your project; no other files needed.
 *
 * Build (native):
 *   cc -std=c99 -shared -fPIC -o plugin.so src/plugin.c
 *
 * Build (WASM):
 *   clang --target=wasm32 --no-standard-libraries \
 *         -Wl,--export-dynamic -Wl,--no-entry -Wl,--allow-undefined \
 *         -o plugin.wasm src/plugin.c
 *
 * Usage:
 *   #include "schemify_plugin.h"   // or "lib.h" if using the api/c/inc path
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
 */

#pragma once

#include <stddef.h>
#include <stdint.h>
#ifdef __wasm__
/* Freestanding WASM — no libc, use compiler builtins. */
static inline void* _sp_memcpy(void* dst, const void* src, size_t n) {
    return __builtin_memcpy(dst, src, n);
}
#define memcpy _sp_memcpy
#else
#include <string.h>
#endif

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
#define SP_TAG_FILE_RESPONSE     0x12
#define SP_TAG_HOVER             0x13
#define SP_TAG_KEY_EVENT         0x14

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
#define SP_TAG_REGISTER_COMMAND  0x8F
#define SP_TAG_SUBSCRIBE_EVENTS  0x92
#define SP_TAG_CONSUME_EVENT     0x93
#define SP_TAG_OVERRIDE_KEYBIND  0x94

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
#define SP_TAG_UI_TOOLTIP            0xAC
#define SP_TAG_UI_TEXT_INPUT         0xAD

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

/* Event subscription flags (for sp_write_subscribe_events) */
#define SP_EVENT_HOVER  (1 << 0)
#define SP_EVENT_KEYS   (1 << 1)

/* ── String view (zero-copy into input buffer) ────────────────────────────── */

typedef struct {
    const uint8_t* ptr;
    uint16_t       len;
} SpStr;

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
typedef struct { int32_t world_x; int32_t world_y; uint8_t element_type; int32_t element_idx; SpStr element_name; } SpMsgHover;
typedef struct { uint8_t key; uint8_t mods; uint8_t action;               } SpMsgKeyEvent;

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
        SpMsgHover             hover;
        SpMsgKeyEvent          key_event;
    } u;
} SpMsg;

/* ── Reader ───────────────────────────────────────────────────────────────── */

typedef struct {
    const uint8_t* buf;
    size_t         len;
    size_t         pos;
} SpReader;

static inline SpReader sp_reader_init(const uint8_t* buf, size_t len) {
    SpReader r; r.buf = buf; r.len = len; r.pos = 0; return r;
}

static inline uint16_t _sp_rd_u16(const uint8_t* b) {
    return (uint16_t)((uint32_t)b[0] | ((uint32_t)b[1] << 8));
}
static inline uint32_t _sp_rd_u32(const uint8_t* b) {
    return (uint32_t)b[0] | ((uint32_t)b[1]<<8) | ((uint32_t)b[2]<<16) | ((uint32_t)b[3]<<24);
}
static inline int32_t  _sp_rd_i32(const uint8_t* b) { return (int32_t)_sp_rd_u32(b); }
static inline float    _sp_rd_f32(const uint8_t* b) {
    uint32_t bits = _sp_rd_u32(b); float v; memcpy(&v, &bits, 4); return v;
}
static inline int _sp_rd_str(const uint8_t* buf, size_t payload_end, size_t* off, SpStr* out) {
    if (*off + 2 > payload_end) return 0;
    uint16_t slen = _sp_rd_u16(buf + *off); *off += 2;
    if (*off + slen > payload_end) return 0;
    out->ptr = buf + *off; out->len = slen; *off += slen; return 1;
}

static int sp_reader_next(SpReader* r, SpMsg* msg) {
    for (;;) {
        if (r->pos + 3 > r->len) return 0;
        uint8_t  tag        = r->buf[r->pos];
        uint16_t payload_sz = _sp_rd_u16(r->buf + r->pos + 1);
        size_t   hdr_end    = r->pos + 3;
        size_t   payload_end = hdr_end + payload_sz;
        if (payload_end > r->len) return 0;
        const uint8_t* p = r->buf + hdr_end;
        size_t off = 0;
#define _SP_NEED(n) do { if (off + (n) > payload_sz) goto skip; } while (0)
        msg->tag = tag;
        switch (tag) {
        case SP_TAG_LOAD: case SP_TAG_UNLOAD: case SP_TAG_SCHEMATIC_CHANGED:
            r->pos = payload_end; return 1;
        case SP_TAG_TICK:
            _SP_NEED(4); msg->u.tick.dt = _sp_rd_f32(p+off); r->pos = payload_end; return 1;
        case SP_TAG_DRAW_PANEL:
            _SP_NEED(2); msg->u.draw_panel.panel_id = _sp_rd_u16(p+off); r->pos = payload_end; return 1;
        case SP_TAG_BUTTON_CLICKED:
            _SP_NEED(6); msg->u.button_clicked.panel_id = _sp_rd_u16(p+off); off+=2;
            msg->u.button_clicked.widget_id = _sp_rd_u32(p+off); r->pos = payload_end; return 1;
        case SP_TAG_SLIDER_CHANGED:
            _SP_NEED(10); msg->u.slider_changed.panel_id = _sp_rd_u16(p+off); off+=2;
            msg->u.slider_changed.widget_id = _sp_rd_u32(p+off); off+=4;
            msg->u.slider_changed.val = _sp_rd_f32(p+off); r->pos = payload_end; return 1;
        case SP_TAG_TEXT_CHANGED:
            _SP_NEED(6); msg->u.text_changed.panel_id  = _sp_rd_u16(p+off); off+=2;
            msg->u.text_changed.widget_id = _sp_rd_u32(p+off); off+=4;
            if (!_sp_rd_str(p, payload_sz, &off, &msg->u.text_changed.text)) goto skip;
            r->pos = payload_end; return 1;
        case SP_TAG_CHECKBOX_CHANGED:
            _SP_NEED(7); msg->u.checkbox_changed.panel_id = _sp_rd_u16(p+off); off+=2;
            msg->u.checkbox_changed.widget_id = _sp_rd_u32(p+off); off+=4;
            msg->u.checkbox_changed.val = p[off]; r->pos = payload_end; return 1;
        case SP_TAG_COMMAND:
            off=0; if (!_sp_rd_str(p,payload_sz,&off,&msg->u.command.tag)) goto skip;
            if (!_sp_rd_str(p,payload_sz,&off,&msg->u.command.payload)) goto skip;
            r->pos = payload_end; return 1;
        case SP_TAG_STATE_RESPONSE:
            off=0; if (!_sp_rd_str(p,payload_sz,&off,&msg->u.state_response.key)) goto skip;
            if (!_sp_rd_str(p,payload_sz,&off,&msg->u.state_response.val)) goto skip;
            r->pos = payload_end; return 1;
        case SP_TAG_CONFIG_RESPONSE:
            off=0; if (!_sp_rd_str(p,payload_sz,&off,&msg->u.config_response.key)) goto skip;
            if (!_sp_rd_str(p,payload_sz,&off,&msg->u.config_response.val)) goto skip;
            r->pos = payload_end; return 1;
        case SP_TAG_SELECTION_CHANGED:
            _SP_NEED(4); msg->u.selection_changed.instance_idx = _sp_rd_i32(p+off);
            r->pos = payload_end; return 1;
        case SP_TAG_SCHEMATIC_SNAPSHOT:
            _SP_NEED(12); msg->u.schematic_snapshot.instance_count = _sp_rd_u32(p+off); off+=4;
            msg->u.schematic_snapshot.wire_count = _sp_rd_u32(p+off); off+=4;
            msg->u.schematic_snapshot.net_count  = _sp_rd_u32(p+off);
            r->pos = payload_end; return 1;
        case SP_TAG_INSTANCE_DATA:
            _SP_NEED(4); off=0;
            msg->u.instance_data.idx = _sp_rd_u32(p+off); off+=4;
            if (!_sp_rd_str(p,payload_sz,&off,&msg->u.instance_data.name))   goto skip;
            if (!_sp_rd_str(p,payload_sz,&off,&msg->u.instance_data.symbol)) goto skip;
            r->pos = payload_end; return 1;
        case SP_TAG_INSTANCE_PROP:
            _SP_NEED(4); off=0;
            msg->u.instance_prop.idx = _sp_rd_u32(p+off); off+=4;
            if (!_sp_rd_str(p,payload_sz,&off,&msg->u.instance_prop.key)) goto skip;
            if (!_sp_rd_str(p,payload_sz,&off,&msg->u.instance_prop.val)) goto skip;
            r->pos = payload_end; return 1;
        case SP_TAG_NET_DATA:
            _SP_NEED(4); off=0;
            msg->u.net_data.idx = _sp_rd_u32(p+off); off+=4;
            if (!_sp_rd_str(p,payload_sz,&off,&msg->u.net_data.name)) goto skip;
            r->pos = payload_end; return 1;
        case SP_TAG_HOVER:
            _SP_NEED(13);
            msg->u.hover.world_x = _sp_rd_i32(p); msg->u.hover.world_y = _sp_rd_i32(p+4);
            msg->u.hover.element_type = p[8]; msg->u.hover.element_idx = _sp_rd_i32(p+9);
            off=13; if (!_sp_rd_str(p,payload_sz,&off,&msg->u.hover.element_name))
                { msg->u.hover.element_name.ptr = 0; msg->u.hover.element_name.len = 0; }
            r->pos = payload_end; return 1;
        case SP_TAG_KEY_EVENT:
            _SP_NEED(3); msg->u.key_event.key = p[0]; msg->u.key_event.mods = p[1];
            msg->u.key_event.action = p[2]; r->pos = payload_end; return 1;
        default: goto skip;
        }
#undef _SP_NEED
skip:
        r->pos = payload_end;
    }
}

/* ── Writer ───────────────────────────────────────────────────────────────── */

typedef struct { uint8_t* buf; size_t cap; size_t pos; int overflow; } SpWriter;

static inline SpWriter sp_writer_init(uint8_t* buf, size_t cap) {
    SpWriter w; w.buf=buf; w.cap=cap; w.pos=0; w.overflow=0; return w;
}
static inline int sp_writer_overflow(const SpWriter* w) { return w->overflow; }

static inline int  _sp_wr_room(SpWriter* w, size_t n) {
    if (w->overflow) return 0;
    if (w->pos+n > w->cap) { w->overflow=1; return 0; }
    return 1;
}
static inline void _sp_wr_hdr(SpWriter* w, uint8_t tag, uint16_t psz) {
    w->buf[w->pos]=(tag); w->buf[w->pos+1]=(uint8_t)(psz&0xFF);
    w->buf[w->pos+2]=(uint8_t)(psz>>8); w->pos+=3;
}
static inline void _sp_wr_u8 (SpWriter* w, uint8_t  v) { w->buf[w->pos++]=v; }
static inline void _sp_wr_u16(SpWriter* w, uint16_t v) {
    w->buf[w->pos]=(uint8_t)(v&0xFF); w->buf[w->pos+1]=(uint8_t)(v>>8); w->pos+=2;
}
static inline void _sp_wr_u32(SpWriter* w, uint32_t v) {
    w->buf[w->pos]=(uint8_t)(v&0xFF); w->buf[w->pos+1]=(uint8_t)((v>>8)&0xFF);
    w->buf[w->pos+2]=(uint8_t)((v>>16)&0xFF); w->buf[w->pos+3]=(uint8_t)((v>>24)&0xFF);
    w->pos+=4;
}
static inline void _sp_wr_i32(SpWriter* w, int32_t v) { _sp_wr_u32(w,(uint32_t)v); }
static inline void _sp_wr_f32(SpWriter* w, float v) { uint32_t b; memcpy(&b,&v,4); _sp_wr_u32(w,b); }
static inline void _sp_wr_str(SpWriter* w, const char* s, size_t n) {
    _sp_wr_u16(w,(uint16_t)n);
    if (n) { memcpy(w->buf+w->pos,s,n); w->pos+=n; }
}
static inline void _sp_wr_f32arr(SpWriter* w, const float* a, uint32_t n) {
    _sp_wr_u32(w,n); for (uint32_t i=0;i<n;i++) _sp_wr_f32(w,a[i]);
}
static inline void _sp_wr_u8arr(SpWriter* w, const uint8_t* a, uint32_t n) {
    _sp_wr_u32(w,n); if (n) { memcpy(w->buf+w->pos,a,n); w->pos+=n; }
}

/* ── Writer public API ────────────────────────────────────────────────────── */

static inline void sp_write_set_status(SpWriter* w, const char* msg, size_t len) {
    uint16_t p=(uint16_t)(2+len); if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_SET_STATUS,p); _sp_wr_str(w,msg,len);
}
static inline void sp_write_log(SpWriter* w, uint8_t level,
                                 const char* tag, size_t tlen, const char* msg, size_t mlen) {
    uint16_t p=(uint16_t)(1+2+tlen+2+mlen); if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_LOG,p); _sp_wr_u8(w,level); _sp_wr_str(w,tag,tlen); _sp_wr_str(w,msg,mlen);
}
static inline void sp_write_register_panel(SpWriter* w,
                                            const char* id, size_t id_len,
                                            const char* title, size_t title_len,
                                            const char* vim, size_t vim_len,
                                            uint8_t layout, uint8_t keybind) {
    uint16_t p=(uint16_t)(2+id_len+2+title_len+2+vim_len+1+1);
    if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_REGISTER_PANEL,p);
    _sp_wr_str(w,id,id_len); _sp_wr_str(w,title,title_len); _sp_wr_str(w,vim,vim_len);
    _sp_wr_u8(w,layout); _sp_wr_u8(w,keybind);
}
static inline void sp_write_push_command(SpWriter* w, const char* tag, size_t tlen, const char* pl, size_t plen) {
    uint16_t p=(uint16_t)(2+tlen+2+plen); if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_PUSH_COMMAND,p); _sp_wr_str(w,tag,tlen); _sp_wr_str(w,pl,plen);
}
static inline void sp_write_set_state(SpWriter* w, const char* k, size_t kl, const char* v, size_t vl) {
    uint16_t p=(uint16_t)(2+kl+2+vl); if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_SET_STATE,p); _sp_wr_str(w,k,kl); _sp_wr_str(w,v,vl);
}
static inline void sp_write_get_state(SpWriter* w, const char* k, size_t kl) {
    uint16_t p=(uint16_t)(2+kl); if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_GET_STATE,p); _sp_wr_str(w,k,kl);
}
static inline void sp_write_set_config(SpWriter* w, const char* id, size_t il, const char* k, size_t kl, const char* v, size_t vl) {
    uint16_t p=(uint16_t)(2+il+2+kl+2+vl); if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_SET_CONFIG,p); _sp_wr_str(w,id,il); _sp_wr_str(w,k,kl); _sp_wr_str(w,v,vl);
}
static inline void sp_write_get_config(SpWriter* w, const char* id, size_t il, const char* k, size_t kl) {
    uint16_t p=(uint16_t)(2+il+2+kl); if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_GET_CONFIG,p); _sp_wr_str(w,id,il); _sp_wr_str(w,k,kl);
}
static inline void sp_write_request_refresh(SpWriter* w) {
    if (!_sp_wr_room(w,3)) return; _sp_wr_hdr(w,SP_TAG_REQUEST_REFRESH,0);
}
static inline void sp_write_subscribe_events(SpWriter* w, uint8_t event_mask) {
    if (!_sp_wr_room(w,3+1)) return; _sp_wr_hdr(w,SP_TAG_SUBSCRIBE_EVENTS,1); _sp_wr_u8(w,event_mask);
}
static inline void sp_write_consume_event(SpWriter* w) {
    if (!_sp_wr_room(w,3)) return; _sp_wr_hdr(w,SP_TAG_CONSUME_EVENT,0);
}
static inline void sp_write_override_keybind(SpWriter* w, uint8_t key, uint8_t mods, const char* cmd, size_t clen) {
    uint16_t p=(uint16_t)(1+1+2+clen); if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_OVERRIDE_KEYBIND,p); _sp_wr_u8(w,key); _sp_wr_u8(w,mods); _sp_wr_str(w,cmd,clen);
}
static inline void sp_write_register_keybind(SpWriter* w, uint8_t key, uint8_t mods, const char* cmd, size_t clen) {
    uint16_t p=(uint16_t)(1+1+2+clen); if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_REGISTER_KEYBIND,p); _sp_wr_u8(w,key); _sp_wr_u8(w,mods); _sp_wr_str(w,cmd,clen);
}
static inline void sp_write_place_device(SpWriter* w, const char* sym, size_t sl, const char* name, size_t nl, int32_t x, int32_t y) {
    uint16_t p=(uint16_t)(2+sl+2+nl+4+4); if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_PLACE_DEVICE,p); _sp_wr_str(w,sym,sl); _sp_wr_str(w,name,nl);
    _sp_wr_i32(w,x); _sp_wr_i32(w,y);
}
static inline void sp_write_add_wire(SpWriter* w, int32_t x0, int32_t y0, int32_t x1, int32_t y1) {
    if (!_sp_wr_room(w,3+16)) return; _sp_wr_hdr(w,SP_TAG_ADD_WIRE,16);
    _sp_wr_i32(w,x0); _sp_wr_i32(w,y0); _sp_wr_i32(w,x1); _sp_wr_i32(w,y1);
}
static inline void sp_write_set_instance_prop(SpWriter* w, uint32_t idx, const char* k, size_t kl, const char* v, size_t vl) {
    uint16_t p=(uint16_t)(4+2+kl+2+vl); if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_SET_INSTANCE_PROP,p); _sp_wr_u32(w,idx); _sp_wr_str(w,k,kl); _sp_wr_str(w,v,vl);
}
static inline void sp_write_query_instances(SpWriter* w) {
    if (!_sp_wr_room(w,3)) return; _sp_wr_hdr(w,SP_TAG_QUERY_INSTANCES,0);
}
static inline void sp_write_query_nets(SpWriter* w) {
    if (!_sp_wr_room(w,3)) return; _sp_wr_hdr(w,SP_TAG_QUERY_NETS,0);
}

/* ── UI widget writers ────────────────────────────────────────────────────── */

static inline void sp_write_ui_label(SpWriter* w, const char* t, size_t l, uint32_t id) {
    uint16_t p=(uint16_t)(2+l+4); if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_UI_LABEL,p); _sp_wr_str(w,t,l); _sp_wr_u32(w,id);
}
static inline void sp_write_ui_button(SpWriter* w, const char* t, size_t l, uint32_t id) {
    uint16_t p=(uint16_t)(2+l+4); if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_UI_BUTTON,p); _sp_wr_str(w,t,l); _sp_wr_u32(w,id);
}
static inline void sp_write_ui_separator(SpWriter* w, uint32_t id) {
    if (!_sp_wr_room(w,3+4)) return; _sp_wr_hdr(w,SP_TAG_UI_SEPARATOR,4); _sp_wr_u32(w,id);
}
static inline void sp_write_ui_begin_row(SpWriter* w, uint32_t id) {
    if (!_sp_wr_room(w,3+4)) return; _sp_wr_hdr(w,SP_TAG_UI_BEGIN_ROW,4); _sp_wr_u32(w,id);
}
static inline void sp_write_ui_end_row(SpWriter* w, uint32_t id) {
    if (!_sp_wr_room(w,3+4)) return; _sp_wr_hdr(w,SP_TAG_UI_END_ROW,4); _sp_wr_u32(w,id);
}
static inline void sp_write_ui_slider(SpWriter* w, float val, float min, float max, uint32_t id) {
    if (!_sp_wr_room(w,3+16)) return; _sp_wr_hdr(w,SP_TAG_UI_SLIDER,16);
    _sp_wr_f32(w,val); _sp_wr_f32(w,min); _sp_wr_f32(w,max); _sp_wr_u32(w,id);
}
static inline void sp_write_ui_checkbox(SpWriter* w, uint8_t val, const char* t, size_t l, uint32_t id) {
    uint16_t p=(uint16_t)(1+2+l+4); if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_UI_CHECKBOX,p); _sp_wr_u8(w,val); _sp_wr_str(w,t,l); _sp_wr_u32(w,id);
}
static inline void sp_write_ui_progress(SpWriter* w, float f, uint32_t id) {
    if (!_sp_wr_room(w,3+8)) return; _sp_wr_hdr(w,SP_TAG_UI_PROGRESS,8); _sp_wr_f32(w,f); _sp_wr_u32(w,id);
}
static inline void sp_write_ui_plot(SpWriter* w, const char* title, size_t tlen,
                                     const float* xs, const float* ys, uint32_t count, uint32_t id) {
    size_t big = 2+tlen + 4+(size_t)count*4 + 4+(size_t)count*4 + 4;
    if (big > 0xFFFF) { w->overflow=1; return; }
    uint16_t p=(uint16_t)big; if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_UI_PLOT,p); _sp_wr_str(w,title,tlen);
    _sp_wr_f32arr(w,xs,count); _sp_wr_f32arr(w,ys,count); _sp_wr_u32(w,id);
}
static inline void sp_write_ui_image(SpWriter* w, uint32_t width, uint32_t height,
                                      const uint8_t* pixels, uint32_t pixel_count, uint32_t id) {
    size_t big = 4+4+4+(size_t)pixel_count+4;
    if (big > 0xFFFF) { w->overflow=1; return; }
    uint16_t p=(uint16_t)big; if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_UI_IMAGE,p); _sp_wr_u32(w,width); _sp_wr_u32(w,height);
    _sp_wr_u8arr(w,pixels,pixel_count); _sp_wr_u32(w,id);
}
static inline void sp_write_ui_collapsible_start(SpWriter* w, const char* label, size_t llen, uint8_t open, uint32_t id) {
    uint16_t p=(uint16_t)(2+llen+1+4); if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_UI_COLLAPSIBLE_START,p); _sp_wr_str(w,label,llen); _sp_wr_u8(w,open); _sp_wr_u32(w,id);
}
static inline void sp_write_ui_collapsible_end(SpWriter* w, uint32_t id) {
    if (!_sp_wr_room(w,3+4)) return; _sp_wr_hdr(w,SP_TAG_UI_COLLAPSIBLE_END,4); _sp_wr_u32(w,id);
}
static inline void sp_write_ui_tooltip(SpWriter* w, const char* t, size_t l, uint32_t id) {
    uint16_t p=(uint16_t)(2+l+4); if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_UI_TOOLTIP,p); _sp_wr_str(w,t,l); _sp_wr_u32(w,id);
}
static inline void sp_write_ui_text_input(SpWriter* w, const char* hint, size_t hlen,
                                           const char* text, size_t tlen, uint32_t id) {
    uint16_t p=(uint16_t)(2+hlen+2+tlen+4); if (!_sp_wr_room(w,3+p)) return;
    _sp_wr_hdr(w,SP_TAG_UI_TEXT_INPUT,p); _sp_wr_str(w,hint,hlen); _sp_wr_str(w,text,tlen); _sp_wr_u32(w,id);
}

/* ── Plugin descriptor ────────────────────────────────────────────────────── */

typedef size_t (*SchemifyProcessFn)(
    const uint8_t* in_ptr,  size_t in_len,
    uint8_t*       out_ptr, size_t out_cap
);

#define SCHEMIFY_ABI_VERSION 8

typedef struct {
    uint32_t          abi_version;
    const char*       name;
    const char*       version_str;
    SchemifyProcessFn process;
} SchemifyDescriptor;

#define SCHEMIFY_PLUGIN(plugin_name, plugin_version, process_fn)       \
    __attribute__((visibility("default")))                             \
    extern const SchemifyDescriptor schemify_plugin;                  \
    const SchemifyDescriptor schemify_plugin = {                      \
        .abi_version = SCHEMIFY_ABI_VERSION,                          \
        .name        = (plugin_name),                                 \
        .version_str = (plugin_version),                              \
        .process     = (process_fn),                                  \
    };

#ifdef __cplusplus
} /* extern "C" */
#endif
