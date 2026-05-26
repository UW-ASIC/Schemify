//! SchemifyRS plugin in Rust.
//!
//! Demonstrates:
//! - Compiled binary as a subprocess plugin
//! - Sending requests (query_nets) and handling responses
//! - Drawing overlay markers for lint errors
//! - Registering commands
//!
//! Build: `cargo build --release`
//! The entry in plugin.toml points to `./target/release/rust-linter`

use std::collections::HashMap;
use std::io::{self, BufRead, Write};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

// ── JSON-RPC types ──

#[derive(Serialize)]
struct Notification {
    jsonrpc: &'static str,
    method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    params: Option<Value>,
}

#[derive(Serialize)]
struct Request {
    jsonrpc: &'static str,
    id: u32,
    method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    params: Option<Value>,
}

#[derive(Deserialize)]
struct IncomingMessage {
    method: Option<String>,
    id: Option<u32>,
    params: Option<Value>,
    result: Option<Value>,
    error: Option<Value>,
}

// ── Helpers ──

fn send_raw(msg: &impl Serialize) {
    let mut out = serde_json::to_string(msg).expect("serialize");
    out.push('\n');
    let stdout = io::stdout();
    let mut lock = stdout.lock();
    let _ = lock.write_all(out.as_bytes());
    let _ = lock.flush();
}

fn notify(method: &str, params: Option<Value>) {
    send_raw(&Notification {
        jsonrpc: "2.0",
        method: method.into(),
        params,
    });
}

fn request(id: u32, method: &str, params: Option<Value>) {
    send_raw(&Request {
        jsonrpc: "2.0",
        id,
        method: method.into(),
        params,
    });
}

fn log(message: &str) {
    notify(
        "host/log",
        Some(json!({"level": "info", "message": message})),
    );
}

fn set_status(message: &str) {
    notify("host/set_status", Some(json!({"message": message})));
}

// ── Plugin state ──

struct State {
    next_id: u32,
    query_nets_id: Option<u32>,
}

impl State {
    fn new() -> Self {
        Self {
            next_id: 1,
            query_nets_id: None,
        }
    }

    fn alloc_id(&mut self) -> u32 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }
}

// ── Lint logic ──

fn run_lint(state: &mut State) {
    log("querying nets for lint...");
    let id = state.alloc_id();
    state.query_nets_id = Some(id);
    request(id, "state/query_nets", None);
}

fn on_nets_result(result: &Value) {
    // The host returns net data; we check for floating nets.
    // This is a demo — real logic would inspect connectivity.
    let nets = result.as_array().map(|a| a.len()).unwrap_or(0);

    if nets == 0 {
        set_status("Lint: no nets found");
        // Clear overlay
        notify(
            "overlay/update",
            Some(json!({
                "name": "lint_errors",
                "z_order": 100,
                "visible": true,
                "shapes": []
            })),
        );
        return;
    }

    // Demo: flag every other net with a warning marker at origin
    let mut shapes = Vec::new();
    for (i, net) in result
        .as_array()
        .unwrap_or(&Vec::new())
        .iter()
        .enumerate()
    {
        if i % 2 == 0 {
            // Place a marker — in a real plugin you'd use actual coordinates
            shapes.push(json!({
                "Marker": {
                    "x": (i as f32) * 50.0,
                    "y": 0.0,
                    "kind": "Warning",
                    "color": [255, 200, 60, 220]
                }
            }));
        }
    }

    let count = shapes.len();
    notify(
        "overlay/update",
        Some(json!({
            "name": "lint_errors",
            "z_order": 100,
            "visible": true,
            "shapes": shapes
        })),
    );

    set_status(&format!("Lint: {count} warnings in {nets} nets"));
    log(&format!("lint complete: {count} warnings"));
}

// ── Main loop ──

fn main() {
    let mut state = State::new();
    let stdin = io::stdin();

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let msg: IncomingMessage = match serde_json::from_str(trimmed) {
            Ok(m) => m,
            Err(_) => continue,
        };

        // Handle response to our request
        if msg.method.is_none() {
            if let Some(id) = msg.id {
                if state.query_nets_id == Some(id) {
                    state.query_nets_id = None;
                    if let Some(ref result) = msg.result {
                        on_nets_result(result);
                    } else if let Some(ref err) = msg.error {
                        log(&format!("query_nets failed: {err}"));
                    }
                }
            }
            continue;
        }

        let method = msg.method.as_deref().unwrap_or("");
        match method {
            "lifecycle/initialize" => {
                log("rust-linter initialized");
                notify(
                    "commands/register",
                    Some(json!({
                        "name": "lint_now",
                        "description": "Run schematic lint check",
                        "keybind": "Ctrl+Shift+L"
                    })),
                );
                set_status("Linter ready");
                run_lint(&mut state);
            }
            "lifecycle/shutdown" => {
                log("rust-linter shutting down");
                // Clear overlay
                notify(
                    "overlay/update",
                    Some(json!({
                        "name": "lint_errors",
                        "z_order": 100,
                        "visible": false,
                        "shapes": []
                    })),
                );
                break;
            }
            "state/schematic_changed" => {
                run_lint(&mut state);
            }
            _ => {}
        }
    }
}
