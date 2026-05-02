"""Schemify AgentHarness plugin — JSON-RPC socket for LLM agents.

Exposes the full Schemify command surface, file I/O, state queries,
and plugin skill documentation over a Unix domain socket.

Panel: BOTTOM_BAR, vim_cmd "agent"
"""

from __future__ import annotations

import importlib.util as _ilu
import os
import sys
import threading
import json

# ---------------------------------------------------------------------------
# SDK path resolution
# ---------------------------------------------------------------------------
_PLUGIN_SRC_DIR = os.path.dirname(os.path.abspath(__file__))
_SDK_LIB = os.path.normpath(
    os.path.join(_PLUGIN_SRC_DIR, "..", "..", "..", "tools", "api", "python", "src", "lib.py")
)
# Fallback: installed location (lib.py alongside plugin.py)
if not os.path.isfile(_SDK_LIB):
    _SDK_LIB = os.path.join(_PLUGIN_SRC_DIR, "lib.py")
if not os.path.isfile(_SDK_LIB):
    _SDK_LIB = os.path.normpath(
        os.path.join(_PLUGIN_SRC_DIR, "..", "lib.py")
    )
_spec = _ilu.spec_from_file_location("schemify_plugin", _SDK_LIB)
schemify_plugin = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(schemify_plugin)  # type: ignore

# Local imports
sys.path.insert(0, _PLUGIN_SRC_DIR)
from rpc_server import RpcServer  # noqa: E402
from command_map import CommandMap  # noqa: E402

TAG = "AgentHarness"

# Widget IDs for the chat UI
WID_CHAT_SCROLL = 100
WID_CHAT_MSG_BASE = 110  # messages: 110-599
WID_CHAT_INPUT = 600
WID_CHAT_SEND = 601
WID_CHAT_INTERRUPT = 602
WID_CHAT_CLEAR = 603


def _socket_path() -> str:
    """Determine socket path: $XDG_RUNTIME_DIR or ~/.config/Schemify/."""
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime:
        return os.path.join(runtime, "schemify-agent.sock")
    cfg = os.path.join(os.path.expanduser("~"), ".config", "Schemify")
    os.makedirs(cfg, exist_ok=True)
    return os.path.join(cfg, "schemify-agent.sock")


def _skills_dir() -> str:
    """Locate skills/ directory."""
    d = os.path.normpath(os.path.join(_PLUGIN_SRC_DIR, "..", "skills"))
    if os.path.isdir(d):
        return d
    # Installed location
    d = os.path.normpath(os.path.join(_PLUGIN_SRC_DIR, "skills"))
    if os.path.isdir(d):
        return d
    return ""


