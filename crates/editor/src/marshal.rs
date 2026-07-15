//! JSON → [`Command`] marshaling: the lenient wire format shared by the
//! MCP server, the CLI, and the plugin host. Deliberately hand-written —
//! it accepts SI-suffix strings ("10n"), "A"/"B" cursor selectors, named
//! line styles, and optional fields with defaults, which a serde derive
//! could not express without polluting core's domain types.
//!
//! Lives in core because it changes exactly when [`Command`] changes
//! (common closure); the coverage test below makes that a compile-time
//! guarantee.

use anyhow::{anyhow, Context, Result};
use serde_json::Value;

use crate::schemify::{Color, Command, Tool};
use crate::wave::parse_si;

// ════════════════════════════════════════════════════════════

pub fn command_from_json(v: &Value) -> Result<Command> {
    if let Some(name) = v.as_str() {
        return unit_command(name).ok_or_else(|| anyhow!("unknown unit command '{name}'"));
    }
    let obj = v
        .as_object()
        .filter(|o| o.len() == 1)
        .context("command must be a string or a single-key {Variant: params} object")?;
    let (name, p) = obj.iter().next().unwrap();
    if let Some(cmd) = unit_command(name) {
        return Ok(cmd);
    }

    use Command::*;
    Ok(match name.as_str() {
        // Tuple variants
        "CloseTab" => CloseTab(scalar_usize(p)?),
        "SwitchTab" => SwitchTab(scalar_usize(p)?),
        "DeleteInstance" => DeleteInstance(scalar_usize(p)?),
        "DeleteWire" => DeleteWire(scalar_usize(p)?),
        "DeleteBus" => DeleteBus(scalar_usize(p)?),
        "DeleteBusRipper" => DeleteBusRipper(scalar_usize(p)?),
        "SetSpiceCode" => SetSpiceCode(scalar_str(p)?),
        "SetDocumentation" => SetDocumentation(scalar_str(p)?),
        "SetStimulusLang" => SetStimulusLang(scalar_str(p)?),
        "SetSimBackend" => SetSimBackend(scalar_str(p)?),
        "SetSimCorner" => SetSimCorner(scalar_str(p)?),
        "SetTool" => SetTool(tool_from_name(&scalar_str(p)?)?),

        // Struct variants
        "PlaceDevice" => PlaceDevice {
            symbol_path: req_str(p, "symbol_path")?,
            name: req_str(p, "name")?,
            x: num(p, "x")?,
            y: num(p, "y")?,
            rotation: opt_num(p, "rotation", 0u8)?,
            flip: p.get("flip").and_then(Value::as_bool).unwrap_or(false),
        },
        "AddWire" => AddWire {
            x0: num(p, "x0")?,
            y0: num(p, "y0")?,
            x1: num(p, "x1")?,
            y1: num(p, "y1")?,
        },
        "AddLine" => AddLine {
            x0: num(p, "x0")?,
            y0: num(p, "y0")?,
            x1: num(p, "x1")?,
            y1: num(p, "y1")?,
        },
        "AddRect" => AddRect {
            x: num(p, "x")?,
            y: num(p, "y")?,
            w: num(p, "w")?,
            h: num(p, "h")?,
        },
        "AddCircle" => AddCircle {
            cx: num(p, "cx")?,
            cy: num(p, "cy")?,
            radius: num(p, "radius")?,
        },
        "AddArc" => AddArc {
            cx: num(p, "cx")?,
            cy: num(p, "cy")?,
            radius: num(p, "radius")?,
            start: float(p, "start")?,
            sweep: float(p, "sweep")?,
        },
        "AddText" => AddText {
            x: num(p, "x")?,
            y: num(p, "y")?,
            content: req_str(p, "content")?,
        },
        "AddPolygon" => AddPolygon {
            points: points_array(p)?,
        },
        "MoveInstance" => MoveInstance {
            idx: num(p, "idx")?,
            dx: num(p, "dx")?,
            dy: num(p, "dy")?,
        },
        "MoveWire" => MoveWire {
            idx: num(p, "idx")?,
            dx: num(p, "dx")?,
            dy: num(p, "dy")?,
        },
        "MoveSelected" => MoveSelected {
            dx: num(p, "dx")?,
            dy: num(p, "dy")?,
        },
        "SetInstanceProp" => SetInstanceProp {
            idx: num(p, "idx")?,
            key: req_str(p, "key")?,
            value: req_str(p, "value")?,
        },
        "RenameInstance" => RenameInstance {
            idx: num(p, "idx")?,
            new_name: req_str(p, "new_name")?,
        },
        "SetWireColor" => SetWireColor {
            idx: num(p, "idx")?,
            color: Color::from_hex(&req_str(p, "color")?).map_err(|e| anyhow!(e))?,
        },
        "AddBus" => AddBus {
            label: req_str(p, "label")?,
            width: num(p, "width")?,
            start_bit: opt_num(p, "start_bit", 0u16)?,
            x0: num(p, "x0")?,
            y0: num(p, "y0")?,
            x1: num(p, "x1")?,
            y1: num(p, "y1")?,
        },
        "SetBusWidth" => SetBusWidth {
            idx: num(p, "idx")?,
            width: num(p, "width")?,
        },
        "RenameBus" => RenameBus {
            idx: num(p, "idx")?,
            new_name: req_str(p, "new_name")?,
        },
        "AddBusRipper" => AddBusRipper {
            bus_idx: num(p, "bus_idx")?,
            bit: num(p, "bit")?,
            x: num(p, "x")?,
            y: num(p, "y")?,
            direction: opt_num(p, "direction", 0u8)?,
        },
        "SplitWire" => SplitWire {
            idx: num(p, "idx")?,
            x: num(p, "x")?,
            y: num(p, "y")?,
        },
        "ExportSpice" => ExportSpice {
            path: req_str(p, "path")?,
        },
        "ImportSpice" => ImportSpice {
            path: req_str(p, "path")?,
        },
        "MarketplaceInstall" => MarketplaceInstall {
            name: req_str(p, "name")?,
        },
        "MarketplaceUninstall" => MarketplaceUninstall {
            name: req_str(p, "name")?,
        },

        // Waveform viewer. {"WaveOpen": "f.raw"} and {"WaveOpen": {"path":
        // "f.raw"}} both accepted; x positions accept numbers or SI-suffix
        // strings ("10n", "2.5meg").
        "WaveOpen" => WaveOpen {
            path: scalar_str(p).or_else(|_| req_str(p, "path"))?,
        },
        "WaveAddTrace" => WaveAddTrace {
            expr: scalar_str(p).or_else(|_| req_str(p, "expr"))?,
            file: opt_u16(p, "file")?,
            block: opt_num(p, "block", 0u16)?,
            pane: opt_u16(p, "pane")?,
        },
        "WaveRemoveTrace" => WaveRemoveTrace(scalar_usize(p)? as u32),
        "WaveSetTraceStyle" => WaveSetTraceStyle {
            idx: num(p, "idx")?,
            color: match p.get("color").and_then(Value::as_str) {
                Some(hex) => Color::from_hex(hex).map_err(|e| anyhow!(e))?,
                None => Color::NONE, // auto palette
            },
            width: p
                .get("width")
                .and_then(Value::as_f64)
                .map(|f| f as f32)
                .unwrap_or(1.5),
            line_style: line_style_code(p)?,
            visible: p.get("visible").and_then(Value::as_bool).unwrap_or(true),
        },
        "WaveRemovePane" => WaveRemovePane(scalar_u16(p)?),
        "WaveSetActivePane" => WaveSetActivePane(scalar_u16(p)?),
        "WaveSetCursor" => WaveSetCursor {
            cursor: cursor_code(p)?,
            x: f64_or_si(p, "x")?,
            visible: p.get("visible").and_then(Value::as_bool).unwrap_or(true),
        },
        "WaveSetXLog" => WaveSetXLog(
            p.as_bool()
                .or_else(|| p.get("on").and_then(Value::as_bool))
                .ok_or_else(|| anyhow!("expected boolean payload"))?,
        ),
        "WaveSetXRange" => WaveSetXRange {
            min: f64_or_si(p, "min")?,
            max: f64_or_si(p, "max")?,
        },
        "WaveSetYRange" => WaveSetYRange {
            pane: opt_num(p, "pane", 0u16)?,
            min: f64_or_si(p, "min")?,
            max: f64_or_si(p, "max")?,
        },
        "WaveExportCsv" => WaveExportCsv {
            path: scalar_str(p).or_else(|_| req_str(p, "path"))?,
        },

        // Optimizer. {"OptimizerNew": "amp"} and {"OptimizerNew": {"name":
        // "amp"}} both accepted; bounds accept numbers or SI-suffix strings.
        "OptimizerNew" => OptimizerNew {
            name: scalar_str(p)
                .ok()
                .or_else(|| p.get("name").and_then(Value::as_str).map(ToOwned::to_owned))
                .unwrap_or_default(),
        },
        "OptimizerClose" => OptimizerClose { id: num(p, "id")? },
        "OptimizerSetWindowOpen" => OptimizerSetWindowOpen {
            id: num(p, "id")?,
            open: req_bool(p, "open")?,
        },
        "OptimizerAddParam" => OptimizerAddParam {
            id: num(p, "id")?,
            name: req_str(p, "name")?,
            min: f64_or_si(p, "min")?,
            max: f64_or_si(p, "max")?,
            init: f64_or_si(p, "init")?,
        },
        "OptimizerRemoveParam" => OptimizerRemoveParam {
            id: num(p, "id")?,
            name: req_str(p, "name")?,
        },
        "OptimizerAddObjective" => OptimizerAddObjective {
            id: num(p, "id")?,
            name: req_str(p, "name")?,
            target: target_str(p)?,
            weight: opt_f64(p, "weight", 1.0)?,
        },
        "OptimizerRemoveObjective" => OptimizerRemoveObjective {
            id: num(p, "id")?,
            name: req_str(p, "name")?,
        },
        "OptimizerSetAlgorithm" => OptimizerSetAlgorithm {
            id: num(p, "id")?,
            algorithm: req_str(p, "algorithm")?,
        },
        "OptimizerReport" => OptimizerReport {
            id: num(p, "id")?,
            params: opt_f64_vec(p, "params")?,
            measured: f64_vec(p, "measured")?,
        },
        "OptimizerReset" => OptimizerReset { id: num(p, "id")? },

        other => return Err(anyhow!("unknown command '{other}'")),
    })
}

