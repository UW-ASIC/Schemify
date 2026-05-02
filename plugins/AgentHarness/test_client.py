#!/usr/bin/env python3
"""Test client for AgentHarness — builds a common-source amplifier.

Usage:
  1. Start Schemify (with AgentHarness enabled)
  2. Run: python3 test_client.py

This creates a simple NMOS common-source amplifier:
  - M1 (nmos4): amplifier transistor
  - R1 (resistor): drain load
  - V1 (vsource): VDD supply
  - V2 (vsource): input signal
  - GND symbols
  - Wires connecting everything
"""

import json
import os
import socket
import sys
import time


def sock_path():
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime:
        return os.path.join(runtime, "schemify-agent.sock")
    return os.path.expanduser("~/.config/Schemify/schemify-agent.sock")


class AgentClient:
    def __init__(self):
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._id = 0

    def connect(self, path: str):
        self._sock.connect(path)
        print(f"Connected to {path}")

    def call(self, method: str, params: dict | None = None) -> dict:
        self._id += 1
        msg = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params:
            msg["params"] = params
        raw = json.dumps(msg).encode() + b"\n"
        self._sock.sendall(raw)

        buf = b""
        while b"\n" not in buf:
            chunk = self._sock.recv(4096)
            if not chunk:
                raise ConnectionError("Socket closed")
            buf += chunk

        line = buf.split(b"\n", 1)[0]
        resp = json.loads(line)

        if "error" in resp:
            print(f"  ERROR: {resp['error']}")
        elif "result" in resp:
            result = resp["result"]
            # Compact display
            if isinstance(result, dict):
                print(f"  -> {result}")
            elif isinstance(result, list) and len(result) > 5:
                print(f"  -> [{len(result)} items]")
            else:
                print(f"  -> {result}")
        return resp

    def cmd(self, text: str) -> dict:
        """Send a Schemify command (same as vim bar)."""
        print(f"  CMD: {text}")
        return self.call("command", {"text": text})

    def close(self):
        self._sock.close()


def build_common_source_amp(c: AgentClient):
    """Build a common-source NMOS amplifier schematic."""

    print("\n=== Building Common-Source Amplifier ===\n")

    # Check initial state
    print("1. Checking info...")
    c.call("info")

    # List available skills
    print("\n2. Available skills:")
    c.call("list_skills")

    # Create a new file
    print("\n3. Creating new schematic...")
    c.cmd("file_new")
    time.sleep(0.3)

    # Place components
    print("\n4. Placing components...")

    # NMOS amplifier transistor at center
    c.cmd("place nmos4 M1 200 300")
    time.sleep(0.1)

    # Drain load resistor above M1
    c.cmd("place resistor RD 200 150")
    time.sleep(0.1)

    # VDD supply at top
    c.cmd("place vdd VDD1 200 50")
    time.sleep(0.1)

    # Input voltage source on the left
    c.cmd("place vsource Vin 50 300")
    time.sleep(0.1)

    # VDD supply source
    c.cmd("place vsource VDD 50 150")
    time.sleep(0.1)

    # Ground symbols
    c.cmd("place gnd GND1 200 400")
    time.sleep(0.1)
    c.cmd("place gnd GND2 50 400")
    time.sleep(0.1)

    # Output label
    c.cmd("place lab_pin OUT 300 200")
    time.sleep(0.1)

    # Set properties
    print("\n5. Setting properties...")
    c.cmd("set-prop 0 W 10u")
    c.cmd("set-prop 0 L 180n")
    c.cmd("set-prop 0 model nch")
    c.cmd("set-prop 1 value 10k")
    c.cmd("set-prop 4 value 1.8")  # VDD = 1.8V
    time.sleep(0.1)

    # Add wires
    print("\n6. Adding wires...")

    # VDD to RD top
    c.cmd("add-wire 200 50 200 130 VDD")

    # RD bottom to M1 drain
    c.cmd("add-wire 200 170 200 280")

    # Output tap at drain node
    c.cmd("add-wire 200 200 300 200 out")

    # M1 source to GND
    c.cmd("add-wire 200 320 200 400")

    # Vin to M1 gate
    c.cmd("add-wire 50 300 160 300 vin")

    # Vin source GND
    c.cmd("add-wire 50 350 50 400")

    # VDD source connections
    c.cmd("add-wire 50 130 50 50")
    c.cmd("add-wire 50 50 200 50 VDD")

    time.sleep(0.3)

    # Refresh and check
    print("\n7. Refreshing state...")
    c.call("refresh")

    print("\n8. Listing instances...")
    c.call("list_instances")

    print("\n9. Listing nets...")
    c.call("list_nets")

    # Save
    print("\n10. Saving...")
    c.cmd("file_save_as /tmp/common_source_amp.chn")

    print("\n=== Done! Common-source amplifier created ===")
    print("File saved to: /tmp/common_source_amp.chn")


def main():
    path = sock_path()
    print(f"AgentHarness test client")
    print(f"Socket: {path}")

    if not os.path.exists(path):
        print(f"\nSocket not found at {path}")
        print("Make sure Schemify is running with AgentHarness enabled.")
        print("\nTo enable:")
        print("  1. Add 'AgentHarness' to [plugins] enabled list in Config.toml")
        print("  2. Start Schemify")
        sys.exit(1)

    c = AgentClient()
    try:
        c.connect(path)
        build_common_source_amp(c)
    except ConnectionRefusedError:
        print(f"\nConnection refused. Is Schemify running?")
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nInterrupted.")
    finally:
        c.close()


if __name__ == "__main__":
    main()
