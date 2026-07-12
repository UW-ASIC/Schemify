//! AI assistant panel — a cursor-style chat sidebar driving an agent backend
//! (claude-code / codex CLIs, or any OpenAI-compatible local server like
//! ZINC) whose ONLY tool surface is this process's MCP socket
//! ([`schemify_agent::socket::serve`], started in `SchemifyGui::new`).
//!
//! Cursor-style transcript: streamed text, collapsible thinking, tool-call
//! cards with live status + results, and a per-turn summary of what changed.
//! Conversations are multi-turn: CLI backends resume via their session id,
//! the local backend replays [`ChatMsg`] history.
//!
//! The session runs on a worker thread (blocking event iterator); events
//! arrive over an mpsc channel and are drained into the transcript each
//! frame. Presentation state lives in [`AgentPanelState`] (GuiState); the
//! channel + kill handle live in [`AgentRuntime`] on `SchemifyGui` (not Clone).
//!
//! Keys: Enter = send · Ctrl+Enter = newline · Ctrl+C = interrupt.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use eframe::egui;
use serde_json::{json, Value};

use schemify_agent::zinc::{self, Zinc, ZincStatus};
use schemify_agent::{Agent, Backend, ChatMsg, Event, McpConfig, SessionHandle};
use schemify_editor::handler::{App, Origin};

use crate::components::doc_view::render_simple_markdown;
use crate::state::GuiState;

/// Worker → GUI channel: normalized events, or a fatal error string.
pub type EventRx = Receiver<Result<Event, String>>;

/// Port our managed ZINC instance serves on.
const ZINC_PORT: u16 = 8080;

/// Live-session runtime (not Clone, so not in GuiState).
#[derive(Default)]
pub struct AgentRuntime {
    rx: Option<EventRx>,
    handle: Option<SessionHandle>,
    /// Managed ZINC server, if we launched one (killed on drop / app exit).
    zinc: Option<Zinc>,
}

#[derive(Debug, Clone)]
pub enum Entry {
    User(String),
    /// Reasoning stream; collapses once `done`.
    Thinking { text: String, done: bool },
    /// Assistant text; `done` = false while deltas are still streaming in.
    Text { text: String, done: bool },
    /// Tool call card; `result` arrives later, `is_error` colors it.
    Tool {
        name: String,
        input: String,
        result: Option<String>,
        is_error: bool,
    },
    /// Final answer of a turn (gets the turn summary underneath).
    Done(String),
    Error(String),
}

#[derive(Debug, Clone)]
pub struct AgentPanelState {
    pub open: bool,
    pub backend: Backend,
    /// Optional explicit API key; empty = the CLI's subscription login.
    pub api_key: String,
    /// Optional model override; empty = the backend's default.
    pub model: String,
    /// OpenAI-compatible base URL for the Local backend.
    pub base_url: String,
    pub prompt: String,
    pub transcript: Vec<Entry>,
    pub running: bool,
    /// CLI session id from the last turn — resumed on the next send.
    pub session_id: Option<String>,
    /// Prior turns for the local backend (CLIs keep history server-side).
    pub history: Vec<ChatMsg>,
    /// Catalog model id for the managed ZINC launcher.
    pub zinc_model: String,
    /// `zinc model list` cache; None = not fetched yet.
    pub zinc_models: Option<Vec<String>>,
    /// Workspace snapshot per turn — revert to any point of the chat.
    pub checkpoints: Vec<Checkpoint>,
    /// Prompts typed while a session ran; auto-sent when the turn ends.
    pub queued: Vec<String>,
    /// Disk file of the current chat (auto-saved after each turn).
    pub chat_file: Option<PathBuf>,
    /// Up/Down prompt recall position (index into past user prompts).
    pub recall: Option<usize>,
}

/// Compressed workspace state taken just before one user turn ran.
#[derive(Debug, Clone)]
pub struct Checkpoint {
    /// Transcript index of the User entry this snapshot precedes.
    pub entry: usize,
    /// history length at snapshot time (for truncation on revert).
    pub history_len: usize,
    /// zlib-compressed JSON: {active, docs: [{name, origin, dirty, chn}]}.
    bytes: Vec<u8>,
}

impl Default for AgentPanelState {
    fn default() -> Self {
        Self {
            open: false,
            backend: Backend::ClaudeCode,
            api_key: String::new(),
            model: String::new(),
            base_url: "http://localhost:8080/v1".into(),
            prompt: String::new(),
            transcript: Vec::new(),
            running: false,
            session_id: None,
            history: Vec::new(),
            zinc_model: "qwen35-9b-q4k-m".into(),
            zinc_models: None,
            checkpoints: Vec::new(),
            queued: Vec::new(),
            chat_file: None,
            recall: None,
        }
    }
}

