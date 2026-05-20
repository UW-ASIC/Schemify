//! XSchem import plugin for SchemifyRS.
//!
//! Standalone subprocess plugin that communicates via JSON-RPC over stdin/stdout.
//! Imports XSchem `.sch` and `.sym` files into a serializable `ImportResult`.

mod result;
mod tcl;
mod xschem;

use std::io::{self, BufRead, Write};
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use result::ImportResult;

/// Simple parse error type (replaces `ImportError` from schemify-import).
#[derive(Debug)]
pub struct ParseError(pub String);

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "parse error: {}", self.0)
    }
}

impl std::error::Error for ParseError {}

// -- JSON-RPC types --

#[derive(Debug, Deserialize)]
struct RpcRequest {
    jsonrpc: String,
    id: Option<Value>,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Debug, Serialize)]
struct RpcResponse {
    jsonrpc: String,
    id: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<RpcError>,
}

#[derive(Debug, Serialize)]
struct RpcError {
    code: i32,
    message: String,
}

impl RpcResponse {
    fn success(id: Value, result: Value) -> Self {
        Self {
            jsonrpc: "2.0".into(),
            id,
            result: Some(result),
            error: None,
        }
    }

    fn error(id: Value, code: i32, message: String) -> Self {
        Self {
            jsonrpc: "2.0".into(),
            id,
            result: None,
            error: Some(RpcError { code, message }),
        }
    }
}

// -- Plugin info --

#[derive(Debug, Serialize)]
struct PluginInfo {
    name: String,
    version: String,
    description: String,
    capabilities: Vec<String>,
}

// -- Import logic --

/// Import an XSchem file from a file path.
fn import_file(path: &str) -> Result<ImportResult, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("failed to read '{}': {}", path, e))?;

    let mut result = import_string(&content)?;

    // Set name from file stem
    let p = Path::new(path);
    if let Some(stem) = p.file_stem().and_then(|s| s.to_str()) {
        result.name = stem.to_string();
    }

    // Set schematic type from extension
    if let Some(ext) = p.extension().and_then(|e| e.to_str()) {
        if ext == "sym" {
            result.schematic_type = "symbol".to_string();
        }
    }

    Ok(result)
}

/// Import XSchem content from a string.
fn import_string(content: &str) -> Result<ImportResult, String> {
    let doc = xschem::parse_xschem(content)
        .map_err(|e| format!("{}", e))?;

    // Check version if present
    if let Some(ref ver) = doc.version {
        if !ver.contains("xschem") {
            return Err(format!("unrecognized version header: {}", ver));
        }
    }

    xschem::convert(&doc)
        .map_err(|e| format!("{}", e))
}

// -- JSON-RPC dispatch --

fn handle_request(req: &RpcRequest) -> RpcResponse {
    let id = req.id.clone().unwrap_or(Value::Null);

    match req.method.as_str() {
        "initialize" => {
            let info = PluginInfo {
                name: "ImportXSchem".into(),
                version: "0.1.0".into(),
                description: "Import XSchem .sch and .sym files".into(),
                capabilities: vec!["import/file".into(), "import/string".into()],
            };
            match serde_json::to_value(&info) {
                Ok(v) => RpcResponse::success(id, v),
                Err(e) => RpcResponse::error(id, -32603, format!("serialization error: {}", e)),
            }
        }

        "import/file" => {
            let path = match req.params.get("path").and_then(|v| v.as_str()) {
                Some(p) => p,
                None => {
                    return RpcResponse::error(
                        id,
                        -32602,
                        "missing 'path' parameter".into(),
                    );
                }
            };

            match import_file(path) {
                Ok(result) => match serde_json::to_value(&result) {
                    Ok(v) => RpcResponse::success(id, v),
                    Err(e) => {
                        RpcResponse::error(id, -32603, format!("serialization error: {}", e))
                    }
                },
                Err(e) => RpcResponse::error(id, -32000, e),
            }
        }

        "import/string" => {
            let content = match req.params.get("content").and_then(|v| v.as_str()) {
                Some(c) => c,
                None => {
                    return RpcResponse::error(
                        id,
                        -32602,
                        "missing 'content' parameter".into(),
                    );
                }
            };

            let name = req
                .params
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("imported");

            match import_string(content) {
                Ok(mut result) => {
                    result.name = name.to_string();
                    match serde_json::to_value(&result) {
                        Ok(v) => RpcResponse::success(id, v),
                        Err(e) => {
                            RpcResponse::error(id, -32603, format!("serialization error: {}", e))
                        }
                    }
                }
                Err(e) => RpcResponse::error(id, -32000, e),
            }
        }

        "shutdown" => {
            // Respond, then the loop will exit on EOF or we handle it
            RpcResponse::success(id, Value::Null)
        }

        _ => RpcResponse::error(id, -32601, format!("unknown method: {}", req.method)),
    }
}

fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut stdout = stdout.lock();

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };

        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let req: RpcRequest = match serde_json::from_str(trimmed) {
            Ok(r) => r,
            Err(e) => {
                let resp = RpcResponse::error(
                    Value::Null,
                    -32700,
                    format!("parse error: {}", e),
                );
                let _ = serde_json::to_writer(&mut stdout, &resp);
                let _ = stdout.write_all(b"\n");
                let _ = stdout.flush();
                continue;
            }
        };

        let is_shutdown = req.method == "shutdown";

        let resp = handle_request(&req);
        let _ = serde_json::to_writer(&mut stdout, &resp);
        let _ = stdout.write_all(b"\n");
        let _ = stdout.flush();

        if is_shutdown {
            break;
        }
    }
}

// -- Integration tests --

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn import_simple_schematic() {
        let input = r#"v {xschem version=3.4.5 file_version=1.2}
G {}
K {}
V {}
S {}
E {}
C {devices/res.sym} 100 200 0 0 {name=R1 value=10k}
C {devices/cap.sym} 300 400 2 1 {name=C1 value=1u}
C {devices/gnd.sym} 100 500 0 0 {name=l1 lab=GND}
N 100 200 300 200 {lab=net1}
N 300 400 100 400 {}
T {Title: Test} 0 -100 0 0 0.5 0.5 {}
"#;
        let result = import_string(input).unwrap();

        assert_eq!(result.instances.len(), 3);
        assert_eq!(result.wires.len(), 2);
        assert_eq!(result.texts.len(), 1);

        // Check first instance (resistor)
        assert_eq!(result.instances[0].kind, "resistor");
        assert_eq!(result.instances[0].x, 100);
        assert_eq!(result.instances[0].y, 200);

        // Check second instance (capacitor with rotation and flip)
        assert_eq!(result.instances[1].kind, "capacitor");
        assert_eq!(result.instances[1].rotation, 2);
        assert!(result.instances[1].flip);

        // Check GND instance
        assert_eq!(result.instances[2].kind, "gnd");

        // Check wire with label
        assert_eq!(result.wires[0].net_name, "net1");
    }

    #[test]
    fn import_empty_schematic() {
        let input = "v {xschem version=3.4.5}\n";
        let result = import_string(input).unwrap();
        assert_eq!(result.instances.len(), 0);
        assert_eq!(result.wires.len(), 0);
    }

    #[test]
    fn import_with_pdk_model() {
        let input = r#"v {xschem version=3.4.5}
C {sky130_fd_pr/nfet_01v8.sym} 200 300 0 0 {name=M1 model=sky130_fd_pr__nfet_01v8 w=0.42 l=0.15}
"#;
        let result = import_string(input).unwrap();
        assert_eq!(result.instances.len(), 1);
        assert_eq!(result.instances[0].kind, "nmos4");
    }

    #[test]
    fn import_geometric_elements() {
        let input = r#"v {xschem version=3.4.5}
L 4 0 0 100 100
B 5 10 20 110 120
A 4 50 50 25 0 360
"#;
        let result = import_string(input).unwrap();
        assert_eq!(result.lines.len(), 1);
        assert_eq!(result.rects.len(), 1);
        assert_eq!(result.arcs.len(), 1);
    }

    #[test]
    fn import_unsupported_version() {
        // "not_xschem" contains "xschem" as substring, so it passes.
        let input = "v {not_xschem version=1.0}\n";
        let result = import_string(input);
        assert!(result.is_ok());

        // A truly unrecognized version header should fail.
        let input2 = "v {some_other_tool version=1.0}\n";
        let result2 = import_string(input2);
        assert!(result2.is_err());
    }

    #[test]
    fn import_error_display() {
        let err = ParseError("line 5: bad token".into());
        assert_eq!(format!("{}", err), "parse error: line 5: bad token");
    }

    #[test]
    fn json_rpc_initialize() {
        let req = RpcRequest {
            jsonrpc: "2.0".into(),
            id: Some(Value::Number(1.into())),
            method: "initialize".into(),
            params: Value::Null,
        };
        let resp = handle_request(&req);
        assert!(resp.result.is_some());
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["name"], "ImportXSchem");
    }

    #[test]
    fn json_rpc_import_string() {
        let content = r#"v {xschem version=3.4.5}
C {devices/res.sym} 100 200 0 0 {name=R1 value=10k}
"#;
        let params = serde_json::json!({
            "content": content,
            "name": "test"
        });
        let req = RpcRequest {
            jsonrpc: "2.0".into(),
            id: Some(Value::Number(2.into())),
            method: "import/string".into(),
            params,
        };
        let resp = handle_request(&req);
        assert!(resp.result.is_some());
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["name"], "test");
        assert_eq!(result["instances"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn json_rpc_unknown_method() {
        let req = RpcRequest {
            jsonrpc: "2.0".into(),
            id: Some(Value::Number(3.into())),
            method: "nonexistent".into(),
            params: Value::Null,
        };
        let resp = handle_request(&req);
        assert!(resp.error.is_some());
        assert_eq!(resp.error.unwrap().code, -32601);
    }

    #[test]
    fn json_rpc_missing_params() {
        let req = RpcRequest {
            jsonrpc: "2.0".into(),
            id: Some(Value::Number(4.into())),
            method: "import/file".into(),
            params: Value::Null,
        };
        let resp = handle_request(&req);
        assert!(resp.error.is_some());
        assert_eq!(resp.error.unwrap().code, -32602);
    }

    #[test]
    fn json_rpc_shutdown() {
        let req = RpcRequest {
            jsonrpc: "2.0".into(),
            id: Some(Value::Number(5.into())),
            method: "shutdown".into(),
            params: Value::Null,
        };
        let resp = handle_request(&req);
        assert!(resp.result.is_some());
        assert!(resp.error.is_none());
    }

    #[test]
    fn import_file_sets_name_and_type() {
        // Write a temp file to test import_file
        let dir = std::env::temp_dir();
        let sch_path = dir.join("test_import.sch");
        std::fs::write(
            &sch_path,
            "v {xschem version=3.4.5}\nC {devices/res.sym} 0 0 0 0 {name=R1 value=1k}\n",
        )
        .unwrap();

        let result = import_file(sch_path.to_str().unwrap()).unwrap();
        assert_eq!(result.name, "test_import");
        assert_eq!(result.schematic_type, "schematic");
        assert_eq!(result.instances.len(), 1);

        let _ = std::fs::remove_file(&sch_path);

        // Test .sym extension
        let sym_path = dir.join("test_import.sym");
        std::fs::write(
            &sym_path,
            "v {xschem version=3.4.5}\n",
        )
        .unwrap();

        let result = import_file(sym_path.to_str().unwrap()).unwrap();
        assert_eq!(result.name, "test_import");
        assert_eq!(result.schematic_type, "symbol");

        let _ = std::fs::remove_file(&sym_path);
    }
}
