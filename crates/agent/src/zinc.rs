//! Managed local ZINC server (github.com/zolotukhin/zinc).
//!
//! ZINC ships no prebuilt binaries (it's `zig build` from source), so we
//! never install it — but if `zinc` is on PATH we can do everything else:
//! pull a catalog model (ZINC downloads it itself), run the
//! OpenAI-compatible server on a port, watch it come up, kill it on drop.
//!
//! ponytail: pull progress is opaque (status stays Pulling for the whole
//! download) — parse `zinc model pull` stdout for a percentage if users ask.

use std::net::{SocketAddr, TcpStream};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::Value;

#[derive(Debug, Clone, PartialEq)]
pub enum ZincStatus {
    /// `zinc model pull` running (first pull downloads the model).
    Pulling,
    /// Server spawned, waiting for the port to answer.
    Starting,
    Running,
    Failed(String),
    Stopped,
}

pub fn installed() -> bool {
    crate::on_path("zinc")
}

/// Catalog model ids from `zinc model list --json`; empty on any failure
/// (callers fall back to a free-text field).
pub fn models() -> Vec<String> {
    let Ok(out) = Command::new("zinc").args(["model", "list", "--json"]).output() else {
        return Vec::new();
    };
    let Ok(v) = serde_json::from_slice::<Value>(&out.stdout) else {
        return Vec::new();
    };
    let items = v
        .as_array()
        .or_else(|| v.get("models").and_then(Value::as_array));
    items
        .map(|a| a.iter().filter_map(model_id).collect())
        .unwrap_or_default()
}

/// Schema-lenient: entries are bare strings or objects with id/name.
fn model_id(m: &Value) -> Option<String> {
    m.as_str()
        .or_else(|| m.get("id").and_then(Value::as_str))
        .or_else(|| m.get("name").and_then(Value::as_str))
        .map(str::to_string)
}

/// A managed ZINC server: pull → serve → ready, on a background thread.
/// Poll [`Zinc::status`]; the child dies with this handle.
pub struct Zinc {
    status: Arc<Mutex<ZincStatus>>,
    child: Arc<Mutex<Option<Child>>>,
    pub port: u16,
}

impl Zinc {
    pub fn launch(model_id: &str, port: u16) -> Zinc {
        let status = Arc::new(Mutex::new(ZincStatus::Pulling));
        let child = Arc::new(Mutex::new(None));
        let (st, ch, id) = (Arc::clone(&status), Arc::clone(&child), model_id.to_string());
        std::thread::spawn(move || run(&st, &ch, &id, port));
        Zinc { status, child, port }
    }

    pub fn status(&self) -> ZincStatus {
        self.status
            .lock()
            .map(|s| s.clone())
            .unwrap_or(ZincStatus::Stopped)
    }

    pub fn base_url(&self) -> String {
        format!("http://localhost:{}/v1", self.port)
    }

    pub fn stop(&self) {
        if let Ok(mut guard) = self.child.lock() {
            if let Some(mut c) = guard.take() {
                let _ = c.kill();
                let _ = c.wait();
            }
        }
        if let Ok(mut s) = self.status.lock() {
            *s = ZincStatus::Stopped;
        }
    }
}

impl Drop for Zinc {
    fn drop(&mut self) {
        self.stop();
    }
}

fn run(status: &Mutex<ZincStatus>, child: &Mutex<Option<Child>>, model_id: &str, port: u16) {
    let set = |s: ZincStatus| {
        if let Ok(mut g) = status.lock() {
            *g = s;
        }
    };

    // 1. Pull — a no-op when the model is already cached, a long download
    //    the first time. ZINC does the downloading; we just wait.
    match Command::new("zinc")
        .args(["model", "pull", model_id])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
    {
        Ok(out) if !out.status.success() => {
            let err = String::from_utf8_lossy(&out.stderr);
            let tail = err.lines().last().unwrap_or("pull failed");
            set(ZincStatus::Failed(format!("pull: {tail}")));
            return;
        }
        Err(e) => {
            set(ZincStatus::Failed(format!("pull: {e}")));
            return;
        }
        _ => {}
    }

    // 2. Serve.
    set(ZincStatus::Starting);
    let spawned = Command::new("zinc")
        .args(["--model-id", model_id, "-p", &port.to_string()])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    match spawned {
        Ok(c) => {
            if let Ok(mut g) = child.lock() {
                *g = Some(c);
            }
        }
        Err(e) => {
            set(ZincStatus::Failed(e.to_string()));
            return;
        }
    }

    // 3. Wait for the port (model load can take a while on first token).
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    for _ in 0..240 {
        if TcpStream::connect_timeout(&addr, Duration::from_millis(500)).is_ok() {
            set(ZincStatus::Running);
            return;
        }
        // Child gone (crashed, or the user hit Stop)?
        if let Ok(mut g) = child.lock() {
            match g.as_mut() {
                None => return, // stop() already set the status
                Some(c) => {
                    if let Ok(Some(code)) = c.try_wait() {
                        set(ZincStatus::Failed(format!("zinc exited: {code}")));
                        return;
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    set(ZincStatus::Failed("timed out waiting for the server".into()));
}
