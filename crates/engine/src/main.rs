mod plugin_cli;

use std::path::PathBuf;
use std::process;

use clap::{Parser, Subcommand};
use schemify_core::commands::{Command, Tool};
use schemify_core::types::Color;
use schemify_handler::App;

#[derive(Parser)]
#[command(name = "schemify", about = "SchemifyRS — schematic editor")]
struct Cli {
    /// Schematic file to operate on
    #[arg(long, short)]
    file: Option<PathBuf>,

    /// Save file after command execution
    #[arg(long)]
    save: bool,

    #[command(subcommand)]
    command: Option<CliCommand>,
}

#[derive(Subcommand)]
enum CliCommand {
    // ── View ──
    ZoomIn,
    ZoomOut,
    ZoomFit,
    ZoomReset,
    ToggleFullscreen,
    ToggleColorScheme,
    ToggleGrid,

    // ── File ──
    FileNew,
    FileOpen,
    FileSave,
    FileSaveAs,
    NewTab,
    CloseTab { index: usize },
    SwitchTab { index: usize },
    ReloadFromDisk,

    // ── Selection ──
    SelectAll,
    SelectNone,
    InvertSelection,

    // ── Clipboard ──
    Copy,
    Cut,
    Paste,

    // ── Tool ──
    SetTool {
        /// select|wire|move|pan|line|rect|polygon|arc|circle|text
        tool: String,
    },

    // ── Dialogs ──
    OpenFindDialog,
    OpenPropsDialog,
    OpenSettings,
    OpenSpiceCodeEditor,
    OpenNewPrimDialog,
    OpenMarketplace,
    OpenImportDialog,

    // ── Undo/Redo ──
    Undo,
    Redo,

    // ── Deletion ──
    DeleteSelected,
    DeleteInstance { idx: usize },
    DeleteWire { idx: usize },

    // ── Duplication ──
    DuplicateSelected,

    // ── Transform ──
    RotateCw,
    RotateCcw,
    FlipHorizontal,
    FlipVertical,
    NudgeUp,
    NudgeDown,
    NudgeLeft,
    NudgeRight,
    AlignToGrid,

    // ── Placement ──
    PlaceDevice {
        #[arg(long)]
        symbol_path: String,
        #[arg(long)]
        name: String,
        #[arg(long)]
        x: i32,
        #[arg(long)]
        y: i32,
        #[arg(long, default_value = "0")]
        rotation: u8,
        #[arg(long)]
        flip: bool,
    },

    // ── Wiring ──
    AddWire {
        #[arg(long)]
        x0: i32,
        #[arg(long)]
        y0: i32,
        #[arg(long)]
        x1: i32,
        #[arg(long)]
        y1: i32,
        #[arg(long)]
        net_name: Option<String>,
        #[arg(long)]
        bus: bool,
    },

    // ── Geometry ──
    AddLine {
        #[arg(long)]
        x0: i32,
        #[arg(long)]
        y0: i32,
        #[arg(long)]
        x1: i32,
        #[arg(long)]
        y1: i32,
    },
    AddRect {
        #[arg(long)]
        x: i32,
        #[arg(long)]
        y: i32,
        #[arg(long)]
        w: i32,
        #[arg(long)]
        h: i32,
    },
    AddCircle {
        #[arg(long)]
        cx: i32,
        #[arg(long)]
        cy: i32,
        #[arg(long)]
        radius: i32,
    },
    AddArc {
        #[arg(long)]
        cx: i32,
        #[arg(long)]
        cy: i32,
        #[arg(long)]
        radius: i32,
        #[arg(long)]
        start: f32,
        #[arg(long)]
        sweep: f32,
    },
    AddText {
        #[arg(long)]
        x: i32,
        #[arg(long)]
        y: i32,
        #[arg(long)]
        content: String,
    },

    // ── Movement ──
    MoveInstance {
        #[arg(long)]
        idx: usize,
        #[arg(long)]
        dx: i32,
        #[arg(long)]
        dy: i32,
    },
    MoveWire {
        #[arg(long)]
        idx: usize,
        #[arg(long)]
        dx: i32,
        #[arg(long)]
        dy: i32,
    },
    MoveSelected {
        #[arg(long)]
        dx: i32,
        #[arg(long)]
        dy: i32,
    },