/// Show the assistant side panel; call before the CentralPanel claims space.
pub fn panel(
    ui: &mut egui::Ui,
    app: &mut App,
    gui: &mut GuiState,
    rt: &mut AgentRuntime,
    socket: &Path,
) {
    drain_events(gui, rt);
    // A turn just finished and prompts are queued: send the next one.
    if !gui.agent.running && rt.rx.is_none() && !gui.agent.queued.is_empty() {
        let prompt = gui.agent.queued.remove(0);
        send(app, &mut gui.agent, rt, socket, prompt);
    }
    if gui.agent.running {
        // Events arrive without input; keep polling while a session runs.
        ui.ctx().request_repaint_after(Duration::from_millis(100));
        // Ctrl+C interrupts the running session (consumed here so the
        // transcript's copy shortcut yields while an agent runs).
        if ui
            .ctx()
            .input_mut(|i| i.consume_key(egui::Modifiers::COMMAND, egui::Key::C))
        {
            stop(gui, rt);
        }
    }
    if let Some(z) = &rt.zinc {
        // Pull/startup progresses without input; keep polling.
        if matches!(z.status(), ZincStatus::Pulling | ZincStatus::Starting) {
            ui.ctx().request_repaint_after(Duration::from_millis(500));
        }
    }
    if !gui.agent.open {
        return;
    }

    egui::Panel::right("agent_panel")
        .resizable(true)
        .default_size(340.0)
        .show(ui, |ui| {
            header(ui, gui, rt);
            ui.separator();

            // Input pinned to the bottom; transcript fills the rest.
            egui::Panel::bottom("agent_input")
                .show(ui, |ui| input_area(ui, app, gui, rt, socket));
            egui::CentralPanel::default().show(ui, |ui| transcript(ui, app, gui));
        });
}

fn header(ui: &mut egui::Ui, gui: &mut GuiState, rt: &mut AgentRuntime) {
    ui.horizontal(|ui| {
        ui.heading("Assistant");
        if gui.agent.running {
            ui.spinner();
        }
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if ui
                .small_button("New chat")
                .on_hover_text("Save this chat and start a fresh conversation")
                .clicked()
            {
                save_chat(&mut gui.agent);
                gui.agent.transcript.clear();
                gui.agent.session_id = None;
                gui.agent.history.clear();
                gui.agent.checkpoints.clear();
                gui.agent.queued.clear();
                gui.agent.chat_file = None;
                gui.agent.recall = None;
            }
            ui.add_enabled_ui(!gui.agent.running, |ui| {
                ui.menu_button("History", |ui| {
                    let chats = list_chats();
                    if chats.is_empty() {
                        ui.weak("No saved chats yet");
                    }
                    for (path, label) in chats {
                        if Some(&path) == gui.agent.chat_file.as_ref() {
                            ui.weak(format!("\u{25B8} {label}"));
                            continue;
                        }
                        if ui.button(label).clicked() {
                            save_chat(&mut gui.agent);
                            load_chat(&mut gui.agent, &path);
                            ui.close();
                        }
                    }
                });
            });
        });
    });
    ui.horizontal(|ui| {
        let state = &mut gui.agent;
        let before = state.backend;
        egui::ComboBox::from_id_salt("agent_backend")
            .selected_text(state.backend.label())
            .show_ui(ui, |ui| {
                for b in [Backend::ClaudeCode, Backend::Codex, Backend::Local] {
                    ui.selectable_value(&mut state.backend, b, b.label());
                }
            });
        if state.backend != before {
            // A CLI session id is meaningless on another backend.
            state.session_id = None;
        }
        let model_hint = match state.backend {
            Backend::ClaudeCode => "model: sonnet | opus | haiku",
            Backend::Codex => "model id (blank = default)",
            Backend::Local => "model id (blank = server default)",
        };
        ui.add(
            egui::TextEdit::singleline(&mut state.model)
                .desired_width(150.0)
                .hint_text(model_hint),
        );
        ui.menu_button("\u{1F511}", |ui| {
            ui.label("API key (blank = subscription login)");
            ui.add(
                egui::TextEdit::singleline(&mut state.api_key)
                    .password(true)
                    .hint_text("sk-..."),
            );
        })
        .response
        .on_hover_text("API key override");
    });
    if gui.agent.backend == Backend::Local {
        ui.horizontal(|ui| {
            ui.label("URL");
            ui.add(
                egui::TextEdit::singleline(&mut gui.agent.base_url)
                    .desired_width(f32::INFINITY)
                    .hint_text("http://localhost:8080/v1"),
            )
            .on_hover_text("OpenAI-compatible endpoint (ZINC, llama.cpp, Ollama, vLLM)");
        });
        if zinc::installed() {
            zinc_row(ui, gui, rt);
        }
    }
}

