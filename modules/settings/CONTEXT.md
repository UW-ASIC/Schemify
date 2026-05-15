# settings

User configuration persistence for theme and keybind preferences. Reads/writes JSON files under `~/.config/Schemify/`. Pure config module -- no GUI rendering, no schematic knowledge, no dependencies on other Schemify modules.

## Responsibility

- Resolve config directory (`~/.config/Schemify/`)
- Load/save `theme.json` and `keybinds.json`
- Load theme presets from `plugins/Themes/themes/` (bundled) and `~/.config/Schemify/themes/` (user)
- Provide active theme config and keybind overrides to GUI at runtime
- Manage settings dialog UI state (tab selection, edit buffers, dirty flag)

## Public API

Exposed through `lib.zig` re-exports and sub-module access.

### lib.zig (top-level)

| Symbol | Kind | Description |
|--------|------|-------------|
| `load(Allocator)` | fn | Init: resolve config dir, create dirs, load both configs from disk |
| `reload(Allocator)` | fn | Re-read both configs from disk (after external edit) |
| `deinit(Allocator)` | fn | Free keybind overrides list |
| `configDir()` | fn | Returns resolved `~/.config/Schemify/` path (empty before `load`) |
| `getActiveThemeJson(Allocator)` | fn | Serialize active theme to JSON string. Caller owns memory |
| `applyThemePreset(usize, Allocator)` | fn | Apply preset by index, save to disk. Returns success bool |
| `applyKeybindPreset(KeybindPreset, Allocator)` | fn | Apply keybind preset (vim/conventional), save to disk |
| `ensureDefaults(Allocator)` | fn | Write default theme.json/keybinds.json if missing |
| `ThemeConfig` | type | Re-export from types.zig |
| `ThemePreset` | type | Re-export from types.zig |
| `KeybindConfig` | type | Re-export from types.zig |
| `KeybindEntry` | type | Re-export from types.zig |
| `KeybindPreset` | type | Re-export from types.zig |
| `SettingsDialogTab` | type | Re-export from types.zig |
| `SettingsDialogState` | type | Re-export from types.zig |
| `theme` | namespace | Direct access to theme sub-module |
| `keybinds` | namespace | Direct access to keybinds sub-module |

### theme.zig

| Symbol | Kind | Description |
|--------|------|-------------|
| `MAX_PRESETS` | const | 64 -- max bundled + user presets |
| `getActiveConfig()` | fn | `*const ThemeConfig` pointer to global active config |
| `getActiveConfigMut()` | fn | `*ThemeConfig` mutable pointer (for live editing) |
| `getPresets()` | fn | Slice of loaded `ThemePreset` values |
| `loadFromDisk([]const u8, Allocator)` | fn | Load presets + active theme from config dir |
| `saveToDisk([]const u8, Allocator)` | fn | Serialize active config to `theme.json`. Returns bool |
| `applyPreset(usize, []const u8, Allocator)` | fn | Copy preset to active, save. Returns bool |
| `applyJson([]const u8, Allocator)` | fn | Parse raw JSON into active config. Returns bool |
| `toOverridesJson(Allocator)` | fn | Serialize active config to JSON string. Caller owns |

### keybinds.zig

| Symbol | Kind | Description |
|--------|------|-------------|
| `getPreset()` | fn | Returns active `KeybindPreset` enum value |
| `getOverrides()` | fn | Returns `[]const KeybindEntry` slice of user overrides |
| `loadFromDisk([]const u8, Allocator)` | fn | Load from `keybinds.json`. Falls back to vim defaults |
| `saveToDisk([]const u8, Allocator)` | fn | Serialize to `keybinds.json`. Returns bool |
| `applyPreset(KeybindPreset, []const u8, Allocator)` | fn | Set preset, populate overrides (for conventional), save |
| `deinit(Allocator)` | fn | Free overrides list |

### types.zig

| Type | Description |
|------|-------------|
| `ThemeConfig` | 30-field struct: name, dark flag, 19 color slots (RGB/RGBA `?[3]u8`/`?[4]u8`), 9 float/int shape params. All optional except name/dark |
| `ThemePreset` | Inline `[64]u8` name buffer + `ThemeConfig`. `nameSlice()` accessor |
| `KeybindEntry` | Inline `[32]u8` key combo + `[64]u8` command name. `keySlice()`/`cmdSlice()` accessors |
| `KeybindPreset` | Enum: `vim`, `conventional`, `custom`. `label()` for display strings |
| `KeybindConfig` | Preset enum + `ArrayListUnmanaged(KeybindEntry)` overrides |
| `SettingsDialogTab` | Enum: `theme`, `keybinds` |
| `SettingsDialogState` | Dialog UI state: open flag, active tab, selected preset, 4KB JSON edit buffer, status message, dirty flag |

