use serde::{Deserialize, Serialize};
use serde_json::Value;

// Standard JSON-RPC 2.0 error codes.
pub const PARSE_ERROR: i32 = -32700;
pub const INVALID_REQUEST: i32 = -32600;
pub const METHOD_NOT_FOUND: i32 = -32601;
pub const INVALID_PARAMS: i32 = -32602;
pub const INTERNAL_ERROR: i32 = -32603;

/// JSON-RPC version string.
const VERSION: &str = "2.0";

/// Outgoing JSON-RPC notification (no id, no response expected).
#[derive(Debug, Clone, Serialize)]
pub struct Notification {
    pub jsonrpc: &'static str,
    pub method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}

impl Notification {
    /// Create a new notification.
    pub fn new(method: impl Into<String>, params: Option<Value>) -> Self {
        Self {
            jsonrpc: VERSION,
            method: method.into(),
            params,
        }
    }

    /// Encode to newline-delimited JSON.
    pub fn encode(&self) -> String {
        let mut s = serde_json::to_string(self).expect("notification serialize");
        s.push('\n');
        s
    }
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

impl Request {
    /// Create a new request.
    pub fn new(id: u32, method: impl Into<String>, params: Option<Value>) -> Self {
        Self {
            jsonrpc: VERSION,
            id,
            method: method.into(),
            params,
        }
    }

    /// Encode to newline-delimited JSON.
    pub fn encode(&self) -> String {
        let mut s = serde_json::to_string(self).expect("request serialize");
        s.push('\n');
        s
    }
}

/// JSON-RPC error info.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorInfo {
    pub code: i32,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl ErrorInfo {
    /// Create a new error without extra data.
    pub fn new(code: i32, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            data: None,
        }
    }

    /// Create a new error with extra data.
    pub fn with_data(code: i32, message: impl Into<String>, data: Value) -> Self {
        Self {
            code,
            message: message.into(),
            data: Some(data),
        }
    }
}

/// Outgoing JSON-RPC success response.
#[derive(Debug, Clone, Serialize)]
pub struct SuccessResponse {
    pub jsonrpc: &'static str,
    pub id: u32,
    pub result: Value,
}

impl SuccessResponse {
    /// Create a new success response.
    pub fn new(id: u32, result: Value) -> Self {
        Self {
            jsonrpc: VERSION,
            id,
            result,
        }
    }

    /// Encode to newline-delimited JSON.
    pub fn encode(&self) -> String {
        let mut s = serde_json::to_string(self).expect("response serialize");
        s.push('\n');
        s
    }
}

/// Outgoing JSON-RPC error response.
#[derive(Debug, Clone, Serialize)]
pub struct ErrorResponse {
    pub jsonrpc: &'static str,
    pub id: u32,
    pub error: ErrorInfo,
}

impl ErrorResponse {
    /// Create a new error response.
    pub fn new(id: u32, code: i32, message: impl Into<String>) -> Self {
        Self {
            jsonrpc: VERSION,
            id,
            error: ErrorInfo::new(code, message),
        }
    }

    /// Encode to newline-delimited JSON.
    pub fn encode(&self) -> String {
        let mut s = serde_json::to_string(self).expect("error serialize");
        s.push('\n');
        s
    }
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
    Notification::new(method, params).encode()
}

/// Serialize a request to a newline-delimited JSON string.
pub fn encode_request(id: u32, method: &str, params: Option<Value>) -> String {
    Request::new(id, method, params).encode()
}

/// Serialize a success response.
pub fn encode_response(id: u32, result: Value) -> String {
    SuccessResponse::new(id, result).encode()
}

/// Serialize an error response.
pub fn encode_error(id: u32, code: i32, message: &str) -> String {
    ErrorResponse::new(id, code, message).encode()
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

    #[test]
    fn notification_constructor() {
        let n = Notification::new("test/method", Some(serde_json::json!({"x": 1})));
        assert_eq!(n.jsonrpc, "2.0");
        assert_eq!(n.method, "test/method");
        assert!(n.params.is_some());
    }

    #[test]
    fn request_constructor() {
        let r = Request::new(5, "test/req", None);
        assert_eq!(r.id, 5);
        assert_eq!(r.method, "test/req");
        assert!(r.params.is_none());
    }

    #[test]
    fn success_response_constructor() {
        let r = SuccessResponse::new(10, serde_json::json!("ok"));
        assert_eq!(r.id, 10);
        assert_eq!(r.result, serde_json::json!("ok"));
    }

    #[test]
    fn error_response_constructor() {
        let r = ErrorResponse::new(11, INTERNAL_ERROR, "boom");
        assert_eq!(r.id, 11);
        assert_eq!(r.error.code, INTERNAL_ERROR);
        assert_eq!(r.error.message, "boom");
    }

    #[test]
    fn error_info_with_data() {
        let e = ErrorInfo::with_data(
            INVALID_PARAMS,
            "bad params",
            serde_json::json!({"field": "name"}),
        );
        assert_eq!(e.code, INVALID_PARAMS);
        assert!(e.data.is_some());
        assert_eq!(e.data.unwrap()["field"], "name");
    }

    #[test]
    fn error_codes() {
        assert_eq!(PARSE_ERROR, -32700);
        assert_eq!(INVALID_REQUEST, -32600);
        assert_eq!(METHOD_NOT_FOUND, -32601);
        assert_eq!(INVALID_PARAMS, -32602);
        assert_eq!(INTERNAL_ERROR, -32603);
    }

    #[test]
    fn request_with_params_roundtrip() {
        let req = Request::new(100, "overlay/update", Some(serde_json::json!({
            "name": "myoverlay",
            "shapes": []
        })));
        let encoded = req.encode();
        let parsed = parse_line(&encoded).unwrap();
        match parsed {
            IncomingMessage::Request { id, method, params } => {
                assert_eq!(id, 100);
                assert_eq!(method, "overlay/update");
                let p = params.unwrap();
                assert_eq!(p["name"], "myoverlay");
            }
            _ => panic!("expected request"),
        }
    }

    #[test]
    fn notification_no_params_roundtrip() {
        let n = Notification::new("lifecycle/shutdown", None);
        let encoded = n.encode();
        let parsed = parse_line(&encoded).unwrap();
        match parsed {
            IncomingMessage::Notification { method, params } => {
                assert_eq!(method, "lifecycle/shutdown");
                assert!(params.is_none());
            }
            _ => panic!("expected notification"),
        }
    }
}
