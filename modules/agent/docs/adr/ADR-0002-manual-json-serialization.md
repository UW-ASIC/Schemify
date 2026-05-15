# ADR-0002: Manual JSON serialization instead of std.json

## Status: accepted

## Context

The module produces large amounts of JSON: tool list responses, resource contents, prompt messages, diagnostic results, JSON-RPC envelopes. Zig's `std.json` API changed significantly between 0.13 and 0.15 (stringify vs. fmt, Value vs. typed parsing). The module was written during this transition and needs to produce known-good JSON without depending on API stability.

## Decision

All JSON output is built by appending to `std.ArrayList(u8)` via a writer. A single `writeJsonStr` helper handles string escaping (quotes, backslashes, control characters, \uXXXX). Structural JSON (`{`, `}`, `,`, `:`) is written as literal bytes. `std.json.parseFromSlice` is used only for *input* parsing (incoming JSON-RPC messages and tool arguments).

## Consequences

- Zero dependency on `std.json` serialization API. Immune to Zig stdlib churn in this area.
- JSON output is always valid because the structure is hardcoded. No runtime reflection or schema generation.
- Verbose: every handler manually writes `{"key":` + escape + `,"key2":` etc. Adding a field requires editing raw JSON fragments.
- Easy to introduce malformed JSON if a handler forgets a closing brace or comma. Mitigated by tests that parse every handler's output with `std.json.parseFromSlice`.
- Tool schemas are embedded as comptime string literals, not generated from types. Schema and handler can drift (see: `generate_netlist` format parameter).
