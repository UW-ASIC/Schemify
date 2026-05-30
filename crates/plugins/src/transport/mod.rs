pub mod subprocess;
pub mod wasm;

use crate::manifest::PluginManifest;
use std::path::Path;

/// Errors arising from plugin transport operations.
#[derive(Debug)]
pub enum TransportError {
    /// Failed to spawn the plugin process/runtime.
    SpawnFailed(String),
    /// Failed to send a message to the plugin.
    SendFailed(String),
    /// Failed to receive a message from the plugin.
    RecvFailed(String),
    /// Transport is not currently running.
    NotRunning,
    /// WASM-specific error.
    WasmError(String),
}

impl std::fmt::Display for TransportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::SpawnFailed(e) => write!(f, "spawn failed: {e}"),
            Self::SendFailed(e) => write!(f, "send failed: {e}"),
            Self::RecvFailed(e) => write!(f, "recv failed: {e}"),
            Self::NotRunning => write!(f, "transport not running"),
            Self::WasmError(e) => write!(f, "wasm error: {e}"),
        }
    }
}

impl std::error::Error for TransportError {}

/// Object-safe trait for plugin IPC transports.
///
/// Transports handle spawning, message passing, and lifecycle for a single
/// plugin instance. The protocol layer (JSON-RPC) is handled above this --
/// transport only sees raw strings (newline-delimited JSON lines).
pub trait PluginTransport {
    /// Spawn/start the plugin using the given manifest and plugin directory.
    fn spawn(&mut self, manifest: &PluginManifest, plugin_dir: &Path)
        -> Result<(), TransportError>;

    /// Send a message (newline-delimited JSON line) to the plugin.
    fn send(&mut self, msg: &str) -> Result<(), TransportError>;

    /// Try to receive a message from the plugin (non-blocking).
    /// Returns `Ok(None)` if no message is available yet.
    fn recv(&mut self) -> Result<Option<String>, TransportError>;

    /// Stop the plugin transport, cleaning up resources.
    fn stop(&mut self) -> Result<(), TransportError>;

    /// Whether the transport is currently running.
    fn is_running(&self) -> bool;
}

/// Create the appropriate transport for a given plugin language/runtime string.
pub fn create_transport(language: &str) -> Box<dyn PluginTransport> {
    match language {
        "native" | "subprocess" | "python" => Box::new(subprocess::SubprocessTransport::new()),
        "wasm" => Box::new(wasm::WasmTransport::new()),
        _ => Box::new(subprocess::SubprocessTransport::new()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transport_error_display_spawn_failed() {
        let err = TransportError::SpawnFailed("bad binary".into());
        assert_eq!(format!("{err}"), "spawn failed: bad binary");
    }

    #[test]
    fn transport_error_display_send_failed() {
        let err = TransportError::SendFailed("broken pipe".into());
        assert_eq!(format!("{err}"), "send failed: broken pipe");
    }

    #[test]
    fn transport_error_display_recv_failed() {
        let err = TransportError::RecvFailed("eof".into());
        assert_eq!(format!("{err}"), "recv failed: eof");
    }

    #[test]
    fn transport_error_display_not_running() {
        let err = TransportError::NotRunning;
        assert_eq!(format!("{err}"), "transport not running");
    }

    #[test]
    fn transport_error_display_wasm() {
        let err = TransportError::WasmError("invalid module".into());
        assert_eq!(format!("{err}"), "wasm error: invalid module");
    }

    #[test]
    fn transport_error_is_error_trait() {
        let err: Box<dyn std::error::Error> = Box::new(TransportError::SpawnFailed("test".into()));
        assert!(err.to_string().contains("spawn failed"));
    }

    #[test]
    fn create_transport_subprocess_for_native() {
        let t = create_transport("native");
        assert!(!t.is_running());
    }

    #[test]
    fn create_transport_subprocess_for_subprocess() {
        let t = create_transport("subprocess");
        assert!(!t.is_running());
    }

    #[test]
    fn create_transport_subprocess_for_python() {
        let t = create_transport("python");
        assert!(!t.is_running());
    }

    #[test]
    fn create_transport_wasm() {
        let t = create_transport("wasm");
        assert!(!t.is_running());
    }

    #[test]
    fn create_transport_unknown_falls_back_to_subprocess() {
        let t = create_transport("lua");
        assert!(!t.is_running());
    }
}
