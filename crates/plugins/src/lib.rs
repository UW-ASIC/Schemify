pub mod capability;
pub mod host;
pub mod jsonrpc;
pub mod manager;
pub mod manifest;
pub mod transport;

pub use capability::{negotiate, HostCapabilities, NegotiatedCapabilities};
pub use host::HostAction;
pub use manager::{PluginManager, PluginState};
pub use manifest::PluginManifest;
pub use transport::{create_transport, PluginTransport, TransportError};

/// Errors originating from the plugin subsystem.
#[derive(Debug, thiserror::Error)]
pub enum PluginError {
    /// JSON serialization of an outgoing message failed.
    #[error("encode failed: {0}")]
    EncodeFailed(#[from] serde_json::Error),

    /// Transport-level error (spawn, send, recv).
    #[error(transparent)]
    Transport(#[from] TransportError),

    /// A plugin was not found by name.
    #[error("unknown plugin: {0}")]
    UnknownPlugin(String),

    /// Operation invalid for the plugin's current lifecycle state.
    #[error("{0}")]
    InvalidState(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plugin_error_display_encode_failed() {
        // Construct a serde_json::Error by parsing invalid JSON
        let serde_err = serde_json::from_str::<serde_json::Value>("not json").unwrap_err();
        let err = PluginError::EncodeFailed(serde_err);
        let msg = format!("{err}");
        assert!(msg.starts_with("encode failed:"), "got: {msg}");
    }

    #[test]
    fn plugin_error_display_transport() {
        let err = PluginError::Transport(TransportError::NotRunning);
        let msg = format!("{err}");
        assert_eq!(msg, "transport not running");
    }

    #[test]
    fn plugin_error_display_unknown_plugin() {
        let err = PluginError::UnknownPlugin("foo".into());
        assert_eq!(format!("{err}"), "unknown plugin: foo");
    }

    #[test]
    fn plugin_error_display_invalid_state() {
        let err = PluginError::InvalidState("already running".into());
        assert_eq!(format!("{err}"), "already running");
    }

    #[test]
    fn plugin_error_from_transport_error() {
        let terr = TransportError::SpawnFailed("bad binary".into());
        let perr: PluginError = terr.into();
        assert!(matches!(perr, PluginError::Transport(_)));
    }

    #[test]
    fn plugin_error_is_std_error() {
        let err: Box<dyn std::error::Error> = Box::new(PluginError::UnknownPlugin("test".into()));
        assert!(err.to_string().contains("unknown plugin"));
    }
}
