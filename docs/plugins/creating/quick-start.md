# Quick Start: Your First Plugin in 5 Minutes

By the end of this page, you'll have a working **Note Pad** plugin that adds a panel to Schemify where you can create notes, mark them done, and have them persist across sessions. Pick any of the five supported languages -- the result is identical.

## What You'll Build

- A sidebar panel in Schemify
- An "Add Note" button that creates numbered notes
- Checkboxes to mark notes as done
- A "Clear Done" button to remove completed notes
- Persistent state across editor restarts

::: info Coming Soon
A text input widget is planned for a future protocol update. Currently, plugins can use buttons, checkboxes, sliders, and labels for user interaction. See the [API Reference](/plugins/api) for the full widget list.
:::

## Prerequisites

::: code-group

```txt [Zig]
- Zig 0.14+ (https://ziglang.org/download/)
- That's it -- Zig handles everything
```

```txt [C]
- A C compiler (gcc or clang)
- Zig 0.14+ for the build system (https://ziglang.org/download/)
```

```txt [Rust]
- Rust toolchain with cargo (https://rustup.rs/)
- Zig 0.14+ for the build system (https://ziglang.org/download/)
```

```txt [Python]
- Python 3.10+ (https://python.org/downloads/)
- SchemifyPython host plugin installed in Schemify
```

```txt [Go]
- TinyGo 0.32+ (https://tinygo.org/getting-started/install/)
- Zig 0.14+ for the build system (https://ziglang.org/download/)
```

:::

## Project Setup

Create a new directory for your plugin and set up the following files:

::: code-group

```txt [Zig]
notepad-plugin/
  build.zig.zon
  build.zig
  src/
    main.zig
```

```txt [C]
notepad-plugin/
  build.zig.zon
  build.zig
  src/
    main.c
```

```txt [Rust]
notepad-plugin/
  Cargo.toml
  build.zig.zon
  build.zig
  src/
    lib.rs
```

```txt [Python]
notepad.py        # Single file -- no project structure needed
```

```txt [Go]
notepad-plugin/
  go.mod
  build.zig.zon
  build.zig
  main.go
```

:::

## Build Configuration

::: code-group

```zig [Zig]
// build.zig.zon
.{
    .name = "notepad-plugin",
    .version = "0.1.0",
    .dependencies = .{
        .schemify = .{
            .path = "../../",  // Path to Schemify root
        },
    },
    .paths = .{"."},
}
```

```zig [C]
// build.zig.zon
.{
    .name = "notepad-plugin",
    .version = "0.1.0",
    .dependencies = .{
        .schemify = .{
            .path = "../../",  // Path to Schemify root
        },
    },
    .paths = .{"."},
}
```

```toml [Rust]
# Cargo.toml
[package]
name = "notepad-plugin"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
schemify-plugin = { path = "../../tools/sdk/bindings/rust/schemify-plugin" }
```

```txt [Python]
# No build configuration needed.
# Just drop notepad.py into:
#   ~/.config/Schemify/SchemifyPython/scripts/
```

```go [Go]
// go.mod
module notepad-plugin

go 1.21

require github.com/uwasic/schemify/tools/sdk/bindings/tinygo/schemify v0.0.0
replace github.com/uwasic/schemify/tools/sdk/bindings/tinygo/schemify => ../../tools/sdk/bindings/tinygo/schemify
```

:::

## The Plugin Code

This is the complete Note Pad plugin. Every language tab shows the full, working implementation -- no code is omitted.

::: code-group

