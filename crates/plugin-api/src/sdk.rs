//! Guest-side SDK for writing Schemify plugins in Rust.
//!
//! A plugin implements [`Plugin`] and drives it with a stdio
//! [`PluginRuntime`]:
//!
//! ```no_run
//! use schemify_plugin_api::sdk::{Plugin, PluginRuntime, RuntimeError};
//!
//! struct MyPlugin;
//! impl Plugin for MyPlugin {}
//!
//! fn main() -> Result<(), RuntimeError> {
//!     PluginRuntime::stdio().run(&mut MyPlugin)
//! }
//! ```

    use std::collections::VecDeque;
    use std::io::{self, BufRead, BufReader, Write};

    use serde_json::{json, Value};

    // Re-exports so plugin binaries only need this module.
    pub use crate::{
        AlertLevel, CommandInvocation, ErrorInfo, InitializeEvent, InstanceRecord, InstanceRef,
        MarkerKind, NetRecord, NetlistRecord, OverlayShape, PanelLayout, PdkCellRecord,
        PdkRecord, ProjectRecord, ThemeColor, ThemeTokens, ThemeValue, UiAction, WidgetNode,
    };

    use crate::{methods, IncomingMessage};

    #[derive(Debug, thiserror::Error)]
    pub enum RuntimeError {
        #[error("io failed: {0}")]
        Io(#[from] io::Error),

        #[error("json failed: {0}")]
        Json(#[from] serde_json::Error),

        #[error("host returned error {code}: {message}")]
        HostError { code: i32, message: String },

        #[error("unexpected end of input")]
        EndOfInput,
    }

    /// A response to a request this plugin sent to the host.
    #[derive(Debug, Clone)]
    pub struct ResponseMessage {
        pub id: u32,
        pub result: Option<Value>,
        pub error: Option<ErrorInfo>,
    }

    /// Decoded event from the host.
    #[derive(Debug, Clone)]
    pub enum HostEvent {
        Initialize(InitializeEvent),
        Shutdown,
        SchematicChanged,
        SelectionChanged,
        ThemeChanged(ThemeTokens),
        Command(CommandInvocation),
        UiAction(UiAction),
        Response(ResponseMessage),
        Notification {
            method: String,
            params: Option<Value>,
        },
    }

    /// Plugin event callbacks. All default to no-ops.
    pub trait Plugin {
        fn on_initialize(
            &mut self,
            _runtime: &mut PluginRuntime,
            _event: InitializeEvent,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn on_shutdown(&mut self, _runtime: &mut PluginRuntime) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn on_command(
            &mut self,
            _runtime: &mut PluginRuntime,
            _command: CommandInvocation,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn on_ui_action(
            &mut self,
            _runtime: &mut PluginRuntime,
            _action: UiAction,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn on_schematic_changed(
            &mut self,
            _runtime: &mut PluginRuntime,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn on_selection_changed(
            &mut self,
            _runtime: &mut PluginRuntime,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn on_theme_changed(
            &mut self,
            _runtime: &mut PluginRuntime,
            _theme: ThemeTokens,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn on_response(
            &mut self,
            _runtime: &mut PluginRuntime,
            _response: ResponseMessage,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn on_notification(
            &mut self,
            _runtime: &mut PluginRuntime,
            _method: String,
            _params: Option<Value>,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }
    }

    /// Guest-side event loop and host API.
    pub struct PluginRuntime {
        reader: Box<dyn BufRead + Send>,
        writer: Box<dyn Write + Send>,
        next_id: u32,
        deferred: VecDeque<IncomingMessage>,
    }

    impl PluginRuntime {
        /// Runtime speaking over stdin/stdout (the standard transport).
        pub fn stdio() -> Self {
            Self {
                reader: Box::new(BufReader::new(io::stdin())),
                writer: Box::new(io::stdout()),
                next_id: 1,
                deferred: VecDeque::new(),
            }
        }

        /// Run the event loop until shutdown or EOF.
        pub fn run<P: Plugin>(&mut self, plugin: &mut P) -> Result<(), RuntimeError> {
            loop {
                match self.read_event()? {
                    HostEvent::Initialize(event) => plugin.on_initialize(self, event)?,
                    HostEvent::Shutdown => {
                        plugin.on_shutdown(self)?;
                        return Ok(());
                    }
                    HostEvent::SchematicChanged => plugin.on_schematic_changed(self)?,
                    HostEvent::SelectionChanged => plugin.on_selection_changed(self)?,
                    HostEvent::ThemeChanged(theme) => plugin.on_theme_changed(self, theme)?,
                    HostEvent::Command(command) => plugin.on_command(self, command)?,
                    HostEvent::UiAction(action) => plugin.on_ui_action(self, action)?,
                    HostEvent::Response(response) => plugin.on_response(self, response)?,
                    HostEvent::Notification { method, params } => {
                        plugin.on_notification(self, method, params)?
                    }
                }
            }
        }

        // ── Host API: notifications ────────────────────────────────────────

        pub fn log(
            &mut self,
            level: &str,
            message: impl Into<String>,
        ) -> Result<(), RuntimeError> {
            self.notify(
                methods::LOG,
                Some(json!({"level": level, "message": message.into()})),
            )
        }

        pub fn info(&mut self, message: impl Into<String>) -> Result<(), RuntimeError> {
            self.log("info", message)
        }

        pub fn set_status(&mut self, message: impl Into<String>) -> Result<(), RuntimeError> {
            self.notify(
                methods::SET_STATUS,
                Some(json!({"message": message.into()})),
            )
        }

        pub fn register_panel(
            &mut self,
            name: impl Into<String>,
            slot: PanelLayout,
            priority: i32,
            default_visible: bool,
        ) -> Result<(), RuntimeError> {
            self.notify(
                methods::PANELS_REGISTER,
                Some(json!({
                    "name": name.into(),
                    "slot": slot,
                    "priority": priority,
                    "default_visible": default_visible,
                })),
            )
        }

        pub fn update_widgets(
            &mut self,
            panel: impl Into<String>,
            widgets: Vec<WidgetNode>,
        ) -> Result<(), RuntimeError> {
            self.notify(
                methods::PANELS_UPDATE_WIDGETS,
                Some(json!({"panel": panel.into(), "widgets": widgets})),
            )
        }

        pub fn register_command(
            &mut self,
            name: impl Into<String>,
            description: impl Into<String>,
            keybind: Option<&str>,
        ) -> Result<(), RuntimeError> {
            self.notify(
                methods::COMMANDS_REGISTER,
                Some(json!({
                    "name": name.into(),
                    "description": description.into(),
                    "keybind": keybind,
                })),
            )
        }

        pub fn update_overlay(
            &mut self,
            name: impl Into<String>,
            z_order: i32,
            visible: bool,
            shapes: Vec<OverlayShape>,
        ) -> Result<(), RuntimeError> {
            self.notify(
                methods::OVERLAY_UPDATE,
                Some(json!({
                    "name": name.into(),
                    "z_order": z_order,
                    "visible": visible,
                    "shapes": shapes,
                })),
            )
        }

        pub fn set_theme_override(
            &mut self,
            priority: i32,
            overrides: impl IntoIterator<Item = (String, ThemeValue)>,
        ) -> Result<(), RuntimeError> {
            let overrides = overrides
                .into_iter()
                .map(|(key, value)| serde_json::to_value(value).map(|value| (key, value)))
                .collect::<Result<serde_json::Map<String, Value>, _>>()?;
            self.notify(
                methods::THEME_OVERRIDE,
                Some(json!({"priority": priority, "overrides": overrides})),
            )
        }

        /// Dispatch a host command by action name (e.g. `"zoom_in"`, `"undo"`).
        /// The host maps known action strings onto editor commands.
        pub fn dispatch_action(&mut self, action: &str) -> Result<(), RuntimeError> {
            self.notify(methods::COMMANDS_DISPATCH, Some(json!({"action": action})))
        }

        /// Dispatch a full externally-tagged editor command, e.g.
        /// `json!({"SetInstanceProp": {"idx": 3, "key": "W", "value": "2u"}})`.
        /// Same JSON shape the CLI and MCP accept.
        pub fn dispatch_command(&mut self, command: Value) -> Result<(), RuntimeError> {
            self.notify(methods::COMMANDS_DISPATCH, Some(command))
        }

        pub fn notify(&mut self, method: &str, params: Option<Value>) -> Result<(), RuntimeError> {
            let msg = crate::notification(method, params)?;
            self.writer.write_all(msg.as_bytes())?;
            self.writer.flush()?;
            Ok(())
        }

        // ── Host API: requests ─────────────────────────────────────────────

        /// Send a request; returns its id. Response arrives via `on_response`
        /// or a blocking `request_json`.
        pub fn request(
            &mut self,
            method: &str,
            params: Option<Value>,
        ) -> Result<u32, RuntimeError> {
            let id = self.next_id;
            self.next_id = self.next_id.wrapping_add(1);
            let msg = crate::request(id, method, params)?;
            self.writer.write_all(msg.as_bytes())?;
            self.writer.flush()?;
            Ok(id)
        }

        /// Send a request and block until its response arrives. Other messages
        /// received meanwhile are deferred and replayed to the event loop.
        pub fn request_json(
            &mut self,
            method: &str,
            params: Option<Value>,
        ) -> Result<Value, RuntimeError> {
            let id = self.request(method, params)?;
            loop {
                match self.read_message()? {
                    IncomingMessage::Response {
                        id: response_id,
                        result,
                        error,
                    } if response_id == id => {
                        if let Some(error) = error {
                            return Err(RuntimeError::HostError {
                                code: error.code,
                                message: error.message,
                            });
                        }
                        return Ok(result.unwrap_or(Value::Null));
                    }
                    other => self.deferred.push_back(other),
                }
            }
        }

        pub fn query_instances(&mut self) -> Result<Vec<InstanceRecord>, RuntimeError> {
            let value = self.request_json(methods::QUERY_INSTANCES, None)?;
            Ok(serde_json::from_value(value)?)
        }

        pub fn query_nets(&mut self) -> Result<Vec<NetRecord>, RuntimeError> {
            let value = self.request_json(methods::QUERY_NETS, None)?;
            Ok(serde_json::from_value(value)?)
        }

        pub fn query_theme(&mut self) -> Result<ThemeTokens, RuntimeError> {
            let value = self.request_json(methods::QUERY_THEME, None)?;
            Ok(serde_json::from_value(value)?)
        }

        pub fn query_project(&mut self) -> Result<ProjectRecord, RuntimeError> {
            let value = self.request_json(methods::QUERY_PROJECT, None)?;
            Ok(serde_json::from_value(value)?)
        }

        /// The active PDK, or `None` if the project has none loaded.
        pub fn query_pdk(&mut self) -> Result<Option<PdkRecord>, RuntimeError> {
            let value = self.request_json(methods::QUERY_PDK, None)?;
            Ok(serde_json::from_value(value)?)
        }

        pub fn query_netlist(&mut self) -> Result<NetlistRecord, RuntimeError> {
            let value = self.request_json(methods::QUERY_NETLIST, None)?;
            Ok(serde_json::from_value(value)?)
        }

        /// Optimizer instances: `Some(id)` = that instance's full state,
        /// `None` = summary list. Raw JSON — the shape is owned by the
        /// host's optimizer state. Requires the `optimizer` capability.
        pub fn query_optimizers(&mut self, id: Option<u32>) -> Result<Value, RuntimeError> {
            let params = id.map(|id| json!({ "id": id }));
            self.request_json(methods::QUERY_OPTIMIZERS, params)
        }

        // ── Incoming ───────────────────────────────────────────────────────

        fn read_event(&mut self) -> Result<HostEvent, RuntimeError> {
            match self.read_message()? {
                // The host currently sends no requests; surface them as raw
                // notifications so a plugin can still observe them.
                IncomingMessage::Request { id, method, params } => Ok(HostEvent::Notification {
                    method,
                    params: Some(json!({"id": id, "params": params})),
                }),
                IncomingMessage::Notification { method, params } => {
                    decode_notification(method, params)
                }
                IncomingMessage::Response { id, result, error } => {
                    Ok(HostEvent::Response(ResponseMessage { id, result, error }))
                }
            }
        }

        fn read_message(&mut self) -> Result<IncomingMessage, RuntimeError> {
            if let Some(message) = self.deferred.pop_front() {
                return Ok(message);
            }
            let mut line = String::new();
            if self.reader.read_line(&mut line)? == 0 {
                return Err(RuntimeError::EndOfInput);
            }
            crate::parse_line(&line).map_err(|err| {
                RuntimeError::Io(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("invalid json-rpc line: {err}"),
                ))
            })
        }
    }

    fn decode_notification(
        method: String,
        params: Option<Value>,
    ) -> Result<HostEvent, RuntimeError> {
        let payload = || params.clone().unwrap_or(Value::Null);
        Ok(match method.as_str() {
            methods::INITIALIZE => HostEvent::Initialize(serde_json::from_value(payload())?),
            methods::SHUTDOWN => HostEvent::Shutdown,
            methods::SCHEMATIC_CHANGED => HostEvent::SchematicChanged,
            methods::SELECTION_CHANGED => HostEvent::SelectionChanged,
            methods::THEME_CHANGED => HostEvent::ThemeChanged(serde_json::from_value(payload())?),
            methods::COMMAND_INVOKE => HostEvent::Command(serde_json::from_value(payload())?),
            methods::UI_ACTION => HostEvent::UiAction(serde_json::from_value(payload())?),
            _ => HostEvent::Notification { method, params },
        })
    }