    // ── Properties ──
    SetInstanceProp {
        #[arg(long)]
        idx: usize,
        #[arg(long)]
        key: String,
        #[arg(long)]
        value: String,
    },
    RenameInstance {
        #[arg(long)]
        idx: usize,
        #[arg(long)]
        new_name: String,
    },
    RenameNet {
        #[arg(long)]
        old_name: String,
        #[arg(long)]
        new_name: String,
    },
    SetSpiceCode {
        code: String,
    },
    SetDocumentation {
        doc: String,
    },
    SetWireColor {
        #[arg(long)]
        idx: usize,
        /// Color as hex: RRGGBB or RRGGBBAA
        #[arg(long)]
        color: String,
    },

    // ── Simulation ──
    RunSim,
    SetStimulusLang {
        /// ngspice|xyce|vacask|ltspice|spectre|pyspice
        lang: String,
    },
    SetSimBackend {
        /// ngspice|xyce|ltspice|spectre
        backend: String,
    },
    /// Generate/update companion stimulus file for a testbench
    GenStimulus,
    /// Show companion stimulus file path
    ShowStimulus,

    // ── Layout ──
    AutoLayout,

    // ── Import ──
    ImportSpice {
        path: String,
    },

    // ── Plugins ──
    PluginsRefresh,

    /// Plugin management (install, uninstall, list)
    Plugin {
        #[command(subcommand)]
        action: plugin_cli::PluginCommand,
    },
}

fn parse_tool(s: &str) -> Result<Tool, String> {
    match s {
        "select" => Ok(Tool::Select),
        "wire" => Ok(Tool::Wire),
        "move" => Ok(Tool::Move),
        "pan" => Ok(Tool::Pan),
        "line" => Ok(Tool::Line),
        "rect" => Ok(Tool::Rect),
        "polygon" => Ok(Tool::Polygon),
        "arc" => Ok(Tool::Arc),
        "circle" => Ok(Tool::Circle),
        "text" => Ok(Tool::Text),
        _ => Err(format!("unknown tool: {s}")),
    }
}

fn parse_color(s: &str) -> Result<Color, String> {
    let hex = s.strip_prefix('#').unwrap_or(s);
    let bytes = u32::from_str_radix(hex, 16).map_err(|e| format!("bad color hex: {e}"))?;
    match hex.len() {
        6 => Ok(Color {
            r: ((bytes >> 16) & 0xFF) as u8,
            g: ((bytes >> 8) & 0xFF) as u8,
            b: (bytes & 0xFF) as u8,
            a: 255,
        }),
        8 => Ok(Color {
            r: ((bytes >> 24) & 0xFF) as u8,
            g: ((bytes >> 16) & 0xFF) as u8,
            b: ((bytes >> 8) & 0xFF) as u8,
            a: (bytes & 0xFF) as u8,
        }),
        _ => Err(format!("color hex must be 6 or 8 chars, got {}", hex.len())),
    }
}

