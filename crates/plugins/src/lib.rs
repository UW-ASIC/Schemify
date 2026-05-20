pub mod manifest;
pub mod jsonrpc;
pub mod capability;
pub mod runtime;
pub mod transport;
pub mod host;
pub mod manager;

pub use manager::{PluginManager, PluginState};
pub use manifest::PluginManifest;
pub use host::HostAction;
pub use capability::{Capability, HostCapabilities, NegotiatedCapabilities, negotiate};
pub use transport::{PluginTransport, TransportError, create_transport};