fn unit_command(name: &str) -> Option<Command> {
    use Command::*;
    Some(match name {
        "ZoomIn" => ZoomIn,
        "ZoomOut" => ZoomOut,
        "ZoomFit" => ZoomFit,
        "ZoomReset" => ZoomReset,
        "ToggleFullscreen" => ToggleFullscreen,
        "ToggleColorScheme" => ToggleColorScheme,
        "ToggleGrid" => ToggleGrid,
        "FileNew" => FileNew,
        "FileOpen" => FileOpen,
        "FileSave" => FileSave,
        "FileSaveAs" => FileSaveAs,
        "NewTab" => NewTab,
        "CloseActiveTab" => CloseActiveTab,
        "ReloadFromDisk" => ReloadFromDisk,
        "SelectAll" => SelectAll,
        "SelectNone" => SelectNone,
        "InvertSelection" => InvertSelection,
        "Copy" => Copy,
        "Cut" => Cut,
        "Paste" => Paste,
        "OpenFindDialog" => OpenFindDialog,
        "OpenPropsDialog" => OpenPropsDialog,
        "OpenSettings" => OpenSettings,
        "OpenSpiceCodeEditor" => OpenSpiceCodeEditor,
        "OpenNewPrimDialog" => OpenNewPrimDialog,
        "OpenMarketplace" => OpenMarketplace,
        "OpenImportDialog" => OpenImportDialog,
        "OpenLibraryBrowser" => OpenLibraryBrowser,
        "OpenFileExplorer" => OpenFileExplorer,
        "Undo" => Undo,
        "Redo" => Redo,
        "DeleteSelected" => DeleteSelected,
        "DuplicateSelected" => DuplicateSelected,
        "RotateCw" => RotateCw,
        "RotateCcw" => RotateCcw,
        "FlipHorizontal" => FlipHorizontal,
        "FlipVertical" => FlipVertical,
        "NudgeUp" => NudgeUp,
        "NudgeDown" => NudgeDown,
        "NudgeLeft" => NudgeLeft,
        "NudgeRight" => NudgeRight,
        "AlignToGrid" => AlignToGrid,
        "RunSim" => RunSim,
        "ExportNetlist" => ExportNetlist,
        "GenerateSymbolFromSchematic" => GenerateSymbolFromSchematic,
        "AlignLeft" => AlignLeft,
        "AlignRight" => AlignRight,
        "AlignTop" => AlignTop,
        "AlignBottom" => AlignBottom,
        "AlignCenterH" => AlignCenterH,
        "AlignCenterV" => AlignCenterV,
        "DistributeH" => DistributeH,
        "DistributeV" => DistributeV,
        "MarketplaceFetch" => MarketplaceFetch,
        "PluginsRefresh" => PluginsRefresh,
        "ReloadProjectConfig" => ReloadProjectConfig,
        "WaveReload" => WaveReload,
        "WaveClearTraces" => WaveClearTraces,
        "WaveAddPane" => WaveAddPane,
        "WaveZoomFit" => WaveZoomFit,
        _ => return None,
    })
}

