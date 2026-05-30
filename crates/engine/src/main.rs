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
    CloseTab {
        index: usize,
    },
    SwitchTab {
        index: usize,
    },
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
    DeleteInstance {
        idx: usize,
    },
    DeleteWire {
        idx: usize,
    },

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
        CliCommand::RenameNet { old_name, new_name } => Command::RenameNet { old_name, new_name },
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

// ====================================================
// Tests
// ====================================================

#[cfg(test)]
mod tests {
    use super::*;

    // ── CLI arg parsing ─────────────────────────────────

    #[test]
    fn no_subcommand_yields_none() {
        let cli = Cli::try_parse_from(["schemify"]).unwrap();
        assert!(cli.command.is_none());
        assert!(cli.file.is_none());
        assert!(!cli.save);
    }

    #[test]
    fn file_flag_long() {
        let cli = Cli::try_parse_from(["schemify", "--file", "test.chn"]).unwrap();
        assert_eq!(cli.file.as_deref(), Some(std::path::Path::new("test.chn")));
    }

    #[test]
    fn file_flag_short() {
        let cli = Cli::try_parse_from(["schemify", "-f", "test.chn"]).unwrap();
        assert_eq!(cli.file.as_deref(), Some(std::path::Path::new("test.chn")));
    }

    #[test]
    fn save_flag() {
        let cli = Cli::try_parse_from(["schemify", "--save", "zoom-in"]).unwrap();
        assert!(cli.save);
    }

    #[test]
    fn unknown_subcommand_is_error() {
        let result = Cli::try_parse_from(["schemify", "nonexistent-command"]);
        assert!(result.is_err());
    }

    // ── Simple subcommands (no arguments) ───────────────

    #[test]
    fn simple_subcommands_parse() {
        // Verify that every zero-argument subcommand parses.
        type CaseCheck = fn(&CliCommand) -> bool;
        let cases: &[(&[&str], CaseCheck)] = &[
            (&["schemify", "zoom-in"], |c| {
                matches!(c, CliCommand::ZoomIn)
            }),
            (&["schemify", "zoom-out"], |c| {
                matches!(c, CliCommand::ZoomOut)
            }),
            (&["schemify", "zoom-fit"], |c| {
                matches!(c, CliCommand::ZoomFit)
            }),
            (&["schemify", "zoom-reset"], |c| {
                matches!(c, CliCommand::ZoomReset)
            }),
            (&["schemify", "toggle-fullscreen"], |c| {
                matches!(c, CliCommand::ToggleFullscreen)
            }),
            (&["schemify", "toggle-color-scheme"], |c| {
                matches!(c, CliCommand::ToggleColorScheme)
            }),
            (&["schemify", "toggle-grid"], |c| {
                matches!(c, CliCommand::ToggleGrid)
            }),
            (&["schemify", "file-new"], |c| {
                matches!(c, CliCommand::FileNew)
            }),
            (&["schemify", "file-open"], |c| {
                matches!(c, CliCommand::FileOpen)
            }),
            (&["schemify", "file-save"], |c| {
                matches!(c, CliCommand::FileSave)
            }),
            (&["schemify", "file-save-as"], |c| {
                matches!(c, CliCommand::FileSaveAs)
            }),
            (&["schemify", "new-tab"], |c| {
                matches!(c, CliCommand::NewTab)
            }),
            (&["schemify", "reload-from-disk"], |c| {
                matches!(c, CliCommand::ReloadFromDisk)
            }),
            (&["schemify", "select-all"], |c| {
                matches!(c, CliCommand::SelectAll)
            }),
            (&["schemify", "select-none"], |c| {
                matches!(c, CliCommand::SelectNone)
            }),
            (&["schemify", "invert-selection"], |c| {
                matches!(c, CliCommand::InvertSelection)
            }),
            (&["schemify", "copy"], |c| matches!(c, CliCommand::Copy)),
            (&["schemify", "cut"], |c| matches!(c, CliCommand::Cut)),
            (&["schemify", "paste"], |c| matches!(c, CliCommand::Paste)),
            (&["schemify", "undo"], |c| matches!(c, CliCommand::Undo)),
            (&["schemify", "redo"], |c| matches!(c, CliCommand::Redo)),
            (&["schemify", "delete-selected"], |c| {
                matches!(c, CliCommand::DeleteSelected)
            }),
            (&["schemify", "duplicate-selected"], |c| {
                matches!(c, CliCommand::DuplicateSelected)
            }),
            (&["schemify", "rotate-cw"], |c| {
                matches!(c, CliCommand::RotateCw)
            }),
            (&["schemify", "rotate-ccw"], |c| {
                matches!(c, CliCommand::RotateCcw)
            }),
            (&["schemify", "flip-horizontal"], |c| {
                matches!(c, CliCommand::FlipHorizontal)
            }),
            (&["schemify", "flip-vertical"], |c| {
                matches!(c, CliCommand::FlipVertical)
            }),
            (&["schemify", "nudge-up"], |c| {
                matches!(c, CliCommand::NudgeUp)
            }),
            (&["schemify", "nudge-down"], |c| {
                matches!(c, CliCommand::NudgeDown)
            }),
            (&["schemify", "nudge-left"], |c| {
                matches!(c, CliCommand::NudgeLeft)
            }),
            (&["schemify", "nudge-right"], |c| {
                matches!(c, CliCommand::NudgeRight)
            }),
            (&["schemify", "align-to-grid"], |c| {
                matches!(c, CliCommand::AlignToGrid)
            }),
            (&["schemify", "run-sim"], |c| {
                matches!(c, CliCommand::RunSim)
            }),
            (&["schemify", "gen-stimulus"], |c| {
                matches!(c, CliCommand::GenStimulus)
            }),
            (&["schemify", "show-stimulus"], |c| {
                matches!(c, CliCommand::ShowStimulus)
            }),
            (&["schemify", "auto-layout"], |c| {
                matches!(c, CliCommand::AutoLayout)
            }),
            (&["schemify", "plugins-refresh"], |c| {
                matches!(c, CliCommand::PluginsRefresh)
            }),
            (&["schemify", "open-find-dialog"], |c| {
                matches!(c, CliCommand::OpenFindDialog)
            }),
            (&["schemify", "open-props-dialog"], |c| {
                matches!(c, CliCommand::OpenPropsDialog)
            }),
            (&["schemify", "open-settings"], |c| {
                matches!(c, CliCommand::OpenSettings)
            }),
            (&["schemify", "open-spice-code-editor"], |c| {
                matches!(c, CliCommand::OpenSpiceCodeEditor)
            }),
            (&["schemify", "open-new-prim-dialog"], |c| {
                matches!(c, CliCommand::OpenNewPrimDialog)
            }),
            (&["schemify", "open-marketplace"], |c| {
                matches!(c, CliCommand::OpenMarketplace)
            }),
            (&["schemify", "open-import-dialog"], |c| {
                matches!(c, CliCommand::OpenImportDialog)
            }),
        ];

        for (args, check) in cases {
            let cli = Cli::try_parse_from(*args)
                .unwrap_or_else(|e| panic!("failed to parse {:?}: {e}", args));
            let cmd = cli.command.as_ref().unwrap_or_else(|| {
                panic!("expected Some(command) for {:?}", args);
            });
            assert!(check(cmd), "wrong variant for {:?}", args);
        }
    }

