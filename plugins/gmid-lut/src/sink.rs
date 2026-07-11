//! Thread-safe host notifier for worker threads.
//!
//! `PluginRuntime` is owned by the main event loop (blocked on stdin), so
//! workers write JSON-RPC notification lines straight to stdout. Each line
//! is one `write_all` on the process-global stdout lock, so worker and
//! main-loop lines never interleave mid-message.

use schemify_plugin_api::{methods, notification, WidgetNode};
use serde_json::json;
use std::io::Write;

#[derive(Clone, Default)]
pub struct HostSink;

impl HostSink {
    fn send(&self, line: Result<String, serde_json::Error>) {
        if let Ok(line) = line {
            let stdout = std::io::stdout();
            let mut lock = stdout.lock();
            let _ = lock.write_all(line.as_bytes());
            let _ = lock.flush();
        }
    }

    pub fn update_widgets(&self, panel: &str, widgets: Vec<WidgetNode>) {
        self.send(notification(
            methods::PANELS_UPDATE_WIDGETS,
            Some(json!({"panel": panel, "widgets": widgets})),
        ));
    }

    pub fn set_status(&self, message: impl Into<String>) {
        self.send(notification(
            methods::SET_STATUS,
            Some(json!({"message": message.into()})),
        ));
    }

    pub fn log(&self, level: &str, message: impl Into<String>) {
        self.send(notification(
            methods::LOG,
            Some(json!({"level": level, "message": message.into()})),
        ));
    }
}
