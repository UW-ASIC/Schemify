use std::path::Path;

use super::{PluginTransport, TransportError};
use crate::manifest::PluginManifest;

#[cfg(feature = "wasm")]
use std::collections::VecDeque;
#[cfg(feature = "wasm")]
use std::path::PathBuf;

/// Internal state for WASM host function callbacks.
#[cfg(feature = "wasm")]
pub struct WasmState {
    /// Messages from host to plugin (plugin calls host_recv).
    pub inbox: VecDeque<String>,
    /// Messages from plugin to host (plugin calls host_send).
    pub outbox: VecDeque<String>,
}

/// WASM plugin transport.
///
/// When the `wasm` feature is enabled, this loads `.wasm` modules via wasmtime
/// and communicates through shared memory buffers exposed as host functions:
/// - `host_send(ptr, len)` -- plugin sends a message to the host
/// - `host_recv(ptr, len) -> i32` -- plugin receives a message from the host
///
/// Without the `wasm` feature, all trait methods return appropriate errors
/// indicating that WASM support is not compiled in.
pub struct WasmTransport {
    #[cfg(feature = "wasm")]
    running: bool,
    #[cfg(feature = "wasm")]
    module_path: Option<PathBuf>,
    #[cfg(feature = "wasm")]
    inbox: VecDeque<String>,
    #[cfg(feature = "wasm")]
    outbox: VecDeque<String>,
    #[cfg(feature = "wasm")]
    engine: wasmtime::Engine,
    #[cfg(feature = "wasm")]
    store: Option<wasmtime::Store<WasmState>>,
    #[cfg(feature = "wasm")]
    instance: Option<wasmtime::Instance>,
    #[cfg(feature = "wasm")]
    memory: Option<wasmtime::Memory>,
}

impl WasmTransport {
    /// Create a new, idle WASM transport.
    pub fn new() -> Self {
        Self {
            #[cfg(feature = "wasm")]
            running: false,
            #[cfg(feature = "wasm")]
            module_path: None,
            #[cfg(feature = "wasm")]
            inbox: VecDeque::new(),
            #[cfg(feature = "wasm")]
            outbox: VecDeque::new(),
            #[cfg(feature = "wasm")]
            engine: wasmtime::Engine::default(),
            #[cfg(feature = "wasm")]
            store: None,
            #[cfg(feature = "wasm")]
            instance: None,
            #[cfg(feature = "wasm")]
            memory: None,
        }
    }
}

impl Default for WasmTransport {
    fn default() -> Self {
        Self::new()
    }
}

// -- Feature-gated implementation (with wasmtime) -------------------------

#[cfg(feature = "wasm")]
impl PluginTransport for WasmTransport {
    fn spawn(
        &mut self,
        manifest: &PluginManifest,
        plugin_dir: &Path,
    ) -> Result<(), TransportError> {
        if self.running {
            return Err(TransportError::SpawnFailed(
                "transport already running".into(),
            ));
        }

        let wasm_path = plugin_dir.join(&manifest.plugin.entry);
        if !wasm_path.exists() {
            return Err(TransportError::SpawnFailed(format!(
                "wasm module not found: {}",
                wasm_path.display()
            )));
        }

        let module = wasmtime::Module::from_file(&self.engine, &wasm_path)
            .map_err(|e| TransportError::WasmError(format!("failed to load module: {e}")))?;

        let wasm_state = WasmState {
            inbox: VecDeque::new(),
            outbox: VecDeque::new(),
        };
        let mut store = wasmtime::Store::new(&self.engine, wasm_state);

        let mut linker = wasmtime::Linker::new(&self.engine);

        // Expose host_send(ptr: i32, len: i32) -- plugin writes a message for the host.
        linker
            .func_wrap(
                "env",
                "host_send",
                |mut caller: wasmtime::Caller<'_, WasmState>, ptr: i32, len: i32| {
                    let memory = match caller.get_export("memory").and_then(|e| e.into_memory()) {
                        Some(m) => m,
                        None => {
                            eprintln!("host_send: plugin does not export memory");
                            return;
                        }
                    };
                    let data = memory.data(&caller);
                    let start = ptr as usize;
                    let end = start + len as usize;
                    if end > data.len() {
                        return;
                    }
                    if let Ok(msg) = std::str::from_utf8(&data[start..end]) {
                        caller.data_mut().outbox.push_back(msg.to_owned());
                    }
                },
            )
            .map_err(|e| TransportError::WasmError(format!("failed to link host_send: {e}")))?;

