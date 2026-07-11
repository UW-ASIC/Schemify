//! Host side of the plugin system, plus the marketplace that distributes
//! plugins.
//!
//! - [`manifest`]: plugin.toml schema + loading
//! - [`transport`]: subprocess JSON-RPC transport
//! - [`decode`]: capability negotiation, message → [`PluginHostAction`]
//! - [`manager`]: discovery/lifecycle/per-tick pump ([`PluginManager`])
//! - [`marketplace`]: registry fetch, tarball install ([`Marketplace`])
//! - [`service`]: [`PluginService`] — the one place that owns a
//!   [`PluginManager`] + [`Marketplace`] pair

pub mod decode;
pub mod manager;
pub mod manifest;
pub mod marketplace;
pub mod service;
pub mod transport;

// Flat re-exports: consumers say `schemify_plugin_host::PluginManager`.
pub use decode::*;
pub use manager::*;
pub use manifest::*;
pub use marketplace::{Marketplace, SearchResult};
pub use service::PluginService;
pub use transport::*;

// Wire types shared with guests live in plugin-api; re-exported so host
// consumers need only this crate.
pub use schemify_plugin_api::protocol::*;