fn tool_from_name(s: &str) -> Result<Tool> {
    Ok(match s.to_ascii_lowercase().as_str() {
        "select" => Tool::Select,
        "wire" => Tool::Wire,
        "bus" => Tool::Bus,
        "busripper" | "bus_ripper" => Tool::BusRipper,
        "move" => Tool::Move,
        "pan" => Tool::Pan,
        "line" => Tool::Line,
        "rect" => Tool::Rect,
        "polygon" => Tool::Polygon,
        "arc" => Tool::Arc,
        "circle" => Tool::Circle,
        "text" => Tool::Text,
        other => return Err(anyhow!("unknown tool '{other}'")),
    })
}

/// Required integer field, range-checked into the target type.
/// Required string param.
pub fn req_str(params: &Value, key: &str) -> Result<String> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| anyhow!("missing string parameter '{key}'"))
}

pub fn num<T: TryFrom<i64>>(p: &Value, key: &str) -> Result<T> {
    let n = p
        .get(key)
        .and_then(Value::as_i64)
        .ok_or_else(|| anyhow!("missing integer parameter '{key}'"))?;
    T::try_from(n).map_err(|_| anyhow!("parameter '{key}' out of range"))
}

/// Optional integer field with default.
pub fn opt_num<T: TryFrom<i64>>(p: &Value, key: &str, default: T) -> Result<T> {
    match p.get(key) {
        None | Some(Value::Null) => Ok(default),
        Some(_) => num(p, key),
    }
}

