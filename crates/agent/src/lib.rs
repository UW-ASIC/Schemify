//! schemify-agent — drive user-local agent CLIs (claude-code, codex) headless,
//! or any OpenAI-compatible local server (ZINC, llama.cpp, Ollama, vLLM),
//! with Schemify's MCP server as their ONLY tool surface.
//!
//! Layout:
//! * `server`   — the JSON-RPC 2.0 app server (old `schemify-mcp` crate)
//! * `protocol` — real MCP protocol adapter (initialize / tools/list / tools/call)
//!   exposing every server method as an MCP tool
//! * `socket`   — unix-socket listener for a live process (GUI) + the stdio↔socket
//!   bridge the spawned CLI uses to reach it
//! * `local`    — OpenAI-compatible chat-completions tool loop for local models
//! * here      — the agent driver: spawn `claude -p` / `codex exec` (or run the
//!   local loop), wire the MCP surface in, lock out built-in tools, stream events
//!
//! Auth is the user's problem by design: their subscription login (stored by
//! the CLI itself) or an API key they hand us, which we only pass through as
//! an env var to the subprocess. We never store or proxy credentials.

pub mod local;
pub mod protocol;
pub mod server;
pub mod socket;
pub mod zinc;

pub use server::{command_from_json, run_stdio, McpServer, Sink};

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Lines};
use std::path::PathBuf;
use std::process::{Child, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    ClaudeCode,
    Codex,
    /// Any OpenAI-compatible `/v1` server (ZINC, llama.cpp, Ollama, vLLM).
    Local,
}

