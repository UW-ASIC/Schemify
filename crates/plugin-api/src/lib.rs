//! Guest-facing plugin API: the wire protocol and the Rust SDK.
//!
//! Plugins speak JSON-RPC 2.0 over newline-delimited JSON on stdin/stdout.
//! This crate is everything a plugin binary needs — no host machinery.
//!
//! - [`protocol`]: panel/widget/overlay/theme wire types, JSON-RPC framing,
//!   method names, query payload records.
//! - [`sdk`]: [`sdk::PluginRuntime`] for writing plugins in Rust.

pub mod protocol;
pub mod sdk;

// Root re-exports: `schemify_plugin_api::WidgetNode` etc. work directly.
pub use protocol::*;