```zig [Zig]
// src/main.zig -- Note Pad plugin for Schemify (Zig)
const std = @import("std");
const Plugin = @import("PluginIF");

// --- Plugin state (global, persists across calls) ---
const MAX_NOTES = 32;
var notes: [MAX_NOTES]Note = undefined;
var note_count: u16 = 0;
var next_id: u16 = 1;

const Note = struct {
    id: u16,
    done: bool,
};

// --- Entry point: called by host every frame ---
export fn schemify_process(
    in_ptr: [*]const u8,
    in_len: usize,
    out_ptr: [*]u8,
    out_cap: usize,
) usize {
    var r = Plugin.Reader.init(in_ptr[0..in_len]);
    var w = Plugin.Writer.init(out_ptr[0..out_cap]);

    while (r.next()) |msg| switch (msg) {
        // Plugin loaded -- register our panel and load saved state
        .load => {
            w.registerPanel(.{
                .id = "notepad",
                .title = "Note Pad",
                .vim_cmd = "notepad",
                .layout = .right_sidebar,
                .keybind = 0,
            });
            w.getState("notes");
        },

        // Host asks us to draw our panel UI
        .draw_panel => {
            w.button("Add Note", 1);
            w.button("Clear Done", 2);
            w.separator(3);

            // Render each note as a checkbox
            for (notes[0..note_count], 0..) |note, i| {
                var buf: [32]u8 = undefined;
                const lbl = std.fmt.bufPrint(&buf, "Note {d}", .{note.id}) catch "Note";
                w.checkbox(note.done, lbl, @intCast(100 + i));
            }

            if (note_count == 0) {
                w.label("No notes yet. Click 'Add Note' to start.", 99);
            }
        },

        // User clicked a button
        .button_clicked => |ev| {
            if (ev.widget_id == 1 and note_count < MAX_NOTES) {
                // "Add Note" button
                notes[note_count] = .{ .id = next_id, .done = false };
                note_count += 1;
                next_id += 1;
                saveState(&w);
            } else if (ev.widget_id == 2) {
                // "Clear Done" button -- remove all checked notes
                var write_idx: u16 = 0;
                for (notes[0..note_count]) |note| {
                    if (!note.done) {
                        notes[write_idx] = note;
                        write_idx += 1;
                    }
                }
                note_count = write_idx;
                saveState(&w);
            }
        },

        // User toggled a checkbox
        .checkbox_changed => |ev| {
            const idx = ev.widget_id -| 100;
            if (idx < note_count) {
                notes[idx].done = ev.val != 0;
                saveState(&w);
            }
        },

        // Host returned our saved state
        .state_response => |ev| {
            if (std.mem.eql(u8, ev.key, "notes")) {
                loadNotes(ev.val);
            }
        },

        else => {},
    };

    return if (w.overflow()) std.math.maxInt(usize) else w.pos;
}

// --- Serialize notes to "id,done;id,done;..." and persist ---
fn saveState(w: *Plugin.Writer) void {
    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    for (notes[0..note_count], 0..) |note, i| {
        if (i > 0) {
            buf[pos] = ';';
            pos += 1;
        }
        const written = std.fmt.bufPrint(buf[pos..], "{d},{d}", .{
            note.id,
            @as(u8, if (note.done) 1 else 0),
        }) catch break;
        pos += written.len;
    }
    w.setState("notes", buf[0..pos]);
}

// --- Deserialize notes from "id,done;id,done;..." ---
fn loadNotes(val: []const u8) void {
    note_count = 0;
    next_id = 1;
    if (val.len == 0) return;

    var it = std.mem.splitScalar(u8, val, ';');
    while (it.next()) |entry| {
        if (note_count >= MAX_NOTES) break;
        var parts = std.mem.splitScalar(u8, entry, ',');
        const id_str = parts.next() orelse continue;
        const done_str = parts.next() orelse continue;
        const id = std.fmt.parseInt(u16, id_str, 10) catch continue;
        const done = std.mem.eql(u8, done_str, "1");
        notes[note_count] = .{ .id = id, .done = done };
        note_count += 1;
        if (id >= next_id) next_id = id + 1;
    }
}

// --- Plugin descriptor (required export) ---
export const schemify_plugin: Plugin.Descriptor = .{
    .name = "NotePad",
    .version_str = "0.1.0",
    .process = schemify_process,
};
```

