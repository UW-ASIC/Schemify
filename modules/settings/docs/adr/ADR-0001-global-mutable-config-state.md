# ADR-0001: Global mutable config state

## Status: accepted

## Context

CLAUDE.md mandates pure functions and no hidden state. The settings module stores active theme config, presets, and keybind config in file-scoped `var` globals (`active_config`, `presets_buf`, `presets_count`). Consumers access them via pointer-returning functions (`getActiveConfig()`, `getPresets()`). The alternative is to return owned config structs from `load()` and thread them through the call stack.

## Decision

Use file-scoped global state. Settings are:
- Loaded once at startup, rarely mutated (preset switch, manual edit + reload).
- Read every frame by the GUI theme system via `getActiveConfig()`.
- Singular -- there is exactly one active theme and one keybind config at any time.

Threading config through `main -> gui -> dialogs -> every widget` would add a parameter to dozens of functions for data that is effectively application-global and immutable within a frame.

## Consequences

- Simple access: any module with `@import("settings")` reads config without parameter passing.
- Testing requires calling `load()` first or accepting default values. Cannot test two configs in parallel.
- Not thread-safe. Acceptable because the app is single-threaded.
- Violates the letter of "pure functions, no hidden state" from CLAUDE.md. Accepted as a pragmatic exception for app-level singleton config.