/// Managed ZINC launcher: pick a catalog model, we pull + serve + watch it.
fn zinc_row(ui: &mut egui::Ui, gui: &mut GuiState, rt: &mut AgentRuntime) {
    let (accent, error) = (gui.theme.accent, gui.theme.error);
    let state = &mut gui.agent;
    let status = rt.zinc.as_ref().map(Zinc::status);
    ui.horizontal(|ui| {
        ui.label("ZINC");
        // ponytail: `zinc model list` runs once on the GUI thread (~fast);
        // move it off-thread if a slow disk ever makes it noticeable.
        let models = state.zinc_models.get_or_insert_with(zinc::models);
        if models.is_empty() {
            ui.add(
                egui::TextEdit::singleline(&mut state.zinc_model)
                    .desired_width(150.0)
                    .hint_text("catalog model id"),
            );
        } else {
            egui::ComboBox::from_id_salt("zinc_model")
                .selected_text(&state.zinc_model)
                .show_ui(ui, |ui| {
                    for m in models.iter() {
                        ui.selectable_value(&mut state.zinc_model, m.clone(), m);
                    }
                });
        }
        match &status {
            None | Some(ZincStatus::Stopped) | Some(ZincStatus::Failed(_)) => {
                let can_start = !state.zinc_model.trim().is_empty();
                if ui
                    .add_enabled(can_start, egui::Button::new("Start"))
                    .on_hover_text("Pull the model (ZINC downloads it) and run the server")
                    .clicked()
                {
                    let z = Zinc::launch(state.zinc_model.trim(), ZINC_PORT);
                    state.base_url = z.base_url();
                    rt.zinc = Some(z);
                }
            }
            Some(_) => {
                if ui.button("Stop").clicked() {
                    if let Some(z) = &rt.zinc {
                        z.stop();
                    }
                }
            }
        }
        match &status {
            Some(ZincStatus::Pulling) => {
                ui.spinner();
                ui.weak("pulling model\u{2026}");
            }
            Some(ZincStatus::Starting) => {
                ui.spinner();
                ui.weak("starting\u{2026}");
            }
            Some(ZincStatus::Running) => {
                ui.colored_label(accent, format!("running :{ZINC_PORT}"));
            }
            Some(ZincStatus::Failed(e)) => {
                ui.colored_label(error, truncate(e, 40)).on_hover_text(e);
            }
            Some(ZincStatus::Stopped) | None => {}
        }
    });
}

fn transcript(ui: &mut egui::Ui, app: &mut App, gui: &mut GuiState) {
    let accent = gui.theme.accent;
    let error = gui.theme.error;
    // Split borrows: transcript is read while the math cache mutates.
    let GuiState {
        agent,
        doc_math_cache,
        ..
    } = gui;
    let running = agent.running;
    // Checkpoint index clicked this frame; applied after the loop (the
    // transcript is borrowed immutably while rendering).
    let mut revert: Option<usize> = None;
    egui::ScrollArea::vertical()
        .stick_to_bottom(true)
        .auto_shrink([false, false])
        .show(ui, |ui| {
            for (idx, entry) in agent.transcript.iter().enumerate() {
                match entry {
                    Entry::User(t) => {
                        egui::Frame::group(ui.style())
                            .fill(accent.linear_multiply(0.12))
                            .show(ui, |ui| {
                                ui.set_width(ui.available_width());
                                ui.horizontal_top(|ui| {
                                    ui.label(egui::RichText::new(t).strong());
                                    ui.with_layout(
                                        egui::Layout::right_to_left(egui::Align::TOP),
                                        |ui| {
                                            let ck = agent
                                                .checkpoints
                                                .iter()
                                                .position(|c| c.entry == idx);
                                            if let Some(ck) = ck {
                                                if ui
                                                    .add_enabled(
                                                        !running,
                                                        egui::Button::new("\u{21BA}").small(),
                                                    )
                                                    .on_hover_text(
                                                        "Revert workspace + chat to before \
                                                         this message",
                                                    )
                                                    .clicked()
                                                {
                                                    revert = Some(ck);
                                                }
                                            }
                                        },
                                    );
                                });
                            });
                    }
                    Entry::Thinking { text, done } => {
                        if *done {
                            egui::CollapsingHeader::new(
                                egui::RichText::new("Thought").italics().weak().size(12.0),
                            )
                            .id_salt(("agent_think", idx))
                            .default_open(false)
                            .show(ui, |ui| {
                                ui.label(
                                    egui::RichText::new(text).italics().weak().size(12.0),
                                );
                            });
                        } else {
                            ui.label(
                                egui::RichText::new("Thinking\u{2026}")
                                    .italics()
                                    .weak()
                                    .size(12.0),
                            );
                            ui.label(egui::RichText::new(text).italics().weak().size(12.0));
                        }
                    }
                    Entry::Text { text, .. } => render_simple_markdown(ui, doc_math_cache, text),
                    Entry::Tool {
                        name,
                        input,
                        result,
                        is_error,
                    } => {
                        let (icon, color) = match (result, *is_error) {
                            (Some(_), true) => ("\u{2717}", error),
                            (Some(_), false) => ("\u{2713}", accent),
                            (None, _) if running => ("\u{29D6}", ui.visuals().weak_text_color()),
                            (None, _) => ("\u{2717}", error), // never answered
                        };
                        let title = egui::RichText::new(format!(
                            "{icon} {}",
                            tool_label(name, input)
                        ))
                        .monospace()
                        .size(12.0)
                        .color(color);
                        egui::CollapsingHeader::new(title)
                            .id_salt(("agent_tool", idx))
                            .default_open(false)
                            .show(ui, |ui| {
                                ui.label(
                                    egui::RichText::new(pretty_json(input))
                                        .monospace()
                                        .weak()
                                        .size(11.0),
                                );
                                if let Some(r) = result {
                                    ui.separator();
                                    ui.label(
                                        egui::RichText::new(truncate(r, 1200))
                                            .monospace()
                                            .weak()
                                            .size(11.0),
                                    );
                                }
                            });
                    }
                    Entry::Done(t) => {
                        ui.separator();
                        render_simple_markdown(ui, doc_math_cache, t);
                        if let Some(summary) = turn_summary(&agent.transcript, idx) {
                            ui.label(
                                egui::RichText::new(summary).weak().size(11.0),
                            );
                        }
                    }
                    Entry::Error(t) => {
                        ui.colored_label(error, t);
                    }
                }
                ui.add_space(4.0);
            }
            if agent.transcript.is_empty() {
                ui.weak("Ask the assistant to build, inspect, or fix your schematic.");
                ui.weak("It drives Schemify through its MCP tools only.");
            }
        });
    if let Some(ck) = revert {
        revert_to(app, agent, ck);
    }
}

