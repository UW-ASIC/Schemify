# Schemify Plugin Protocol Specification

Version 1 -- 2026-05-16

## 1. Overview

Schemify plugins are subprocess programs that communicate with the host over JSON-RPC 2.0, using newline-delimited JSON (NDJSON) on stdin (host-to-plugin) and stdout (plugin-to-host). The host spawns the plugin process, exchanges lifecycle messages, and polls stdout non-blockingly each frame. Any language that can read stdin and write stdout can implement a plugin.

## 2. Transport

- Each message is exactly one JSON object followed by a `\n` (0x0A) byte.
- JSON must be compact (no pretty-printing, no embedded newlines).
- There is no length prefix and no content-type header.
- The host sets `O_NONBLOCK` on the plugin's stdout and drains up to 16 lines per tick.
- Stderr is captured but not part of the protocol.

## 3. JSON-RPC 2.0 Envelope

Every message contains `"jsonrpc": "2.0"`.

**Notification** (no response expected):

```json
{"jsonrpc":"2.0","method":"<method>","params":<object>}
```

`params` may be omitted when there are no parameters.

**Request** (response required):

```json
{"jsonrpc":"2.0","id":<integer>,"method":"<method>","params":<object>}
```

**Success response:**

```json
{"jsonrpc":"2.0","id":<integer>,"result":<value>}
```

**Error response:**

```json
{"jsonrpc":"2.0","id":<integer>,"error":{"code":<integer>,"message":"<string>"}}
```

`id` is always a non-negative integer. The responder echoes the same `id` from the request.

## 4. Protocol Version

The current protocol version is **1**. The host sends it in the `lifecycle/initialize` params. Plugins should verify compatibility and may reject unknown versions.

```json
{"jsonrpc":"2.0","method":"lifecycle/initialize","params":{"protocol_version":1}}
```

## 5. Host-to-Plugin Messages

All messages in this section are sent by the host on the plugin's stdin.

| Method | Type | Params | Description |
|---|---|---|---|
| `lifecycle/initialize` | notification | `{"protocol_version": <int>}` | Sent once after spawn. Plugin should perform setup. |
| `lifecycle/shutdown` | notification | *(none)* | Sent before the host kills the process. Plugin should clean up. |
| `lifecycle/tick` | notification | `{"dt": <float>}` | Sent every frame. `dt` is seconds since last tick. |
| `ui/draw_panel` | notification | `{"panel_id": <int>}` | Requests the plugin to emit widgets for the given panel. |
| `ui/button_clicked` | notification | `{"panel_id": <int>, "widget_id": <int>}` | A button widget was clicked. |
| `ui/slider_changed` | notification | `{"panel_id": <int>, "widget_id": <int>, "value": <float>}` | A slider value changed. |
| `ui/checkbox_changed` | notification | `{"panel_id": <int>, "widget_id": <int>, "value": <bool>}` | A checkbox was toggled. |
| `ui/text_changed` | notification | `{"panel_id": <int>, "widget_id": <int>}` | Text input content changed. |

## 6. Plugin-to-Host Messages

All messages in this section are sent by the plugin on stdout.

### Notifications (no response)

| Method | Params | Description |
|---|---|---|
| `host/set_status` | `{"text": "<string>"}` | Set the status bar message. |
| `host/log` | `{"message": "<string>", "level": "<string>"}` | Log a message. Level: `"info"`, `"warn"`, `"err"`. |
| `host/push_command` | `{"command": "<string>"}` | Push a command string into the host command queue. |
| `host/request_refresh` | `{}` | Request the host to refresh plugin state. |
| `host/register_panel` | `{"id": "<string>", "title": "<string>", "layout": <int>, "vim_cmd": "<string>", "keybind": <int>}` | Register a UI panel at runtime. See section 8 for layout values. |
| `host/register_command` | `{"id": "<string>", "name": "<string>", "description": "<string>"}` | Register a user-invocable command. |
| `ui/emit_widgets` | `{"panel_id": <int>, "widgets": [<widget>, ...]}` | Emit the widget tree for a panel. Typically sent in response to `ui/draw_panel`. |

### Requests (response expected)

| Method | Params | Expected Result |
|---|---|---|
| `host/read_file` | `{"path": "<string>"}` | `{"data": "<string>"}` or error. Subject to capability checks. |
| `host/write_file` | `{"path": "<string>", "data": "<string>"}` | `{"success": <bool>}` or error. Subject to capability checks. |
| `host/query_state` | `{"key": "<string>"}` | `{"value": "<string>"}` or error. |

## 7. Widget Schema

Widgets are JSON objects in the `widgets` array of `ui/emit_widgets`. Widget IDs are **strings**, not integers.

### Widget Tags

