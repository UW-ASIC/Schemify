"""JSON-RPC 2.0 server over a Unix domain socket.

Runs in a background thread. Each client connection is handled in its own
thread. The server is single-process safe (removes stale socket on start).
"""

from __future__ import annotations

import json
import os
import socket
import struct
import threading
from typing import Callable


class RpcServer:
    """Threaded Unix socket JSON-RPC server."""

    def __init__(self, sock_path: str, handler: Callable[[str, dict], dict]) -> None:
        self._path = sock_path
        self._handler = handler
        self._server_sock: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._running = False
        self._clients: list[threading.Thread] = []
        self._client_count = 0
        self._lock = threading.Lock()

    def start(self) -> None:
        # Remove stale socket
        try:
            os.unlink(self._path)
        except FileNotFoundError:
            pass

        self._server_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server_sock.bind(self._path)
        self._server_sock.listen(4)
        self._server_sock.settimeout(1.0)  # So we can check _running periodically
        self._running = True

        self._thread = threading.Thread(target=self._accept_loop, daemon=True, name="agent-rpc")
        self._thread.start()

    def stop(self) -> None:
        self._running = False
        if self._server_sock:
            try:
                self._server_sock.close()
            except OSError:
                pass
            self._server_sock = None
        try:
            os.unlink(self._path)
        except FileNotFoundError:
            pass

    def has_clients(self) -> bool:
        with self._lock:
            return self._client_count > 0

    def _accept_loop(self) -> None:
        while self._running:
            try:
                conn, _ = self._server_sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            t = threading.Thread(target=self._client_loop, args=(conn,), daemon=True)
            t.start()

    def _client_loop(self, conn: socket.socket) -> None:
        with self._lock:
            self._client_count += 1
        try:
            conn.settimeout(None)
            buf = b""
            while self._running:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buf += chunk
                # Process all complete newline-delimited JSON-RPC messages
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    resp = self._process_message(line)
                    if resp is not None:
                        out = json.dumps(resp).encode() + b"\n"
                        try:
                            conn.sendall(out)
                        except OSError:
                            return
        except (ConnectionResetError, BrokenPipeError, OSError):
            pass
        finally:
            with self._lock:
                self._client_count -= 1
            try:
                conn.close()
            except OSError:
                pass

    def _process_message(self, data: bytes) -> dict | None:
        try:
            msg = json.loads(data)
        except json.JSONDecodeError as e:
            return {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": f"Parse error: {e}"},
            }

        req_id = msg.get("id")
        method = msg.get("method", "")
        params = msg.get("params", {})

        if not method:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32600, "message": "Missing method"},
            }

        try:
            result = self._handler(method, params if isinstance(params, dict) else {})
        except Exception as e:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32603, "message": str(e)},
            }

        if "error" in result:
            return {"jsonrpc": "2.0", "id": req_id, "error": result["error"]}

        return {"jsonrpc": "2.0", "id": req_id, "result": result.get("result")}