/// Restore the workspace snapshot and truncate the conversation to it.
fn revert_to(app: &mut App, agent: &mut AgentPanelState, ck: usize) {
    let cp = agent.checkpoints[ck].clone();
    if !restore_snapshot(app, &cp.bytes) {
        agent
            .transcript
            .push(Entry::Error("checkpoint restore failed".into()));
        return;
    }
    agent.transcript.truncate(cp.entry);
    agent.history.truncate(cp.history_len);
    agent.checkpoints.truncate(ck);
    // CLI sessions can't rewind server-side; continue as a fresh one.
    agent.session_id = None;
    app.state.status_msg = "Reverted to checkpoint".into();
}

/// "5 tool calls · PlaceDevice ×3 · saved rc.chn" for the turn ending at
/// `done_idx`; None if the turn used no tools.
fn turn_summary(entries: &[Entry], done_idx: usize) -> Option<String> {
    let start = entries[..done_idx]
        .iter()
        .rposition(|e| matches!(e, Entry::User(_)))?;
    let (mut calls, mut failed) = (0usize, 0usize);
    let mut notes: Vec<(String, usize)> = Vec::new();
    for e in &entries[start..done_idx] {
        if let Entry::Tool {
            name,
            input,
            is_error,
            ..
        } = e
        {
            calls += 1;
            if *is_error {
                failed += 1;
            }
            if let Some(note) = change_note(name, input) {
                match notes.iter_mut().find(|(n, _)| *n == note) {
                    Some((_, count)) => *count += 1,
                    None => notes.push((note, 1)),
                }
            }
        }
    }
    if calls == 0 {
        return None;
    }
    let mut parts = vec![format!(
        "{calls} tool call{}",
        if calls == 1 { "" } else { "s" }
    )];
    if failed > 0 {
        parts.push(format!("{failed} failed"));
    }
    for (note, count) in notes {
        parts.push(if count > 1 {
            format!("{note} \u{00D7}{count}")
        } else {
            note
        });
    }
    Some(parts.join(" \u{00B7} "))
}

/// What a tool call changed, for the turn summary. None = read-only.
fn change_note(name: &str, input: &str) -> Option<String> {
    let v: Value = serde_json::from_str(input).unwrap_or(Value::Null);
    let path_name = || {
        v.get("path")
            .or_else(|| v.get("name"))
            .and_then(Value::as_str)
            .map(|p| p.rsplit('/').next().unwrap_or(p).to_string())
    };
    match name {
        "session_dispatch" => Some(dispatch_label(&v)),
        "session_save" => Some(format!(
            "saved {}",
            path_name().unwrap_or_else(|| "document".into())
        )),
        "session_open" | "session_open_content" => Some(format!(
            "opened {}",
            path_name().unwrap_or_else(|| "document".into())
        )),
        "wave_open" => Some(format!(
            "loaded {}",
            path_name().unwrap_or_else(|| "waveform".into())
        )),
        "session_reset" => Some("reset session".into()),
        n if n.starts_with("marketplace_install") => Some("installed plugin".into()),
        "marketplace_uninstall" => Some("uninstalled plugin".into()),
        _ => None,
    }
}

/// The Command name inside a session_dispatch input, e.g. "PlaceDevice R1".
fn dispatch_label(input: &Value) -> String {
    match input.get("command") {
        // A string is either a unit command ("ZoomIn") or a stringified
        // object — the server unwraps the latter, mirror it in the label.
        Some(Value::String(s)) => match serde_json::from_str::<Value>(s) {
            Ok(obj) if obj.is_object() => dispatch_label(&serde_json::json!({ "command": obj })),
            _ => s.clone(),
        },
        Some(Value::Object(m)) if m.len() == 1 => {
            let (cmd, args) = m.iter().next().expect("len 1");
            let detail = args
                .get("name")
                .or_else(|| args.get("path"))
                .or_else(|| args.get("symbol_path"))
                .and_then(Value::as_str);
            match detail {
                Some(d) => format!("{cmd} {d}"),
                None => cmd.clone(),
            }
        }
        _ => "dispatch".into(),
    }
}

/// Human-readable card title for a tool call.
fn tool_label(name: &str, input: &str) -> String {
    let v: Value = serde_json::from_str(input).unwrap_or(Value::Null);
    match name {
        "session_dispatch" => dispatch_label(&v),
        _ => {
            let mut label = name.replace('_', " ");
            if let Some(p) = v
                .get("path")
                .or_else(|| v.get("name"))
                .or_else(|| v.get("trace"))
                .or_else(|| v.get("query"))
                .and_then(Value::as_str)
            {
                label.push(' ');
                label.push_str(p);
            }
            label
        }
    }
}