| Tag | Description |
|---|---|
| `label` | Static text. |
| `button` | Clickable button. |
| `separator` | Horizontal divider. |
| `begin_row` | Start a horizontal layout group. |
| `end_row` | End a horizontal layout group. |
| `slider` | Numeric slider. |
| `checkbox` | Toggle checkbox. |
| `progress` | Progress bar (read-only). |
| `collapsible_start` | Start of a collapsible section. |
| `collapsible_end` | End of a collapsible section. |
| `tooltip` | Tooltip text attached to the preceding widget. |
| `text_input` | Single-line text field. |
| `text_area` | Multi-line text field. |

### Widget Object Fields

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `tag` | string | yes | -- | One of the tag values above. |
| `str` | string | no | `""` | Display text, label content, or hint text. |
| `widget_id` | string | no | `""` | Unique identifier for interactive widgets. Referenced in event callbacks. |
| `val` | float | no | `0.0` | Current value (slider position, checkbox state as 0.0/1.0, progress fraction). |
| `min` | float | no | `0.0` | Minimum value (sliders). |
| `max` | float | no | `1.0` | Maximum value (sliders). |
| `open` | bool | no | `false` | Initial open state (`collapsible_start` only). |

Fields at their default value may be omitted from the wire format.

### Example

```json
{"jsonrpc":"2.0","method":"ui/emit_widgets","params":{"panel_id":0,"widgets":[
  {"tag":"label","str":"Count: 5"},
  {"tag":"separator"},
  {"tag":"button","str":"Increment","widget_id":"inc"},
  {"tag":"slider","widget_id":"gain","val":0.5,"min":0.0,"max":10.0}
]}}
```

## 8. Panel Layout

The `layout` field in `host/register_panel` is an integer enum:

| Value | Name | Description |
|---|---|---|
| 0 | `overlay` | Floating overlay panel. |
| 1 | `left_sidebar` | Docked to the left sidebar. |
| 2 | `right_sidebar` | Docked to the right sidebar. |
| 3 | `bottom_bar` | Docked to the bottom bar. |

## 9. Lifecycle

```
Host                              Plugin
 |                                  |
 |--- spawn process --------------->|
 |                                  |
 |-- lifecycle/initialize --------->|
 |                                  |  (plugin calls on_load, registers panels/commands)
 |<-- host/register_panel ----------|
 |<-- host/register_command --------|
 |                                  |
 |== per-frame loop ================|
 |                                  |
 |-- lifecycle/tick --------------->|
 |                                  |
 |-- ui/draw_panel {panel_id:0} --->|
 |<-- ui/emit_widgets --------------|
 |                                  |
 |-- ui/button_clicked ------------>|  (user interaction)
 |<-- host/set_status --------------|
 |                                  |
 |== end loop ======================|
 |                                  |
 |-- lifecycle/shutdown ----------->|
 |                                  |  (plugin calls on_unload, exits)
 |--- process exits --------------->|
```

1. The host spawns the plugin subprocess using the `command` from `plugin.toml`.
2. The host sends `lifecycle/initialize` with the protocol version.
3. The plugin performs setup (registers panels, commands) and enters its read loop.
4. Each frame, the host sends `lifecycle/tick` and `ui/draw_panel` for visible panels.
5. The plugin responds to `ui/draw_panel` by sending `ui/emit_widgets`.
6. User interactions (button clicks, slider changes, etc.) are forwarded as notifications.
7. On shutdown, the host sends `lifecycle/shutdown`. The plugin cleans up and exits.

## 10. Error Handling

Standard JSON-RPC 2.0 error codes:

| Code | Name | Meaning |
|---|---|---|
| -32700 | Parse error | Invalid JSON. |
| -32600 | Invalid request | Missing `jsonrpc` field or wrong version. |
| -32601 | Method not found | Unknown method name. |
| -32602 | Invalid params | Params present but wrong type or missing required fields. |
| -32603 | Internal error | Host-side processing failure. |

Error responses are only sent for messages with an `id` (requests). Malformed notifications are silently dropped.

## 11. Capabilities

Plugin capabilities are declared in `plugin.toml` under `[capabilities]`. The host enforces these at runtime -- for example, `host/read_file` requests are rejected unless the plugin has the appropriate file-read capability.

| Capability | Description |
|---|---|
| `file_read_project` | Read files within the project directory. |
| `file_read_plugin_data` | Read files within the plugin's data directory. |
| `file_write_plugin_data` | Write files within the plugin's data directory. |
| `schematic_mutate` | Modify the schematic (place components, add wires). |
| `network` | Make network requests. |
| `canvas_draw` | Draw directly on the canvas overlay. |
| `simulate` | Invoke simulation. |

### plugin.toml Example

```toml
[plugin]
name        = "My Plugin"
version     = "0.1.0"
author      = "Your Name"
description = "A Schemify plugin"
command     = "python3 src/plugin.py"
runtime     = "subprocess"
api         = 1

[capabilities]
file_read_project = true

[[panels]]
id       = "main"
title    = "My Plugin"
layout   = "right_sidebar"
```
