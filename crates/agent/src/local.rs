//! OpenAI-compatible local backend (ZINC, llama.cpp, Ollama, vLLM).
//!
//! One [`LocalTurn`] = one user prompt: a streaming chat-completions tool
//! loop. Each roundtrip sends the message history plus the Schemify tool
//! specs with `stream: true`; SSE deltas surface as [`Event::TextDelta`] /
//! [`Event::ThinkingDelta`] as they arrive, tool-call fragments accumulate
//! until the stream ends, then each requested call is executed against the
//! live MCP socket and fed back — until the model answers without tool
//! calls. Servers that ignore `tools` (ZINC today) degrade to plain chat;
//! servers that ignore `stream` fall back to one-shot JSON.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};

use crate::protocol::TOOLS;
use crate::{AgentError, ChatMsg, Event};

/// Backstop against a model that never stops calling tools.
const MAX_ROUNDS: usize = 32;

// Full domain context; same document the CLI backends get. Keep answers
// short is implied by its golden rules.

pub struct LocalConfig {
    pub base_url: String,
    pub model: Option<String>,
    pub api_key: Option<String>,
}

/// One tool call assembled from streamed fragments (OpenAI indexes them).
#[derive(Default)]
struct ToolCallAcc {
    id: String,
    name: String,
    args: String,
}

/// In-flight SSE response for one model roundtrip. Lines arrive over a
/// channel from a reader thread, so cancellation never waits on the socket.
struct Streaming {
    rx: Receiver<std::io::Result<String>>,
    content: String,
    tool_calls: Vec<ToolCallAcc>,
    /// Non-SSE lines, in case the server ignored `stream: true`.
    raw: String,
}

impl Streaming {
    fn new(rx: Receiver<std::io::Result<String>>) -> Self {
        Self {
            rx,
            content: String::new(),
            tool_calls: Vec::new(),
            raw: String::new(),
        }
    }
}

pub struct LocalTurn {
    cfg: LocalConfig,
    messages: Vec<Value>,
    socket: PathBuf,
    conn: Option<(BufReader<UnixStream>, UnixStream)>,
    streaming: Option<Streaming>,
    cancel: Arc<AtomicBool>,
    done: bool,
    rounds: usize,
    next_id: i64,
}

impl LocalTurn {
    pub(crate) fn new(
        cfg: LocalConfig,
        prompt: &str,
        history: &[ChatMsg],
        socket: PathBuf,
    ) -> Self {
        let mut messages =
            vec![json!({ "role": "system", "content": crate::SYSTEM_CONTEXT })];
        for m in history {
            let role = if m.user { "user" } else { "assistant" };
            messages.push(json!({ "role": role, "content": m.text }));
        }
        messages.push(json!({ "role": "user", "content": prompt }));
        Self {
            cfg,
            messages,
            socket,
            conn: None,
            streaming: None,
            cancel: Arc::new(AtomicBool::new(false)),
            done: false,
            rounds: 0,
            next_id: 0,
        }
    }

