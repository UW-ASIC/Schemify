//! Schemify plugin system: subprocess plugins speaking JSON-RPC 2.0 over
//! newline-delimited JSON on stdin/stdout.
//!
//! Host side: [`PluginManifest`] (plugin.toml), [`SubprocessTransport`],
//! capability negotiation ([`negotiate`]), and [`PluginManager`] whose
//! [`PluginManager::tick`] drains plugin messages into [`PluginHostAction`]s.
//!
//! Guest side: [`sdk::PluginRuntime`] for writing plugins in Rust.
//!
//! All plugin-facing wire types (overlay shapes, widget tree, theme values)
//! live in this crate — they are protocol types, owned by the protocol.

pub mod host;
pub mod protocol;
pub mod sdk;

// Root re-exports: every pre-split `schemify_plugins::X` path keeps working.
pub use host::*;
pub use protocol::*;