    // ── Subcommands with arguments ──────────────────────

    #[test]
    fn import_spice_subcommand() {
        let cli = Cli::try_parse_from(["schemify", "import-spice", "/tmp/test.spice"]).unwrap();
        match &cli.command {
            Some(CliCommand::ImportSpice { path }) => {
                assert_eq!(path, "/tmp/test.spice");
            }
            _ => panic!("expected ImportSpice"),
        }
    }

    #[test]
    fn import_spice_missing_path_is_error() {
        let result = Cli::try_parse_from(["schemify", "import-spice"]);
        assert!(result.is_err());
    }

    #[test]
    fn close_tab_subcommand() {
        let cli = Cli::try_parse_from(["schemify", "close-tab", "2"]).unwrap();
        match &cli.command {
            Some(CliCommand::CloseTab { index }) => assert_eq!(*index, 2),
            _ => panic!("expected CloseTab"),
        }
    }

    #[test]
    fn switch_tab_subcommand() {
        let cli = Cli::try_parse_from(["schemify", "switch-tab", "0"]).unwrap();
        match &cli.command {
            Some(CliCommand::SwitchTab { index }) => assert_eq!(*index, 0),
            _ => panic!("expected SwitchTab"),
        }
    }

    #[test]
    fn set_tool_subcommand() {
        let cli = Cli::try_parse_from(["schemify", "set-tool", "wire"]).unwrap();
        match &cli.command {
            Some(CliCommand::SetTool { tool }) => assert_eq!(tool, "wire"),
            _ => panic!("expected SetTool"),
        }
    }

    #[test]
    fn delete_instance_subcommand() {
        let cli = Cli::try_parse_from(["schemify", "delete-instance", "5"]).unwrap();
        match &cli.command {
            Some(CliCommand::DeleteInstance { idx }) => assert_eq!(*idx, 5),
            _ => panic!("expected DeleteInstance"),
        }
    }

    #[test]
    fn delete_wire_subcommand() {
        let cli = Cli::try_parse_from(["schemify", "delete-wire", "3"]).unwrap();
        match &cli.command {
            Some(CliCommand::DeleteWire { idx }) => assert_eq!(*idx, 3),
            _ => panic!("expected DeleteWire"),
        }
    }

    #[test]
    fn place_device_all_args() {
        let cli = Cli::try_parse_from([
            "schemify",
            "place-device",
            "--symbol-path",
            "nmos4",
            "--name",
            "M1",
            "--x",
            "100",
            "--y",
            "200",
            "--rotation",
            "1",
            "--flip",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::PlaceDevice {
                symbol_path,
                name,
                x,
                y,
                rotation,
                flip,
            }) => {
                assert_eq!(symbol_path, "nmos4");
                assert_eq!(name, "M1");
                assert_eq!((*x, *y), (100, 200));
                assert_eq!(*rotation, 1);
                assert!(*flip);
            }
            _ => panic!("expected PlaceDevice"),
        }
    }