```c [C]
/* src/main.c -- Note Pad plugin for Schemify (C) */
#include "schemify_plugin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* --- Plugin state --- */
#define MAX_NOTES 32

typedef struct {
    uint16_t id;
    uint8_t  done;
} Note;

static Note     notes[MAX_NOTES];
static uint16_t note_count = 0;
static uint16_t next_id    = 1;

/* --- Forward declarations --- */
static void save_state(SpWriter* w);
static void load_notes(const char* val, size_t len);

/* --- Entry point --- */
static size_t notepad_process(
    const uint8_t* in_ptr, size_t in_len,
    uint8_t* out_ptr, size_t out_cap
) {
    SpReader r = sp_reader_init(in_ptr, in_len);
    SpWriter w = sp_writer_init(out_ptr, out_cap);
    SpMsg msg;

    while (sp_reader_next(&r, &msg)) {
        switch (msg.tag) {

        /* Plugin loaded -- register panel and request saved state */
        case SP_TAG_LOAD:
            sp_write_register_panel(&w,
                "notepad", 7, "Note Pad", 8, "notepad", 7,
                SP_LAYOUT_RIGHT_SIDEBAR, 0);
            sp_write_get_state(&w, "notes", 5);
            break;

        /* Host asks us to draw our panel */
        case SP_TAG_DRAW_PANEL:
            sp_write_ui_button(&w, "Add Note", 8, 1);
            sp_write_ui_button(&w, "Clear Done", 10, 2);
            sp_write_ui_separator(&w, 3);

            /* Render each note as a checkbox */
            for (uint16_t i = 0; i < note_count; i++) {
                char label[32];
                int n = snprintf(label, sizeof(label), "Note %d", notes[i].id);
                sp_write_ui_checkbox(&w, notes[i].done, label, (size_t)n, 100 + i);
            }

            if (note_count == 0) {
                const char* empty = "No notes yet. Click 'Add Note' to start.";
                sp_write_ui_label(&w, empty, strlen(empty), 99);
            }
            break;

        /* User clicked a button */
        case SP_TAG_BUTTON_CLICKED:
            if (msg.u.button_clicked.widget_id == 1 && note_count < MAX_NOTES) {
                /* "Add Note" */
                notes[note_count].id   = next_id++;
                notes[note_count].done = 0;
                note_count++;
                save_state(&w);
            } else if (msg.u.button_clicked.widget_id == 2) {
                /* "Clear Done" -- compact array */
                uint16_t wr = 0;
                for (uint16_t i = 0; i < note_count; i++) {
                    if (!notes[i].done) {
                        notes[wr++] = notes[i];
                    }
                }
                note_count = wr;
                save_state(&w);
            }
            break;

        /* User toggled a checkbox */
        case SP_TAG_CHECKBOX_CHANGED: {
            uint32_t idx = msg.u.checkbox_changed.widget_id - 100;
            if (idx < note_count) {
                notes[idx].done = msg.u.checkbox_changed.val;
                save_state(&w);
            }
            break;
        }

        /* Host returned our saved state */
        case SP_TAG_STATE_RESPONSE: {
            char key[16];
            sp_str_cstr(msg.u.state_response.key, key, sizeof(key));
            if (strcmp(key, "notes") == 0) {
                load_notes((const char*)msg.u.state_response.val.ptr,
                           msg.u.state_response.val.len);
            }
            break;
        }

        default: break;
        }
    }

    return sp_writer_overflow(&w) ? (size_t)-1 : w.pos;
}

/* --- Serialize: "id,done;id,done;..." --- */
static void save_state(SpWriter* w) {
    char buf[512];
    int pos = 0;
    for (uint16_t i = 0; i < note_count; i++) {
        if (i > 0) buf[pos++] = ';';
        pos += snprintf(buf + pos, sizeof(buf) - pos,
                        "%d,%d", notes[i].id, notes[i].done);
    }
    sp_write_set_state(w, "notes", 5, buf, (size_t)pos);
}

/* --- Deserialize: "id,done;id,done;..." --- */
static void load_notes(const char* val, size_t len) {
    note_count = 0;
    next_id = 1;
    if (len == 0) return;

    /* Work on a mutable copy for strtok-style parsing */
    char buf[512];
    size_t n = len < sizeof(buf) - 1 ? len : sizeof(buf) - 1;
    memcpy(buf, val, n);
    buf[n] = '\0';

    char* entry = buf;
    while (entry && note_count < MAX_NOTES) {
        char* semi = strchr(entry, ';');
        if (semi) *semi = '\0';

        char* comma = strchr(entry, ',');
        if (comma) {
            *comma = '\0';
            uint16_t id   = (uint16_t)atoi(entry);
            uint8_t  done = (uint8_t)atoi(comma + 1);
            notes[note_count].id   = id;
            notes[note_count].done = done;
            note_count++;
            if (id >= next_id) next_id = id + 1;
        }

        entry = semi ? semi + 1 : NULL;
    }
}

/* --- Descriptor export (required) --- */
SCHEMIFY_PLUGIN("NotePad", "0.1.0", notepad_process)
```

