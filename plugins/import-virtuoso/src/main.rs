//! Schemify ImportVirtuoso subprocess plugin.
//!
//! A standalone binary that communicates with the host via JSON-RPC over
//! stdin/stdout. Imports Cadence Virtuoso CDL, Spectre, and Verilog-A files.

mod cdl;
mod convert;
mod pdk_map;
mod result;
mod spectre;
mod verilog_a;

use std::io::{self, BufRead, Write};

use serde::{Deserialize, Serialize};
use serde_json::Value;

// -- JSON-RPC types -----------------------------------------------------------

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct RpcRequest {
    jsonrpc: String,
    method: String,
    #[serde(default)]
    params: Value,
    id: Value,
}

#[derive(Debug, Serialize)]
struct RpcResponse {
    jsonrpc: String,
    result: Option<Value>,
    error: Option<RpcError>,
    id: Value,
}

#[derive(Debug, Serialize)]
struct RpcError {
    code: i32,
    message: String,
}

impl RpcResponse {
    fn success(id: Value, result: Value) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            result: Some(result),
            error: None,
            id,
        }
    }

    fn error(id: Value, code: i32, message: String) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            result: None,
            error: Some(RpcError { code, message }),
            id,
        }
    }
}

// -- Parameter types ----------------------------------------------------------

#[derive(Debug, Deserialize)]
struct ContentParams {
    content: String,
}

#[derive(Debug, Deserialize)]
struct FileParams {
    path: String,
    content: String,
}

// -- Main loop ----------------------------------------------------------------

fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut stdout_lock = stdout.lock();

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };

        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let request: RpcRequest = match serde_json::from_str(trimmed) {
            Ok(r) => r,
            Err(e) => {
                let resp = RpcResponse::error(
                    Value::Null,
                    -32700,
                    format!("Parse error: {}", e),
                );
                let _ = writeln!(stdout_lock, "{}", serde_json::to_string(&resp).unwrap());
                let _ = stdout_lock.flush();
                continue;
            }
        };

        let response = handle_request(&request);

        let _ = writeln!(stdout_lock, "{}", serde_json::to_string(&response).unwrap());
        let _ = stdout_lock.flush();

        // Exit on shutdown
        if request.method == "shutdown" {
            break;
        }
    }
}

fn handle_request(req: &RpcRequest) -> RpcResponse {
    match req.method.as_str() {
        "initialize" => handle_initialize(req),
        "import/cdl" => handle_import_cdl(req),
        "import/spectre" => handle_import_spectre(req),
        "import/verilog_a" => handle_import_verilog_a(req),
        "import/file" => handle_import_file(req),
        "shutdown" => handle_shutdown(req),
        _ => RpcResponse::error(
            req.id.clone(),
            -32601,
            format!("Method not found: {}", req.method),
        ),
    }
}

fn handle_initialize(req: &RpcRequest) -> RpcResponse {
    let info = serde_json::json!({
        "name": "ImportVirtuoso",
        "version": "0.1.0",
        "description": "Import Cadence Virtuoso CDL, Spectre, and Verilog-A files",
        "capabilities": {
            "commands": true,
        },
        "methods": [
            "import/cdl",
            "import/spectre",
            "import/verilog_a",
            "import/file",
        ],
    });

    RpcResponse::success(req.id.clone(), info)
}

fn handle_import_cdl(req: &RpcRequest) -> RpcResponse {
    let params: ContentParams = match serde_json::from_value(req.params.clone()) {
        Ok(p) => p,
        Err(e) => {
            return RpcResponse::error(
                req.id.clone(),
                -32602,
                format!("Invalid params: {}", e),
            );
        }
    };

    match convert::import_cdl(&params.content) {
        Ok(result) => match serde_json::to_value(&result) {
            Ok(v) => RpcResponse::success(req.id.clone(), v),
            Err(e) => RpcResponse::error(req.id.clone(), -32603, format!("Serialize error: {}", e)),
        },
        Err(e) => RpcResponse::error(req.id.clone(), -32000, format!("CDL parse error: {}", e)),
    }
}

