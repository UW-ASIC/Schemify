# AgentHarness

LLM agent harness for Schemify. Exposes the full Schemify command surface over a JSON-RPC 2.0 Unix domain socket, enabling AI agents (Claude Code, etc.) to create schematics, run simulations, and use plugins programmatically.

## Install

```bash
make install
```

This builds a native `.so` and installs to `~/.config/Schemify/plugins/AgentHarness/`.

## Socket

The plugin listens on:
- `$XDG_RUNTIME_DIR/schemify-agent.sock` (Linux)
- `~/.config/Schemify/schemify-agent.sock` (fallback)

## JSON-RPC Methods

### Commands
- `command` — execute any Schemify command (same as vim bar)
- `refresh` — refresh instance/net cache from schematic

### Queries
- `list_instances` — list all schematic instances
- `list_nets` — list all nets
- `info` — document info (file, counts)
- `get_instance_prop` — get instance properties
- `get_state` — get host state (current_file, etc.)

### Skills
- `list_skills` — list available skill documents
- `get_skill` — read a skill document by name

### File I/O
- `read_file` — read a file
- `write_file` — write a file
- `list_project_files` — glob project files

### Network
- `http_get` — fetch a URL

## Protocol

Newline-delimited JSON-RPC 2.0 over Unix socket:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"command","params":{"text":"place nmos4 M1 100 200"}}' | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/schemify-agent.sock
```

## Skills

The `skills/` directory contains markdown documentation for LLM consumption:
- `schemify_commands.md` — full command reference
- `chn_format.md` — .chn file format spec
- `ccreator.md` — CCreator plugin usage
- `spice_import.md` — SpiceImport plugin
- `gmid_optimizer.md` — GMIDOptimizer plugin
- `pdk_switcher.md` — PDKSwitcherino plugin
- `primitives.md` — primitive kinds, pins, SPICE prefixes

## LLM Agent Client

`clients/schemify_agent.py` is a ready-to-use interactive agent that connects
any LLM to Schemify. Bring your own API key or run locally.

### Cloud Providers

```bash
# Anthropic Claude
export ANTHROPIC_API_KEY=sk-ant-...
python3 clients/schemify_agent.py --provider anthropic
python3 clients/schemify_agent.py --provider anthropic --model claude-opus-4-20250514

# OpenAI
export OPENAI_API_KEY=sk-...
python3 clients/schemify_agent.py --provider openai
python3 clients/schemify_agent.py --provider openai --model gpt-4.1

# Google Gemini
export GEMINI_API_KEY=...
python3 clients/schemify_agent.py --provider gemini
python3 clients/schemify_agent.py --provider gemini --model gemini-2.5-pro
```

### Local / Self-Hosted

```bash
# Ollama (no API key needed — runs locally)
ollama pull qwen2.5-coder
python3 clients/schemify_agent.py --provider ollama --model qwen2.5-coder

# Other Ollama models
python3 clients/schemify_agent.py --provider ollama --model llama3.1
python3 clients/schemify_agent.py --provider ollama --model codellama
python3 clients/schemify_agent.py --provider ollama --model deepseek-coder-v2
python3 clients/schemify_agent.py --provider ollama --model mistral

# LM Studio (runs locally, OpenAI-compatible API)
python3 clients/schemify_agent.py --provider openai-compat \
    --base-url http://localhost:1234/v1 --model local-model

# Any OpenAI-compatible API (Together, Groq, Fireworks, vLLM, etc.)
export LLM_API_KEY=...
python3 clients/schemify_agent.py --provider openai-compat \
    --base-url https://api.together.xyz/v1 --model meta-llama/Llama-3-70b-chat-hf
```

### Interactive Mode

Run without arguments for guided provider selection:

```bash
python3 clients/schemify_agent.py
```

### How It Works

1. Connects to the AgentHarness socket
2. Loads all skill docs (commands, file format, plugin interfaces) as LLM context
3. You chat naturally: "Build me a differential pair with 10u/180n NMOS"
4. The LLM generates Schemify commands
5. You confirm execution (Y/n)
6. Commands run live in Schemify, results feed back to the LLM