```rust [Rust]
// src/lib.rs -- Note Pad plugin for Schemify (Rust)
use schemify_plugin::{Plugin, Writer, InMsg, PanelDef, PanelLayout};

const MAX_NOTES: usize = 32;

struct Note {
    id: u16,
    done: bool,
}

#[derive(Default)]
struct NotepadPlugin {
    notes: Vec<Note>,
    next_id: u16,
}

impl Plugin for NotepadPlugin {
    /// Called once when the plugin is loaded.
    fn on_load(&mut self, w: &mut Writer) {
        self.next_id = 1;

        // Register a right-sidebar panel
        w.register_panel(&PanelDef {
            id: "notepad",
            title: "Note Pad",
            vim_cmd: "notepad",
            layout: PanelLayout::RightSidebar,
            keybind: 0,
        });

        // Request any previously saved notes
        w.get_state("notes");
    }

    /// Called every frame to render the panel UI.
    fn on_draw(&mut self, _panel_id: u16, w: &mut Writer) {
        w.button("Add Note", 1);
        w.button("Clear Done", 2);
        w.separator(3);

        // Render each note as a checkbox
        for (i, note) in self.notes.iter().enumerate() {
            let label = format!("Note {}", note.id);
            w.checkbox(note.done, &label, 100 + i as u32);
        }

        if self.notes.is_empty() {
            w.label("No notes yet. Click 'Add Note' to start.", 99);
        }
    }

    /// Called for button clicks, checkbox toggles, state responses, etc.
    fn on_event(&mut self, ev: InMsg, w: &mut Writer) {
        match ev {
            // "Add Note" button
            InMsg::ButtonClicked { widget_id: 1, .. } => {
                if self.notes.len() < MAX_NOTES {
                    self.notes.push(Note { id: self.next_id, done: false });
                    self.next_id += 1;
                    self.save_state(w);
                }
            }
            // "Clear Done" button
            InMsg::ButtonClicked { widget_id: 2, .. } => {
                self.notes.retain(|n| !n.done);
                self.save_state(w);
            }
            // Checkbox toggled
            InMsg::CheckboxChanged { widget_id, val, .. } => {
                let idx = widget_id.wrapping_sub(100) as usize;
                if idx < self.notes.len() {
                    self.notes[idx].done = val;
                    self.save_state(w);
                }
            }
            // Restore saved state
            InMsg::StateResponse { key, val, .. } if key == "notes" => {
                self.load_notes(val);
            }
            _ => {}
        }
    }
}

impl NotepadPlugin {
    /// Serialize notes as "id,done;id,done;..." and persist.
    fn save_state(&self, w: &mut Writer) {
        let val: String = self.notes.iter()
            .map(|n| format!("{},{}", n.id, if n.done { 1 } else { 0 }))
            .collect::<Vec<_>>()
            .join(";");
        w.set_state("notes", &val);
    }

    /// Deserialize notes from "id,done;id,done;...".
    fn load_notes(&mut self, val: &str) {
        self.notes.clear();
        self.next_id = 1;
        if val.is_empty() { return; }

        for entry in val.split(';') {
            let mut parts = entry.split(',');
            let id: u16 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
            let done: bool = parts.next().map(|s| s == "1").unwrap_or(false);
            if id > 0 {
                self.notes.push(Note { id, done });
                if id >= self.next_id { self.next_id = id + 1; }
            }
        }
    }
}

// Generate the schemify_plugin export symbol and schemify_process entry point
schemify_plugin::export_plugin!(NotepadPlugin, "NotePad", "0.1.0");
```

