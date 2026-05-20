use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const PARSE_ERROR: i32 = -32700;
pub const INVALID_REQUEST: i32 = -32600;
pub const METHOD_NOT_FOUND: i32 = -32601;
pub const INVALID_PARAMS: i32 = -32602;
pub const INTERNAL_ERROR: i32 = -32603;

/// Outgoing JSON-RPC notification (no id, no response expected).
#[derive(Debug, Clone, Serialize)]
pub struct Notification {
    pub jsonrpc: &'static str,
    pub method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}

/// Outgoing JSON-RPC request (has id, expects response).
#[derive(Debug, Clone, Serialize)]
pub struct Request {
    pub jsonrpc: &'static str,
    pub id: u32,
    pub method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}

/// JSON-RPC error info.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorInfo {
    pub code: i32,
    pub message: String,
}

/// Outgoing JSON-RPC success response.
#[derive(Debug, Clone, Serialize)]
pub struct SuccessResponse {
    pub jsonrpc: &'static str,
    pub id: u32,
    pub result: Value,
}

/// Outgoing JSON-RPC error response.
#[derive(Debug, Clone, Serialize)]
pub struct ErrorResponse {
    pub jsonrpc: &'static str,
    pub id: u32,
    pub error: ErrorInfo,
}

/// Parsed incoming message from a plugin.
#[derive(Debug)]
pub enum IncomingMessage {
    Request {
        id: u32,
        method: String,
        params: Option<Value>,
    },
    Notification {
        method: String,
        params: Option<Value>,
    },
    Response {
        id: u32,
        result: Option<Value>,
        error: Option<ErrorInfo>,
    },
}

/// Serialize a notification to a newline-delimited JSON string.
pub fn encode_notification(method: &str, params: Option<Value>) -> String {
    let msg = Notification {
        jsonrpc: "2.0",
        method: method.to_owned(),
        params,
    };
    let mut s = serde_json::to_string(&msg).expect("notification serialize");
    s.push('\n');
    s
}

/// Serialize a request to a newline-delimited JSON string.
pub fn encode_request(id: u32, method: &str, params: Option<Value>) -> String {
    let msg = Request {
        jsonrpc: "2.0",
        id,
        method: method.to_owned(),
        params,
    };
    let mut s = serde_json::to_string(&msg).expect("request serialize");
    s.push('\n');
    s
}

/// Serialize a success response.
pub fn encode_response(id: u32, result: Value) -> String {
    let msg = SuccessResponse {
        jsonrpc: "2.0",
        id,
        result,
    };
    let mut s = serde_json::to_string(&msg).expect("response serialize");
    s.push('\n');
    s
}

/// Serialize an error response.
pub fn encode_error(id: u32, code: i32, message: &str) -> String {
    let msg = ErrorResponse {
        jsonrpc: "2.0",
        id,
        error: ErrorInfo {
            code,
            message: message.to_owned(),
        },
    };
    let mut s = serde_json::to_string(&msg).expect("error serialize");
    s.push('\n');
    s
}

/// Parse a single line of newline-delimited JSON into an IncomingMessage.
pub fn parse_line(line: &str) -> Result<IncomingMessage, String> {
    let v: Value = serde_json::from_str(line.trim())
        .map_err(|e| format!("JSON parse error: {e}"))?;

    let obj = v.as_object().ok_or("expected JSON object")?;

    // Response: has "id" and ("result" or "error"), no "method"
    if obj.contains_key("id") && !obj.contains_key("method") {
        let id = obj["id"]
            .as_u64()
            .ok_or("id must be integer")? as u32;
        return Ok(IncomingMessage::Response {
            id,
            result: obj.get("result").cloned(),
            error: obj.get("error").and_then(|e| {
                serde_json::from_value(e.clone()).ok()
            }),
        });
    }

    let method = obj
        .get("method")
        .and_then(|m| m.as_str())
        .ok_or("missing method field")?
        .to_owned();
    let params = obj.get("params").cloned();

    // Request: has "id" and "method"
    if let Some(id_val) = obj.get("id") {
        let id = id_val.as_u64().ok_or("id must be integer")? as u32;
        return Ok(IncomingMessage::Request { id, method, params });
    }

    // Notification: has "method" but no "id"
    Ok(IncomingMessage::Notification { method, params })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_notification() {
        let encoded = encode_notification(
            "lifecycle/tick",
            Some(serde_json::json!({"dt": 0.016})),
        );
        assert!(encoded.ends_with('\n'));
        let parsed = parse_line(&encoded).unwrap();
        match parsed {
            IncomingMessage::Notification { method, params } => {
                assert_eq!(method, "lifecycle/tick");
                let dt = params.unwrap()["dt"].as_f64().unwrap();
                assert!((dt - 0.016).abs() < 1e-6);
            }
            _ => panic!("expected notification"),
        }
    }

    #[test]
    fn roundtrip_request() {
        let encoded = encode_request(42, "state/query_instances", None);
        let parsed = parse_line(&encoded).unwrap();
        match parsed {
            IncomingMessage::Request { id, method, params } => {
                assert_eq!(id, 42);
                assert_eq!(method, "state/query_instances");
                assert!(params.is_none());
            }
            _ => panic!("expected request"),
        }
    }

    #[test]
    fn roundtrip_response() {
        let encoded = encode_response(7, serde_json::json!({"ok": true}));
        let parsed = parse_line(&encoded).unwrap();
        match parsed {
            IncomingMessage::Response { id, result, error } => {
                assert_eq!(id, 7);
                assert!(result.unwrap()["ok"].as_bool().unwrap());
                assert!(error.is_none());
            }
            _ => panic!("expected response"),
        }
    }

    #[test]
    fn roundtrip_error_response() {
        let encoded = encode_error(3, METHOD_NOT_FOUND, "no such method");
        let parsed = parse_line(&encoded).unwrap();
        match parsed {
            IncomingMessage::Response { id, error, .. } => {
                assert_eq!(id, 3);
                let e = error.unwrap();
                assert_eq!(e.code, METHOD_NOT_FOUND);
                assert_eq!(e.message, "no such method");
            }
            _ => panic!("expected error response"),
        }
    }

    #[test]
    fn parse_garbage() {
        assert!(parse_line("not json").is_err());
    }

    #[test]
    fn parse_missing_method() {
        assert!(parse_line(r#"{"jsonrpc":"2.0"}"#).is_err());
    }
}
