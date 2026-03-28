# Plugin Architecture

## The ABI boundary

Plugins communicate with the host through a single `extern struct` exported as
the symbol `schemify_plugin`.  Using `extern struct` means the layout is defined
by the C ABI — not Zig's internal layout — so every language that can produce a
C-compatible shared library or WASM module can implement a plugin.

```zig
// src/PluginIF.zig (abridged)
pub const ProcessFn = *const fn (
    in_ptr: [*]const u8,
    in_len: usize,
    out_ptr: [*]u8,
    out_cap: usize,
) callconv(.c) usize;

pub const Descriptor = extern struct {
    name:        [*:0]const u8,
    version_str: [*:0]const u8,
    process:     ProcessFn,
};
```

Every plugin must export a `Descriptor` constant named `schemify_plugin` and
implement a single `process` function.  There are no other required exports.

## Message-passing protocol

All communication between the host and a plugin goes through `process`.  The
host packs one or more messages into the input buffer and calls `process`; the
plugin reads those messages, acts on them, and writes response messages into the
output buffer.

### Wire format

```
[u8 tag][u16 payload_sz LE][payload_sz bytes]
```

- **tag** — identifies the message type (see `Tag` enum in `src/PluginIF.zig`)
- **payload_sz** — length of the payload in bytes, little-endian u16
- **payload** — message-specific bytes

Payload encoding conventions:

| Type        | Encoding                              |
|-------------|---------------------------------------|
| string      | `[u16 len LE][len bytes]` (UTF-8, no null terminator) |
| f32 array   | `[u32 count LE][count × 4 bytes LE]`  |
| u8 array    | `[u32 count LE][count bytes]`         |
| scalar ints | little-endian, width matches type     |

### Buffer overflow and retry

`process` returns the number of bytes written to `out_ptr`.  If the output
buffer was too small to hold all response messages, the plugin must write
nothing and return `std.math.maxInt(usize)`.  The host will double the buffer
and call `process` again with the same input.

### Reader / Writer helpers

`src/PluginIF.zig` ships a `Reader` and a `Writer` that handle all encoding and
decoding, so plugins do not need to manipulate the wire format directly:

```zig
var r = Plugin.Reader.init(in_ptr[0..in_len]);
var w = Plugin.Writer.init(out_ptr[0..out_cap]);

while (r.next()) |msg| {
    switch (msg) { ... }
}

return if (w.overflow()) std.math.maxInt(usize) else w.pos;
```

`Reader.next()` skips unknown tags and tags from the wrong direction
transparently, so plugins are forward-compatible with new host message types.

## Host → plugin messages

The host drives the plugin lifecycle and delivers events by sending messages
in the input buffer:

| Tag                  | When sent                                              |
|----------------------|--------------------------------------------------------|
| `load`               | Once, when the plugin is first loaded                  |
| `unload`             | Once, before the plugin is closed                      |
| `tick`               | Every frame; payload includes `dt: f32`                |
| `draw_panel`         | Each frame a registered panel is visible               |
| `button_clicked`     | User clicked a button the plugin rendered              |
| `slider_changed`     | User moved a slider                                    |
| `text_changed`       | User edited a text field                               |
| `checkbox_changed`   | User toggled a checkbox                                |
| `command`            | A keybind or external trigger fired a plugin command   |
| `state_response`     | Reply to a previous `get_state` request                |
| `config_response`    | Reply to a previous `get_config` request               |
| `schematic_changed`  | The active schematic was modified                      |
| `selection_changed`  | The selected instance changed                          |
| `schematic_snapshot` | Summary counts for instances, wires, nets              |
| `instance_data`      | Per-instance data from a `query_instances` request     |
| `instance_prop`      | A property of one instance                            |
| `net_data`           | A net name/index from a `query_nets` request           |

## Plugin → host messages

The plugin writes response messages using `Writer` methods.  Most can be sent
during any `process` call; UI widget messages are only meaningful during
`draw_panel`.

**Lifecycle and commands**

| Writer method       | Effect                                             |
|---------------------|----------------------------------------------------|
| `registerPanel`     | Register a panel (id, title, vim cmd, layout)      |
| `setStatus`         | Set the host status bar text                       |
| `log`               | Emit a log entry with level, tag, and message      |
| `pushCommand`       | Push a command into the host command queue         |
| `requestRefresh`    | Ask the host to repaint on the next frame          |
| `registerKeybind`   | Bind a key+mods combination to a command tag       |
| `setState`          | Persist a key/value in plugin state storage        |
| `getState`          | Request a state value (arrives as `state_response`) |
| `setConfig`         | Write a TOML-backed config value                   |
| `getConfig`         | Request a config value (arrives as `config_response`) |

**Schematic mutations**

| Writer method       | Effect                                             |
|---------------------|----------------------------------------------------|
| `placeDevice`       | Place a device symbol in the active schematic      |
| `addWire`           | Add a wire segment                                 |
| `setInstanceProp`   | Set a property on a schematic instance             |
| `queryInstances`    | Request all instance data (replies via `instance_data`) |
| `queryNets`         | Request all net data (replies via `net_data`)      |

## Runtime lifecycle

`src/plugins/runtime.zig` manages native plugins:

1. `dlopen` the `.so`
2. `dlsym("schemify_plugin")` to get the `Descriptor`
3. Call `process` with a `load` message
4. Call `process` with a `tick` message every frame
5. Call `process` with a `draw_panel` message each frame a panel is visible
6. Call `process` with an `unload` message before `dlclose`

The same binary protocol runs on WASM.  The WASM host (`src/web/plugin_host.js`)
calls the exported `schemify_process` function with the same wire-format buffers.
No `extern "host"` imports are required; the protocol is identical on both
targets.

## Panel rendering

Panels are declared by writing a `register_panel` message during the `load`
call.  Each frame the panel is visible the host sends a `draw_panel` message.
The plugin responds by writing a sequence of UI widget messages — `ui_label`,
`ui_button`, `ui_slider`, etc. — which the host interprets and renders in order.

```zig
.draw_panel => |ev| {
    _ = ev;
    w.label("Threshold", 0);
    w.slider(threshold, 0.0, 1.0, 1);
    w.button("Apply", 2);
},
```

Widget `id` values are chosen by the plugin.  When the user interacts with a
widget, the host sends a corresponding event (`button_clicked`, `slider_changed`,
etc.) carrying the same `panel_id` and `widget_id`.

Available UI widgets: `label`, `button`, `separator`, `beginRow`/`endRow`,
`slider`, `checkbox`, `progress`, `plot`, `image`,
`collapsibleStart`/`collapsibleEnd`.

## Filesystem: Vfs

Both native and WASM targets expose a platform-agnostic filesystem API through
`Plugin.Vfs` (`src/core/Vfs.zig`):

- **Native** — thin wrappers around `std.fs.cwd()`
- **WASM** — backed by an in-memory store in the JS host that can optionally
  persist to IndexedDB / OPFS

```zig
const data = try Plugin.Vfs.readAlloc(alloc, "config.toml");
try Plugin.Vfs.writeAll("output.sch", data);
try Plugin.Vfs.makePath("my-plugin/cache");
```

See [FileIO & VFS](./creating/wasm#vfs) for usage patterns.
