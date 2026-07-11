### Here's a description of what is found in display/

- state.rs <=> core logic, and global state management
  - Exposes a theme struct that can be changed at runtime using the handler reading a config file.
- handler.rs <=> handles updates to the state, wrapper over the core's handler. Has to match 1 to 1 (comptime check)
- ui.rs <=> the actual UI, it has state.rs to get state. This is top-level
- canvas/, canvas UI logic uses handler.rs
- components/, other UI components
- keybinds.rs <=> Keybinds