    #[test]
    fn place_device_defaults() {
        let cli = Cli::try_parse_from([
            "schemify",
            "place-device",
            "--symbol-path",
            "res",
            "--name",
            "R1",
            "--x",
            "0",
            "--y",
            "0",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::PlaceDevice { rotation, flip, .. }) => {
                assert_eq!(*rotation, 0, "default rotation should be 0");
                assert!(!flip, "default flip should be false");
            }
            _ => panic!("expected PlaceDevice"),
        }
    }

    #[test]
    fn add_wire_all_args() {
        let cli = Cli::try_parse_from([
            "schemify",
            "add-wire",
            "--x0",
            "0",
            "--y0",
            "10",
            "--x1",
            "50",
            "--y1",
            "10",
            "--net-name",
            "VDD",
            "--bus",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::AddWire {
                x0,
                y0,
                x1,
                y1,
                net_name,
                bus,
            }) => {
                assert_eq!((*x0, *y0, *x1, *y1), (0, 10, 50, 10));
                assert_eq!(net_name.as_deref(), Some("VDD"));
                assert!(*bus);
            }
            _ => panic!("expected AddWire"),
        }
    }

    #[test]
    fn add_wire_optional_fields_default() {
        let cli = Cli::try_parse_from([
            "schemify", "add-wire", "--x0", "0", "--y0", "0", "--x1", "10", "--y1", "0",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::AddWire { net_name, bus, .. }) => {
                assert!(net_name.is_none());
                assert!(!bus);
            }
            _ => panic!("expected AddWire"),
        }
    }

    #[test]
    fn move_selected_subcommand() {
        // Use --key=value syntax for negative numbers (clap treats bare -N as flags).
        let cli =
            Cli::try_parse_from(["schemify", "move-selected", "--dx=-5", "--dy", "3"]).unwrap();
        match &cli.command {
            Some(CliCommand::MoveSelected { dx, dy }) => {
                assert_eq!((*dx, *dy), (-5, 3));
            }
            _ => panic!("expected MoveSelected"),
        }
    }

    #[test]
    fn move_instance_subcommand() {
        let cli = Cli::try_parse_from([
            "schemify",
            "move-instance",
            "--idx",
            "4",
            "--dx",
            "10",
            "--dy=-20",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::MoveInstance { idx, dx, dy }) => {
                assert_eq!(*idx, 4);
                assert_eq!((*dx, *dy), (10, -20));
            }
            _ => panic!("expected MoveInstance"),
        }
    }

    #[test]
    fn set_spice_code_subcommand() {
        let cli =
            Cli::try_parse_from(["schemify", "set-spice-code", ".subckt test\n.ends"]).unwrap();
        match &cli.command {
            Some(CliCommand::SetSpiceCode { code }) => {
                assert_eq!(code, ".subckt test\n.ends");
            }
            _ => panic!("expected SetSpiceCode"),
        }
    }

    #[test]
    fn add_text_subcommand() {
        let cli = Cli::try_parse_from([
            "schemify",
            "add-text",
            "--x",
            "10",
            "--y",
            "20",
            "--content",
            "Hello World",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::AddText { x, y, content }) => {
                assert_eq!((*x, *y), (10, 20));
                assert_eq!(content, "Hello World");
            }
            _ => panic!("expected AddText"),
        }
    }

    #[test]
    fn add_rect_subcommand() {
        let cli = Cli::try_parse_from([
            "schemify", "add-rect", "--x", "5", "--y", "10", "--w", "20", "--h", "30",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::AddRect { x, y, w, h }) => {
                assert_eq!((*x, *y, *w, *h), (5, 10, 20, 30));
            }
            _ => panic!("expected AddRect"),
        }
    }

    #[test]
    fn add_circle_subcommand() {
        let cli = Cli::try_parse_from([
            "schemify",
            "add-circle",
            "--cx",
            "50",
            "--cy",
            "60",
            "--radius",
            "25",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::AddCircle { cx, cy, radius }) => {
                assert_eq!((*cx, *cy, *radius), (50, 60, 25));
            }
            _ => panic!("expected AddCircle"),
        }
    }

    #[test]
    fn add_line_subcommand() {
        let cli = Cli::try_parse_from([
            "schemify", "add-line", "--x0", "0", "--y0", "0", "--x1", "100", "--y1", "100",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::AddLine { x0, y0, x1, y1 }) => {
                assert_eq!((*x0, *y0, *x1, *y1), (0, 0, 100, 100));
            }
            _ => panic!("expected AddLine"),
        }
    }

