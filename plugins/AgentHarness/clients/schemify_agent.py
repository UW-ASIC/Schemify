#!/usr/bin/env python3
"""Schemify LLM Agent — interactive circuit design assistant.

Connects to the AgentHarness socket and uses an LLM to design circuits,
run plugins, and manage schematics conversationally.

Supported providers:
  - Anthropic Claude    (claude-sonnet-4-20250514, claude-opus-4-20250514)
  - OpenAI              (gpt-4o, gpt-4.1, o3)
  - Google Gemini       (gemini-2.5-pro, gemini-2.5-flash)
  - Ollama (local)      (llama3, codellama, qwen2.5, mistral, etc.)
  - Any OpenAI-compatible API (Together, Groq, Fireworks, LM Studio, etc.)

Usage:
  # Claude
  export ANTHROPIC_API_KEY=sk-ant-...
  python3 schemify_agent.py --provider anthropic

  # OpenAI
  export OPENAI_API_KEY=sk-...
  python3 schemify_agent.py --provider openai

  # Gemini
  export GEMINI_API_KEY=...
  python3 schemify_agent.py --provider gemini

  # Ollama (local, no API key needed)
  python3 schemify_agent.py --provider ollama --model llama3

  # Any OpenAI-compatible endpoint
  python3 schemify_agent.py --provider openai-compat \\
      --base-url http://localhost:8080/v1 --model my-model

  # Interactive provider selection
  python3 schemify_agent.py
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import urllib.request
import urllib.error
from typing import Any


# ---------------------------------------------------------------------------
# AgentHarness socket client
# ---------------------------------------------------------------------------

class HarnessClient:
    """JSON-RPC client for the AgentHarness Unix socket."""

    def __init__(self, sock_path: str):
        self._path = sock_path
        self._sock: socket.socket | None = None
        self._id = 0
        self._buf = b""

    def connect(self):
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.connect(self._path)

    def close(self):
        if self._sock:
            self._sock.close()
            self._sock = None

    def call(self, method: str, params: dict | None = None) -> Any:
        self._id += 1
        msg = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params:
            msg["params"] = params
        self._sock.sendall(json.dumps(msg).encode() + b"\n")

        while b"\n" not in self._buf:
            chunk = self._sock.recv(8192)
            if not chunk:
                raise ConnectionError("Socket closed")
            self._buf += chunk

        line, self._buf = self._buf.split(b"\n", 1)
        resp = json.loads(line)

        if "error" in resp:
            return {"error": resp["error"]}
        return resp.get("result")

    def cmd(self, text: str) -> Any:
        return self.call("command", {"text": text})

    def load_skills(self) -> str:
        """Load all skill docs and concatenate them into a system prompt."""
        names = self.call("list_skills") or []
        parts = []
        for name in names:
            skill = self.call("get_skill", {"name": name})
            if skill and "content" in skill:
                parts.append(skill["content"])
        return "\n\n---\n\n".join(parts)


# ---------------------------------------------------------------------------
# LLM provider abstraction
# ---------------------------------------------------------------------------

SYSTEM_PREFIX = (
    "You are a Schemify circuit design assistant. You help users create "
    "analog and mixed-signal circuits by writing Python code using the "
    "CCreator API.\n\n"
    "## How to create circuits\n\n"
    "Output a complete CCreator Python class inside a ```python code block. "
    "The code will be saved to a file and imported into Schemify via the "
    "CCreator plugin. Do NOT output raw Schemify commands.\n\n"
    "## CCreator API\n\n"
    "### Realistic circuits (`@realistic.analog`)\n\n"
    "Define transistor-level netlists using the `NetlistBuilder`:\n\n"
    "```python\n"
    "from ccreator import realistic\n"
    "from ccreator.core import Port\n\n"
    "@realistic.analog\n"
    "class MyCircuit:\n"
    "    ports = [\n"
    "        Port('in', 'input', 'voltage'),\n"
    "        Port('out', 'output', 'voltage'),\n"
    "        Port('vdd', 'inout', 'voltage'),\n"
    "        Port('gnd', 'inout', 'voltage'),\n"
    "    ]\n"
    "    parameters = {'RD': 10e3, 'W': 10e-6, 'L': 180e-9}\n\n"
    "    def build(self, n):\n"
    "        n.R('RD', 'vdd', 'out', self.RD)\n"
    "        n.MOSFET('M1', 'out', 'in', 'gnd', 'gnd', 'nch',\n"
    "                 w=self.W, l=self.L)\n"
    "```\n\n"
    "### NetlistBuilder methods (`n`)\n\n"
    "| Method | Signature | Description |\n"
    "|--------|-----------|-------------|\n"
    "| `n.R()` | `(name, n1, n2, value)` | Resistor |\n"
    "| `n.C()` | `(name, n1, n2, value)` | Capacitor |\n"
    "| `n.L()` | `(name, n1, n2, value)` | Inductor |\n"
    "| `n.V()` | `(name, n1, n2, **kwargs)` | Voltage source |\n"
    "| `n.I()` | `(name, n1, n2, **kwargs)` | Current source |\n"
    "| `n.MOSFET()` | `(name, drain, gate, source, bulk, model, **kwargs)` | MOSFET |\n"
    "| `n.BJT()` | `(name, collector, base, emitter, model, **kwargs)` | BJT |\n"
    "| `n.raw()` | `(spice_line)` | Raw SPICE line |\n\n"
    "### Behavioral circuits (`@behavioral.analog`)\n\n"
    "Define transfer functions using SymPy:\n\n"
    "```python\n"
    "from ccreator import behavioral\n"
    "from ccreator.core import Port\n\n"
    "@behavioral.analog\n"
    "class IdealAmp:\n"
    "    ports = [Port('in', 'input', 'voltage'), Port('out', 'output', 'voltage')]\n"
    "    parameters = {'gain': 100}\n\n"
    "    def transfer_function(self, s):\n"
    "        return self.gain\n"
    "```\n\n"
    "### Testbenches (`@testbench`)\n\n"
    "```python\n"
    "from ccreator.core.decorators import testbench\n\n"
    "@testbench\n"
    "class MyTB:\n"
    "    parameters = {'dut': None}\n\n"
    "    def build(self, tb):\n"
    "        tb.instance(self.dut, name='DUT',\n"
    "                    connections={'in': 'vin', 'out': 'vout', 'gnd': '0'})\n"
    "        tb.V('Vin', 'vin', '0', dc=0.6)\n"
    "        tb.probe('vout')\n\n"
    "    def analysis(self, tb):\n"
    "        tb.dc(source='Vin', start=0, stop=1.2, step=0.001)\n"
    "```\n\n"
    "### Port definition\n\n"
    "```python\n"
    "Port(name, direction, signal_type)\n"
    "```\n"
    "- `direction`: `'input'`, `'output'`, `'inout'`\n"
    "- `signal_type`: `'voltage'`\n\n"
    "### Rules\n\n"
    "- Always include `gnd` as an `'inout'` port for ground reference.\n"
    "- Node names in `build()` correspond to port names.\n"
    "- Use SI values for parameters (e.g., `10e3` not `'10k'`).\n"
    "- One class per response. Include all imports.\n\n"
    "## Example\n\n"
    "User: Build me a common-source amplifier\n\n"
    "Assistant: Here is an NMOS common-source amplifier with resistive load:\n\n"
    "```python\n"
    "from ccreator import realistic\n"
    "from ccreator.core import Port\n\n"
    "@realistic.analog\n"
    "class CommonSourceAmp:\n"
    "    ports = [\n"
    "        Port('in', 'input', 'voltage'),\n"
    "        Port('out', 'output', 'voltage'),\n"
    "        Port('vdd', 'inout', 'voltage'),\n"
    "        Port('gnd', 'inout', 'voltage'),\n"
    "    ]\n"
    "    parameters = {'RD': 10e3, 'W': 10e-6, 'L': 180e-9}\n\n"
    "    def build(self, n):\n"
    "        n.R('RD', 'vdd', 'out', self.RD)\n"
    "        n.MOSFET('M1', 'out', 'in', 'gnd', 'gnd', 'nch',\n"
    "                 w=self.W, l=self.L)\n"
    "```\n\n"
    "## Reference documentation\n\n"
)


def _build_system_prompt(skills_text: str) -> str:
    return SYSTEM_PREFIX + skills_text


def _http_post(url: str, headers: dict, body: dict, timeout: int = 120) -> dict:
    """Simple HTTP POST returning parsed JSON."""
    data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


class LLMProvider:
    """Base class for LLM providers."""

    def chat(self, messages: list[dict], system: str) -> str:
        raise NotImplementedError


class AnthropicProvider(LLMProvider):
    def __init__(self, api_key: str, model: str = "claude-sonnet-4-20250514"):
        self.api_key = api_key
        self.model = model
        self.url = "https://api.anthropic.com/v1/messages"

    def chat(self, messages: list[dict], system: str) -> str:
        body = {
            "model": self.model,
            "max_tokens": 4096,
            "system": system,
            "messages": messages,
        }
        headers = {
            "Content-Type": "application/json",
            "x-api-key": self.api_key,
            "anthropic-version": "2023-06-01",
        }
        resp = _http_post(self.url, headers, body)
        # Extract text from content blocks
        content = resp.get("content", [])
        parts = []
        for block in content:
            if block.get("type") == "text":
                parts.append(block["text"])
        return "\n".join(parts)


class OpenAIProvider(LLMProvider):
    def __init__(self, api_key: str, model: str = "gpt-4o",
                 base_url: str = "https://api.openai.com/v1"):
        self.api_key = api_key
        self.model = model
        self.url = f"{base_url.rstrip('/')}/chat/completions"

    def chat(self, messages: list[dict], system: str) -> str:
        msgs = [{"role": "system", "content": system}] + messages
        body = {
            "model": self.model,
            "messages": msgs,
            "max_tokens": 4096,
        }
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.api_key}",
        }
        resp = _http_post(self.url, headers, body)
        return resp["choices"][0]["message"]["content"]


class GeminiProvider(LLMProvider):
    def __init__(self, api_key: str, model: str = "gemini-2.5-flash"):
        self.api_key = api_key
        self.model = model

    def chat(self, messages: list[dict], system: str) -> str:
        url = (
            f"https://generativelanguage.googleapis.com/v1beta/models/"
            f"{self.model}:generateContent?key={self.api_key}"
        )
        # Convert messages to Gemini format
        contents = []
        for msg in messages:
            role = "user" if msg["role"] == "user" else "model"
            contents.append({
                "role": role,
                "parts": [{"text": msg["content"]}],
            })
        body = {
            "system_instruction": {"parts": [{"text": system}]},
            "contents": contents,
            "generationConfig": {"maxOutputTokens": 4096},
        }
        headers = {"Content-Type": "application/json"}
        resp = _http_post(url, headers, body)
        candidates = resp.get("candidates", [])
        if candidates:
            parts = candidates[0].get("content", {}).get("parts", [])
            return "".join(p.get("text", "") for p in parts)
        return ""


class OllamaProvider(LLMProvider):
    def __init__(self, model: str = "llama3",
                 base_url: str = "http://localhost:11434"):
        self.model = model
        self.url = f"{base_url.rstrip('/')}/api/chat"

    def chat(self, messages: list[dict], system: str) -> str:
        msgs = [{"role": "system", "content": system}] + messages
        body = {
            "model": self.model,
            "messages": msgs,
            "stream": False,
        }
        headers = {"Content-Type": "application/json"}
        resp = _http_post(self.url, headers, body, timeout=300)
        return resp.get("message", {}).get("content", "")


# ---------------------------------------------------------------------------
# Python code extraction and execution
# ---------------------------------------------------------------------------

_CIRCUIT_COUNTER = 0


def extract_python(text: str) -> str | None:
    """Extract a Python code block from the LLM response.

    Returns the full Python source string, or None if no python block found.
    """
    blocks: list[str] = []
    in_code_block = False
    code_lang = ""
    current_lines: list[str] = []

    for line in text.split("\n"):
        stripped = line.strip()

        if stripped.startswith("```"):
            if in_code_block:
                if code_lang in ("python", "py"):
                    blocks.append("\n".join(current_lines))
                in_code_block = False
                code_lang = ""
                current_lines = []
            else:
                in_code_block = True
                code_lang = stripped[3:].strip().lower()
                current_lines = []
            continue

        if in_code_block:
            current_lines.append(line)

    if not blocks:
        return None

    return "\n\n".join(blocks)


def execute_python(client: HarnessClient, code: str) -> list[str]:
    """Write CCreator Python, run it to produce SPICE, import via SpiceImport."""
    import subprocess
    import tempfile

    global _CIRCUIT_COUNTER
    _CIRCUIT_COUNTER += 1
    py_path = f"/tmp/schemify_agent_circuit_{_CIRCUIT_COUNTER}.py"
    sp_path = f"/tmp/schemify_agent_circuit_{_CIRCUIT_COUNTER}.sp"

    results = []

    # Append a runner block that finds the circuit class and exports SPICE
    runner_code = code + "\n\n" + _EXPORT_FOOTER.format(sp_path=sp_path)

    # Write the runner script
    with open(py_path, "w") as f:
        f.write(runner_code)
    results.append(f"OK: wrote {py_path}")

    # Resolve CCreator package path relative to this script
    _this_dir = os.path.dirname(os.path.abspath(__file__))
    ccreator_src = os.path.normpath(
        os.path.join(_this_dir, "..", "..", "CCreator", "src")
    )

    env = os.environ.copy()
    extra = ccreator_src
    if "PYTHONPATH" in env:
        extra += os.pathsep + env["PYTHONPATH"]
    env["PYTHONPATH"] = extra

    # Run the script to produce the .sp file
    proc = subprocess.run(
        [sys.executable, py_path],
        capture_output=True, text=True, timeout=30, env=env,
    )
    if proc.returncode != 0:
        results.append(f"ERROR running Python:\n{proc.stderr.strip()}")
        return results

    if proc.stdout.strip():
        results.append(proc.stdout.strip())

    if not os.path.isfile(sp_path):
        results.append(f"ERROR: SPICE file not created at {sp_path}")
        return results
    results.append(f"OK: generated {sp_path}")

    # Import into Schemify via SpiceImport plugin
    import_result = client.cmd(f"plugin spiceimport {sp_path}")
    if isinstance(import_result, dict) and "error" in import_result:
        results.append(f"ERROR importing: {import_result['error']}")
    else:
        results.append(f"OK: imported {sp_path} via SpiceImport")

    # Save the schematic
    save_result = client.cmd("file_save")
    if isinstance(save_result, dict) and "error" in save_result:
        results.append(f"ERROR saving: {save_result['error']}")
    else:
        results.append("OK: saved schematic")

    return results


_EXPORT_FOOTER = '''
# --- auto-generated export block ---
if __name__ == "__main__":
    import importlib, inspect, sys
    from ccreator.core.circuit import BaseCircuit
    _mod = sys.modules[__name__]
    for _name in dir(_mod):
        _obj = getattr(_mod, _name)
        if (isinstance(_obj, type) and issubclass(_obj, BaseCircuit)
                and _obj is not BaseCircuit):
            _instance = _obj()
            _instance.export.spice("{sp_path}")
            print(f"Exported {{_name}} -> {sp_path}")
            break
    else:
        print("ERROR: no CCreator circuit class found", file=sys.stderr)
        sys.exit(1)
'''


# ---------------------------------------------------------------------------
# Interactive REPL
# ---------------------------------------------------------------------------

def interactive_loop(client: HarnessClient, provider: LLMProvider):
    """Main chat loop."""

    print("Loading skills documentation...")
    skills = client.load_skills()
    system = _build_system_prompt(skills)
    print(f"Loaded {len(skills)} chars of skills docs.\n")

    messages: list[dict] = []

    print("=" * 60)
    print("Schemify Agent Ready")
    print("Type your request. The LLM will generate Python circuit code.")
    print("Special inputs:")
    print("  /info     — show current schematic info")
    print("  /list     — list instances")
    print("  /nets     — list nets")
    print("  /refresh  — refresh state from schematic")
    print("  /clear    — clear conversation history")
    print("  /quit     — exit")
    print("=" * 60)

    while True:
        try:
            user_input = input("\nyou> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nBye!")
            break

        if not user_input:
            continue

        # Meta commands
        if user_input == "/quit":
            break
        if user_input == "/clear":
            messages.clear()
            print("Conversation cleared.")
            continue
        if user_input == "/info":
            print(json.dumps(client.call("info"), indent=2))
            continue
        if user_input == "/list":
            print(json.dumps(client.call("list_instances"), indent=2))
            continue
        if user_input == "/nets":
            print(json.dumps(client.call("list_nets"), indent=2))
            continue
        if user_input == "/refresh":
            print(json.dumps(client.call("refresh"), indent=2))
            continue

        # Add context about current state
        info = client.call("info") or {}
        context = f"[Current state: file={info.get('file','(none)')}, " \
                  f"instances={info.get('instances',0)}, nets={info.get('nets',0)}]"

        messages.append({"role": "user", "content": f"{context}\n\n{user_input}"})

        # Call LLM
        print("\nThinking...")
        try:
            response = provider.chat(messages, system)
        except Exception as e:
            print(f"LLM error: {e}")
            messages.pop()  # Remove failed user message
            continue

        print(f"\nassistant> {response}")

        messages.append({"role": "assistant", "content": response})

        # Extract and execute Python code
        code = extract_python(response)
        if code:
            print(f"\n--- Python circuit code ({len(code.splitlines())} lines) ---")
            print(code)
            print("---")
            confirm = input("\nGenerate SPICE & import into Schemify? [Y/n] ").strip().lower()
            if confirm in ("", "y", "yes"):
                results = execute_python(client, code)
                for r in results:
                    print(f"  {r}")

                # Feed results back to conversation
                result_text = "\n".join(results)
                messages.append({
                    "role": "user",
                    "content": f"[Import results:\n{result_text}]",
                })
            else:
                print("Skipped.")


# ---------------------------------------------------------------------------
# Provider selection
# ---------------------------------------------------------------------------

PROVIDERS = {
    "anthropic": {
        "name": "Anthropic Claude",
        "env_key": "ANTHROPIC_API_KEY",
        "default_model": "claude-sonnet-4-20250514",
        "models": ["claude-sonnet-4-20250514", "claude-opus-4-20250514", "claude-haiku-4-5-20251001"],
    },
    "openai": {
        "name": "OpenAI",
        "env_key": "OPENAI_API_KEY",
        "default_model": "gpt-4o",
        "models": ["gpt-4o", "gpt-4.1", "gpt-4.1-mini", "o3", "o4-mini"],
    },
    "gemini": {
        "name": "Google Gemini",
        "env_key": "GEMINI_API_KEY",
        "default_model": "gemini-2.5-flash",
        "models": ["gemini-2.5-pro", "gemini-2.5-flash"],
    },
    "ollama": {
        "name": "Ollama (local)",
        "env_key": None,
        "default_model": "llama3",
        "models": ["llama3", "llama3.1", "codellama", "qwen2.5", "qwen2.5-coder",
                    "mistral", "mixtral", "deepseek-coder-v2", "phi3", "gemma2"],
    },
    "openai-compat": {
        "name": "OpenAI-compatible API",
        "env_key": "LLM_API_KEY",
        "default_model": "",
        "models": [],
        "note": "Works with: Together, Groq, Fireworks, LM Studio, vLLM, etc.",
    },
}


def select_provider_interactive() -> tuple[str, str, str, str]:
    """Interactive provider selection. Returns (provider, model, api_key, base_url)."""
    print("\nSelect LLM provider:\n")
    keys = list(PROVIDERS.keys())
    for i, key in enumerate(keys, 1):
        info = PROVIDERS[key]
        note = f" — {info['note']}" if "note" in info else ""
        local = " (no API key)" if info["env_key"] is None else ""
        print(f"  {i}. {info['name']}{local}{note}")

    choice = input("\nChoice [1]: ").strip()
    idx = int(choice) - 1 if choice.isdigit() else 0
    idx = max(0, min(idx, len(keys) - 1))
    provider_key = keys[idx]
    info = PROVIDERS[provider_key]

    # Model
    if info["models"]:
        print(f"\nAvailable models: {', '.join(info['models'])}")
    model = input(f"Model [{info['default_model']}]: ").strip()
    if not model:
        model = info["default_model"]

    # API key
    api_key = ""
    if info["env_key"]:
        api_key = os.environ.get(info["env_key"], "")
        if not api_key:
            api_key = input(f"API key (${info['env_key']}): ").strip()
        if not api_key and provider_key != "openai-compat":
            print(f"Warning: no API key. Set ${info['env_key']} or enter it above.")

    # Base URL (for openai-compat)
    base_url = ""
    if provider_key == "openai-compat":
        base_url = input("Base URL [http://localhost:8080/v1]: ").strip()
        if not base_url:
            base_url = "http://localhost:8080/v1"
    elif provider_key == "ollama":
        base_url = input("Ollama URL [http://localhost:11434]: ").strip()
        if not base_url:
            base_url = "http://localhost:11434"

    return provider_key, model, api_key, base_url


def make_provider(provider_key: str, model: str, api_key: str,
                  base_url: str) -> LLMProvider:
    """Instantiate the selected provider."""
    if provider_key == "anthropic":
        return AnthropicProvider(api_key, model)
    elif provider_key == "openai":
        return OpenAIProvider(api_key, model)
    elif provider_key == "gemini":
        return GeminiProvider(api_key, model)
    elif provider_key == "ollama":
        return OllamaProvider(model, base_url)
    elif provider_key == "openai-compat":
        return OpenAIProvider(api_key, model, base_url)
    else:
        raise ValueError(f"Unknown provider: {provider_key}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Schemify LLM Agent — AI-powered circuit design",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --provider anthropic
  %(prog)s --provider openai --model gpt-4.1
  %(prog)s --provider ollama --model qwen2.5-coder
  %(prog)s --provider gemini --model gemini-2.5-pro
  %(prog)s --provider openai-compat --base-url http://localhost:8080/v1 --model my-model
  %(prog)s  (interactive provider selection)
""",
    )
    parser.add_argument("--provider", choices=list(PROVIDERS.keys()),
                        help="LLM provider")
    parser.add_argument("--model", help="Model name (provider-specific)")
    parser.add_argument("--api-key", help="API key (or use env var)")
    parser.add_argument("--base-url", help="API base URL (for openai-compat/ollama)")
    parser.add_argument("--socket", help="AgentHarness socket path")
    args = parser.parse_args()

    # Socket path
    sock_path = args.socket
    if not sock_path:
        runtime = os.environ.get("XDG_RUNTIME_DIR")
        if runtime:
            sock_path = os.path.join(runtime, "schemify-agent.sock")
        else:
            sock_path = os.path.expanduser("~/.config/Schemify/schemify-agent.sock")

    if not os.path.exists(sock_path):
        print(f"AgentHarness socket not found: {sock_path}")
        print("Start Schemify with AgentHarness enabled first.")
        sys.exit(1)

    # Provider selection
    if args.provider:
        provider_key = args.provider
        info = PROVIDERS[provider_key]
        model = args.model or info["default_model"]
        api_key = args.api_key or os.environ.get(info["env_key"] or "", "")
        base_url = args.base_url or ""
        if provider_key == "ollama" and not base_url:
            base_url = "http://localhost:11434"
    else:
        provider_key, model, api_key, base_url = select_provider_interactive()

    provider = make_provider(provider_key, model, api_key, base_url)
    print(f"\nProvider: {PROVIDERS[provider_key]['name']}")
    print(f"Model: {model}")
    print(f"Socket: {sock_path}")

    # Connect
    client = HarnessClient(sock_path)
    try:
        client.connect()
        print("Connected to Schemify.")
        interactive_loop(client, provider)
    except ConnectionRefusedError:
        print("Connection refused. Is Schemify running?")
        sys.exit(1)
    finally:
        client.close()


if __name__ == "__main__":
    main()
