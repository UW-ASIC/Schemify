"""Maps JSON-RPC method calls to Schemify Writer operations.

This module translates high-level RPC commands into the binary
protocol calls that the Schemify host understands.
"""

from __future__ import annotations


class CommandMap:
    """Translate RPC (method, params) into Writer calls."""

    def execute(self, method: str, params: dict, w) -> None:
        """Execute a pending write operation via the Schemify Writer.

        Called from on_tick() in the main thread with the active Writer.
        """
        if method == "push_command":
            text = params.get("text", "")
            if text:
                # push_command expects a single command string via the SDK.
                # We use the Writer's internal _hdr to send a push_command tag.
                _push_command(w, text)
            return

        if method == "get_state":
            key = params.get("key", "")
            if key:
                w.get_state(key)
            return

        if method == "query_instances":
            w.query_instances()
            return

        if method == "query_nets":
            w.query_nets()
            return

        if method == "request_refresh":
            w.request_refresh()
            return


def _push_command(w, text: str) -> None:
    """Send a push_command message (tag 0x83) with the command text.

    The push_command tag expects: [u16 len][str command_text]
    This routes through the host's command parser — same as the vim bar.
    """
    import struct
    b = text.encode("utf-8")
    payload = struct.pack("<H", len(b)) + b
    w._hdr(0x83, payload)