fn float(p: &Value, key: &str) -> Result<f32> {
    p.get(key)
        .and_then(Value::as_f64)
        .map(|f| f as f32)
        .ok_or_else(|| anyhow!("missing number parameter '{key}'"))
}

fn scalar_usize(p: &Value) -> Result<usize> {
    p.as_u64()
        .map(|n| n as usize)
        .ok_or_else(|| anyhow!("expected integer payload"))
}

fn scalar_u16(p: &Value) -> Result<u16> {
    scalar_usize(p).and_then(|n| u16::try_from(n).map_err(|_| anyhow!("index out of range")))
}

/// Optional u16 field — absent/null stays `None` (core picks the default).
fn opt_u16(p: &Value, key: &str) -> Result<Option<u16>> {
    match p.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(_) => num(p, key).map(Some),
    }
}

/// Required f64 accepting a JSON number or an SI-suffix string ("10n").
pub fn f64_or_si(p: &Value, key: &str) -> Result<f64> {
    match p.get(key) {
        Some(Value::Number(n)) => n
            .as_f64()
            .ok_or_else(|| anyhow!("parameter '{key}' is not a finite number")),
        Some(Value::String(s)) => parse_si(s)
            .ok_or_else(|| anyhow!("parameter '{key}': cannot parse '{s}'")),
        _ => Err(anyhow!("missing number parameter '{key}'")),
    }
}

/// Optional f64 (number or SI-suffix string) with default.
pub fn opt_f64(p: &Value, key: &str, default: f64) -> Result<f64> {
    match p.get(key) {
        None | Some(Value::Null) => Ok(default),
        Some(_) => f64_or_si(p, key),
    }
}