    pub(crate) fn cancel_flag(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.cancel)
    }

    /// Advance the turn a little; pushes any resulting events.
    /// `Ok(false)` = turn over. Called repeatedly by the session iterator,
    /// so streamed deltas reach the GUI as they arrive.
    pub(crate) fn step(&mut self, out: &mut VecDeque<Event>) -> Result<bool, AgentError> {
        if self.done || self.cancel.load(Ordering::Relaxed) {
            return Ok(false);
        }
        if self.streaming.is_none() {
            self.rounds += 1;
            if self.rounds > MAX_ROUNDS {
                self.done = true;
                out.push_back(Event::Result("stopped: tool-call round limit reached".into()));
                return Ok(true);
            }
            self.streaming = Some(self.send_request()?);
            return Ok(true);
        }
        self.read_stream(out)
    }

    /// POST the chat completion with `stream: true`; returns the SSE reader.
    fn send_request(&mut self) -> Result<Streaming, AgentError> {
        let url = format!(
            "{}/chat/completions",
            self.cfg.base_url.trim_end_matches('/')
        );
        let body = json!({
            "model": self.cfg.model.as_deref().unwrap_or("default"),
            "messages": self.messages,
            "tools": tool_specs(),
            "stream": true,
        });
        let mut req = ureq::post(&url);
        if let Some(key) = &self.cfg.api_key {
            req = req.header("Authorization", &format!("Bearer {key}"));
        }
        let resp = req
            .send_json(&body)
            .map_err(|e| AgentError::Local(e.to_string()))?;
        // Reader thread: a stalled server blocks this thread, never the
        // session — cancellation polls the channel, not the socket. The
        // thread exits when the stream ends or the receiver drops.
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(resp.into_body().into_reader());
            loop {
                let mut line = String::new();
                match reader.read_line(&mut line) {
                    Ok(0) => break, // EOF → sender drops → Disconnected
                    Ok(_) => {
                        if tx.send(Ok(line)).is_err() {
                            break; // session cancelled/dropped
                        }
                    }
                    Err(e) => {
                        let _ = tx.send(Err(e));
                        break;
                    }
                }
            }
        });
        Ok(Streaming::new(rx))
    }

    /// Read SSE lines until one event can be pushed or the stream ends.
    fn read_stream(&mut self, out: &mut VecDeque<Event>) -> Result<bool, AgentError> {
        loop {
            if self.cancel.load(Ordering::Relaxed) {
                self.done = true;
                return Ok(false);
            }
            // Re-borrowed each pass so finish_roundtrip can take &mut self.
            let s = self.streaming.as_mut().expect("in streaming phase");
            let line = match s.rx.recv_timeout(Duration::from_millis(100)) {
                Ok(Ok(l)) => l,
                Ok(Err(e)) => return Err(e.into()),
                Err(RecvTimeoutError::Timeout) => continue, // re-check cancel
                Err(RecvTimeoutError::Disconnected) => return self.finish_roundtrip(out),
            };
            let line = line.trim();
            if line == "data: [DONE]" || line == "data:[DONE]" {
                return self.finish_roundtrip(out);
            }
            if line.is_empty() {
                continue; // SSE event separator / keep-alive
            }
            let Some(data) = line.strip_prefix("data:") else {
                // Not SSE — the server ignored `stream: true`; buffer the
                // plain JSON body and decode it at EOF.
                s.raw.push_str(line);
                continue;
            };
            let chunk: Value = match serde_json::from_str(data.trim()) {
                Ok(v) => v,
                Err(_) => continue, // partial/garbled chunk — skip
            };
            let Some(delta) = chunk.pointer("/choices/0/delta") else {
                continue;
            };
            // Reasoning deltas: DeepSeek/Qwen-style servers use
            // reasoning_content, some use reasoning.
            if let Some(r) = delta
                .get("reasoning_content")
                .or_else(|| delta.get("reasoning"))
                .and_then(Value::as_str)
            {
                if !r.is_empty() {
                    out.push_back(Event::ThinkingDelta(r.to_string()));
                    return Ok(true);
                }
            }
            if let Some(c) = delta.get("content").and_then(Value::as_str) {
                if !c.is_empty() {
                    s.content.push_str(c);
                    out.push_back(Event::TextDelta(c.to_string()));
                    return Ok(true);
                }
            }
            if let Some(calls) = delta.get("tool_calls").and_then(Value::as_array) {
                for tc in calls {
                    let idx = tc.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
                    while s.tool_calls.len() <= idx {
                        s.tool_calls.push(ToolCallAcc::default());
                    }
                    let acc = &mut s.tool_calls[idx];
                    if let Some(id) = tc.get("id").and_then(Value::as_str) {
                        acc.id.push_str(id);
                    }
                    if let Some(n) = tc.pointer("/function/name").and_then(Value::as_str) {
                        acc.name.push_str(n);
                    }
                    if let Some(a) = tc.pointer("/function/arguments").and_then(Value::as_str) {
                        acc.args.push_str(a);
                    }
                }
            }
        }
    }

    /// Stream ended: settle the assistant message, run any tool calls.
    fn finish_roundtrip(&mut self, out: &mut VecDeque<Event>) -> Result<bool, AgentError> {
        let mut s = self.streaming.take().expect("in streaming phase");

        // Non-streaming fallback: the whole response arrived as plain JSON.
        if s.content.is_empty() && s.tool_calls.is_empty() && !s.raw.is_empty() {
            let v: Value = serde_json::from_str(&s.raw)
                .map_err(|e| AgentError::Local(format!("malformed response: {e}")))?;
            let msg = v
                .pointer("/choices/0/message")
                .ok_or_else(|| AgentError::Local(format!("malformed response: {v}")))?;
            s.content = msg
                .get("content")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            for tc in msg
                .get("tool_calls")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                s.tool_calls.push(ToolCallAcc {
                    id: tc.get("id").and_then(Value::as_str).unwrap_or_default().into(),
                    name: tc
                        .pointer("/function/name")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .into(),
                    args: tc
                        .pointer("/function/arguments")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .into(),
                });
            }
        }

        if s.tool_calls.is_empty() {
            self.done = true;
            out.push_back(Event::Result(s.content));
            return Ok(true);
        }

        if !s.content.is_empty() {
            out.push_back(Event::Text(s.content.clone()));
        }
        self.messages.push(json!({
            "role": "assistant",
            "content": if s.content.is_empty() { Value::Null } else { s.content.clone().into() },
            "tool_calls": s.tool_calls.iter().map(|tc| json!({
                "id": tc.id, "type": "function",
                "function": { "name": tc.name, "arguments": tc.args },
            })).collect::<Vec<_>>(),
        }));
        for tc in &s.tool_calls {
            if self.cancel.load(Ordering::Relaxed) {
                self.done = true;
                return Ok(true);
            }
            let args: Value = serde_json::from_str(&tc.args).unwrap_or_else(|_| json!({}));
            out.push_back(Event::ToolUse {
                name: tc.name.clone(),
                input: args.clone(),
            });
            let (text, is_error) = self.call_tool(&tc.name, &args)?;
            out.push_back(Event::ToolResult {
                text: text.clone(),
                is_error,
            });
            self.messages
                .push(json!({ "role": "tool", "tool_call_id": tc.id, "content": text }));
        }
        Ok(true)
    }

    /// Execute one MCP `tools/call` over the live socket (one connection,
    /// opened lazily, reused for the whole turn).
    fn call_tool(&mut self, name: &str, args: &Value) -> Result<(String, bool), AgentError> {
        if self.conn.is_none() {
            let s = UnixStream::connect(&self.socket)?;
            self.conn = Some((BufReader::new(s.try_clone()?), s));
        }
        let (reader, writer) = self.conn.as_mut().expect("just set");
        self.next_id += 1;
        writeln!(
            writer,
            "{}",
            json!({ "jsonrpc": "2.0", "id": self.next_id, "method": "tools/call",
                "params": { "name": name, "arguments": args } })
        )?;
        writer.flush()?;
        let mut line = String::new();
        reader.read_line(&mut line)?;
        let v: Value = serde_json::from_str(&line)
            .map_err(|e| AgentError::Local(format!("socket: {e}")))?;
        if let Some(err) = v.get("error") {
            return Ok((err.to_string(), true));
        }
        let text = v
            .pointer("/result/content/0/text")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let is_error = v
            .pointer("/result/isError")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        Ok((text, is_error))
    }
}