    #[test]
    fn add_arc_subcommand() {
        let cli = Cli::try_parse_from([
            "schemify", "add-arc", "--cx", "5", "--cy", "10", "--radius", "15", "--start", "0.5",
            "--sweep", "2.5",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::AddArc {
                cx,
                cy,
                radius,
                start,
                sweep,
            }) => {
                assert_eq!((*cx, *cy, *radius), (5, 10, 15));
                assert!((*start - 0.5).abs() < f32::EPSILON);
                assert!((*sweep - 2.5).abs() < f32::EPSILON);
            }
            _ => panic!("expected AddArc"),
        }
    }

    #[test]
    fn set_wire_color_subcommand() {
        let cli = Cli::try_parse_from([
            "schemify",
            "set-wire-color",
            "--idx",
            "0",
            "--color",
            "FF0000",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::SetWireColor { idx, color }) => {
                assert_eq!(*idx, 0);
                assert_eq!(color, "FF0000");
            }
            _ => panic!("expected SetWireColor"),
        }
    }

    #[test]
    fn set_instance_prop_subcommand() {
        let cli = Cli::try_parse_from([
            "schemify",
            "set-instance-prop",
            "--idx",
            "2",
            "--key",
            "W",
            "--value",
            "1u",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::SetInstanceProp { idx, key, value }) => {
                assert_eq!(*idx, 2);
                assert_eq!(key, "W");
                assert_eq!(value, "1u");
            }
            _ => panic!("expected SetInstanceProp"),
        }
    }

    #[test]
    fn rename_instance_subcommand() {
        let cli = Cli::try_parse_from([
            "schemify",
            "rename-instance",
            "--idx",
            "1",
            "--new-name",
            "M2",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::RenameInstance { idx, new_name }) => {
                assert_eq!(*idx, 1);
                assert_eq!(new_name, "M2");
            }
            _ => panic!("expected RenameInstance"),
        }
    }

    #[test]
    fn rename_net_subcommand() {
        let cli = Cli::try_parse_from([
            "schemify",
            "rename-net",
            "--old-name",
            "net0",
            "--new-name",
            "VDD",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::RenameNet { old_name, new_name }) => {
                assert_eq!(old_name, "net0");
                assert_eq!(new_name, "VDD");
            }
            _ => panic!("expected RenameNet"),
        }
    }

    #[test]
    fn set_stimulus_lang_subcommand() {
        let cli = Cli::try_parse_from(["schemify", "set-stimulus-lang", "ngspice"]).unwrap();
        match &cli.command {
            Some(CliCommand::SetStimulusLang { lang }) => assert_eq!(lang, "ngspice"),
            _ => panic!("expected SetStimulusLang"),
        }
    }

    #[test]
    fn set_sim_backend_subcommand() {
        let cli = Cli::try_parse_from(["schemify", "set-sim-backend", "xyce"]).unwrap();
        match &cli.command {
            Some(CliCommand::SetSimBackend { backend }) => assert_eq!(backend, "xyce"),
            _ => panic!("expected SetSimBackend"),
        }
    }

    // ── Combined flags + subcommand ─────────────────────

    #[test]
    fn file_and_save_with_subcommand() {
        let cli =
            Cli::try_parse_from(["schemify", "--file", "out.chn", "--save", "zoom-in"]).unwrap();
        assert_eq!(cli.file.as_deref(), Some(std::path::Path::new("out.chn")));
        assert!(cli.save);
        assert!(matches!(cli.command, Some(CliCommand::ZoomIn)));
    }

    #[test]
    fn file_with_import_spice() {
        let cli = Cli::try_parse_from([
            "schemify",
            "--file",
            "result.chn",
            "--save",
            "import-spice",
            "circuit.sp",
        ])
        .unwrap();
        assert_eq!(
            cli.file.as_deref(),
            Some(std::path::Path::new("result.chn"))
        );
        assert!(cli.save);
        match &cli.command {
            Some(CliCommand::ImportSpice { path }) => assert_eq!(path, "circuit.sp"),
            _ => panic!("expected ImportSpice"),
        }
    }

    // ── Plugin subcommands ──────────────────────────────

    #[test]
    fn plugin_install() {
        let cli =
            Cli::try_parse_from(["schemify", "plugin", "install", "github:user/repo@1.0"]).unwrap();
        match &cli.command {
            Some(CliCommand::Plugin {
                action:
                    plugin_cli::PluginCommand::Install {
                        source,
                        project,
                        from_file,
                    },
            }) => {
                assert_eq!(source, "github:user/repo@1.0");
                assert!(!project);
                assert!(!from_file);
            }
            _ => panic!("expected Plugin Install"),
        }
    }

    #[test]
    fn plugin_install_project_flag() {
        let cli = Cli::try_parse_from([
            "schemify",
            "plugin",
            "install",
            "--project",
            "github:user/repo",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::Plugin {
                action: plugin_cli::PluginCommand::Install { project, .. },
            }) => {
                assert!(*project);
            }
            _ => panic!("expected Plugin Install with --project"),
        }
    }

    #[test]
    fn plugin_install_from_file_flag() {
        let cli = Cli::try_parse_from([
            "schemify",
            "plugin",
            "install",
            "--from-file",
            "/tmp/plugin.tar.gz",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::Plugin {
                action:
                    plugin_cli::PluginCommand::Install {
                        source, from_file, ..
                    },
            }) => {
                assert_eq!(source, "/tmp/plugin.tar.gz");
                assert!(*from_file);
            }
            _ => panic!("expected Plugin Install with --from-file"),
        }
    }

