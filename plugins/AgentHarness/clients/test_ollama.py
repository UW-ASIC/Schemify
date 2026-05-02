#!/usr/bin/env python3
"""Smoke test: AgentHarness client + Ollama, with a mock socket server.

Validates the full pipeline without needing Schemify running:
  1. Starts a mock AgentHarness socket server
  2. Connects the LLM client
  3. Sends a circuit design prompt to Ollama
  4. Verifies the LLM generates valid Schemify commands

Usage:
  python3 test_ollama.py
"""

import json
import os
import socket
import tempfile
import threading
import time
import sys

# Add clients/ dir so we can import schemify_agent
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from schemify_agent import OllamaProvider, HarnessClient, extract_commands, _build_system_prompt


# ---------------------------------------------------------------------------
# Mock AgentHarness server
# ---------------------------------------------------------------------------

def _load_real_skills() -> dict[str, str]:
    """Load real skills from the skills/ directory."""
    skills_dir = os.path.normpath(
        os.path.join(os.path.dirname(__file__), "..", "skills")
    )
    skills = {}
    if os.path.isdir(skills_dir):
        for fname in sorted(os.listdir(skills_dir)):
            if fname.endswith(".md"):
                name = fname[:-3]
                with open(os.path.join(skills_dir, fname), "r") as f:
                    skills[name] = f.read()
    if not skills:
        # Fallback minimal
        skills = {
            "schemify_commands": "# Commands\n- `place <symbol> <name> <x> <y>`\n- `add-wire <x0> <y0> <x1> <y1> [net]`\n- `set-prop <idx> <key> <value>`\n- `file_save`\n",
            "primitives": "# Primitives\n- resistor: pins p,n. Props: value\n- nmos4: pins d,g,s,b. Props: W, L, model\n- gnd: ground\n- vdd: VDD\n",
        }
    return skills


MOCK_SKILLS = _load_real_skills()

MOCK_INSTANCES = []
MOCK_COMMAND_LOG = []


def mock_handler(data: bytes) -> bytes:
    """Handle one JSON-RPC message, return response bytes."""
    msg = json.loads(data)
    method = msg.get("method", "")
    params = msg.get("params", {})
    req_id = msg.get("id")

    if method == "list_skills":
        result = list(MOCK_SKILLS.keys())
    elif method == "get_skill":
        name = params.get("name", "")
        if name in MOCK_SKILLS:
            result = {"name": name, "content": MOCK_SKILLS[name]}
        else:
            return json.dumps({"jsonrpc": "2.0", "id": req_id, "error": {"code": -1, "message": "not found"}}).encode() + b"\n"
    elif method == "info":
        result = {"file": "(mock)", "instances": len(MOCK_INSTANCES), "nets": 0}
    elif method == "command":
        text = params.get("text", "")
        MOCK_COMMAND_LOG.append(text)
        MOCK_INSTANCES.append(text)
        result = {"queued": text}
    elif method == "list_instances":
        result = MOCK_INSTANCES
    elif method == "refresh":
        result = {"instances": len(MOCK_INSTANCES), "nets": 0}
    else:
        result = {}

    return json.dumps({"jsonrpc": "2.0", "id": req_id, "result": result}).encode() + b"\n"


def run_mock_server(sock_path: str, ready_event: threading.Event):
    """Run a mock AgentHarness socket server."""
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass
    server.bind(sock_path)
    server.listen(1)
    server.settimeout(30)
    ready_event.set()

    try:
        conn, _ = server.accept()
        conn.settimeout(60)
        buf = b""
        while True:
            try:
                chunk = conn.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if line.strip():
                    resp = mock_handler(line)
                    try:
                        conn.sendall(resp)
                    except BrokenPipeError:
                        break
    except socket.timeout:
        pass
    finally:
        try:
            conn.close()
        except Exception:
            pass
        server.close()
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass


# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

def main():
    print("=" * 60)
    print("Smoke Test: AgentHarness + Ollama (qwen2.5-coder:7b)")
    print("=" * 60)

    # Check Ollama is up
    print("\n1. Checking Ollama...")
    try:
        import urllib.request
        resp = urllib.request.urlopen("http://localhost:11434/api/tags", timeout=5)
        models = json.loads(resp.read())
        names = [m["name"] for m in models.get("models", [])]
        print(f"   Available models: {names}")
        if not any("qwen2.5-coder" in n for n in names):
            print("   WARNING: qwen2.5-coder not found. Run: ollama pull qwen2.5-coder:7b")
            return
    except Exception as e:
        print(f"   ERROR: Ollama not reachable: {e}")
        print("   Run: ollama serve")
        return

    # Start mock server
    print("\n2. Starting mock AgentHarness server...")
    sock_path = os.path.join(tempfile.gettempdir(), "schemify-agent-test.sock")
    ready = threading.Event()
    server_thread = threading.Thread(target=run_mock_server, args=(sock_path, ready), daemon=True)
    server_thread.start()
    ready.wait(timeout=5)
    print(f"   Listening on {sock_path}")

    # Connect client
    print("\n3. Connecting client...")
    client = HarnessClient(sock_path)
    client.connect()
    print("   Connected.")

    # Load skills
    print("\n4. Loading skills...")
    skills = client.load_skills()
    print(f"   Loaded {len(skills)} chars of skill docs.")

    # Build system prompt
    system = _build_system_prompt(skills)

    # Send a circuit design prompt to Ollama
    print("\n5. Asking Ollama to design a circuit...")
    provider = OllamaProvider(model="qwen2.5-coder:7b")

    prompt = (
        "Place a simple voltage divider circuit with two resistors (R1=10k, R2=5k), "
        "a VDD source at the top, and GND at the bottom. Connect them with wires. "
        "Output ONLY the Schemify commands in a code block, nothing else."
    )

    messages = [{"role": "user", "content": prompt}]

    print(f"   Prompt: {prompt[:80]}...")
    print("   Waiting for response...\n")

    try:
        response = provider.chat(messages, system)
    except Exception as e:
        print(f"   ERROR: {e}")
        client.close()
        return

    print("   --- LLM Response ---")
    print(response)
    print("   --- End Response ---\n")

    # Extract commands
    print("6. Extracting commands...")
    commands = extract_commands(response)
    if commands:
        print(f"   Found {len(commands)} command(s):")
        for cmd in commands:
            print(f"     > {cmd}")

        # Execute against mock
        print("\n7. Executing commands against mock server...")
        for cmd in commands:
            try:
                result = client.cmd(cmd)
                status = "OK" if not isinstance(result, dict) or "error" not in result else f"ERR: {result['error']}"
            except (BrokenPipeError, ConnectionError) as e:
                status = f"CONN: {e}"
            print(f"     {status}: {cmd}")
    else:
        print("   No commands extracted. The LLM response may need tuning.")

    # Summary
    print(f"\n{'=' * 60}")
    print(f"Commands generated: {len(commands)}")
    print(f"Commands executed:  {len(MOCK_COMMAND_LOG)}")

    has_place = any("place" in c for c in commands)
    has_wire = any("add-wire" in c or "wire" in c.lower() for c in commands)
    has_prop = any("set-prop" in c for c in commands)

    print(f"Has place commands: {'YES' if has_place else 'no'}")
    print(f"Has wire commands:  {'YES' if has_wire else 'no'}")
    print(f"Has set-prop:       {'YES' if has_prop else 'no'}")

    if has_place:
        print("\nSUCCESS: LLM generated valid Schemify commands!")
    else:
        print("\nPARTIAL: LLM responded but may need prompt tuning.")

    print(f"{'=' * 60}")

    client.close()


if __name__ == "__main__":
    main()
