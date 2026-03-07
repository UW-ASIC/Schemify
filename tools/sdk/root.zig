//! Schemify Plugin SDK — runtime module.
//!
//! Provides a single import point for plugin source files.
//! All re-exports use the same module instances that the build helper
//! wired in, so types are always compatible across the whole build graph.
//!
//! Usage (plugin source):
//!
//!   const sdk = @import("sdk");
//!   const PluginIF = sdk.PluginIF;
//!   const core     = sdk.core;
//!
//! The "sdk" named import is added automatically by
//! `build_plugin_helper.addNativePluginLibrary` and
//! `build_plugin_helper.addWasmPlugin`.

pub const PluginIF = @import("PluginIF");
pub const core = @import("core");