class AgentHarnessPlugin(schemify_plugin.Plugin):
    def __init__(self) -> None:
        self._cmd_map = CommandMap()
        self._rpc: RpcServer | None = None
        self._sock_path = ""
        self._project_dir = ""

        # State cache — populated from host callbacks
        self._instances: list[dict] = []
        self._nets: list[dict] = []
        self._instance_props: dict[int, dict[str, str]] = {}
        self._snapshot: dict = {}
        self._current_file = ""
        self._pending_state: dict[str, str] = {}
        self._state_events: dict[str, threading.Event] = {}

        # Pending writer commands from RPC thread
        self._lock = threading.Lock()
        self._pending_writes: list[tuple[str, dict]] = []

        # Query flow control
        self._query_done = threading.Event()
        self._awaiting_query = False
        self._instance_buf: list[dict] = []
        self._net_buf: list[dict] = []

        # Chat state
        self._chat_history: list[dict] = []  # [{"role": "user"|"assistant"|"system", "content": str}]
        self._streaming_text = ""  # partial response being streamed
        self._is_streaming = False
        self._interrupt_requested = False

    # -- Lifecycle ----------------------------------------------------------

    def on_load(self, w: schemify_plugin.Writer) -> None:
        w.register_panel(
            "agent_harness", "Agent Harness", "agent",
            schemify_plugin.Layout.BOTTOM_BAR, 0,
        )

        self._sock_path = _socket_path()
        self._rpc = RpcServer(self._sock_path, self._handle_rpc)
        self._rpc.start()

        w.set_status(f"AgentHarness: {self._sock_path}")
        w.log(0, TAG, f"Listening on {self._sock_path}")

        # Request initial state
        w.get_state("current_file")
        w.query_instances()
        w.query_nets()

    def on_unload(self, w: schemify_plugin.Writer) -> None:
        if self._rpc:
            self._rpc.stop()
            self._rpc = None
        w.log(0, TAG, "AgentHarness unloaded")

    # -- Panel drawing ------------------------------------------------------

    def on_draw_panel(self, panel_id: int, w: schemify_plugin.Writer) -> None:
        w.label("Agent Harness", 1)
        w.separator(2)

        # -- Status (collapsible) --
        status = "connected" if self._rpc and self._rpc.has_clients() else "waiting"
        w.collapsible_start(f"Status ({status})", False, WID_CHAT_SCROLL)
        w.label(f"Socket: {self._sock_path}", 3)
        w.label(f"Instances: {len(self._instances)}", 5)
        w.label(f"Nets: {len(self._nets)}", 6)
        if self._current_file:
            w.label(f"File: {os.path.basename(self._current_file)}", 7)
        w.collapsible_end(WID_CHAT_SCROLL)

        w.separator(WID_CHAT_SCROLL + 1)

        # -- Chat history --
        wid = WID_CHAT_MSG_BASE
        for msg in self._chat_history[-50:]:
            role = msg["role"]
            content = msg["content"]
            lines = content.split("\n")
            prefix = "You: " if role == "user" else "Agent: " if role == "assistant" else "System: "
            for line in lines[:20]:
                display = prefix + line[:200]
                w.label(display, wid)
                wid += 1
                prefix = "  "
            if len(lines) > 20:
                w.label(f"  ... ({len(lines) - 20} more lines)", wid)
                wid += 1

        # -- Streaming partial response --
        if self._is_streaming and self._streaming_text:
            lines = self._streaming_text.split("\n")
            for line in lines[-10:]:
                w.label(f"Agent: {line[:200]}", wid)
                wid += 1

        w.separator(WID_CHAT_INPUT - 1)

        # -- Chat input --
        w.text_input("Type a message...", "", WID_CHAT_INPUT)

        # -- Buttons --
        w.begin_row(WID_CHAT_SEND)
        if self._is_streaming:
            w.button("Interrupt", WID_CHAT_INTERRUPT)
        w.button("Clear Chat", WID_CHAT_CLEAR)
        w.end_row(WID_CHAT_SEND)

    # -- Tick: drain pending writes from RPC thread -------------------------

    def on_tick(self, dt: float, w: schemify_plugin.Writer) -> None:
        with self._lock:
            pending = list(self._pending_writes)
            self._pending_writes.clear()

        for method, params in pending:
            self._cmd_map.execute(method, params, w)

    # -- Host event handlers ------------------------------------------------

    def on_schematic_changed(self, w: schemify_plugin.Writer) -> None:
        w.query_instances()
        w.query_nets()
        w.get_state("current_file")

    def on_schematic_snapshot(self, msg: dict, w: schemify_plugin.Writer) -> None:
        # Called via custom dispatch below
        self._snapshot = {
            "instance_count": msg.get("instance_count", 0),
            "wire_count": msg.get("wire_count", 0),
            "net_count": msg.get("net_count", 0),
        }

    def on_state_response(self, key: str, val: str, w: schemify_plugin.Writer) -> None:
        if key == "current_file":
            self._current_file = val
        self._pending_state[key] = val
        ev = self._state_events.get(key)
        if ev:
            ev.set()

    def on_instance_data(self, idx: int, name: str, symbol: str,
                         w: schemify_plugin.Writer) -> None:
        self._instance_buf.append({"idx": idx, "name": name, "symbol": symbol})

    def on_selection_changed(self, idx: int, w: schemify_plugin.Writer) -> None:
        pass  # Could track selection if needed

    # -- Custom process override to handle snapshot + query completion ------

    def process(self, in_data: bytes) -> bytes:
        r = schemify_plugin.Reader(in_data)
        w = schemify_plugin.Writer()
        for msg in r:
            t = msg["tag"]
            if   t == "load":               self.on_load(w)
            elif t == "unload":             self.on_unload(w)
            elif t == "tick":               self.on_tick(msg["dt"], w)
            elif t == "draw_panel":         self.on_draw_panel(msg["panel_id"], w)
            elif t == "button_clicked":     self.on_button_clicked(msg["panel_id"], msg["widget_id"], w)
            elif t == "command":            self.on_command(msg["cmd_tag"], msg["payload"], w)
            elif t == "state_response":     self.on_state_response(msg["key"], msg["val"], w)
            elif t == "selection_changed":  self.on_selection_changed(msg["instance_idx"], w)
            elif t == "schematic_changed":  self.on_schematic_changed(w)
            elif t == "schematic_snapshot":
                self._snapshot = {
                    "instance_count": msg.get("instance_count", 0),
                    "wire_count": msg.get("wire_count", 0),
                    "net_count": msg.get("net_count", 0),
                }
                # Snapshot signals end of instance_data/net_data stream
                if self._awaiting_query:
                    self._instances = list(self._instance_buf)
                    self._nets = list(self._net_buf)
                    self._instance_buf.clear()
                    self._net_buf.clear()
                    self._awaiting_query = False
                    self._query_done.set()
            elif t == "instance_data":
                self.on_instance_data(msg["idx"], msg["name"], msg["symbol"], w)
            elif t == "net_data":
                self._net_buf.append({"idx": msg["idx"], "name": msg["name"]})
            elif t == "text_changed":
                self._on_text_changed(msg["panel_id"], msg["widget_id"], msg["text"], w)
            elif t == "instance_prop":
                idx = msg["idx"]
                if idx not in self._instance_props:
                    self._instance_props[idx] = {}
                self._instance_props[idx][msg["key"]] = msg["val"]
        return w.get_bytes()

    # -- Chat text input ----------------------------------------------------

    def _on_text_changed(self, panel_id: int, widget_id: int, text: str,
                         w: schemify_plugin.Writer) -> None:
        if widget_id == WID_CHAT_INPUT and text.strip():
            self._chat_history.append({"role": "user", "content": text.strip(), "_pending": True})
            w.request_refresh()

    # -- Command handling ---------------------------------------------------

    def on_command(self, cmd_tag: str, payload: str, w: schemify_plugin.Writer) -> None:
        if cmd_tag != "agent":
            return
        # The vim command :agent just shows status
        w.set_status(f"AgentHarness: {self._sock_path}")
        w.request_refresh()

    def on_button_clicked(self, panel_id: int, widget_id: int,
                          w: schemify_plugin.Writer) -> None:
        if widget_id == WID_CHAT_INTERRUPT:
            self._interrupt_requested = True
            self._is_streaming = False
            if self._streaming_text:
                self._chat_history.append({"role": "assistant", "content": self._streaming_text + " [interrupted]"})
                self._streaming_text = ""
            w.request_refresh()
        elif widget_id == WID_CHAT_CLEAR:
            self._chat_history.clear()
            self._streaming_text = ""
            self._is_streaming = False
            w.request_refresh()

    # -- RPC handler (called from RPC server thread) ------------------------

    def _handle_rpc(self, method: str, params: dict) -> dict:
        """Handle a JSON-RPC call from the LLM. Thread-safe."""

        # -- Queries (read from cache, no Writer needed) --
        if method == "list_instances":
            return {"result": self._instances}

        if method == "list_wires":
            # Wires are part of the schematic but not streamed via instance_data.
            # Return snapshot count; full wire data requires file read.
            return {"result": [], "note": "Use read_file on the .chn to get wire details, or use list_instances + info"}

        if method == "list_nets":
            return {"result": self._nets}

        if method == "info":
            return {"result": {
                "file": self._current_file,
                "instances": len(self._instances),
                "nets": len(self._nets),
                "snapshot": self._snapshot,
            }}

        if method == "get_instance_prop":
            idx = params.get("idx", -1)
            key = params.get("key")
            props = self._instance_props.get(idx, {})
            if key:
                return {"result": {"val": props.get(key, "")}}
            return {"result": props}

        if method == "get_state":
            key = params.get("key", "")
            # Enqueue a get_state Writer call and wait for response
            ev = threading.Event()
            self._state_events[key] = ev
            with self._lock:
                self._pending_writes.append(("get_state", {"key": key}))
            ev.wait(timeout=5.0)
            self._state_events.pop(key, None)
            val = self._pending_state.pop(key, "")
            return {"result": {"key": key, "val": val}}

        # -- Skills --
        if method == "list_skills":
            sd = _skills_dir()
            if not sd:
                return {"result": []}
            names = [f[:-3] for f in sorted(os.listdir(sd)) if f.endswith(".md")]
            return {"result": names}

        if method == "get_skill":
            name = params.get("name", "")
            sd = _skills_dir()
            if not sd:
                return {"error": {"code": -32000, "message": "Skills directory not found"}}
            path = os.path.join(sd, f"{name}.md")
            if not os.path.isfile(path):
                return {"error": {"code": -32001, "message": f"Skill not found: {name}"}}
            with open(path, "r", encoding="utf-8") as f:
                return {"result": {"name": name, "content": f.read()}}

        # -- File I/O --
        if method == "read_file":
            path = params.get("path", "")
            if not os.path.isabs(path) and self._project_dir:
                path = os.path.join(self._project_dir, path)
            try:
                with open(path, "r", encoding="utf-8") as f:
                    return {"result": {"path": path, "data": f.read()}}
            except Exception as e:
                return {"error": {"code": -32002, "message": str(e)}}

        if method == "write_file":
            path = params.get("path", "")
            data = params.get("data", "")
            if not os.path.isabs(path) and self._project_dir:
                path = os.path.join(self._project_dir, path)
            try:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8") as f:
                    f.write(data)
                return {"result": {"path": path, "written": len(data)}}
            except Exception as e:
                return {"error": {"code": -32003, "message": str(e)}}

        if method == "list_project_files":
            import glob as globmod
            pattern = params.get("glob", "**/*.chn")
            base = self._project_dir or "."
            matches = globmod.glob(os.path.join(base, pattern), recursive=True)
            rel = [os.path.relpath(m, base) for m in sorted(matches)]
            return {"result": rel}

        # -- Network --
        if method == "http_get":
            url = params.get("url", "")
            try:
                import urllib.request
                with urllib.request.urlopen(url, timeout=30) as resp:
                    body = resp.read().decode("utf-8", errors="replace")
                    return {"result": {"status": resp.status, "body": body}}
            except Exception as e:
                return {"error": {"code": -32004, "message": str(e)}}

        # -- Commands (enqueue for on_tick to flush via Writer) --
        if method == "command":
            text = params.get("text", "")
            if not text:
                return {"error": {"code": -32600, "message": "Missing 'text' param"}}
            with self._lock:
                self._pending_writes.append(("push_command", {"text": text}))
            return {"result": {"queued": text}}

        # -- Chat RPC methods --
        if method == "chat_message":
            role = params.get("role", "assistant")
            content = params.get("content", "")
            self._chat_history.append({"role": role, "content": content})
            self._is_streaming = False
            self._streaming_text = ""
            return {"result": {"ok": True}}

        if method == "chat_stream":
            chunk = params.get("chunk", "")
            self._streaming_text += chunk
            self._is_streaming = True
            return {"result": {"ok": True}}

        if method == "chat_stream_end":
            if self._streaming_text:
                self._chat_history.append({"role": "assistant", "content": self._streaming_text})
            self._streaming_text = ""
            self._is_streaming = False
            return {"result": {"ok": True}}

        if method == "chat_poll":
            pending = [m for m in self._chat_history if m.get("_pending")]
            for m in pending:
                m.pop("_pending", None)
            return {"result": pending}

        if method == "is_interrupted":
            was = self._interrupt_requested
            self._interrupt_requested = False
            return {"result": {"interrupted": was}}

        # -- Refresh query cache --
        if method == "refresh":
            self._awaiting_query = True
            self._query_done.clear()
            self._instance_buf.clear()
            self._net_buf.clear()
            with self._lock:
                self._pending_writes.append(("query_instances", {}))
                self._pending_writes.append(("query_nets", {}))
            self._query_done.wait(timeout=5.0)
            return {"result": {
                "instances": len(self._instances),
                "nets": len(self._nets),
            }}

        return {"error": {"code": -32601, "message": f"Unknown method: {method}"}}


# ---------------------------------------------------------------------------
# Module-level entry point
# ---------------------------------------------------------------------------

_plugin = AgentHarnessPlugin()


def schemify_process(in_bytes: bytes) -> bytes:
    return _plugin.process(in_bytes)