    #[test]
    fn plugin_uninstall() {
        let cli = Cli::try_parse_from(["schemify", "plugin", "uninstall", "my-plugin"]).unwrap();
        match &cli.command {
            Some(CliCommand::Plugin {
                action: plugin_cli::PluginCommand::Uninstall { id, keep_data },
            }) => {
                assert_eq!(id, "my-plugin");
                assert!(!keep_data);
            }
            _ => panic!("expected Plugin Uninstall"),
        }
    }

    #[test]
    fn plugin_uninstall_keep_data() {
        let cli = Cli::try_parse_from([
            "schemify",
            "plugin",
            "uninstall",
            "--keep-data",
            "my-plugin",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::Plugin {
                action: plugin_cli::PluginCommand::Uninstall { keep_data, .. },
            }) => {
                assert!(*keep_data);
            }
            _ => panic!("expected Plugin Uninstall with --keep-data"),
        }
    }

    #[test]
    fn plugin_list() {
        let cli = Cli::try_parse_from(["schemify", "plugin", "list"]).unwrap();
        assert!(matches!(
            cli.command,
            Some(CliCommand::Plugin {
                action: plugin_cli::PluginCommand::List
            })
        ));
    }

    // ── parse_tool ──────────────────────────────────────

    #[test]
    fn parse_tool_all_valid() {
        let cases = [
            ("select", Tool::Select),
            ("wire", Tool::Wire),
            ("move", Tool::Move),
            ("pan", Tool::Pan),
            ("line", Tool::Line),
            ("rect", Tool::Rect),
            ("polygon", Tool::Polygon),
            ("arc", Tool::Arc),
            ("circle", Tool::Circle),
            ("text", Tool::Text),
        ];
        for (input, expected) in cases {
            let result = parse_tool(input).unwrap();
            assert_eq!(result, expected, "parse_tool({input:?}) mismatch");
        }
    }

    #[test]
    fn parse_tool_unknown_returns_error() {
        let err = parse_tool("foobar").unwrap_err();
        assert!(err.contains("unknown tool"), "error was: {err}");
    }

    #[test]
    fn parse_tool_empty_string() {
        assert!(parse_tool("").is_err());
    }

    #[test]
    fn parse_tool_case_sensitive() {
        assert!(parse_tool("Select").is_err());
        assert!(parse_tool("WIRE").is_err());
        assert!(parse_tool("Wire").is_err());
    }

    // ── parse_color ─────────────────────────────────────

    #[test]
    fn parse_color_6_char_rgb() {
        let c = parse_color("FF8000").unwrap();
        assert_eq!((c.r, c.g, c.b, c.a), (255, 128, 0, 255));
    }

    #[test]
    fn parse_color_8_char_rgba() {
        let c = parse_color("FF800080").unwrap();
        assert_eq!((c.r, c.g, c.b, c.a), (255, 128, 0, 128));
    }

    #[test]
    fn parse_color_with_hash_prefix() {
        let c = parse_color("#00FF00").unwrap();
        assert_eq!((c.r, c.g, c.b, c.a), (0, 255, 0, 255));
    }

    #[test]
    fn parse_color_hash_8_char() {
        let c = parse_color("#AABBCCDD").unwrap();
        assert_eq!((c.r, c.g, c.b, c.a), (0xAA, 0xBB, 0xCC, 0xDD));
    }

    #[test]
    fn parse_color_black() {
        let c = parse_color("000000").unwrap();
        assert_eq!((c.r, c.g, c.b, c.a), (0, 0, 0, 255));
    }

    #[test]
    fn parse_color_white() {
        let c = parse_color("FFFFFF").unwrap();
        assert_eq!((c.r, c.g, c.b, c.a), (255, 255, 255, 255));
    }

    #[test]
    fn parse_color_fully_transparent() {
        let c = parse_color("FF000000").unwrap();
        assert_eq!(c.a, 0);
    }

    #[test]
    fn parse_color_wrong_length() {
        assert!(parse_color("FFF").is_err());
        assert!(parse_color("FFFFF").is_err());
        assert!(parse_color("FFFFFFFFF").is_err());
        assert!(parse_color("F").is_err());
    }

    #[test]
    fn parse_color_invalid_hex_chars() {
        assert!(parse_color("ZZZZZZ").is_err());
        assert!(parse_color("GG0000").is_err());
    }

    #[test]
    fn parse_color_empty_string() {
        assert!(parse_color("").is_err());
    }

    #[test]
    fn parse_color_lowercase_hex() {
        let c = parse_color("abcdef").unwrap();
        assert_eq!((c.r, c.g, c.b, c.a), (0xAB, 0xCD, 0xEF, 255));
    }

    // ── to_command mapping ──────────────────────────────

