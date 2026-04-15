//! Plugin installer — downloads plugin artifacts and places them where the
//! runtimes expect them.
//!
//! ── Install layouts ──────────────────────────────────────────────────────────
//!
//!  Native  ~/.config/Schemify/<name>/
//!              lib<name>.so            ← Linux
//!              lib<name>.dylib         ← macOS
//!              <name>.dll              ← Windows
//!
//!  Web     <web-out-dir>/plugins/
//!              <name>.wasm
//!          <web-out-dir>/plugins/plugins.json   ← updated automatically

pub const Installer = @import("Installer.zig").Installer;
pub const Target = @import("types.zig").Target;
pub const InstallOptions = @import("types.zig").InstallOptions;
pub const InstallError = @import("types.zig").InstallError;
pub const install = Installer.install;