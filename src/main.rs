//! Unified Schemify entry point.
//!
//! * `schemify`                    — GUI
//! * `schemify cli  [opts] CMD..`  — dispatch commands; headless by default,
//!   `--headful` streams them into a live GUI (`--step-delay` ms between
//!   commands for real-time observation)
//! * `schemify mcp  [opts]`        — JSON-RPC server on stdio; headless by
//!   default, `--headful` mirrors every dispatched command in a live GUI
//!
//! Commands use serde's externally-tagged JSON shape (the same wire format as
//! the MCP `session/dispatch` method): `"ZoomIn"`, `{"CloseTab": 2}`,
//! `{"PlaceDevice": {...}}`. One marshaler (`schemify_agent::command_from_json`)
//! serves CLI and MCP — no mirrored enum.

use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};

use schemify_editor::config;
use schemify_editor::handler::{App, DispatchResult};
use schemify_editor::schemify::Command;
use schemify_gui::{run_gui, run_gui_standalone};
use schemify_agent::{command_from_json, run_stdio, McpServer, Sink};
use schemify_plugin_host::PluginService;

/// The one place plugin runtime + marketplace get constructed (DIP wiring
/// point); every frontend shares this instance.
fn plugin_service() -> Arc<Mutex<PluginService>> {
    Arc::new(Mutex::new(PluginService::new(
        config::global_plugins_dir(),
        config::cache_dir(),
    )))
}

#[derive(Parser)]
#[command(name = "schemify", about = "Schematic capture for circuit design")]
struct Args {
    #[command(subcommand)]
    sub: Option<Sub>,
}

#[derive(Subcommand)]
enum Sub {
    /// Dispatch commands from the command line.
    Cli {
        /// Schematic to load before dispatching.
        #[arg(long)]
        file: Option<PathBuf>,
        /// Write the schematic back after the last command.
        #[arg(long)]
        save: bool,
        /// Drive a live GUI window instead of running headless.
        #[arg(long)]
        headful: bool,
        /// Milliseconds between commands in headful mode.
        #[arg(long, value_name = "MS")]
        step_delay: Option<u64>,
        /// Commands in externally-tagged JSON ("ZoomIn", '{"CloseTab":2}', …),
        /// or @path to a file with one command per line.
        #[arg(required = true)]
        commands: Vec<String>,
    },
    /// Run the MCP JSON-RPC server on stdio.
    Mcp {
        /// Mirror dispatched commands in a live GUI window.
        #[arg(long)]
        headful: bool,
        /// Milliseconds between commands in headful mode.
        #[arg(long, value_name = "MS")]
        step_delay: Option<u64>,
    },
    /// Stdio↔socket MCP proxy for agent CLIs (spawned by claude/codex as
    /// their MCP server; connects to a live GUI's agent socket).
    #[command(hide = true)]
    McpBridge {
        /// Socket path of the live Schemify process.
        socket: PathBuf,
    },
    /// Export a netlist from a schematic, headless (`make netlist`-friendly).
    ExportSpice {
        /// Schematic to netlist.
        #[arg(long)]
        file: PathBuf,
        /// Output path; stdout when omitted.
        #[arg(short, long)]
        out: Option<PathBuf>,
        /// Output format: spice, pyspice, or ir (circuit IR as JSON).
        #[arg(long, default_value = "spice")]
        format: String,
    },
}

fn main() -> Result<()> {
    match Args::parse().sub {
        None => run_gui_standalone().map_err(|e| anyhow::anyhow!("gui: {e}")),
        Some(Sub::Cli {
            file,
            save,
            headful,
            step_delay,
            commands,
        }) => run_cli(file, save, headful, step_delay.map(Duration::from_millis), commands),
        Some(Sub::Mcp { headful, step_delay }) => {
            run_mcp(headful, step_delay.map(Duration::from_millis))
        }
        Some(Sub::McpBridge { socket }) => {
            schemify_agent::socket::run_bridge(&socket).map_err(|e| anyhow::anyhow!("bridge: {e}"))
        }
        Some(Sub::ExportSpice { file, out, format }) => run_export_spice(&file, out.as_deref(), &format),
    }
}