fn handle_import_spectre(req: &RpcRequest) -> RpcResponse {
    let params: ContentParams = match serde_json::from_value(req.params.clone()) {
        Ok(p) => p,
        Err(e) => {
            return RpcResponse::error(
                req.id.clone(),
                -32602,
                format!("Invalid params: {}", e),
            );
        }
    };

    match convert::import_spectre(&params.content) {
        Ok(result) => match serde_json::to_value(&result) {
            Ok(v) => RpcResponse::success(req.id.clone(), v),
            Err(e) => RpcResponse::error(req.id.clone(), -32603, format!("Serialize error: {}", e)),
        },
        Err(e) => RpcResponse::error(
            req.id.clone(),
            -32000,
            format!("Spectre parse error: {}", e),
        ),
    }
}

fn handle_import_verilog_a(req: &RpcRequest) -> RpcResponse {
    let params: ContentParams = match serde_json::from_value(req.params.clone()) {
        Ok(p) => p,
        Err(e) => {
            return RpcResponse::error(
                req.id.clone(),
                -32602,
                format!("Invalid params: {}", e),
            );
        }
    };

    match verilog_a::parse_verilog_a(&params.content) {
        Ok(module) => {
            let result = verilog_a::module_to_result(&module);
            match serde_json::to_value(&result) {
                Ok(v) => RpcResponse::success(req.id.clone(), v),
                Err(e) => {
                    RpcResponse::error(req.id.clone(), -32603, format!("Serialize error: {}", e))
                }
            }
        }
        Err(e) => RpcResponse::error(
            req.id.clone(),
            -32000,
            format!("Verilog-A parse error: {}", e),
        ),
    }
}

fn handle_import_file(req: &RpcRequest) -> RpcResponse {
    let params: FileParams = match serde_json::from_value(req.params.clone()) {
        Ok(p) => p,
        Err(e) => {
            return RpcResponse::error(
                req.id.clone(),
                -32602,
                format!("Invalid params: {}", e),
            );
        }
    };

    // Detect format from file extension
    let path_lower = params.path.to_ascii_lowercase();
    let ext = path_lower.rsplit('.').next().unwrap_or("");

    match ext {
        "cdl" | "spice" | "sp" | "cir" => match convert::import_cdl(&params.content) {
            Ok(result) => match serde_json::to_value(&result) {
                Ok(v) => RpcResponse::success(req.id.clone(), v),
                Err(e) => {
                    RpcResponse::error(req.id.clone(), -32603, format!("Serialize error: {}", e))
                }
            },
            Err(e) => {
                RpcResponse::error(req.id.clone(), -32000, format!("CDL parse error: {}", e))
            }
        },
        "scs" | "spectre" => match convert::import_spectre(&params.content) {
            Ok(result) => match serde_json::to_value(&result) {
                Ok(v) => RpcResponse::success(req.id.clone(), v),
                Err(e) => {
                    RpcResponse::error(req.id.clone(), -32603, format!("Serialize error: {}", e))
                }
            },
            Err(e) => RpcResponse::error(
                req.id.clone(),
                -32000,
                format!("Spectre parse error: {}", e),
            ),
        },
        "va" | "vams" => match verilog_a::parse_verilog_a(&params.content) {
            Ok(module) => {
                let result = verilog_a::module_to_result(&module);
                match serde_json::to_value(&result) {
                    Ok(v) => RpcResponse::success(req.id.clone(), v),
                    Err(e) => RpcResponse::error(
                        req.id.clone(),
                        -32603,
                        format!("Serialize error: {}", e),
                    ),
                }
            }
            Err(e) => RpcResponse::error(
                req.id.clone(),
                -32000,
                format!("Verilog-A parse error: {}", e),
            ),
        },
        _ => RpcResponse::error(
            req.id.clone(),
            -32000,
            format!(
                "Unknown file extension '{}'. Supported: .cdl, .spice, .sp, .cir, .scs, .spectre, .va, .vams",
                ext
            ),
        ),
    }
}

fn handle_shutdown(req: &RpcRequest) -> RpcResponse {
    RpcResponse::success(req.id.clone(), serde_json::json!({"status": "ok"}))
}