```python [Python]
# notepad.py -- Note Pad plugin for Schemify (Python)
import schemify

MAX_NOTES = 32

class NotepadPlugin(schemify.Plugin):
    def __init__(self):
        self.notes = []      # List of {"id": int, "done": bool}
        self.next_id = 1

    def on_load(self, w: schemify.Writer):
        """Called once when the plugin is loaded."""
        # Register a right-sidebar panel
        w.register_panel("notepad", "Note Pad", "notepad",
                         schemify.LAYOUT_RIGHT_SIDEBAR, 0)
        # Request any previously saved notes
        w.get_state("notes")

    def on_draw(self, panel_id: int, w: schemify.Writer):
        """Called every frame to render the panel UI."""
        w.button("Add Note", id=1)
        w.button("Clear Done", id=2)
        w.separator(id=3)

        # Render each note as a checkbox
        for i, note in enumerate(self.notes):
            label = f"Note {note['id']}"
            w.checkbox(note["done"], label, id=100 + i)

        if not self.notes:
            w.label("No notes yet. Click 'Add Note' to start.", id=99)

    def on_event(self, msg: dict, w: schemify.Writer):
        """Called for button clicks, checkbox toggles, state responses."""
        tag = msg["tag"]

        if tag == schemify.TAG_BUTTON_CLICKED:
            if msg["widget_id"] == 1 and len(self.notes) < MAX_NOTES:
                # "Add Note" button
                self.notes.append({"id": self.next_id, "done": False})
                self.next_id += 1
                self._save_state(w)
            elif msg["widget_id"] == 2:
                # "Clear Done" button
                self.notes = [n for n in self.notes if not n["done"]]
                self._save_state(w)

        elif tag == schemify.TAG_CHECKBOX_CHANGED:
            idx = msg["widget_id"] - 100
            if 0 <= idx < len(self.notes):
                self.notes[idx]["done"] = msg["val"]
                self._save_state(w)

        elif tag == schemify.TAG_STATE_RESPONSE:
            if msg["key"] == "notes":
                self._load_notes(msg["val"])

    def _save_state(self, w: schemify.Writer):
        """Serialize notes as 'id,done;id,done;...' and persist."""
        val = ";".join(
            f"{n['id']},{1 if n['done'] else 0}" for n in self.notes
        )
        w.set_state("notes", val)

    def _load_notes(self, val: str):
        """Deserialize notes from 'id,done;id,done;...'."""
        self.notes.clear()
        self.next_id = 1
        if not val:
            return
        for entry in val.split(";"):
            parts = entry.split(",")
            if len(parts) == 2:
                nid = int(parts[0])
                done = parts[1] == "1"
                self.notes.append({"id": nid, "done": done})
                if nid >= self.next_id:
                    self.next_id = nid + 1

# --- Wiring: create the plugin instance and define the process entry point ---
_plugin = NotepadPlugin()

def schemify_process(in_bytes: bytes) -> bytes:
    return schemify.run_plugin(_plugin, in_bytes)
```

