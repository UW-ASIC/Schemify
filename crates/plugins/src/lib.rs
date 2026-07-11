//! Schemify plugin host: subprocess plugins speaking JSON-RPC 2.0 over
//! newline-delimited JSON on stdin/stdout.
//!
//! Host side: [`PluginManifest`] (plugin.toml), [`SubprocessTransport`],
//! capability negotiation ([`negotiate`]), and [`PluginManager`] whose
//! [`PluginManager::tick`] drains plugin messages into [`PluginHostAction`]s.
//!
//! Wire types and the guest SDK live in `schemify-plugin-api`; re-exported
//! here so pre-split `schemify_plugins::X` paths keep working.

pub mod host;

pub use schemify_plugin_api::{protocol, sdk};

// Root re-exports: every pre-split `schemify_plugins::X` path keeps working.
pub use host::*;
pub use protocol::*;