    #[test]
    fn to_command_simple_variants() {
        assert!(matches!(to_command(CliCommand::ZoomIn), Command::ZoomIn));
        assert!(matches!(to_command(CliCommand::ZoomOut), Command::ZoomOut));
        assert!(matches!(to_command(CliCommand::ZoomFit), Command::ZoomFit));
        assert!(matches!(
            to_command(CliCommand::ZoomReset),
            Command::ZoomReset
        ));
        assert!(matches!(
            to_command(CliCommand::ToggleFullscreen),
            Command::ToggleFullscreen
        ));
        assert!(matches!(
            to_command(CliCommand::ToggleColorScheme),
            Command::ToggleColorScheme
        ));
        assert!(matches!(
            to_command(CliCommand::ToggleGrid),
            Command::ToggleGrid
        ));
        assert!(matches!(to_command(CliCommand::FileNew), Command::FileNew));
        assert!(matches!(
            to_command(CliCommand::FileOpen),
            Command::FileOpen
        ));
        assert!(matches!(
            to_command(CliCommand::FileSave),
            Command::FileSave
        ));
        assert!(matches!(
            to_command(CliCommand::FileSaveAs),
            Command::FileSaveAs
        ));
        assert!(matches!(to_command(CliCommand::NewTab), Command::NewTab));
        assert!(matches!(
            to_command(CliCommand::ReloadFromDisk),
            Command::ReloadFromDisk
        ));
        assert!(matches!(
            to_command(CliCommand::SelectAll),
            Command::SelectAll
        ));
        assert!(matches!(
            to_command(CliCommand::SelectNone),
            Command::SelectNone
        ));
        assert!(matches!(
            to_command(CliCommand::InvertSelection),
            Command::InvertSelection
        ));
        assert!(matches!(to_command(CliCommand::Copy), Command::Copy));
        assert!(matches!(to_command(CliCommand::Cut), Command::Cut));
        assert!(matches!(to_command(CliCommand::Paste), Command::Paste));
        assert!(matches!(to_command(CliCommand::Undo), Command::Undo));
        assert!(matches!(to_command(CliCommand::Redo), Command::Redo));
        assert!(matches!(
            to_command(CliCommand::DeleteSelected),
            Command::DeleteSelected
        ));
        assert!(matches!(
            to_command(CliCommand::DuplicateSelected),
            Command::DuplicateSelected
        ));
        assert!(matches!(
            to_command(CliCommand::RotateCw),
            Command::RotateCw
        ));
        assert!(matches!(
            to_command(CliCommand::RotateCcw),
            Command::RotateCcw
        ));
        assert!(matches!(
            to_command(CliCommand::FlipHorizontal),
            Command::FlipHorizontal
        ));
        assert!(matches!(
            to_command(CliCommand::FlipVertical),
            Command::FlipVertical
        ));
        assert!(matches!(to_command(CliCommand::NudgeUp), Command::NudgeUp));
        assert!(matches!(
            to_command(CliCommand::NudgeDown),
            Command::NudgeDown
        ));
        assert!(matches!(
            to_command(CliCommand::NudgeLeft),
            Command::NudgeLeft
        ));
        assert!(matches!(
            to_command(CliCommand::NudgeRight),
            Command::NudgeRight
        ));
        assert!(matches!(
            to_command(CliCommand::AlignToGrid),
            Command::AlignToGrid
        ));
        assert!(matches!(to_command(CliCommand::RunSim), Command::RunSim));
        assert!(matches!(
            to_command(CliCommand::AutoLayout),
            Command::AutoLayout
        ));
        assert!(matches!(
            to_command(CliCommand::PluginsRefresh),
            Command::PluginsRefresh
        ));
        assert!(matches!(
            to_command(CliCommand::OpenFindDialog),
            Command::OpenFindDialog
        ));
        assert!(matches!(
            to_command(CliCommand::OpenPropsDialog),
            Command::OpenPropsDialog
        ));
        assert!(matches!(
            to_command(CliCommand::OpenSettings),
            Command::OpenSettings
        ));
        assert!(matches!(
            to_command(CliCommand::OpenSpiceCodeEditor),
            Command::OpenSpiceCodeEditor
        ));
        assert!(matches!(
            to_command(CliCommand::OpenNewPrimDialog),
            Command::OpenNewPrimDialog
        ));
        assert!(matches!(
            to_command(CliCommand::OpenMarketplace),
            Command::OpenMarketplace
        ));
        assert!(matches!(
            to_command(CliCommand::OpenImportDialog),
            Command::OpenImportDialog
        ));
    }

    #[test]
    fn to_command_close_tab() {
        match to_command(CliCommand::CloseTab { index: 3 }) {
            Command::CloseTab(i) => assert_eq!(i, 3),
            other => panic!("expected CloseTab, got {other:?}"),
        }
    }

    #[test]
    fn to_command_switch_tab() {
        match to_command(CliCommand::SwitchTab { index: 0 }) {
            Command::SwitchTab(i) => assert_eq!(i, 0),
            other => panic!("expected SwitchTab, got {other:?}"),
        }
    }