## Internal Structure

| File | LOC | Role |
|------|-----|------|
| `lib.zig` | 114 | Entry point, config dir resolution, lifecycle (load/reload/deinit), re-exports |
| `theme.zig` | 367 | Theme preset loading, JSON parse/serialize, active config management |
| `keybinds.zig` | 177 | Keybind preset loading, JSON parse/serialize, conventional preset definition |
| `types.zig` | 122 | All public type definitions |

## Dependencies

**Incoming** (modules that depend on settings):
- `main.zig` -- calls `load()`, `ensureDefaults()`, `deinit()`, `getActiveThemeJson()`
- `gui/state.zig` -- embeds `SettingsDialogState` in app state
- `gui/dialogs.zig` -- reads/writes theme config, presets, keybinds via full API surface

**Outgoing**: none. Leaf module. Only depends on `std`.

## Disk Layout

```
~/.config/Schemify/
  theme.json          # active theme config
  keybinds.json       # { "preset": "vim", "bindings": { "ctrl+s": "file_save", ... } }
  themes/             # user-defined preset .json files
```

Bundled presets loaded from `plugins/Themes/themes/*.json` (relative to CWD at runtime).

## Gaps

### Missing Features

- **Settings schema / validation** -- no schema definition; any JSON parses silently, unknown fields ignored, invalid values silently dropped.
- **Settings migration** -- no versioning; if fields are added/removed/renamed between versions, old configs silently lose data.
- **Per-project settings** -- only user-level (`~/.config/Schemify/`). No workspace/project override (e.g., `.schemify/settings.json` in project root).
- **Settings search** -- no way to find a setting by keyword. Relevant once settings grow beyond theme+keybinds.
- **Settings reset to defaults** -- no API to reset individual fields or entire config to defaults. Only full preset apply.
- **Change notification / observer** -- no callback or event when settings change. GUI must poll or manually re-apply after mutation.
- **Settings categories / grouping** -- flat namespace. No grouping beyond theme vs. keybinds. Will need structure when simulation prefs, editor prefs, plugin settings are added.
- **Settings import/export** -- no bundle export (zip theme + keybinds) or import. Users must manually copy files.
- **Settings documentation generation** -- no way to enumerate all settings with descriptions, defaults, valid ranges.
- **General settings** -- no support for non-theme, non-keybind settings (e.g., autosave interval, default grid size, recent files, plugin enable/disable).

### API Issues

- **Global mutable state** -- `active_config`, `presets_buf`, `presets_count` are file-scoped `var` globals. Violates pure-function principle from CLAUDE.md. Makes testing require careful init/teardown sequencing. Thread safety is assumed single-threaded.
- **Silent failure everywhere** -- `load()`, `applyPreset()`, JSON parsing all fail silently (return void or false). No error reporting to caller. Impossible to distinguish "file missing" from "file corrupt" from "permission denied".
- **Config dir path buffer is 512 bytes** -- `$HOME/.config/Schemify` could exceed this on unusual systems. Truncation is silent.
- **Name truncation** -- theme names truncated to 63 chars, key combos to 31 chars, commands to 63 chars. All silent, no error.
- **No validation of color ranges at parse time** -- `clamp8()` silently clamps, but the JSON schema uses `i64`. A value of 999 becomes 255 without warning.
- **No validation of command names** -- keybind entries accept any string as a command name. Typos (e.g., `"fiel_save"`) are silently accepted and will simply never trigger.
- **No validation of key combo syntax** -- `"ctrl+shift+alt+meta+z"` accepted without checking if it's a valid combo the input system can match.
- **Preset loading path is CWD-relative** -- `plugins/Themes/themes/` resolved against CWD. Breaks if app is launched from a different directory.
- **Serialization drops fields** -- `serializeConfig` in theme.zig parses 9 float fields but only serializes 7. `button_padding_h` and `button_padding_v` are parsed from JSON but never written back. Round-trip lossy.
- **`SettingsDialogState` in this module** -- UI state struct (`is_open`, `json_edit_buf`, `dirty`) belongs in gui, not in a "pure config" leaf module. Couples settings to GUI concerns.
- **No `Allocator` parameter on `configDir()`** -- returns pointer into global buffer rather than allocating. Fine for now but prevents dynamic config dir (e.g., `$XDG_CONFIG_HOME` override beyond `$HOME`).
- **`$XDG_CONFIG_HOME` not respected** -- hardcodes `$HOME/.config/Schemify` instead of checking `$XDG_CONFIG_HOME` first per the XDG Base Directory Specification.