        // Expose host_recv(ptr: i32, len: i32) -> i32 -- plugin reads a message from the host.
        // Returns the number of bytes written, or 0 if no message available,
        // or -1 if the buffer is too small.
        linker
            .func_wrap(
                "env",
                "host_recv",
                |mut caller: wasmtime::Caller<'_, WasmState>, ptr: i32, len: i32| -> i32 {
                    let msg = match caller.data_mut().inbox.pop_front() {
                        Some(m) => m,
                        None => return 0,
                    };
                    let bytes = msg.as_bytes();
                    if bytes.len() > len as usize {
                        // Put it back -- buffer too small.
                        caller.data_mut().inbox.push_front(msg);
                        return -1;
                    }
                    let memory = match caller.get_export("memory").and_then(|e| e.into_memory()) {
                        Some(m) => m,
                        None => {
                            eprintln!("host_recv: plugin does not export memory");
                            // Put the message back since we couldn't deliver it.
                            caller.data_mut().inbox.push_front(msg);
                            return -2;
                        }
                    };
                    let start = ptr as usize;
                    memory.data_mut(&mut caller)[start..start + bytes.len()].copy_from_slice(bytes);
                    bytes.len() as i32
                },
            )
            .map_err(|e| TransportError::WasmError(format!("failed to link host_recv: {e}")))?;

        let instance = linker
            .instantiate(&mut store, &module)
            .map_err(|e| TransportError::WasmError(format!("instantiation failed: {e}")))?;

        let memory = instance
            .get_memory(&mut store, "memory")
            .ok_or_else(|| TransportError::WasmError("module does not export memory".into()))?;

        // Call _start or _initialize if exported (WASI convention).
        if let Ok(start_fn) = instance.get_typed_func::<(), ()>(&mut store, "_start") {
            start_fn
                .call(&mut store, ())
                .map_err(|e| TransportError::WasmError(format!("_start failed: {e}")))?;
        } else if let Ok(init_fn) = instance.get_typed_func::<(), ()>(&mut store, "_initialize") {
            init_fn
                .call(&mut store, ())
                .map_err(|e| TransportError::WasmError(format!("_initialize failed: {e}")))?;
        }

        self.module_path = Some(wasm_path);
        self.store = Some(store);
        self.instance = Some(instance);
        self.memory = Some(memory);
        self.running = true;

        Ok(())
    }

    fn send(&mut self, msg: &str) -> Result<(), TransportError> {
        if !self.running {
            return Err(TransportError::NotRunning);
        }
        let store = self.store.as_mut().ok_or(TransportError::NotRunning)?;
        store.data_mut().inbox.push_back(msg.to_owned());

        // If the plugin exports a `plugin_poll` function, call it so it can
        // process the message synchronously.
        if let Some(ref instance) = self.instance {
            if let Ok(poll_fn) = instance.get_typed_func::<(), ()>(store, "plugin_poll") {
                poll_fn
                    .call(store, ())
                    .map_err(|e| TransportError::SendFailed(format!("plugin_poll failed: {e}")))?;
            }
        }

        Ok(())
    }

    fn recv(&mut self) -> Result<Option<String>, TransportError> {
        if !self.running {
            return Err(TransportError::NotRunning);
        }
        let store = self.store.as_mut().ok_or(TransportError::NotRunning)?;
        Ok(store.data_mut().outbox.pop_front())
    }

    fn stop(&mut self) -> Result<(), TransportError> {
        self.running = false;
        self.store = None;
        self.instance = None;
        self.memory = None;
        self.module_path = None;
        self.inbox.clear();
        self.outbox.clear();
        Ok(())
    }

    fn is_running(&self) -> bool {
        self.running
    }
}

// -- Stub implementation (no wasm feature) --------------------------------

#[cfg(not(feature = "wasm"))]
impl PluginTransport for WasmTransport {
    fn spawn(
        &mut self,
        _manifest: &PluginManifest,
        _plugin_dir: &Path,
    ) -> Result<(), TransportError> {
        Err(TransportError::WasmError(
            "WASM support requires the `wasm` feature flag".into(),
        ))
    }

    fn send(&mut self, _msg: &str) -> Result<(), TransportError> {
        Err(TransportError::WasmError(
            "WASM support requires the `wasm` feature flag".into(),
        ))
    }

    fn recv(&mut self) -> Result<Option<String>, TransportError> {
        Err(TransportError::WasmError(
            "WASM support requires the `wasm` feature flag".into(),
        ))
    }

    fn stop(&mut self) -> Result<(), TransportError> {
        Ok(())
    }

    fn is_running(&self) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_transport_not_running() {
        let t = WasmTransport::new();
        assert!(!t.is_running());
    }

    #[test]
    fn default_transport_not_running() {
        let t = WasmTransport::default();
        assert!(!t.is_running());
    }

    #[test]
    fn stop_idle_is_ok() {
        let mut t = WasmTransport::new();
        assert!(t.stop().is_ok());
    }

    #[cfg(not(feature = "wasm"))]
    mod without_feature {
        use super::*;

        #[test]
        fn spawn_returns_wasm_error() {
            let manifest = crate::manifest::PluginManifest::parse(
                r#"
[plugin]
name = "WasmPlugin"
version = "0.1.0"
entry = "plugin.wasm"
"#,
            )
            .unwrap();
            let mut t = WasmTransport::new();
            let result = t.spawn(&manifest, Path::new("/tmp"));
            match result {
                Err(TransportError::WasmError(msg)) => {
                    assert!(
                        msg.contains("wasm"),
                        "error should mention wasm feature: {msg}"
                    );
                }
                other => panic!("expected WasmError, got: {other:?}"),
            }
        }

        #[test]
        fn send_returns_wasm_error() {
            let mut t = WasmTransport::new();
            let result = t.send("hello\n");
            assert!(result.is_err());
            match result.unwrap_err() {
                TransportError::WasmError(msg) => {
                    assert!(msg.contains("wasm"), "got: {msg}");
                }
                other => panic!("expected WasmError, got: {other}"),
            }
        }

        #[test]
        fn recv_returns_wasm_error() {
            let mut t = WasmTransport::new();
            let result = t.recv();
            assert!(result.is_err());
            match result.unwrap_err() {
                TransportError::WasmError(msg) => {
                    assert!(msg.contains("wasm"), "got: {msg}");
                }
                other => panic!("expected WasmError, got: {other}"),
            }
        }
    }
}