    #[test]
    fn to_command_delete_instance() {
        match to_command(CliCommand::DeleteInstance { idx: 7 }) {
            Command::DeleteInstance(i) => assert_eq!(i, 7),
            other => panic!("expected DeleteInstance, got {other:?}"),
        }
    }

    #[test]
    fn to_command_delete_wire() {
        match to_command(CliCommand::DeleteWire { idx: 4 }) {
            Command::DeleteWire(i) => assert_eq!(i, 4),
            other => panic!("expected DeleteWire, got {other:?}"),
        }
    }

    #[test]
    fn to_command_import_spice() {
        match to_command(CliCommand::ImportSpice {
            path: "circuit.sp".into(),
        }) {
            Command::ImportSpice { path } => assert_eq!(path, "circuit.sp"),
            other => panic!("expected ImportSpice, got {other:?}"),
        }
    }

    #[test]
    fn to_command_place_device() {
        match to_command(CliCommand::PlaceDevice {
            symbol_path: "nmos4".into(),
            name: "M1".into(),
            x: 10,
            y: 20,
            rotation: 2,
            flip: true,
        }) {
            Command::PlaceDevice {
                symbol_path,
                name,
                x,
                y,
                rotation,
                flip,
            } => {
                assert_eq!(symbol_path, "nmos4");
                assert_eq!(name, "M1");
                assert_eq!((x, y), (10, 20));
                assert_eq!(rotation, 2);
                assert!(flip);
            }
            other => panic!("expected PlaceDevice, got {other:?}"),
        }
    }

    #[test]
    fn to_command_add_wire() {
        match to_command(CliCommand::AddWire {
            x0: 0,
            y0: 0,
            x1: 100,
            y1: 0,
            net_name: Some("net1".into()),
            bus: false,
        }) {
            Command::AddWire {
                x0,
                y0,
                x1,
                y1,
                net_name,
                bus,
            } => {
                assert_eq!((x0, y0, x1, y1), (0, 0, 100, 0));
                assert_eq!(net_name.as_deref(), Some("net1"));
                assert!(!bus);
            }
            other => panic!("expected AddWire, got {other:?}"),
        }
    }

    #[test]
    fn to_command_add_line() {
        match to_command(CliCommand::AddLine {
            x0: 1,
            y0: 2,
            x1: 3,
            y1: 4,
        }) {
            Command::AddLine { x0, y0, x1, y1 } => {
                assert_eq!((x0, y0, x1, y1), (1, 2, 3, 4));
            }
            other => panic!("expected AddLine, got {other:?}"),
        }
    }

    #[test]
    fn to_command_add_rect() {
        match to_command(CliCommand::AddRect {
            x: 5,
            y: 6,
            w: 7,
            h: 8,
        }) {
            Command::AddRect { x, y, w, h } => {
                assert_eq!((x, y, w, h), (5, 6, 7, 8));
            }
            other => panic!("expected AddRect, got {other:?}"),
        }
    }

    #[test]
    fn to_command_add_circle() {
        match to_command(CliCommand::AddCircle {
            cx: 10,
            cy: 20,
            radius: 30,
        }) {
            Command::AddCircle { cx, cy, radius } => {
                assert_eq!((cx, cy, radius), (10, 20, 30));
            }
            other => panic!("expected AddCircle, got {other:?}"),
        }
    }

    #[test]
    fn to_command_add_arc() {
        match to_command(CliCommand::AddArc {
            cx: 5,
            cy: 10,
            radius: 15,
            start: 0.5,
            sweep: 2.5,
        }) {
            Command::AddArc {
                cx,
                cy,
                radius,
                start,
                sweep,
            } => {
                assert_eq!((cx, cy, radius), (5, 10, 15));
                assert!((start - 0.5).abs() < f32::EPSILON);
                assert!((sweep - 2.5).abs() < f32::EPSILON);
            }
            other => panic!("expected AddArc, got {other:?}"),
        }
    }

    #[test]
    fn to_command_add_text() {
        match to_command(CliCommand::AddText {
            x: 1,
            y: 2,
            content: "hello".into(),
        }) {
            Command::AddText { x, y, content } => {
                assert_eq!((x, y), (1, 2));
                assert_eq!(content, "hello");
            }
            other => panic!("expected AddText, got {other:?}"),
        }
    }

    #[test]
    fn to_command_move_instance() {
        match to_command(CliCommand::MoveInstance {
            idx: 2,
            dx: -10,
            dy: 5,
        }) {
            Command::MoveInstance { idx, dx, dy } => {
                assert_eq!(idx, 2);
                assert_eq!((dx, dy), (-10, 5));
            }
            other => panic!("expected MoveInstance, got {other:?}"),
        }
    }

    #[test]
    fn to_command_move_wire() {
        match to_command(CliCommand::MoveWire {
            idx: 3,
            dx: 1,
            dy: -1,
        }) {
            Command::MoveWire { idx, dx, dy } => {
                assert_eq!(idx, 3);
                assert_eq!((dx, dy), (1, -1));
            }
            other => panic!("expected MoveWire, got {other:?}"),
        }
    }