```go [Go]
// main.go -- Note Pad plugin for Schemify (Go/TinyGo)
package main

import (
	"fmt"
	"strconv"
	"strings"
	"unsafe"

	schemify "github.com/uwasic/schemify/tools/sdk/bindings/tinygo/schemify"
)

const maxNotes = 32

type Note struct {
	ID   uint16
	Done bool
}

type NotepadPlugin struct {
	notes  []Note
	nextID uint16
}

func (p *NotepadPlugin) OnLoad(w *schemify.Writer) {
	p.nextID = 1

	// Register a right-sidebar panel
	w.RegisterPanel("notepad", "Note Pad", "notepad",
		schemify.LayoutRightSidebar, 0)

	// Request any previously saved notes
	w.GetState("notes")
}

func (p *NotepadPlugin) OnUnload(w *schemify.Writer) {}

func (p *NotepadPlugin) OnTick(dt float32, w *schemify.Writer) {}

func (p *NotepadPlugin) OnDraw(panelID uint16, w *schemify.Writer) {
	w.Button("Add Note", 1)
	w.Button("Clear Done", 2)
	w.Separator(3)

	// Render each note as a checkbox
	for i, note := range p.notes {
		label := fmt.Sprintf("Note %d", note.ID)
		w.Checkbox(note.Done, label, uint32(100+i))
	}

	if len(p.notes) == 0 {
		w.Label("No notes yet. Click 'Add Note' to start.", 99)
	}
}

func (p *NotepadPlugin) OnEvent(msg schemify.Msg, w *schemify.Writer) {
	switch msg.Tag {

	case schemify.TagButtonClicked:
		ev := msg.Data.(schemify.MsgButtonClicked)
		if ev.WidgetId == 1 && len(p.notes) < maxNotes {
			// "Add Note" button
			p.notes = append(p.notes, Note{ID: p.nextID, Done: false})
			p.nextID++
			p.saveState(w)
		} else if ev.WidgetId == 2 {
			// "Clear Done" button
			kept := p.notes[:0]
			for _, n := range p.notes {
				if !n.Done {
					kept = append(kept, n)
				}
			}
			p.notes = kept
			p.saveState(w)
		}

	case schemify.TagCheckboxChanged:
		ev := msg.Data.(schemify.MsgCheckboxChanged)
		idx := int(ev.WidgetId) - 100
		if idx >= 0 && idx < len(p.notes) {
			p.notes[idx].Done = ev.Val
			p.saveState(w)
		}

	case schemify.TagStateResponse:
		ev := msg.Data.(schemify.MsgStateResponse)
		if ev.Key == "notes" {
			p.loadNotes(ev.Val)
		}
	}
}

// saveState serializes notes as "id,done;id,done;..." and persists.
func (p *NotepadPlugin) saveState(w *schemify.Writer) {
	var sb strings.Builder
	for i, n := range p.notes {
		if i > 0 {
			sb.WriteByte(';')
		}
		d := 0
		if n.Done {
			d = 1
		}
		fmt.Fprintf(&sb, "%d,%d", n.ID, d)
	}
	w.SetState("notes", sb.String())
}

// loadNotes deserializes notes from "id,done;id,done;...".
func (p *NotepadPlugin) loadNotes(val string) {
	p.notes = nil
	p.nextID = 1
	if val == "" {
		return
	}
	for _, entry := range strings.Split(val, ";") {
		parts := strings.SplitN(entry, ",", 2)
		if len(parts) != 2 {
			continue
		}
		id, err := strconv.ParseUint(parts[0], 10, 16)
		if err != nil {
			continue
		}
		done := parts[1] == "1"
		p.notes = append(p.notes, Note{ID: uint16(id), Done: done})
		if uint16(id) >= p.nextID {
			p.nextID = uint16(id) + 1
		}
	}
}

// --- Plugin instance and ABI entry point ---

var plugin NotepadPlugin

//go:wasmexport schemify_process
func schemify_process(inPtr *byte, inLen uintptr, outPtr *byte, outCap uintptr) uintptr {
	return schemify.RunPlugin(&plugin, inPtr, inLen, outPtr, outCap)
}

// Required by TinyGo -- keep it empty.
func main() {}

// Descriptor export for native builds.
// For WASM builds, the host reads ABI version from the descriptor.
//
//export schemify_plugin
var schemifyPlugin = struct {
	ABIVersion uint32
	Name       *byte
	Version    *byte
	Process    uintptr
}{
	ABIVersion: schemify.AbiVersion,
	Name:       (*byte)(unsafe.Pointer(unsafe.StringData("NotePad\x00"))),
	Version:    (*byte)(unsafe.Pointer(unsafe.StringData("0.1.0\x00"))),
	Process:    0, // filled by RunPlugin at load time
}
```

