pub mod manifest;
pub mod jsonrpc;
pub mod capability;
pub mod transport;
pub mod host;
pub mod manager;

pub use manager::{PluginManager, PluginState};
pub use manifest::PluginManifest;
pub use host::HostAction;
pub use capability::{HostCapabilities, NegotiatedCapabilities, negotiate};
pub use transport::{PluginTransport, TransportError, create_transport};
