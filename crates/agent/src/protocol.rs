//! Real MCP (Model Context Protocol) adapter over the app server.
//!
//! Agent CLIs speak MCP: `initialize` handshake, then `tools/list` /
//! `tools/call`. Every app-server JSON-RPC method becomes one MCP tool
//! (`session/open` → `session_open`); `tools/call` unwraps the arguments and
//! delegates to [`McpServer::handle_method`]. Tool failures are reported
//! in-band (`isError: true`) so the model can read and recover from them.

use serde_json::{json, Value};

use crate::server::McpServer;

/// (tool name, server method, description). Input schemas are a generic
/// object — the descriptions carry the parameter shapes, which is what the
/// models actually read.
pub(crate) const TOOLS: &[(&str, &str, &str)] = &[
    ("session_state", "session/state", "Overview of the session: open documents, active tab, tool, view flags."),
    ("session_reset", "session/reset", "Reset to a fresh empty session. Params: none."),
    ("session_open", "session/open", "Open a schematic file. Params: {path}."),
    ("session_open_content", "session/open_content", "Create/open a document from inline text. Params: {name, content}. The name's extension picks the kind: .chn schematic, .chn_tb testbench, .chn_prim primitive. Opens as a new tab; write it to disk with session_save {path}. Use this to create workspace files on the fly."),
    ("netlist_to_schematic", "session/import_netlist", "PREFERRED way to build a circuit: converts SPICE netlist text into a fully placed and routed schematic, opened as a new document. Far more reliable than manual PlaceDevice/AddWire geometry. A lone .subckt imports as a cell (ports become pins; add `*.PININFO in:I out:O` under the header for directions). X instances may reference cells saved in the project dir by file stem (`X1 in out rc_filter`). Params: {content, name?} (name may carry .chn/.chn_tb/.chn_prim). Then session_save {path} to write it."),
    ("session_save", "session/save", "Save the active document. Params: {path?} (defaults to its origin path). To save a different open tab, session_dispatch {\"SwitchTab\": N} first (tabs listed by session_state)."),
    ("session_set_project_dir", "session/set_project_dir", "Set the project directory (also scans <dir>/plugins). Params: {path}."),
    ("session_dispatch", "session/dispatch", "Dispatch any editor Command (externally-tagged JSON). Params: {command}. Examples: {\"command\":\"ZoomIn\"}, {\"command\":{\"PlaceDevice\":{\"symbol_path\":\"res\",\"name\":\"R1\",\"x\":100,\"y\":200}}}, {\"command\":{\"AddWire\":{\"x0\":0,\"y0\":0,\"x1\":100,\"y1\":0}}}. Call query_commands FIRST for the full command list — do not guess names. To create whole circuits prefer netlist_to_schematic over manual placement."),
    ("query_commands", "query/commands", "Complete reference for every session_dispatch command: unit commands, parameterized JSON shapes, symbol names. Read this before dispatching anything unfamiliar."),
    ("query_files", "query/files", "List workspace files (.chn, .chn_tb, .chn_prim, .spice, .cir, .raw) under the project dir. Requires session_set_project_dir."),
    ("query_instances", "query/instances", "List placed instances (name, symbol, position, kind, props)."),
    ("query_nets", "query/nets", "List nets with connectivity."),
    ("query_view", "query/view", "Text summary of the active schematic with DRC warnings."),
    ("query_netlist", "query/netlist", "PySpice netlist of the active schematic."),
    ("query_documentation", "query/documentation", "Schematic documentation, raw + rendered ({{R1}} refs expanded)."),
    ("query_theme", "query/theme", "Dark-mode flag."),
    ("wave_open", "wave/open", "Load a SPICE .raw waveform file. Params: {path}."),
    ("query_signals", "query/signals", "Signals available in loaded waveform files."),
    ("query_traces", "query/traces", "Plotted traces with styles."),
    ("query_cursors", "query/cursors", "Cursor A/B positions and per-trace readouts."),
    ("query_wave_data", "query/wave_data", "Sampled trace data. Params: {trace, max_points?}."),
    ("optimizer_new", "optimizer/new", "Create an optimizer instance. Params: {name?}."),
    ("optimizer_close", "optimizer/close", "Close an optimizer. Params: {id}."),
    ("optimizer_add_param", "optimizer/add_param", "Add a parameter. Params: {id, name, min, max, init} (numbers or SI strings like \"1p\")."),
    ("optimizer_remove_param", "optimizer/remove_param", "Remove a parameter. Params: {id, name}."),
    ("optimizer_add_objective", "optimizer/add_objective", "Add an objective. Params: {id, name, target: \"min\"|\"max\"|number, weight?}."),
    ("optimizer_remove_objective", "optimizer/remove_objective", "Remove an objective. Params: {id, name}."),
    ("optimizer_set_algorithm", "optimizer/set_algorithm", "Set the algorithm. Params: {id, algorithm}."),
    ("optimizer_suggest", "optimizer/suggest", "Pending candidate point (pure read). Params: {id}."),
    ("optimizer_report", "optimizer/report", "Report measured objectives (advances the algorithm). Params: {id, params?, measured}."),
    ("optimizer_reset", "optimizer/reset", "Clear evaluation history. Params: {id}."),
    ("query_optimizers", "query/optimizers", "List optimizer instances."),
    ("query_optimizer_state", "query/optimizer_state", "Full state of one optimizer. Params: {id}."),
    ("plugins_refresh", "plugins/refresh", "Rescan plugin directories."),
    ("plugins_list", "plugins/list", "List plugins with lifecycle state."),
    ("plugins_start", "plugins/start", "Start a plugin. Params: {id}."),
    ("plugins_stop", "plugins/stop", "Stop a plugin. Params: {id}."),
    ("marketplace_fetch", "marketplace/fetch", "Fetch the marketplace index."),
    ("marketplace_search", "marketplace/search", "Search the marketplace. Params: {query}."),
    ("marketplace_list", "marketplace/list", "Installed marketplace plugins with available updates."),
    ("marketplace_install", "marketplace/install", "Install a plugin. Params: {id}."),
    ("marketplace_install_local", "marketplace/install_local", "Install a plugin from a local archive. Params: {path}."),
    ("marketplace_uninstall", "marketplace/uninstall", "Uninstall a plugin. Params: {id}."),
    ("marketplace_update", "marketplace/update", "Update a plugin. Params: {id}."),
];