fn to_command(cli_cmd: CliCommand) -> Command {
    match cli_cmd {
        CliCommand::ZoomIn => Command::ZoomIn,
        CliCommand::ZoomOut => Command::ZoomOut,
        CliCommand::ZoomFit => Command::ZoomFit,
        CliCommand::ZoomReset => Command::ZoomReset,
        CliCommand::ToggleFullscreen => Command::ToggleFullscreen,
        CliCommand::ToggleColorScheme => Command::ToggleColorScheme,
        CliCommand::ToggleGrid => Command::ToggleGrid,
        CliCommand::FileNew => Command::FileNew,
        CliCommand::FileOpen => Command::FileOpen,
        CliCommand::FileSave => Command::FileSave,
        CliCommand::FileSaveAs => Command::FileSaveAs,
        CliCommand::NewTab => Command::NewTab,
        CliCommand::CloseTab { index } => Command::CloseTab(index),
        CliCommand::SwitchTab { index } => Command::SwitchTab(index),
        CliCommand::ReloadFromDisk => Command::ReloadFromDisk,
        CliCommand::SelectAll => Command::SelectAll,
        CliCommand::SelectNone => Command::SelectNone,
        CliCommand::InvertSelection => Command::InvertSelection,
        CliCommand::Copy => Command::Copy,
        CliCommand::Cut => Command::Cut,
        CliCommand::Paste => Command::Paste,
        CliCommand::SetTool { tool } => {
            let t = parse_tool(&tool).unwrap_or_else(|e| {
                eprintln!("error: {e}");
                process::exit(1);
            });
            Command::SetTool(t)
        }
        CliCommand::OpenFindDialog => Command::OpenFindDialog,
        CliCommand::OpenPropsDialog => Command::OpenPropsDialog,
        CliCommand::OpenSettings => Command::OpenSettings,
        CliCommand::OpenSpiceCodeEditor => Command::OpenSpiceCodeEditor,
        CliCommand::OpenNewPrimDialog => Command::OpenNewPrimDialog,
        CliCommand::OpenMarketplace => Command::OpenMarketplace,
        CliCommand::OpenImportDialog => Command::OpenImportDialog,
        CliCommand::Undo => Command::Undo,
        CliCommand::Redo => Command::Redo,
        CliCommand::DeleteSelected => Command::DeleteSelected,
        CliCommand::DeleteInstance { idx } => Command::DeleteInstance(idx),
        CliCommand::DeleteWire { idx } => Command::DeleteWire(idx),
        CliCommand::DuplicateSelected => Command::DuplicateSelected,
        CliCommand::RotateCw => Command::RotateCw,
        CliCommand::RotateCcw => Command::RotateCcw,
        CliCommand::FlipHorizontal => Command::FlipHorizontal,
        CliCommand::FlipVertical => Command::FlipVertical,
        CliCommand::NudgeUp => Command::NudgeUp,
        CliCommand::NudgeDown => Command::NudgeDown,
        CliCommand::NudgeLeft => Command::NudgeLeft,
        CliCommand::NudgeRight => Command::NudgeRight,
        CliCommand::AlignToGrid => Command::AlignToGrid,
        CliCommand::PlaceDevice {
            symbol_path,
            name,
            x,
            y,
            rotation,
            flip,
        } => Command::PlaceDevice {
            symbol_path,
            name,
            x,
            y,
            rotation,
            flip,
        },
        CliCommand::AddWire {
            x0,
            y0,
            x1,
            y1,
            net_name,
            bus,
        } => Command::AddWire {
            x0,
            y0,
            x1,
            y1,
            net_name,
            bus,
        },
        CliCommand::AddLine { x0, y0, x1, y1 } => Command::AddLine { x0, y0, x1, y1 },
        CliCommand::AddRect { x, y, w, h } => Command::AddRect { x, y, w, h },
        CliCommand::AddCircle { cx, cy, radius } => Command::AddCircle { cx, cy, radius },
        CliCommand::AddArc {
            cx,
            cy,
            radius,
            start,
            sweep,
        } => Command::AddArc {
            cx,
            cy,
            radius,
            start,
            sweep,
        },
        CliCommand::AddText { x, y, content } => Command::AddText { x, y, content },
        CliCommand::MoveInstance { idx, dx, dy } => Command::MoveInstance { idx, dx, dy },
        CliCommand::MoveWire { idx, dx, dy } => Command::MoveWire { idx, dx, dy },
        CliCommand::MoveSelected { dx, dy } => Command::MoveSelected { dx, dy },
        CliCommand::SetInstanceProp { idx, key, value } => {
            Command::SetInstanceProp { idx, key, value }
        }
        CliCommand::RenameInstance { idx, new_name } => Command::RenameInstance { idx, new_name },
        CliCommand::RenameNet {
            old_name,
            new_name,
        } => Command::RenameNet {
            old_name,
            new_name,
        },
        CliCommand::SetSpiceCode { code } => Command::SetSpiceCode(code),
        CliCommand::SetDocumentation { doc } => Command::SetDocumentation(doc),
        CliCommand::SetWireColor { idx, color } => {
            let c = parse_color(&color).unwrap_or_else(|e| {
                eprintln!("error: {e}");
                process::exit(1);
            });
            Command::SetWireColor { idx, color: c }
        }
        CliCommand::RunSim => Command::RunSim,
        CliCommand::SetStimulusLang { lang } => Command::SetStimulusLang(lang),
        CliCommand::SetSimBackend { backend } => Command::SetSimBackend(backend),
        CliCommand::GenStimulus | CliCommand::ShowStimulus => {
            unreachable!("handled before run_cli")
        }
        CliCommand::AutoLayout => Command::AutoLayout,
        CliCommand::ImportSpice { path } => Command::ImportSpice { path },
        CliCommand::PluginsRefresh => Command::PluginsRefresh,
        CliCommand::Plugin { .. } => unreachable!("handled before run_cli"),
    }
}