/// Schemify's MCP tools in the OpenAI function-calling shape.
fn tool_specs() -> Value {
    Value::Array(
        TOOLS
            .iter()
            .map(|(name, _, desc)| {
                json!({
                    "type": "function",
                    "function": {
                        "name": name,
                        "description": desc,
                        "parameters": { "type": "object", "additionalProperties": true },
                    }
                })
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::McpServer;
    use crate::socket::serve;
    use schemify_editor::handler::App;

    #[test]
    fn tool_specs_cover_all_tools() {
        let specs = tool_specs();
        assert_eq!(specs.as_array().unwrap().len(), TOOLS.len());
        assert!(specs
            .as_array()
            .unwrap()
            .iter()
            .any(|t| t["function"]["name"] == "session_dispatch"));
    }

    fn turn(sock: PathBuf) -> LocalTurn {
        LocalTurn::new(
            LocalConfig {
                base_url: "http://unused".into(),
                model: None,
                api_key: None,
            },
            "hi",
            &[],
            sock,
        )
    }

    fn streaming_over(body: &str) -> Streaming {
        let (tx, rx) = mpsc::channel();
        for line in body.split_inclusive('\n') {
            let _ = tx.send(Ok(line.to_string()));
        }
        // tx drops here: channel disconnect = stream EOF.
        Streaming::new(rx)
    }

    /// Drive step() over a canned SSE body (no HTTP, no tool calls).
    fn drain(t: &mut LocalTurn, body: &str) -> Vec<Event> {
        t.streaming = Some(streaming_over(body));
        let mut out = VecDeque::new();
        while !t.done {
            t.step(&mut out).unwrap();
        }
        out.into()
    }

    #[test]
    fn sse_text_and_reasoning_deltas() {
        let body = "\
data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n\
data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"hmm\"}}]}\n\n\
data: {\"choices\":[{\"delta\":{\"content\":\"he\"}}]}\n\n\
data: {\"choices\":[{\"delta\":{\"content\":\"llo\"}}]}\n\n\
data: [DONE]\n";
        let mut t = turn(PathBuf::from("/nonexistent"));
        let events = drain(&mut t, body);
        assert!(matches!(&events[0], Event::ThinkingDelta(r) if r == "hmm"));
        assert!(matches!(&events[1], Event::TextDelta(d) if d == "he"));
        assert!(matches!(&events[2], Event::TextDelta(d) if d == "llo"));
        assert!(matches!(&events[3], Event::Result(r) if r == "hello"));
    }

    #[test]
    fn sse_tool_call_fragments_assemble_and_execute() {
        // Live socket so the assembled call actually executes.
        let path = std::env::temp_dir()
            .join(format!("schemify-local-sse-{}.sock", std::process::id()));
        let srv = crate::protocol::McpToolServer::new(McpServer::direct(App::new()));
        let p = path.clone();
        std::thread::spawn(move || serve(srv, &p));
        for _ in 0..50 {
            if UnixStream::connect(&path).is_ok() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }

        let body = "\
data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"session_\",\"arguments\":\"\"}}]}}]}\n\n\
data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"state\",\"arguments\":\"{}\"}}]}}]}\n\n\
data: [DONE]\n";
        let mut t = turn(path.clone());
        t.streaming = Some(streaming_over(body));
        let mut out = VecDeque::new();
        // One step: reads to DONE, assembles "session_state", executes it.
        t.step(&mut out).unwrap();
        let events: Vec<Event> = out.into();
        assert!(
            matches!(&events[0], Event::ToolUse { name, .. } if name == "session_state"),
            "events: {events:?}"
        );
        assert!(matches!(&events[1], Event::ToolResult { is_error: false, .. }));
        // Follow-up request would go to HTTP — turn is mid-loop, not done.
        assert!(!t.done);
        assert_eq!(t.messages.last().unwrap()["role"], "tool");

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn cancel_interrupts_a_stalled_stream() {
        // A channel with a live sender that never sends = server stalled
        // mid-chunk. Cancel must still end the turn promptly.
        let (_tx, rx) = mpsc::channel::<std::io::Result<String>>();
        let mut t = turn(PathBuf::from("/nonexistent"));
        t.streaming = Some(Streaming::new(rx));
        t.cancel_flag().store(true, Ordering::Relaxed);
        let mut out = VecDeque::new();
        let start = std::time::Instant::now();
        assert!(!t.step(&mut out).unwrap()); // Ok(false) = turn over
        assert!(start.elapsed() < Duration::from_secs(1));
        assert!(out.is_empty());
    }

    #[test]
    fn non_streaming_fallback() {
        let body = r#"{"choices":[{"message":{"role":"assistant","content":"plain"}}]}"#;
        let mut t = turn(PathBuf::from("/nonexistent"));
        let events = drain(&mut t, body);
        assert!(
            matches!(&events[..], [Event::Result(r)] if r == "plain"),
            "events: {events:?}"
        );
    }

    #[test]
    fn call_tool_round_trip() {
        let path = std::env::temp_dir()
            .join(format!("schemify-local-test-{}.sock", std::process::id()));
        let srv = crate::protocol::McpToolServer::new(McpServer::direct(App::new()));
        let p = path.clone();
        std::thread::spawn(move || serve(srv, &p));
        for _ in 0..50 {
            if UnixStream::connect(&path).is_ok() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }

        let mut turn = turn(path.clone());
        let (text, is_error) = turn.call_tool("session_state", &json!({})).unwrap();
        assert!(!is_error);
        assert!(text.contains("{"), "state json: {text}");

        let (_, is_error) = turn.call_tool("nope", &json!({})).unwrap();
        assert!(is_error);

        let _ = std::fs::remove_file(&path);
    }
}