/// MCP wrapper: owns the app server, speaks the MCP protocol over
/// newline-delimited JSON-RPC lines (same shape [`crate::socket`] carries).
pub struct McpToolServer {
    inner: McpServer,
}

impl McpToolServer {
    pub fn new(inner: McpServer) -> Self {
        Self { inner }
    }

    /// Handle one MCP request line; `None` for notifications.
    pub fn handle_line(&mut self, line: &str) -> Option<String> {
        let req: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(e) => return Some(err_line(Value::Null, -32700, &format!("invalid JSON: {e}"))),
        };
        let id = req.get("id").cloned();
        let method = req.get("method").and_then(Value::as_str).unwrap_or("");
        let params = req.get("params").cloned().unwrap_or(Value::Null);

        // Notifications (no id) get no response, whatever the method.
        let id = id?;

        let result = match method {
            "initialize" => json!({
                // Echo the client's version — we have no version-specific behavior.
                "protocolVersion": params
                    .get("protocolVersion")
                    .and_then(Value::as_str)
                    .unwrap_or("2024-11-05"),
                "capabilities": { "tools": {} },
                "serverInfo": {
                    "name": "schemify",
                    "version": env!("CARGO_PKG_VERSION"),
                },
            }),
            "ping" => json!({}),
            "tools/list" => json!({
                "tools": TOOLS.iter().map(|(name, _, desc)| json!({
                    "name": name,
                    "description": desc,
                    "inputSchema": {
                        "type": "object",
                        "additionalProperties": true,
                    },
                })).collect::<Vec<_>>()
            }),
            "tools/call" => {
                let tool = params.get("name").and_then(Value::as_str).unwrap_or("");
                let args = params.get("arguments").cloned().unwrap_or(json!({}));
                match TOOLS.iter().find(|(name, _, _)| *name == tool) {
                    None => tool_result(format!("unknown tool: {tool}"), true),
                    Some((_, srv_method, _)) => {
                        match self.inner.handle_method(srv_method, &args) {
                            Ok(v) => tool_result(v.to_string(), false),
                            // In-band error: the model reads it and retries.
                            Err(e) => tool_result(e.message, true),
                        }
                    }
                }
            }
            other => {
                return Some(err_line(id, -32601, &format!("unknown method: {other}")));
            }
        };
        Some(json!({"jsonrpc": "2.0", "id": id, "result": result}).to_string())
    }
}