impl Backend {
    pub fn binary(self) -> &'static str {
        match self {
            Backend::ClaudeCode => "claude",
            Backend::Codex => "codex",
            Backend::Local => "",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Backend::ClaudeCode => "Claude Code",
            Backend::Codex => "Codex",
            Backend::Local => "Local model",
        }
    }

    fn api_key_env(self) -> &'static str {
        match self {
            Backend::ClaudeCode => "ANTHROPIC_API_KEY",
            Backend::Codex | Backend::Local => "OPENAI_API_KEY",
        }
    }

    /// File the CLI writes after a successful subscription login.
    fn login_file(self) -> Option<PathBuf> {
        // ponytail: $HOME only — Linux/macOS paths; Windows when someone asks.
        let home = std::env::var_os("HOME")?;
        let p = PathBuf::from(home);
        Some(match self {
            Backend::ClaudeCode => p.join(".claude/.credentials.json"),
            Backend::Codex => p.join(".codex/auth.json"),
            Backend::Local => return None,
        })
    }

    pub fn login_hint(self) -> &'static str {
        match self {
            Backend::ClaudeCode => "run `claude` and log in, or provide ANTHROPIC_API_KEY",
            Backend::Codex => "run `codex login`, or provide OPENAI_API_KEY",
            Backend::Local => "set the server URL (e.g. http://localhost:8080/v1)",
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum AgentError {
    #[error("{0} not found on PATH")]
    NotInstalled(&'static str),
    #[error("not logged in: {0}")]
    NotLoggedIn(&'static str),
    #[error("local backend: {0}")]
    Local(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

/// How the spawned CLI reaches the live Schemify MCP server: it spawns
/// `<bridge_exe> mcp-bridge <socket>` as a stdio MCP server, which proxies
/// to the unix socket served by [`socket::serve`] in the GUI process.
/// The local backend connects to the same socket directly.
#[derive(Debug, Clone)]
pub struct McpConfig {
    pub socket: PathBuf,
    /// Binary providing the `mcp-bridge` subcommand (the schemify binary itself).
    pub bridge_exe: PathBuf,
}

impl McpConfig {
    /// Bridge via the current executable (GUI/CLI process = schemify binary).
    pub fn via_current_exe(socket: PathBuf) -> std::io::Result<Self> {
        Ok(Self {
            socket,
            bridge_exe: std::env::current_exe()?,
        })
    }
}

/// Domain context injected into every backend as system prompt: what
/// Schemify is, the netlist-first workflow, geometry rules, limitations.
/// Kept in the skill dir so the doc and the runtime stay one source.
pub const SYSTEM_CONTEXT: &str = include_str!("../skill/CONTEXT.md");

/// One prior chat turn, for backends without server-side session state
/// (the local backend rebuilds its message list from these).
#[derive(Debug, Clone)]
pub struct ChatMsg {
    pub user: bool,
    pub text: String,
}

/// Normalized event from any backend's stream.
#[derive(Debug)]
pub enum Event {
    /// Final full assistant text block (replaces any streamed deltas).
    Text(String),
    /// Streamed assistant text fragment.
    TextDelta(String),
    /// Final full thinking/reasoning block.
    Thinking(String),
    /// Streamed thinking fragment.
    ThinkingDelta(String),
    /// Tool invocation.
    ToolUse { name: String, input: Value },
    /// Tool outcome.
    ToolResult { text: String, is_error: bool },
    /// Final result text; stream ends after this.
    Result(String),
    /// Backend session id — pass back as `resume` to continue the conversation.
    SessionId(String),
    /// Anything we don't model — passed through verbatim.
    Raw(Value),
}

pub struct Agent {
    backend: Backend,
    api_key: Option<String>,
    model: Option<String>,
    base_url: Option<String>,
}

impl Agent {
    pub fn new(backend: Backend) -> Self {
        Agent { backend, api_key: None, model: None, base_url: None }
    }

    /// Use an explicit API key instead of the CLI's subscription login.
    pub fn with_api_key(mut self, key: impl Into<String>) -> Self {
        self.api_key = Some(key.into());
        self
    }

    /// Override the CLI's default model (claude: "sonnet"/"opus"/"haiku" or
    /// a full model id; codex: a model id for `-m`; local: the server model id).
    pub fn with_model(mut self, model: impl Into<String>) -> Self {
        self.model = Some(model.into());
        self
    }

    /// OpenAI-compatible base URL for [`Backend::Local`], e.g.
    /// `http://localhost:8080/v1`.
    pub fn with_base_url(mut self, url: impl Into<String>) -> Self {
        self.base_url = Some(url.into());
        self
    }

    /// Installed + authenticated? Call before `run` to give the user an
    /// actionable error instead of a subprocess failure.
    pub fn check(&self) -> Result<(), AgentError> {
        if self.backend == Backend::Local {
            return match self.base_url.as_deref() {
                Some(u) if u.starts_with("http") => Ok(()),
                _ => Err(AgentError::Local(self.backend.login_hint().into())),
            };
        }
        let bin = self.backend.binary();
        if !on_path(bin) {
            return Err(AgentError::NotInstalled(bin));
        }
        let has_key = self.api_key.is_some()
            || std::env::var_os(self.backend.api_key_env()).is_some();
        let logged_in = self
            .backend
            .login_file()
            .is_some_and(|f| f.exists());
        if !has_key && !logged_in {
            return Err(AgentError::NotLoggedIn(self.backend.login_hint()));
        }
        Ok(())
    }

    /// Spawn one agent turn wired to the Schemify MCP server, with the CLI's
    /// built-in tools locked out — the app is the only tool surface.
    /// Iterate the returned session for events.
    ///
    /// `resume` continues a previous CLI conversation (the session id from an
    /// earlier [`Event::SessionId`]); `history` gives the local backend its
    /// prior turns (CLIs keep their own history server-side and ignore it).
    pub fn run(
        &self,
        prompt: &str,
        mcp: &McpConfig,
        resume: Option<&str>,
        history: &[ChatMsg],
    ) -> Result<Session, AgentError> {
        self.check()?;
        if self.backend == Backend::Local {
            let turn = local::LocalTurn::new(
                local::LocalConfig {
                    base_url: self.base_url.clone().expect("checked"),
                    model: self.model.clone(),
                    api_key: self.api_key.clone(),
                },
                prompt,
                history,
                mcp.socket.clone(),
            );
            return Ok(Session {
                backend: self.backend,
                pending: VecDeque::new(),
                src: Source::Local(turn),
            });
        }
        let bridge = mcp.bridge_exe.to_string_lossy();
        let sock = mcp.socket.to_string_lossy();
        let mut cmd = match self.backend {
            Backend::ClaudeCode => {
                let mcp_json = serde_json::json!({
                    "mcpServers": {
                        "schemify": { "command": bridge, "args": ["mcp-bridge", sock] }
                    }
                })
                .to_string();
                let mut c = Command::new("claude");
                // --verbose is required by claude for stream-json in print mode;
                // --include-partial-messages streams text/thinking deltas.
                // --setting-sources "" keeps the user's global config out of
                // the session (plugins, hooks, skills — they'd leak their
                // whole prompt into the transcript and burn turns).
                // --strict-mcp-config ignores the user's own MCP servers;
                // allow only ours, deny the built-in file/shell/web tools.
                c.args(["-p", prompt, "--output-format", "stream-json", "--verbose"])
                    .arg("--include-partial-messages")
                    .args(["--setting-sources", ""])
                    .args(["--mcp-config", &mcp_json, "--strict-mcp-config"])
                    .args(["--allowedTools", "mcp__schemify"])
                    .args([
                        "--disallowedTools",
                        "Bash,Edit,Write,Read,Glob,Grep,NotebookEdit,WebFetch,WebSearch,Task,TodoWrite,\
                         Skill,SlashCommand,ToolSearch,EnterPlanMode,ExitPlanMode,KillShell,BashOutput,\
                         AskUserQuestion",
                    ]);
                c.args(["--append-system-prompt", SYSTEM_CONTEXT]);
                if let Some(id) = resume {
                    c.args(["--resume", id]);
                }
                c
            }
            Backend::Codex => {
                let mut c = Command::new("codex");
                c.arg("exec");
                if let Some(id) = resume {
                    c.args(["resume", id]);
                }
                // codex exec has no system-prompt flag: carry the context in
                // the first prompt (resumed sessions already saw it).
                let first_prompt;
                let p = if resume.is_some() {
                    prompt
                } else {
                    first_prompt =
                        format!("<context>\n{SYSTEM_CONTEXT}\n</context>\n\n{prompt}");
                    &first_prompt
                };
                // read-only sandbox: MCP calls still work, file writes don't.
                c.args(["--json", "--sandbox", "read-only"])
                    .args(["-c", &format!(r#"mcp_servers.schemify.command="{bridge}""#)])
                    .args(["-c", &format!(r#"mcp_servers.schemify.args=["mcp-bridge","{sock}"]"#)])
                    .arg(p);
                c
            }
            Backend::Local => unreachable!("handled above"),
        };
        if let Some(model) = &self.model {
            match self.backend {
                Backend::ClaudeCode => cmd.args(["--model", model]),
                _ => cmd.args(["-m", model]),
            };
        }
        if let Some(key) = &self.api_key {
            cmd.env(self.backend.api_key_env(), key);
        }
        let mut child = cmd
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()?;
        let stdout = child.stdout.take().expect("stdout piped");
        Ok(Session {
            backend: self.backend,
            pending: VecDeque::new(),
            src: Source::Cli {
                child: Arc::new(Mutex::new(child)),
                lines: BufReader::new(stdout).lines(),
            },
        })
    }
}

/// Cloneable kill switch for a running [`Session`] (Stop button, timeouts).
#[derive(Clone)]
pub struct SessionHandle(HandleInner);

#[derive(Clone)]
enum HandleInner {
    Child(Arc<Mutex<Child>>),
    Cancel(Arc<AtomicBool>),
}

impl SessionHandle {
    /// Kill the agent subprocess (or cancel the local loop); the session
    /// iterator then ends.
    pub fn stop(&self) {
        match &self.0 {
            HandleInner::Child(child) => {
                if let Ok(mut c) = child.lock() {
                    let _ = c.kill();
                }
            }
            HandleInner::Cancel(flag) => flag.store(true, Ordering::Relaxed),
        }
    }
}

/// A running agent turn. Iterates normalized events; stops the backend on drop.
pub struct Session {
    backend: Backend,
    /// One stream line can decode to several events (multi-block messages).
    pending: VecDeque<Event>,
    src: Source,
}

enum Source {
    Cli {
        child: Arc<Mutex<Child>>,
        lines: Lines<BufReader<ChildStdout>>,
    },
    Local(local::LocalTurn),
}

impl Session {
    pub fn handle(&self) -> SessionHandle {
        match &self.src {
            Source::Cli { child, .. } => SessionHandle(HandleInner::Child(Arc::clone(child))),
            Source::Local(turn) => SessionHandle(HandleInner::Cancel(turn.cancel_flag())),
        }
    }
}

impl Iterator for Session {
    type Item = Result<Event, AgentError>;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            if let Some(ev) = self.pending.pop_front() {
                return Some(Ok(ev));
            }
            match &mut self.src {
                Source::Cli { lines, .. } => {
                    let line = loop {
                        match lines.next()? {
                            Ok(l) if l.trim().is_empty() => continue,
                            Ok(l) => break l,
                            Err(e) => return Some(Err(e.into())),
                        }
                    };
                    // Non-JSON lines (banners, warnings) pass through as raw strings.
                    match serde_json::from_str::<Value>(&line) {
                        Ok(v) => parse_event(self.backend, v, &mut self.pending),
                        Err(_) => self.pending.push_back(Event::Raw(Value::String(line))),
                    }
                    // A line may produce no events (stream noise) — loop.
                }
                Source::Local(turn) => match turn.step(&mut self.pending) {
                    Ok(true) => {}
                    Ok(false) => return None,
                    Err(e) => return Some(Err(e)),
                },
            }
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        match &self.src {
            Source::Cli { child, .. } => {
                if let Ok(mut c) = child.lock() {
                    let _ = c.kill();
                    let _ = c.wait();
                }
            }
            Source::Local(turn) => turn.cancel_flag().store(true, Ordering::Relaxed),
        }
    }
}

fn parse_event(backend: Backend, v: Value, out: &mut VecDeque<Event>) {
    match backend {
        Backend::ClaudeCode => parse_claude(v, out),
        Backend::Codex => parse_codex(v, out),
        Backend::Local => out.push_back(Event::Raw(v)), // local never goes through here
    }
}

fn parse_claude(v: Value, out: &mut VecDeque<Event>) {
    match v.get("type").and_then(Value::as_str) {
        Some("system") => match v.get("session_id").and_then(Value::as_str) {
            Some(id) => out.push_back(Event::SessionId(id.to_string())),
            None => out.push_back(Event::Raw(v)),
        },
        Some("stream_event") => {
            // SSE passthrough from --include-partial-messages; only deltas
            // matter, block starts/stops and tool input deltas are noise.
            match v.pointer("/event/delta/type").and_then(Value::as_str) {
                Some("text_delta") => {
                    if let Some(t) = v.pointer("/event/delta/text").and_then(Value::as_str) {
                        out.push_back(Event::TextDelta(t.to_string()));
                    }
                }
                Some("thinking_delta") => {
                    if let Some(t) = v.pointer("/event/delta/thinking").and_then(Value::as_str) {
                        out.push_back(Event::ThinkingDelta(t.to_string()));
                    }
                }
                _ => {}
            }
        }
        Some("result") => {
            let text = v.get("result").and_then(Value::as_str).unwrap_or_default();
            out.push_back(Event::Result(text.to_string()));
        }
        Some(role @ ("assistant" | "user")) => {
            let blocks = v
                .pointer("/message/content")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let before = out.len();
            for b in &blocks {
                match b.get("type").and_then(Value::as_str) {
                    // text/thinking only from the assistant: user-role text
                    // blocks are injected context (hook output, resumed
                    // history), not chat.
                    Some("text") if role == "assistant" => {
                        if let Some(t) = b.get("text").and_then(Value::as_str) {
                            out.push_back(Event::Text(t.to_string()));
                        }
                    }
                    Some("thinking") if role == "assistant" => {
                        if let Some(t) = b.get("thinking").and_then(Value::as_str) {
                            out.push_back(Event::Thinking(t.to_string()));
                        }
                    }
                    Some("tool_use") => out.push_back(Event::ToolUse {
                        name: b
                            .get("name")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        input: b.get("input").cloned().unwrap_or(Value::Null),
                    }),
                    Some("tool_result") => {
                        // Content is either a string or [{type:"text",text}].
                        let text = match b.get("content") {
                            Some(Value::String(s)) => s.clone(),
                            Some(Value::Array(parts)) => parts
                                .iter()
                                .filter_map(|p| p.get("text").and_then(Value::as_str))
                                .collect::<Vec<_>>()
                                .join("\n"),
                            _ => String::new(),
                        };
                        out.push_back(Event::ToolResult {
                            text,
                            is_error: b
                                .get("is_error")
                                .and_then(Value::as_bool)
                                .unwrap_or(false),
                        });
                    }
                    _ => {}
                }
            }
            if out.len() == before {
                out.push_back(Event::Raw(v));
            }
        }
        _ => out.push_back(Event::Raw(v)),
    }
}

fn parse_codex(v: Value, out: &mut VecDeque<Event>) {
    let msg_str = |ptr: &str| {
        v.pointer(ptr)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string()
    };
    match v.pointer("/msg/type").and_then(Value::as_str) {
        Some("session_configured") => {
            match v.pointer("/msg/session_id").and_then(Value::as_str) {
                Some(id) => out.push_back(Event::SessionId(id.to_string())),
                None => out.push_back(Event::Raw(v)),
            }
        }
        Some("agent_message_delta") => out.push_back(Event::TextDelta(msg_str("/msg/delta"))),
        Some("agent_message") => out.push_back(Event::Text(msg_str("/msg/message"))),
        Some("agent_reasoning_delta") => {
            out.push_back(Event::ThinkingDelta(msg_str("/msg/delta")))
        }
        Some("agent_reasoning") => out.push_back(Event::Thinking(msg_str("/msg/text"))),
        Some("agent_reasoning_section_break") => {}
        Some("mcp_tool_call_begin") => out.push_back(Event::ToolUse {
            name: msg_str("/msg/invocation/tool"),
            input: v
                .pointer("/msg/invocation/arguments")
                .cloned()
                .unwrap_or(Value::Null),
        }),
        Some("mcp_tool_call_end") => {
            // result: {"Ok":{"content":[{text}],"isError":bool}} | {"Err":...}
            let res = v.pointer("/msg/result");
            let (text, is_error) = match res {
                Some(r) => {
                    if let Some(ok) = r.get("Ok") {
                        let text = ok
                            .get("content")
                            .and_then(Value::as_array)
                            .map(|parts| {
                                parts
                                    .iter()
                                    .filter_map(|p| p.get("text").and_then(Value::as_str))
                                    .collect::<Vec<_>>()
                                    .join("\n")
                            })
                            .unwrap_or_default();
                        let err = ok.get("isError").and_then(Value::as_bool).unwrap_or(false);
                        (text, err)
                    } else if let Some(e) = r.get("Err") {
                        (e.to_string(), true)
                    } else {
                        (r.to_string(), false)
                    }
                }
                None => (String::new(), false),
            };
            out.push_back(Event::ToolResult { text, is_error });
        }
        Some("task_complete") => {
            out.push_back(Event::Result(msg_str("/msg/last_agent_message")))
        }
        _ => out.push_back(Event::Raw(v)),
    }
}

pub fn available_backends() -> Vec<Backend> {
    // Local is always offered — whether a server is running is checked at send.
    let mut v: Vec<Backend> = [Backend::ClaudeCode, Backend::Codex]
        .into_iter()
        .filter(|b| Agent::new(*b).check().is_ok())
        .collect();
    v.push(Backend::Local);
    v
}

fn on_path(bin: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|d| d.join(bin).is_file()))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn claude(v: Value) -> Vec<Event> {
        let mut out = VecDeque::new();
        parse_claude(v, &mut out);
        out.into()
    }

    fn codex(v: Value) -> Vec<Event> {
        let mut out = VecDeque::new();
        parse_codex(v, &mut out);
        out.into()
    }

    #[test]
    fn claude_events() {
        let text = serde_json::json!({
            "type": "assistant",
            "message": { "content": [{ "type": "text", "text": "hi" }] }
        });
        assert!(matches!(&claude(text)[..], [Event::Text(t)] if t == "hi"));

        // Multi-block message: thinking + text arrive as two events.
        let multi = serde_json::json!({
            "type": "assistant",
            "message": { "content": [
                { "type": "thinking", "thinking": "hmm" },
                { "type": "text", "text": "hi" }
            ] }
        });
        assert!(matches!(
            &claude(multi)[..],
            [Event::Thinking(th), Event::Text(t)] if th == "hmm" && t == "hi"
        ));

        let tool = serde_json::json!({
            "type": "assistant",
            "message": { "content": [{ "type": "tool_use", "name": "mcp__schemify__session_state", "input": {} }] }
        });
        assert!(
            matches!(&claude(tool)[..], [Event::ToolUse { name, .. }] if name == "mcp__schemify__session_state")
        );

        let tool_result = serde_json::json!({
            "type": "user",
            "message": { "content": [{ "type": "tool_result", "is_error": true,
                "content": [{ "type": "text", "text": "{\"ok\":false}" }] }] }
        });
        assert!(matches!(
            &claude(tool_result)[..],
            [Event::ToolResult { text, is_error: true }] if text == "{\"ok\":false}"
        ));

        let delta = serde_json::json!({ "type": "stream_event",
            "event": { "type": "content_block_delta", "delta": { "type": "text_delta", "text": "h" } } });
        assert!(matches!(&claude(delta)[..], [Event::TextDelta(t)] if t == "h"));

        let think_delta = serde_json::json!({ "type": "stream_event",
            "event": { "type": "content_block_delta", "delta": { "type": "thinking_delta", "thinking": "m" } } });
        assert!(matches!(&claude(think_delta)[..], [Event::ThinkingDelta(t)] if t == "m"));

        // Block start/stop stream noise produces nothing.
        let noise = serde_json::json!({ "type": "stream_event",
            "event": { "type": "content_block_stop", "index": 0 } });
        assert!(claude(noise).is_empty());

        let result = serde_json::json!({ "type": "result", "subtype": "success", "result": "done" });
        assert!(matches!(&claude(result)[..], [Event::Result(r)] if r == "done"));

        let init = serde_json::json!({ "type": "system", "subtype": "init", "session_id": "abc" });
        assert!(matches!(&claude(init)[..], [Event::SessionId(id)] if id == "abc"));
    }

    #[test]
    fn codex_events() {
        let text = serde_json::json!({ "id": "1", "msg": { "type": "agent_message", "message": "hi" } });
        assert!(matches!(&codex(text)[..], [Event::Text(t)] if t == "hi"));

        let delta = serde_json::json!({ "id": "1", "msg": { "type": "agent_message_delta", "delta": "h" } });
        assert!(matches!(&codex(delta)[..], [Event::TextDelta(t)] if t == "h"));

        let reasoning = serde_json::json!({ "id": "1", "msg": { "type": "agent_reasoning", "text": "hmm" } });
        assert!(matches!(&codex(reasoning)[..], [Event::Thinking(t)] if t == "hmm"));

        let sid = serde_json::json!({ "id": "0", "msg": { "type": "session_configured", "session_id": "s-1" } });
        assert!(matches!(&codex(sid)[..], [Event::SessionId(id)] if id == "s-1"));

        let tool = serde_json::json!({ "id": "2", "msg": { "type": "mcp_tool_call_begin",
            "invocation": { "server": "schemify", "tool": "query_nets", "arguments": {} } } });
        assert!(matches!(&codex(tool)[..], [Event::ToolUse { name, .. }] if name == "query_nets"));

        let end = serde_json::json!({ "id": "2", "msg": { "type": "mcp_tool_call_end",
            "invocation": { "server": "schemify", "tool": "query_nets" },
            "result": { "Ok": { "content": [{ "type": "text", "text": "nets" }], "isError": false } } } });
        assert!(matches!(
            &codex(end)[..],
            [Event::ToolResult { text, is_error: false }] if text == "nets"
        ));

        let done = serde_json::json!({ "id": "3", "msg": { "type": "task_complete", "last_agent_message": "done" } });
        assert!(matches!(&codex(done)[..], [Event::Result(r)] if r == "done"));

        let other = serde_json::json!({ "id": "4", "msg": { "type": "token_count" } });
        assert!(matches!(&codex(other)[..], [Event::Raw(_)]));
    }
}