fn pretty_json(s: &str) -> String {
    serde_json::from_str::<Value>(s)
        .ok()
        .and_then(|v| serde_json::to_string_pretty(&v).ok())
        .unwrap_or_else(|| s.to_string())
}

fn input_area(
    ui: &mut egui::Ui,
    app: &mut App,
    gui: &mut GuiState,
    rt: &mut AgentRuntime,
    socket: &Path,
) {
    ui.add_space(4.0);

    // Prompts waiting for the current turn to finish.
    let mut unqueue: Option<usize> = None;
    for (i, q) in gui.agent.queued.iter().enumerate() {
        ui.horizontal(|ui| {
            if ui.small_button("\u{2715}").on_hover_text("Remove from queue").clicked() {
                unqueue = Some(i);
            }
            ui.weak(format!("\u{29D6} queued: {}", truncate(q, 60)));
        });
    }
    if let Some(i) = unqueue {
        gui.agent.queued.remove(i);
    }

    // Key handling before the TextEdit sees the events: plain Enter sends,
    // Ctrl+Enter becomes a newline (consumed here, appended by hand).
    let edit_id = egui::Id::new("agent_prompt_edit");
    let focused = ui.ctx().memory(|m| m.has_focus(edit_id));
    let (mut send_key, mut newline_key) = (false, false);
    if focused {
        ui.input_mut(|i| {
            newline_key = i.consume_key(egui::Modifiers::COMMAND, egui::Key::Enter);
            send_key = i.consume_key(egui::Modifiers::NONE, egui::Key::Enter);
        });
    }
    if newline_key {
        // ponytail: appends at the buffer end, not the cursor — fine for the
        // type-then-send flow; cursor-aware insert when someone complains.
        gui.agent.prompt.push('\n');
    }

    // Up/Down recall past prompts (shell-style). Only when the box is empty
    // or still showing a recalled prompt, so arrows keep working for
    // multi-line editing of typed text.
    if focused {
        let past: Vec<&String> = gui
            .agent
            .transcript
            .iter()
            .filter_map(|e| match e {
                Entry::User(t) => Some(t),
                _ => None,
            })
            .collect();
        let recalled = gui
            .agent
            .recall
            .and_then(|i| past.get(i).copied())
            .is_some_and(|t| *t == gui.agent.prompt);
        if !past.is_empty() && (gui.agent.prompt.is_empty() || recalled) {
            let (up, down) = ui.input_mut(|i| {
                (
                    i.consume_key(egui::Modifiers::NONE, egui::Key::ArrowUp),
                    i.consume_key(egui::Modifiers::NONE, egui::Key::ArrowDown),
                )
            });
            if up {
                let next = match gui.agent.recall {
                    Some(i) if i > 0 => i - 1,
                    Some(i) => i,
                    None => past.len() - 1,
                };
                gui.agent.recall = Some(next);
                gui.agent.prompt = past[next].clone();
            } else if down {
                match gui.agent.recall {
                    Some(i) if i + 1 < past.len() => {
                        gui.agent.recall = Some(i + 1);
                        gui.agent.prompt = past[i + 1].clone();
                    }
                    Some(_) => {
                        gui.agent.recall = None;
                        gui.agent.prompt.clear();
                    }
                    None => {}
                }
            }
        } else if !recalled && !gui.agent.prompt.is_empty() {
            gui.agent.recall = None; // user typed something else
        }
    }

    ui.add(
        egui::TextEdit::multiline(&mut gui.agent.prompt)
            .id(edit_id)
            .desired_rows(2)
            .desired_width(f32::INFINITY)
            .hint_text("e.g. place an RC low-pass and show me the netlist"),
    );
    ui.add_space(2.0);
    ui.horizontal(|ui| {
        let has_text = !gui.agent.prompt.trim().is_empty();
        let running = gui.agent.running;
        let label = if running { "Queue" } else { "Send" };
        let clicked = ui.add_enabled(has_text, egui::Button::new(label)).clicked();
        if running {
            if ui.button("Stop").clicked() {
                stop(gui, rt);
            }
            ui.weak("Ctrl+C · Enter \u{2192} queue");
        } else {
            ui.weak("Enter \u{2192} send · Ctrl+Enter \u{2192} newline");
        }
        if has_text && (clicked || send_key) {
            let prompt = std::mem::take(&mut gui.agent.prompt).trim().to_string();
            if running {
                gui.agent.queued.push(prompt);
            } else {
                send(app, &mut gui.agent, rt, socket, prompt);
            }
        }
    });
    ui.add_space(4.0);
}

fn stop(gui: &mut GuiState, rt: &mut AgentRuntime) {
    if let Some(handle) = &rt.handle {
        handle.stop(); // backend ends the stream; drain_events flips running
        gui.agent
            .transcript
            .push(Entry::Error("interrupted".into()));
    }
}