fn tool_result(text: String, is_error: bool) -> Value {
    json!({
        "content": [{ "type": "text", "text": text }],
        "isError": is_error,
    })
}

fn err_line(id: Value, code: i32, message: &str) -> String {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": { "code": code, "message": message },
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use schemify_editor::handler::App;

    fn server() -> McpToolServer {
        McpToolServer::new(McpServer::direct(App::new()))
    }

    fn call(srv: &mut McpToolServer, req: Value) -> Value {
        let resp = srv.handle_line(&req.to_string()).expect("response");
        serde_json::from_str(&resp).unwrap()
    }

    #[test]
    fn handshake_and_tool_flow() {
        let mut srv = server();

        let r = call(&mut srv, json!({"jsonrpc":"2.0","id":1,"method":"initialize",
            "params":{"protocolVersion":"2025-03-26","capabilities":{}}}));
        assert_eq!(r["result"]["protocolVersion"], "2025-03-26");
        assert_eq!(r["result"]["serverInfo"]["name"], "schemify");

        // Notification: no response.
        assert!(srv
            .handle_line(&json!({"jsonrpc":"2.0","method":"notifications/initialized"}).to_string())
            .is_none());

        let r = call(&mut srv, json!({"jsonrpc":"2.0","id":2,"method":"tools/list"}));
        let tools = r["result"]["tools"].as_array().unwrap();
        assert_eq!(tools.len(), TOOLS.len());
        assert!(tools.iter().any(|t| t["name"] == "session_dispatch"));

        // Place a device through tools/call, read it back.
        let r = call(&mut srv, json!({"jsonrpc":"2.0","id":3,"method":"tools/call",
            "params":{"name":"session_dispatch","arguments":{"command":{"PlaceDevice":{
                "symbol_path":"res","name":"R1","x":100,"y":200}}}}}));
        assert_eq!(r["result"]["isError"], false);

        let r = call(&mut srv, json!({"jsonrpc":"2.0","id":4,"method":"tools/call",
            "params":{"name":"query_instances","arguments":{}}}));
        let text = r["result"]["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("R1"), "instances: {text}");

        // netlist_to_schematic: inline SPICE → placed schematic document.
        let r = call(&mut srv, json!({"jsonrpc":"2.0","id":20,"method":"tools/call",
            "params":{"name":"netlist_to_schematic","arguments":{
                "name":"rc_filter",
                "content":"* rc\nV1 in 0 AC 1\nR1 in out 1k\nC1 out 0 100n\n.end"}}}));
        assert_eq!(r["result"]["isError"], false, "{r}");
        let text = r["result"]["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("rc_filter"), "import: {text}");

        // query_commands serves the dispatch reference.
        let r = call(&mut srv, json!({"jsonrpc":"2.0","id":21,"method":"tools/call",
            "params":{"name":"query_commands","arguments":{}}}));
        let text = r["result"]["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("PlaceDevice") && text.contains("AddWire"), "ref: {text}");

        // Stringified command objects (model quirk) unwrap server-side.
        let r = call(&mut srv, json!({"jsonrpc":"2.0","id":30,"method":"tools/call",
            "params":{"name":"session_dispatch","arguments":{
                "command":"{\"PlaceDevice\":{\"symbol_path\":\"res\",\"name\":\"R2\",\"x\":300,\"y\":200}}"}}}));
        assert_eq!(r["result"]["isError"], false);

        // Bad tool + bad command are in-band errors, not protocol errors.
        let r = call(&mut srv, json!({"jsonrpc":"2.0","id":5,"method":"tools/call",
            "params":{"name":"nope","arguments":{}}}));
        assert_eq!(r["result"]["isError"], true);
        let r = call(&mut srv, json!({"jsonrpc":"2.0","id":6,"method":"tools/call",
            "params":{"name":"session_dispatch","arguments":{"command":"Nope"}}}));
        assert_eq!(r["result"]["isError"], true);

        // Unknown protocol method is a JSON-RPC error.
        let r = call(&mut srv, json!({"jsonrpc":"2.0","id":7,"method":"resources/list"}));
        assert_eq!(r["error"]["code"], -32601);
    }
}