/// Required boolean field.
pub fn req_bool(p: &Value, key: &str) -> Result<bool> {
    p.get(key)
        .and_then(Value::as_bool)
        .ok_or_else(|| anyhow!("missing boolean parameter '{key}'"))
}

/// Required array of f64.
pub fn f64_vec(p: &Value, key: &str) -> Result<Vec<f64>> {
    p.get(key)
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("missing array parameter '{key}'"))?
        .iter()
        .map(|v| {
            v.as_f64()
                .ok_or_else(|| anyhow!("parameter '{key}' must be an array of numbers"))
        })
        .collect()
}

/// Optional array of f64 — absent/null stays `None`.
pub fn opt_f64_vec(p: &Value, key: &str) -> Result<Option<Vec<f64>>> {
    match p.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(_) => f64_vec(p, key).map(Some),
    }
}

/// Objective target: "min", "max", or a number (string or JSON number) to
/// approach. Core parses the string; numbers pass through as their text.
pub fn target_str(p: &Value) -> Result<String> {
    match p.get("target") {
        Some(Value::String(s)) => Ok(s.clone()),
        Some(Value::Number(n)) => Ok(n.to_string()),
        _ => Err(anyhow!(
            "missing parameter 'target' (\"min\", \"max\", or a number)"
        )),
    }
}

/// Cursor selector: "A"/"B" (case-insensitive) or 0/1.
fn cursor_code(p: &Value) -> Result<u8> {
    match p.get("cursor") {
        Some(Value::String(s)) if s.eq_ignore_ascii_case("a") => Ok(0),
        Some(Value::String(s)) if s.eq_ignore_ascii_case("b") => Ok(1),
        Some(Value::Number(n)) if n.as_u64() == Some(0) => Ok(0),
        Some(Value::Number(n)) if n.as_u64() == Some(1) => Ok(1),
        _ => Err(anyhow!("cursor must be \"A\", \"B\", 0, or 1")),
    }
}

/// Line style: "solid"/"dash"/"dot" or 0/1/2; default solid.
fn line_style_code(p: &Value) -> Result<u8> {
    match p.get("line_style") {
        None | Some(Value::Null) => Ok(0),
        Some(Value::String(s)) => match s.to_ascii_lowercase().as_str() {
            "solid" => Ok(0),
            "dash" | "dashed" => Ok(1),
            "dot" | "dotted" => Ok(2),
            other => Err(anyhow!("unknown line style '{other}'")),
        },
        Some(Value::Number(n)) if n.as_u64().is_some_and(|v| v <= 2) => {
            Ok(n.as_u64().unwrap() as u8)
        }
        _ => Err(anyhow!("line_style must be solid|dash|dot or 0..=2")),
    }
}

fn scalar_str(p: &Value) -> Result<String> {
    p.as_str()
        .map(ToOwned::to_owned)
        .ok_or_else(|| anyhow!("expected string payload"))
}