fn run_cli(cli: Cli, cli_cmd: CliCommand) {
    let mut app = App::new();

    // Load file if provided — skip for import-spice (file is the save target)
    let is_import = matches!(cli_cmd, CliCommand::ImportSpice { .. });
    if let Some(ref path) = cli.file {
        if !is_import || path.exists() {
            if let Err(e) = app.open_file(path) {
                eprintln!("error opening {}: {e}", path.display());
                process::exit(1);
            }
        }
    }

    let cmd = to_command(cli_cmd);
    app.dispatch(cmd);

    // Save if requested
    if cli.save {
        match &cli.file {
            Some(path) => {
                if let Err(e) = app.save_to_path(path) {
                    eprintln!("error saving {}: {e}", path.display());
                    process::exit(1);
                }
            }
            None => {
                eprintln!("error: --save requires --file");
                process::exit(1);
            }
        }
    }
}

fn require_file(cli: &Cli) -> &std::path::Path {
    match &cli.file {
        Some(p) => p,
        None => {
            eprintln!("error: this command requires --file <testbench.chn_tb>");
            process::exit(1);
        }
    }
}

fn run_gen_stimulus(cli: &Cli) {
    let path = require_file(cli);
    let mut app = App::new();
    if let Err(e) = app.open_file(path) {
        eprintln!("error opening {}: {e}", path.display());
        process::exit(1);
    }
    let sch = app.schematic();
    let stim_path = schemify_io::stimulus::stimulus_path(path, sch.stimulus_lang);

    let existing = std::fs::read_to_string(&stim_path).ok();

    let netlist = if sch.spice_body.is_empty() {
        format!("* No netlist generated yet for: {}", sch.name)
    } else {
        sch.spice_body.clone()
    };

    let output = schemify_io::stimulus::generate_stimulus(
        &sch.name,
        sch.stimulus_lang,
        sch.sim_backend,
        &netlist,
        existing.as_deref(),
    );

    std::fs::write(&stim_path, &output).unwrap_or_else(|e| {
        eprintln!("error writing {}: {e}", stim_path.display());
        process::exit(1);
    });
    println!("Wrote stimulus: {}", stim_path.display());
}

fn run_show_stimulus(cli: &Cli) {
    let path = require_file(cli);
    let mut app = App::new();
    if let Err(e) = app.open_file(path) {
        eprintln!("error opening {}: {e}", path.display());
        process::exit(1);
    }
    let sch = app.schematic();
    let stim_path = schemify_io::stimulus::stimulus_path(path, sch.stimulus_lang);
    let exists = stim_path.exists();

    println!("Testbench:      {}", sch.name);
    println!("Stimulus lang:  {}", sch.stimulus_lang.as_str());
    println!("Sim backend:    {}", sch.sim_backend.as_str());
    println!("Stimulus file:  {}", stim_path.display());
    println!("File exists:    {exists}");
}

fn main() {
    let mut cli = Cli::parse();
    let command = cli.command.take();

    match command {
        None => {
            // No subcommand → launch GUI
            if let Err(e) = schemify_display::run_gui() {
                eprintln!("GUI error: {e}");
                process::exit(1);
            }
        }
        Some(CliCommand::Plugin { action }) => {
            let project_dir = cli.file.as_deref().and_then(|f| f.parent());
            plugin_cli::run_plugin_command(action, project_dir);
        }
        Some(CliCommand::GenStimulus) => run_gen_stimulus(&cli),
        Some(CliCommand::ShowStimulus) => run_show_stimulus(&cli),
        Some(cmd) => run_cli(cli, cmd),
    }
}