:::

## Build and Install

::: code-group

```sh [Zig]
# From the notepad-plugin/ directory:
zig build
# The .so/.dll is built to zig-out/lib/
# Copy to your Schemify plugin directory:
cp zig-out/lib/libnotepad-plugin.so ~/.config/Schemify/NotePad/libNotePad.so
```

```sh [C]
# From the notepad-plugin/ directory:
zig build
# Copy to your Schemify plugin directory:
cp zig-out/lib/libnotepad-plugin.so ~/.config/Schemify/NotePad/libNotePad.so
```

```sh [Rust]
# Build the shared library:
cargo build --release
# Copy to your Schemify plugin directory:
cp target/release/libnotepad_plugin.so ~/.config/Schemify/NotePad/libNotePad.so
```

```sh [Python]
# No build step -- just copy the script:
mkdir -p ~/.config/Schemify/SchemifyPython/scripts
cp notepad.py ~/.config/Schemify/SchemifyPython/scripts/notepad.py
```

```sh [Go]
# Build with TinyGo for WASM:
tinygo build -o notepad.wasm -target=wasi .
# Or build a native shared library:
tinygo build -o libNotePad.so -buildmode=c-shared .
cp libNotePad.so ~/.config/Schemify/NotePad/libNotePad.so
```

:::

## See It in Action

1. **Launch Schemify** -- the Note Pad panel appears in the right sidebar
2. **Click "Add Note"** -- a checkbox appears labeled "Note 1"
3. **Click "Add Note" again** -- "Note 2" appears below it
4. **Check off "Note 1"** -- the checkbox is marked as done
5. **Click "Clear Done"** -- "Note 1" disappears, leaving only "Note 2"
6. **Restart Schemify** -- your notes are still there thanks to `setState`/`getState` persistence

## How It Works

Every Schemify plugin follows the same lifecycle, regardless of language:

1. **Load** -- The host sends a `load` message. Your plugin registers a panel and optionally requests saved state.
2. **Draw** -- Each frame, the host sends `draw_panel`. Your plugin writes UI widget messages (buttons, checkboxes, labels) to the output buffer.
3. **Events** -- When the user interacts with a widget, the host sends the corresponding event (`button_clicked`, `checkbox_changed`, etc.) in the next frame's input batch.
4. **State** -- Call `setState` to persist data and `getState` to retrieve it. The host stores it for you across sessions.

All communication happens through a flat binary buffer -- no function pointers, no callbacks, no host imports. This is what makes the same plugin work on both native and WASM targets.

## What's Next?

Ready to build something bigger? Check out the full guide for your language:

- [Zig Plugin Guide](/plugins/creating/zig) -- native Zig with direct access to `PluginIF`
- [C Plugin Guide](/plugins/creating/c) -- header-only C99 SDK
- [C++ Plugin Guide](/plugins/creating/cpp) -- same C SDK, works with C++
- [Rust Plugin Guide](/plugins/creating/rust) -- safe Rust wrappers with `Plugin` trait
- [Python Plugin Guide](/plugins/creating/python) -- runs via the SchemifyPython host
- [Go Plugin Guide](/plugins/creating/go) -- TinyGo for WASM or native builds
- [WASM Plugin Guide](/plugins/creating/wasm) -- cross-language WASM targeting

For the complete message protocol and all available widgets, see the [API Reference](/plugins/api).