/// `schemify export-spice`: load a schematic, build the circuit IR, and
/// emit it in the requested format — no GUI, no dispatch loop.
fn run_export_spice(file: &Path, out: Option<&Path>, format: &str) -> Result<()> {
    use schemify_editor::sim::{codegen, ir};

    let mut app = App::new();
    app.open_file(file)
        .with_context(|| format!("opening {}", file.display()))?;

    let circuit: ir::CircuitIR = app.build_circuit_ir();
    let text = match format {
        "spice" => codegen::emit_spice(&circuit),
        "pyspice" => codegen::emit_pyspice(&circuit),
        "ir" => serde_json::to_string_pretty(&circuit).context("serializing circuit IR")?,
        other => anyhow::bail!("unknown format '{other}' (expected spice, pyspice, or ir)"),
    };

    match out {
        Some(path) => std::fs::write(path, &text)
            .with_context(|| format!("writing {}", path.display()))?,
        None => print!("{text}"),
    }
    Ok(())
}

/// Expand `@file` references and parse every command up front so a typo
/// fails before anything dispatches.
fn parse_commands(raw: &[String]) -> Result<Vec<Command>> {
    let mut out = Vec::with_capacity(raw.len());
    for arg in raw {
        let texts: Vec<String> = match arg.strip_prefix('@') {
            Some(path) => std::fs::read_to_string(path)
                .with_context(|| format!("reading command file {path}"))?
                .lines()
                .map(str::trim)
                .filter(|l| !l.is_empty() && !l.starts_with('#'))
                .map(String::from)
                .collect(),
            None => vec![arg.clone()],
        };
        for text in texts {
            // Accept bare unit-command names without JSON quotes: ZoomIn
            let value: serde_json::Value = serde_json::from_str(&text)
                .unwrap_or_else(|_| serde_json::Value::String(text.clone()));
            out.push(
                command_from_json(&value).with_context(|| format!("parsing command '{text}'"))?,
            );
        }
    }
    Ok(out)
}

fn run_cli(
    file: Option<PathBuf>,
    save: bool,
    headful: bool,
    step_delay: Option<Duration>,
    raw: Vec<String>,
) -> Result<()> {
    let cmds = parse_commands(&raw)?;

    let mut app = App::new();
    if let Some(path) = &file {
        if path.exists() {
            app.open_file(path)
                .with_context(|| format!("opening {}", path.display()))?;
        }
        // Missing file: fresh document, created on --save (old engine semantics).
    }

    if !headful {
        for cmd in cmds {
            if let DispatchResult::Unhandled(c) = app.dispatch(cmd) {
                eprintln!("warning: command not handled in headless mode: {c:?}");
            }
        }
        if save {
            let path = file.context("--save requires --file")?;
            app.save_to_path(&path)
                .with_context(|| format!("saving {}", path.display()))?;
        }
        println!("{}", serde_json::json!({ "status": "ok" }));
        return Ok(());
    }

    // Headful: GUI owns the main thread; a feeder thread queues the commands
    // and the GUI pumps them one per step-delay tick.
    let app = Arc::new(Mutex::new(app));
    let (tx, rx) = mpsc::channel::<Command>();
    for cmd in cmds {
        tx.send(cmd).expect("channel open");
    }
    drop(tx); // GUI keeps running after the queue drains; user closes it.

    run_gui(app.clone(), Some(rx), step_delay, plugin_service())
        .map_err(|e| anyhow::anyhow!("gui: {e}"))?;

    if save {
        let path = file.context("--save requires --file")?;
        let mut app = app.lock().unwrap_or_else(|p| p.into_inner());
        app.save_to_path(&path)
            .with_context(|| format!("saving {}", path.display()))?;
    }
    Ok(())
}

fn run_mcp(headful: bool, step_delay: Option<Duration>) -> Result<()> {
    if !headful {
        let mut server = McpServer::direct(App::new());
        return run_stdio(&mut server);
    }

    // Headful: stdio loop on a worker thread, GUI on the main thread
    // (eframe requires it). Queries read the shared App; dispatches stream
    // through the channel so the GUI animates them with step-delay.
    let app = Arc::new(Mutex::new(App::new()));
    let service = plugin_service();
    let (tx, rx) = mpsc::channel::<Command>();
    let mut server = McpServer::new(app.clone(), Sink::Channel(tx), service.clone());
    std::thread::spawn(move || {
        if let Err(e) = run_stdio(&mut server) {
            eprintln!("mcp: {e}");
        }
        // stdin EOF: leave the GUI up; user closes it.
    });

    run_gui(app, Some(rx), step_delay, service).map_err(|e| anyhow::anyhow!("gui: {e}"))
}