fn send(
    app: &mut App,
    state: &mut AgentPanelState,
    rt: &mut AgentRuntime,
    socket: &Path,
    prompt: String,
) {
    // Snapshot the workspace before the turn touches it.
    state.checkpoints.push(Checkpoint {
        entry: state.transcript.len(),
        history_len: state.history.len(),
        bytes: take_snapshot(app),
    });
    state.transcript.push(Entry::User(prompt.clone()));

    let mut agent = Agent::new(state.backend);
    if !state.api_key.trim().is_empty() {
        agent = agent.with_api_key(state.api_key.trim());
    }
    if !state.model.trim().is_empty() {
        agent = agent.with_model(state.model.trim());
    }
    if state.backend == Backend::Local {
        agent = agent.with_base_url(state.base_url.trim());
    }
    if let Err(e) = agent.check() {
        state.transcript.push(Entry::Error(e.to_string()));
        return;
    }
    let mcp = match McpConfig::via_current_exe(socket.to_path_buf()) {
        Ok(m) => m,
        Err(e) => {
            state.transcript.push(Entry::Error(format!("bridge: {e}")));
            return;
        }
    };

    // Spawn is fast; run it here so the kill handle is available immediately.
    let session = match agent.run(&prompt, &mcp, state.session_id.as_deref(), &state.history) {
        Ok(s) => s,
        Err(e) => {
            state.transcript.push(Entry::Error(e.to_string()));
            return;
        }
    };
    state.history.push(ChatMsg {
        user: true,
        text: prompt,
    });
    rt.handle = Some(session.handle());

    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for ev in session {
            if tx.send(ev.map_err(|e| e.to_string())).is_err() {
                break; // GUI gone; Session drop stops the backend
            }
        }
    });
    rt.rx = Some(rx);
    state.running = true;
}

fn drain_events(gui: &mut GuiState, rt: &mut AgentRuntime) {
    let Some(r) = &mut rt.rx else { return };
    loop {
        match r.try_recv() {
            Ok(Ok(ev)) => push_event(&mut gui.agent, ev),
            Ok(Err(e)) => gui.agent.transcript.push(Entry::Error(e)),
            Err(TryRecvError::Empty) => break,
            Err(TryRecvError::Disconnected) => {
                rt.rx = None;
                rt.handle = None;
                gui.agent.running = false;
                finalize_streaming(&mut gui.agent.transcript);
                save_chat(&mut gui.agent); // turn done — persist
                break;
            }
        }
    }
}

fn push_event(state: &mut AgentPanelState, ev: Event) {
    let tr = &mut state.transcript;
    match ev {
        Event::TextDelta(d) => append_delta(tr, false, &d),
        Event::ThinkingDelta(d) => append_delta(tr, true, &d),
        Event::Text(t) => finalize_block(tr, false, t),
        Event::Thinking(t) => finalize_block(tr, true, t),
        Event::ToolUse { name, input } => {
            finalize_streaming(tr); // a tool call ends any streaming block
            tr.push(Entry::Tool {
                // Strip claude's mcp__schemify__ prefix; others are bare.
                name: name.rsplit("__").next().unwrap_or(&name).to_string(),
                input: input.to_string(),
                result: None,
                is_error: false,
            });
        }
        Event::ToolResult { text, is_error } => {
            // Attach to the most recent unanswered tool call.
            for e in tr.iter_mut().rev() {
                if let Entry::Tool {
                    result, is_error: err, ..
                } = e
                {
                    if result.is_none() {
                        *result = Some(text);
                        *err = is_error;
                        break;
                    }
                }
            }
        }
        Event::SessionId(id) => state.session_id = Some(id),
        Event::Result(t) => {
            finalize_streaming(tr);
            if t.is_empty() {
                return;
            }
            state.history.push(ChatMsg {
                user: false,
                text: t.clone(),
            });
            // Claude's final result repeats the last assistant text; promote
            // that entry to Done instead of duplicating it.
            if let Some(last @ Entry::Text { .. }) = tr.last_mut() {
                if matches!(last, Entry::Text { text, .. } if *text == t) {
                    *last = Entry::Done(t);
                    return;
                }
            }
            tr.push(Entry::Done(t));
        }
        Event::Raw(_) => {}
    }
}

/// Append a streamed fragment to the trailing open block of its kind, or
/// start a new one.
fn append_delta(tr: &mut Vec<Entry>, thinking: bool, delta: &str) {
    match tr.last_mut() {
        Some(Entry::Text { text, done }) if !thinking && !*done => text.push_str(delta),
        Some(Entry::Thinking { text, done }) if thinking && !*done => text.push_str(delta),
        _ => tr.push(if thinking {
            Entry::Thinking {
                text: delta.to_string(),
                done: false,
            }
        } else {
            Entry::Text {
                text: delta.to_string(),
                done: false,
            }
        }),
    }
}

/// A full block arrived: replace its streamed counterpart (deltas can drop
/// or garble under load — the full text is authoritative), or push as done.
fn finalize_block(tr: &mut Vec<Entry>, thinking: bool, full: String) {
    for e in tr.iter_mut().rev() {
        match e {
            Entry::Text { text, done } if !thinking && !*done => {
                *text = full;
                *done = true;
                return;
            }
            Entry::Thinking { text, done } if thinking && !*done => {
                *text = full;
                *done = true;
                return;
            }
            Entry::User(_) => break, // don't cross into the previous turn
            _ => {}
        }
    }
    tr.push(if thinking {
        Entry::Thinking { text: full, done: true }
    } else {
        Entry::Text { text: full, done: true }
    });
}

