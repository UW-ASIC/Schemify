# ADR-0002: Vim-first keybind defaults

## Status: accepted

## Context

Most GUI apps default to conventional keybinds (Ctrl+S save, Ctrl+Z undo). Schemify targets EDA engineers, many of whom use vim-style editors. The keybind system needed a default.

## Decision

Default keybind preset is `vim`. Single-key shortcuts (e.g., `r` for rotate, `w` for wire) are the baseline. A `conventional` preset is available that remaps these to Ctrl+ combos. The default is set in `KeybindConfig` struct init (`.preset = .vim`) and in the `loadFromDisk` fallback path.

## Consequences

- Power users get efficient single-key shortcuts out of the box.
- New users unfamiliar with vim will find the app unresponsive to expected shortcuts (Ctrl+S, Ctrl+Z) until they switch presets. This is a deliberate trade-off: the target audience benefits more from vim defaults than it is harmed.
- Changing the default later would break muscle memory for existing users. The preset system makes this manageable (existing `keybinds.json` files would preserve `"preset": "vim"`), but new installs would change behavior.
- First-run experience should surface the preset choice prominently (not yet implemented).
