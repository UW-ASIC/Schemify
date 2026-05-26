#!/usr/bin/env python3
"""
Simple SchemifyRS plugin demonstrating:
- Lifecycle handling (initialize, shutdown)
- Logging to host
- Setting status bar message
- Registering a command
- Receiving state change notifications
"""
import json
import sys


def send(msg: dict):
    """Send a JSON-RPC message to the host via stdout."""
    print(json.dumps(msg), flush=True)


def notify(method: str, params: dict = None):
    """Send a JSON-RPC notification (no response expected)."""
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    send(msg)


def log(message: str, level: str = "info"):
    """Log a message through the host."""
    notify("host/log", {"level": level, "message": message})


def set_status(message: str):
    """Set the status bar message."""
    notify("host/set_status", {"message": message})


def handle_initialize(params):
    """Called when the host initializes us."""
    host_caps = params.get("host_capabilities", {})
    api = host_caps.get("api_version", "unknown")
    log(f"initialized (host api: {api})")
    set_status("Hello plugin ready")

    # Register a command so users can trigger us
    notify("commands/register", {
        "name": "hello_greet",
        "description": "Print a greeting to the log",
        "keybind": "Ctrl+Shift+H",
    })


def handle_shutdown():
    """Called when the host is shutting us down."""
    log("goodbye!")
    sys.exit(0)


def handle_schematic_changed():
    """Called when the schematic changes (we subscribed in plugin.toml)."""
    log("schematic changed — I could do something useful here")


def main():
    log("python-hello starting")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            log(f"bad JSON: {line}", level="warn")
            continue

        method = msg.get("method", "")
        params = msg.get("params")

        if method == "lifecycle/initialize":
            handle_initialize(params or {})
        elif method == "lifecycle/shutdown":
            handle_shutdown()
        elif method == "state/schematic_changed":
            handle_schematic_changed()
        else:
            # Unknown method — just log it
            log(f"unhandled: {method}")


if __name__ == "__main__":
    main()