/// Close any still-streaming blocks (stream ended or a tool call cut in).
fn finalize_streaming(tr: &mut Vec<Entry>) {
    for e in tr.iter_mut().rev() {
        match e {
            Entry::Text { done, .. } | Entry::Thinking { done, .. } if !*done => *done = true,
            Entry::User(_) => break,
            _ => {}
        }
    }
}

// ── Chat persistence ────────────────────────────────────────

/// `~/.local/share/schemify/chats`, created on demand.
/// ponytail: $HOME only — same Linux/macOS scope as the agent crate.
fn chats_dir() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    let dir = PathBuf::from(home).join(".local/share/schemify/chats");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

fn backend_id(b: Backend) -> &'static str {
    match b {
        Backend::ClaudeCode => "claude",
        Backend::Codex => "codex",
        Backend::Local => "local",
    }
}

fn backend_from_id(s: &str) -> Backend {
    match s {
        "codex" => Backend::Codex,
        "local" => Backend::Local,
        _ => Backend::ClaudeCode,
    }
}

fn entry_json(e: &Entry) -> Value {
    match e {
        Entry::User(t) => json!({"t": "user", "text": t}),
        Entry::Thinking { text, .. } => json!({"t": "think", "text": text}),
        Entry::Text { text, .. } => json!({"t": "text", "text": text}),
        Entry::Tool {
            name,
            input,
            result,
            is_error,
        } => json!({"t": "tool", "name": name, "input": input, "result": result, "err": is_error}),
        Entry::Done(t) => json!({"t": "done", "text": t}),
        Entry::Error(t) => json!({"t": "error", "text": t}),
    }
}

fn entry_from_json(v: &Value) -> Option<Entry> {
    let text = || v.get("text").and_then(Value::as_str).unwrap_or("").to_string();
    Some(match v.get("t").and_then(Value::as_str)? {
        "user" => Entry::User(text()),
        "think" => Entry::Thinking { text: text(), done: true },
        "text" => Entry::Text { text: text(), done: true },
        "tool" => Entry::Tool {
            name: v.get("name").and_then(Value::as_str).unwrap_or("").to_string(),
            input: v.get("input").and_then(Value::as_str).unwrap_or("").to_string(),
            result: v.get("result").and_then(Value::as_str).map(str::to_string),
            is_error: v.get("err").and_then(Value::as_bool).unwrap_or(false),
        },
        "done" => Entry::Done(text()),
        "error" => Entry::Error(text()),
        _ => return None,
    })
}

/// Persist the current chat (no-op while empty). Called after each turn,
/// on New chat, and before loading another chat.
fn save_chat(state: &mut AgentPanelState) {
    if state.transcript.is_empty() {
        return;
    }
    let Some(dir) = chats_dir() else { return };
    if state.chat_file.is_none() {
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        state.chat_file = Some(dir.join(format!("{ts}.json")));
    }
    let doc = json!({
        "version": 1,
        "backend": backend_id(state.backend),
        "model": state.model,
        "session_id": state.session_id,
        "history": state.history.iter()
            .map(|m| json!({"user": m.user, "text": m.text})).collect::<Vec<_>>(),
        "transcript": state.transcript.iter().map(entry_json).collect::<Vec<_>>(),
    });
    let _ = std::fs::write(state.chat_file.as_ref().expect("set above"), doc.to_string());
}

fn load_chat(state: &mut AgentPanelState, path: &Path) {
    let Ok(raw) = std::fs::read_to_string(path) else {
        state.transcript.push(Entry::Error("failed to read chat".into()));
        return;
    };
    let Ok(v) = serde_json::from_str::<Value>(&raw) else {
        state.transcript.push(Entry::Error("corrupt chat file".into()));
        return;
    };
    state.transcript = v
        .get("transcript")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(entry_from_json).collect())
        .unwrap_or_default();
    state.history = v
        .get("history")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .map(|m| ChatMsg {
                    user: m.get("user").and_then(Value::as_bool).unwrap_or(false),
                    text: m.get("text").and_then(Value::as_str).unwrap_or("").to_string(),
                })
                .collect()
        })
        .unwrap_or_default();
    state.backend = backend_from_id(v.get("backend").and_then(Value::as_str).unwrap_or(""));
    state.model = v.get("model").and_then(Value::as_str).unwrap_or("").to_string();
    // CLI session files persist on disk, so resuming across app restarts works.
    state.session_id = v.get("session_id").and_then(Value::as_str).map(str::to_string);
    state.checkpoints.clear(); // snapshots belong to the app session, not the chat
    state.queued.clear();
    state.recall = None;
    state.chat_file = Some(path.to_path_buf());
}

/// Saved chats, newest first, labeled by their first user prompt.
fn list_chats() -> Vec<(PathBuf, String)> {
    let Some(dir) = chats_dir() else { return Vec::new() };
    let Ok(rd) = std::fs::read_dir(&dir) else { return Vec::new() };
    let mut files: Vec<PathBuf> = rd
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .collect();
    files.sort();
    files.reverse();
    files
        .into_iter()
        .take(20) // ponytail: newest 20; add scrolling/search when it hurts
        .filter_map(|p| {
            let raw = std::fs::read_to_string(&p).ok()?;
            let v: Value = serde_json::from_str(&raw).ok()?;
            let first = v
                .get("transcript")
                .and_then(Value::as_array)
                .and_then(|a| {
                    a.iter().find_map(|e| {
                        (e.get("t")? == "user").then(|| e.get("text"))?
                    })
                })
                .and_then(Value::as_str)
                .unwrap_or("(empty)");
            Some((p, truncate(first, 48)))
        })
        .collect()
}