fn points_array(p: &Value) -> Result<Vec<[i32; 2]>> {
    p.get("points")
        .and_then(Value::as_array)
        .context("missing 'points' array")?
        .iter()
        .map(|pt| {
            let xy = pt.as_array().filter(|a| a.len() == 2)?;
            Some([xy[0].as_i64()? as i32, xy[1].as_i64()? as i32])
        })
        .collect::<Option<Vec<_>>>()
        .context("polygon points must be [x, y] integer pairs")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Compile-time coverage: every Command variant maps to its wire name.
    /// Adding a Command variant breaks this match — extend it AND the
    /// marshaler above. No wildcard, ever.
    fn wire_name(cmd: &Command) -> &'static str {
        use Command::*;
        match cmd {
            ZoomIn => "ZoomIn",
            ZoomOut => "ZoomOut",
            ZoomFit => "ZoomFit",
            ZoomReset => "ZoomReset",
            ToggleFullscreen => "ToggleFullscreen",
            ToggleColorScheme => "ToggleColorScheme",
            ToggleGrid => "ToggleGrid",
            FileNew => "FileNew",
            FileOpen => "FileOpen",
            FileSave => "FileSave",
            FileSaveAs => "FileSaveAs",
            NewTab => "NewTab",
            CloseTab(_) => "CloseTab",
            CloseActiveTab => "CloseActiveTab",
            SwitchTab(_) => "SwitchTab",
            ReloadFromDisk => "ReloadFromDisk",
            SelectAll => "SelectAll",
            SelectNone => "SelectNone",
            InvertSelection => "InvertSelection",
            Copy => "Copy",
            Cut => "Cut",
            Paste => "Paste",
            SetTool(_) => "SetTool",
            OpenFindDialog => "OpenFindDialog",
            OpenPropsDialog => "OpenPropsDialog",
            OpenSettings => "OpenSettings",
            OpenSpiceCodeEditor => "OpenSpiceCodeEditor",
            OpenNewPrimDialog => "OpenNewPrimDialog",
            OpenMarketplace => "OpenMarketplace",
            OpenImportDialog => "OpenImportDialog",
            OpenLibraryBrowser => "OpenLibraryBrowser",
            OpenFileExplorer => "OpenFileExplorer",
            Undo => "Undo",
            Redo => "Redo",
            DeleteSelected => "DeleteSelected",
            DeleteInstance(_) => "DeleteInstance",
            DeleteWire(_) => "DeleteWire",
            DuplicateSelected => "DuplicateSelected",
            RotateCw => "RotateCw",
            RotateCcw => "RotateCcw",
            FlipHorizontal => "FlipHorizontal",
            FlipVertical => "FlipVertical",
            NudgeUp => "NudgeUp",
            NudgeDown => "NudgeDown",
            NudgeLeft => "NudgeLeft",
            NudgeRight => "NudgeRight",
            AlignToGrid => "AlignToGrid",
            PlaceDevice { .. } => "PlaceDevice",
            AddWire { .. } => "AddWire",
            AddLine { .. } => "AddLine",
            AddRect { .. } => "AddRect",
            AddCircle { .. } => "AddCircle",
            AddArc { .. } => "AddArc",
            AddText { .. } => "AddText",
            AddPolygon { .. } => "AddPolygon",
            MoveInstance { .. } => "MoveInstance",
            MoveWire { .. } => "MoveWire",
            MoveSelected { .. } => "MoveSelected",
            SetInstanceProp { .. } => "SetInstanceProp",
            RenameInstance { .. } => "RenameInstance",
            SetSpiceCode(_) => "SetSpiceCode",
            SetDocumentation(_) => "SetDocumentation",
            SetWireColor { .. } => "SetWireColor",
            RunSim => "RunSim",
            ExportNetlist => "ExportNetlist",
            SetStimulusLang(_) => "SetStimulusLang",
            SetSimBackend(_) => "SetSimBackend",
            SetSimCorner(_) => "SetSimCorner",
            GenerateSymbolFromSchematic => "GenerateSymbolFromSchematic",
            AddBus { .. } => "AddBus",
            DeleteBus(_) => "DeleteBus",
            SetBusWidth { .. } => "SetBusWidth",
            RenameBus { .. } => "RenameBus",
            AddBusRipper { .. } => "AddBusRipper",
            DeleteBusRipper(_) => "DeleteBusRipper",
            SplitWire { .. } => "SplitWire",
            AlignLeft => "AlignLeft",
            AlignRight => "AlignRight",
            AlignTop => "AlignTop",
            AlignBottom => "AlignBottom",
            AlignCenterH => "AlignCenterH",
            AlignCenterV => "AlignCenterV",
            DistributeH => "DistributeH",
            DistributeV => "DistributeV",
            ExportSpice { .. } => "ExportSpice",
            ImportSpice { .. } => "ImportSpice",
            MarketplaceFetch => "MarketplaceFetch",
            MarketplaceInstall { .. } => "MarketplaceInstall",
            MarketplaceUninstall { .. } => "MarketplaceUninstall",
            PluginsRefresh => "PluginsRefresh",
            PluginCommand { .. } => "PluginCommand",
            ReloadProjectConfig => "ReloadProjectConfig",
            WaveOpen { .. } => "WaveOpen",
            WaveReload => "WaveReload",
            WaveAddTrace { .. } => "WaveAddTrace",
            WaveRemoveTrace(_) => "WaveRemoveTrace",
            WaveClearTraces => "WaveClearTraces",
            WaveSetTraceStyle { .. } => "WaveSetTraceStyle",
            WaveAddPane => "WaveAddPane",
            WaveRemovePane(_) => "WaveRemovePane",
            WaveSetActivePane(_) => "WaveSetActivePane",
            WaveSetCursor { .. } => "WaveSetCursor",
            WaveSetXLog(_) => "WaveSetXLog",
            WaveSetXRange { .. } => "WaveSetXRange",
            WaveSetYRange { .. } => "WaveSetYRange",
            WaveZoomFit => "WaveZoomFit",
            WaveExportCsv { .. } => "WaveExportCsv",
            OptimizerNew { .. } => "OptimizerNew",
            OptimizerClose { .. } => "OptimizerClose",
            OptimizerSetWindowOpen { .. } => "OptimizerSetWindowOpen",
            OptimizerAddParam { .. } => "OptimizerAddParam",
            OptimizerRemoveParam { .. } => "OptimizerRemoveParam",
            OptimizerAddObjective { .. } => "OptimizerAddObjective",
            OptimizerRemoveObjective { .. } => "OptimizerRemoveObjective",
            OptimizerSetAlgorithm { .. } => "OptimizerSetAlgorithm",
            OptimizerReport { .. } => "OptimizerReport",
            OptimizerReset { .. } => "OptimizerReset",
        }
    }

    #[test]
    fn every_unit_command_decodes_by_name() {
        // Unit-like commands: string form must round-trip through the
        // marshaler back to a variant with the same wire name.
        for name in [
            "ZoomIn", "ZoomOut", "ZoomFit", "ZoomReset", "ToggleFullscreen",
            "ToggleColorScheme", "ToggleGrid", "FileNew", "FileOpen", "FileSave",
            "FileSaveAs", "NewTab", "CloseActiveTab", "ReloadFromDisk", "SelectAll",
            "SelectNone", "InvertSelection", "Copy", "Cut", "Paste", "OpenFindDialog",
            "OpenPropsDialog", "OpenSettings", "OpenSpiceCodeEditor", "OpenNewPrimDialog",
            "OpenMarketplace", "OpenImportDialog", "OpenLibraryBrowser", "OpenFileExplorer",
            "Undo", "Redo", "DeleteSelected", "DuplicateSelected", "RotateCw", "RotateCcw",
            "FlipHorizontal", "FlipVertical", "NudgeUp", "NudgeDown", "NudgeLeft",
            "NudgeRight", "AlignToGrid", "RunSim", "ExportNetlist",
            "GenerateSymbolFromSchematic", "AlignLeft", "AlignRight", "AlignTop",
            "AlignBottom", "AlignCenterH", "AlignCenterV", "DistributeH", "DistributeV",
            "MarketplaceFetch", "PluginsRefresh", "ReloadProjectConfig", "WaveReload",
            "WaveClearTraces", "WaveAddPane", "WaveZoomFit",
        ] {
            let cmd = command_from_json(&json!(name))
                .unwrap_or_else(|e| panic!("{name} failed to decode: {e}"));
            assert_eq!(wire_name(&cmd), name);
        }
    }

    #[test]
    fn struct_commands_decode_with_si_suffixes() {
        let cmd = command_from_json(
            &json!({"MoveInstance": {"idx": 3, "dx": -20, "dy": 40}}),
        )
        .unwrap();
        assert_eq!(wire_name(&cmd), "MoveInstance");

        let cmd = command_from_json(
            &json!({"WaveSetXRange": {"min": "10n", "max": "1u"}}),
        )
        .unwrap();
        match cmd {
            Command::WaveSetXRange { min, max } => {
                assert!((min - 1e-8).abs() < 1e-20);
                assert!((max - 1e-6).abs() < 1e-18);
            }
            other => panic!("wrong decode: {other:?}"),
        }

        let cmd = command_from_json(&json!({"WaveSetCursor": {"cursor": "B", "x": 1.0}})).unwrap();
        assert_eq!(wire_name(&cmd), "WaveSetCursor");
    }
}
