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
//! `{"PlaceDevice": {...}}`. One marshaler (`schemify_mcp::command_from_json`)
//! serves CLI and MCP — no mirrored enum.

use std::path::PathBuf;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};

use schemify_core::handler::App;
use schemify_core::schemify::Command;
use schemify_display::{run_gui, run_gui_standalone};
use schemify_mcp::{command_from_json, run_stdio, McpServer, Sink};

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
    }
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
            app.dispatch(cmd);
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

    run_gui(app.clone(), Some(rx), step_delay).map_err(|e| anyhow::anyhow!("gui: {e}"))?;

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
    let (tx, rx) = mpsc::channel::<Command>();
    let mut server = McpServer::new(app.clone(), Sink::Channel(tx));
    std::thread::spawn(move || {
        if let Err(e) = run_stdio(&mut server) {
            eprintln!("mcp: {e}");
        }
        // stdin EOF: leave the GUI up; user closes it.
    });

    run_gui(app, Some(rx), step_delay).map_err(|e| anyhow::anyhow!("gui: {e}"))
}