// ── Checkpoints ─────────────────────────────────────────────

/// All open documents (as .chn text) + active tab, zlib-compressed.
fn take_snapshot(app: &App) -> Vec<u8> {
    let docs: Vec<Value> = app
        .state
        .documents
        .iter()
        .enumerate()
        .map(|(i, d)| {
            json!({
                "name": format!("{}{}", d.name, d.kind.ext()),
                "origin": match &d.origin {
                    Origin::File(p) => json!(p),
                    _ => Value::Null,
                },
                "dirty": d.dirty,
                "chn": app.document_text(i).unwrap_or_default(),
            })
        })
        .collect();
    let raw = json!({"active": app.state.active_doc, "docs": docs}).to_string();
    let mut enc =
        flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    let _ = enc.write_all(raw.as_bytes());
    enc.finish().unwrap_or_default()
}

fn restore_snapshot(app: &mut App, bytes: &[u8]) -> bool {
    let mut dec = flate2::write::ZlibDecoder::new(Vec::new());
    let raw = match dec.write_all(bytes).and_then(|_| dec.finish()) {
        Ok(r) => r,
        Err(_) => return false,
    };
    let Ok(v) = serde_json::from_slice::<Value>(&raw) else {
        return false;
    };
    let Some(docs) = v.get("docs").and_then(Value::as_array) else {
        return false;
    };
    app.state.documents.clear();
    app.state.active_doc = 0;
    for d in docs {
        let name = d.get("name").and_then(Value::as_str).unwrap_or("untitled.chn");
        let chn = d.get("chn").and_then(Value::as_str).unwrap_or("");
        app.open_from_content(name, chn);
        if let Some(doc) = app.state.documents.last_mut() {
            doc.dirty = d.get("dirty").and_then(Value::as_bool).unwrap_or(true);
            if let Some(p) = d.get("origin").and_then(Value::as_str) {
                doc.origin = Origin::File(PathBuf::from(p));
            }
        }
    }
    // Never leave the app with zero documents (active_document() indexes).
    if app.state.documents.is_empty() {
        app.open_from_content("untitled.chn", "");
    }
    let active = v.get("active").and_then(Value::as_u64).unwrap_or(0) as usize;
    app.state.active_doc = active.min(app.state.documents.len() - 1);
    true
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let cut: String = s.chars().take(max).collect();
        format!("{cut}\u{2026}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chat_save_load_round_trip() {
        let mut state = AgentPanelState {
            backend: Backend::Codex,
            model: "gpt-x".into(),
            session_id: Some("s-42".into()),
            transcript: vec![
                Entry::User("build rc".into()),
                Entry::Thinking { text: "hmm".into(), done: true },
                Entry::Tool {
                    name: "session_dispatch".into(),
                    input: "{\"command\":\"ZoomIn\"}".into(),
                    result: Some("{\"ok\":true}".into()),
                    is_error: false,
                },
                Entry::Done("done".into()),
            ],
            history: vec![ChatMsg { user: true, text: "build rc".into() }],
            chat_file: Some(std::env::temp_dir().join("schemify-chat-test.json")),
            ..Default::default()
        };
        save_chat(&mut state);

        let mut loaded = AgentPanelState::default();
        load_chat(&mut loaded, state.chat_file.as_ref().unwrap());
        assert_eq!(loaded.backend, Backend::Codex);
        assert_eq!(loaded.model, "gpt-x");
        assert_eq!(loaded.session_id.as_deref(), Some("s-42"));
        assert_eq!(loaded.transcript.len(), 4);
        assert!(matches!(&loaded.transcript[0], Entry::User(t) if t == "build rc"));
        assert!(matches!(
            &loaded.transcript[2],
            Entry::Tool { result: Some(r), is_error: false, .. } if r == "{\"ok\":true}"
        ));
        assert_eq!(loaded.history.len(), 1);

        let _ = std::fs::remove_file(state.chat_file.unwrap());
    }

    #[test]
    fn snapshot_round_trip() {
        let mut app = App::new();
        app.open_from_content("filter.chn", "");
        let docs_before = app.state.documents.len();
        let active_before = app.state.active_doc;

        let snap = take_snapshot(&app);
        assert!(!snap.is_empty());

        // Mutate: extra doc + different active tab.
        app.open_from_content("junk.chn_tb", "");
        assert_ne!(app.state.documents.len(), docs_before);

        assert!(restore_snapshot(&mut app, &snap));
        assert_eq!(app.state.documents.len(), docs_before);
        assert_eq!(app.state.active_doc, active_before);
        assert!(app.state.documents.iter().any(|d| d.name == "filter"));

        // Garbage bytes fail cleanly, leaving the app usable.
        assert!(!restore_snapshot(&mut app, b"not a snapshot"));
        assert!(!app.state.documents.is_empty());
    }
}