    #[test]
    fn to_command_move_selected() {
        match to_command(CliCommand::MoveSelected { dx: 7, dy: -3 }) {
            Command::MoveSelected { dx, dy } => assert_eq!((dx, dy), (7, -3)),
            other => panic!("expected MoveSelected, got {other:?}"),
        }
    }

    #[test]
    fn to_command_set_instance_prop() {
        match to_command(CliCommand::SetInstanceProp {
            idx: 0,
            key: "W".into(),
            value: "1u".into(),
        }) {
            Command::SetInstanceProp { idx, key, value } => {
                assert_eq!(idx, 0);
                assert_eq!(key, "W");
                assert_eq!(value, "1u");
            }
            other => panic!("expected SetInstanceProp, got {other:?}"),
        }
    }

    #[test]
    fn to_command_rename_instance() {
        match to_command(CliCommand::RenameInstance {
            idx: 1,
            new_name: "M2".into(),
        }) {
            Command::RenameInstance { idx, new_name } => {
                assert_eq!(idx, 1);
                assert_eq!(new_name, "M2");
            }
            other => panic!("expected RenameInstance, got {other:?}"),
        }
    }

    #[test]
    fn to_command_rename_net() {
        match to_command(CliCommand::RenameNet {
            old_name: "net0".into(),
            new_name: "VDD".into(),
        }) {
            Command::RenameNet { old_name, new_name } => {
                assert_eq!(old_name, "net0");
                assert_eq!(new_name, "VDD");
            }
            other => panic!("expected RenameNet, got {other:?}"),
        }
    }

    #[test]
    fn to_command_set_spice_code() {
        match to_command(CliCommand::SetSpiceCode {
            code: ".subckt foo".into(),
        }) {
            Command::SetSpiceCode(code) => assert_eq!(code, ".subckt foo"),
            other => panic!("expected SetSpiceCode, got {other:?}"),
        }
    }

    #[test]
    fn to_command_set_documentation() {
        match to_command(CliCommand::SetDocumentation {
            doc: "docs here".into(),
        }) {
            Command::SetDocumentation(doc) => assert_eq!(doc, "docs here"),
            other => panic!("expected SetDocumentation, got {other:?}"),
        }
    }

    #[test]
    fn to_command_set_tool_valid() {
        match to_command(CliCommand::SetTool {
            tool: "select".into(),
        }) {
            Command::SetTool(t) => assert_eq!(t, Tool::Select),
            other => panic!("expected SetTool, got {other:?}"),
        }
    }

    #[test]
    fn to_command_set_wire_color_valid() {
        match to_command(CliCommand::SetWireColor {
            idx: 1,
            color: "00FF00".into(),
        }) {
            Command::SetWireColor { idx, color } => {
                assert_eq!(idx, 1);
                assert_eq!((color.r, color.g, color.b, color.a), (0, 255, 0, 255));
            }
            other => panic!("expected SetWireColor, got {other:?}"),
        }
    }

    #[test]
    fn to_command_set_stimulus_lang() {
        match to_command(CliCommand::SetStimulusLang {
            lang: "ngspice".into(),
        }) {
            Command::SetStimulusLang(lang) => assert_eq!(lang, "ngspice"),
            other => panic!("expected SetStimulusLang, got {other:?}"),
        }
    }

    #[test]
    fn to_command_set_sim_backend() {
        match to_command(CliCommand::SetSimBackend {
            backend: "xyce".into(),
        }) {
            Command::SetSimBackend(backend) => assert_eq!(backend, "xyce"),
            other => panic!("expected SetSimBackend, got {other:?}"),
        }
    }

    // ── Error paths ─────────────────────────────────────

    #[test]
    fn missing_required_arg_is_error() {
        // place-device requires --symbol-path, --name, --x, --y
        assert!(Cli::try_parse_from(["schemify", "place-device"]).is_err());
        assert!(
            Cli::try_parse_from(["schemify", "place-device", "--symbol-path", "nmos4",]).is_err()
        );
    }

    #[test]
    fn wrong_type_arg_is_error() {
        // close-tab expects usize, not a string
        assert!(Cli::try_parse_from(["schemify", "close-tab", "abc"]).is_err());
        // add-rect --x expects i32
        assert!(Cli::try_parse_from([
            "schemify",
            "add-rect",
            "--x",
            "not_a_number",
            "--y",
            "0",
            "--w",
            "1",
            "--h",
            "1",
        ])
        .is_err());
    }

    #[test]
    fn negative_coordinates_accepted() {
        // Use --key=value syntax for negative numbers (clap treats bare -N as flags).
        let cli = Cli::try_parse_from([
            "schemify",
            "add-line",
            "--x0=-100",
            "--y0=-50",
            "--x1",
            "100",
            "--y1",
            "50",
        ])
        .unwrap();
        match &cli.command {
            Some(CliCommand::AddLine { x0, y0, x1, y1 }) => {
                assert_eq!((*x0, *y0, *x1, *y1), (-100, -50, 100, 50));
            }
            _ => panic!("expected AddLine"),
        }
    }
}
