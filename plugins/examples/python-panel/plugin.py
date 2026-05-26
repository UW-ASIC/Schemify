#!/usr/bin/env python3
"""
SchemifyRS plugin demonstrating:
- Registering a panel in the sidebar
- Querying schematic instances (request/response)
- Drawing overlay markers on the canvas
- Handling multiple event subscriptions
- Responding to theme changes
- Pushing widget trees with theme-aware colors
"""
import json
import sys
import threading


# --- JSON-RPC helpers ---

_next_id = 0
_pending = {}  # id -> callback


def send(msg: dict):
    print(json.dumps(msg), flush=True)


def notify(method: str, params: dict = None):
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    send(msg)


def request(method: str, params: dict = None, callback=None):
    """Send a request and register a callback for the response."""
    global _next_id
    _next_id += 1
    rid = _next_id
    msg = {"jsonrpc": "2.0", "id": rid, "method": method}
    if params is not None:
        msg["params"] = params
    if callback:
        _pending[rid] = callback
    send(msg)
    return rid


def log(message: str, level: str = "info"):
    notify("host/log", {"level": level, "message": message})


# --- Plugin logic ---

instance_cache = []
is_dark_mode = True


def on_instances_result(result):
    """Called when we get the instance query response."""
    global instance_cache
    if result is None:
        return
    instance_cache = result if isinstance(result, list) else []
    log(f"cached {len(instance_cache)} instances")
    update_overlay()
    update_panel()


def update_overlay():
    """Draw a marker on every instance position."""
    shapes = []
    for inst in instance_cache:
        # Instances have x, y fields (world coordinates)
        x = inst.get("x", 0)
        y = inst.get("y", 0)
        shapes.append({
            "Marker": {
                "x": float(x),
                "y": float(y),
                "kind": "Info",
                "color": [100, 200, 255, 180],
            }
        })

    notify("overlay/update", {
        "name": "instance_markers",
        "z_order": 5,
        "visible": True,
        "shapes": shapes,
    })


def update_panel():
    """Push widget tree to our registered panel."""
    count = len(instance_cache)
    widgets = [
        {"Heading": "Instance Inspector"},
        {"KeyValue": {"entries": [
            ["Instances", str(count)],
            ["Theme", "Dark" if is_dark_mode else "Light"],
        ]}},
        {"Separator": None},
        {"Button": {"label": "Refresh", "action": "refresh"}},
    ]
    if count > 0:
        # Badge uses a theme token — adapts to dark/light mode automatically
        widgets.append({"Badge": {"text": f"{count} found", "color": "success"}})
    else:
        widgets.append({"Alert": {"level": "warn", "message": "No instances found"}})

    # ProgressBar with theme-aware accent color
    widgets.append({"ProgressBar": {"value": min(count / 20.0, 1.0), "color": "accent"}})

    notify("panels/update_widgets", {
        "panel": "Instance Inspector",
        "widgets": widgets,
    })


def refresh_instances():
    """Query the host for all instances."""
    request("state/query_instances", callback=on_instances_result)


# --- Message handling ---

def handle_message(msg: dict):
    method = msg.get("method")
    params = msg.get("params")
    msg_id = msg.get("id")

    # Response to one of our requests
    if method is None and msg_id is not None:
        cb = _pending.pop(msg_id, None)
        if cb:
            cb(msg.get("result"))
        return

    # Notifications from host
    if method == "lifecycle/initialize":
        log("instance inspector starting")
        # Register our panel
        notify("panels/register", {
            "name": "Instance Inspector",
            "slot": "RightSidebar",
            "priority": 10,
            "default_visible": True,
        })
        # Register refresh command
        notify("commands/register", {
            "name": "inspect_refresh",
            "description": "Refresh instance inspection",
            "keybind": "Ctrl+Shift+I",
        })
        # Initial query
        refresh_instances()

    elif method == "lifecycle/shutdown":
        log("inspector shutting down")
        # Clear overlay before exit
        notify("overlay/update", {
            "name": "instance_markers",
            "z_order": 5,
            "visible": False,
            "shapes": [],
        })
        sys.exit(0)

    elif method == "state/schematic_changed":
        refresh_instances()

    elif method == "state/selection_changed":
        log("selection changed")

    elif method == "state/theme_changed":
        global is_dark_mode
        # Theme tokens are included in the notification payload
        if params and "tokens" in params:
            dark_token = params["tokens"].get("dark_mode")
            if dark_token and isinstance(dark_token, dict):
                is_dark_mode = dark_token.get("Bool", True)
        log(f"theme changed (dark={is_dark_mode})")
        update_panel()

    else:
        if method:
            log(f"unhandled: {method}")


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        handle_message(msg)


if __name__ == "__main__":
    main()
