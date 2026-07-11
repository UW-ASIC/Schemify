//! Waveform viewer state — lives on a `Document` (`doc.wave: Some(_)` makes
//! the tab a waveform tab). Pure state + transformations; rendering lives in
//! the display crate, transport in CLI/MCP via the shared `Command` enum.

use crate::schemify::Color;
use schemify_wave::{eval, parse_expr, EvalResult, RawPlot};
// Re-export for consumers (display SI tick labels, MCP SI parsing).
pub use schemify_wave::{format_si, parse_si};
use std::path::{Path, PathBuf};

// ════════════════════════════════════════════════════════════
// Style
// ════════════════════════════════════════════════════════════

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum LineStyle {
    #[default]
    Solid = 0,
    Dash,
    Dot,
}

impl LineStyle {
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => LineStyle::Dash,
            2 => LineStyle::Dot,
            _ => LineStyle::Solid,
        }
    }
}

/// 8 bytes. `Color::NONE` = auto palette color by trace index.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TraceStyle {
    pub color: Color,
    pub width: f32,
    pub line_style: LineStyle,
    pub visible: bool,
}

impl Default for TraceStyle {
    fn default() -> Self {
        Self {
            color: Color::NONE,
            width: 1.5,
            line_style: LineStyle::Solid,
            visible: true,
        }
    }
}

/// Default palette, cycled by trace index when style.color is NONE.
pub const TRACE_PALETTE: [Color; 8] = [
    Color::rgb(0x4f, 0x9c, 0xf7), // blue
    Color::rgb(0xe5, 0x48, 0x4d), // red
    Color::rgb(0xf2, 0xc1, 0x3a), // yellow
    Color::rgb(0x52, 0xc4, 0x6b), // green
    Color::rgb(0xc8, 0x6b, 0xe0), // purple
    Color::rgb(0x4d, 0xd0, 0xc4), // teal
    Color::rgb(0xf0, 0x8c, 0x3a), // orange
    Color::rgb(0xb0, 0xb0, 0xb0), // gray
];

// ════════════════════════════════════════════════════════════
// Traces / panes / cursors
// ════════════════════════════════════════════════════════════

/// A plotted curve: an expression evaluated against one analysis block of
/// one loaded file. `expr` may be a bare signal (`v(out)`) or derived
/// (`db(v(out)/v(in))`). The evaluated columns are cached; invalidated on
/// file reload.
#[derive(Debug, Clone)]
pub struct Trace {
    pub expr: String,
    /// Index into `WaveState::files`.
    pub file: u16,
    /// Analysis block within the file (`RawPlot` index).
    pub block: u16,
    /// Display pane this trace draws in.
    pub pane: u16,
    pub style: TraceStyle,
    /// Cached evaluation; `None` = needs (re-)eval.
    pub cached: Option<EvalResult>,
}

/// One stacked plot pane. X range is shared across panes (`WaveState::x_range`);
/// Y is independent.
#[derive(Debug, Clone)]
pub struct Pane {
    pub y_range: [f64; 2],
    /// Autoscale Y on next render / zoom-fit.
    pub y_auto: bool,
}

impl Default for Pane {
    fn default() -> Self {
        Self {
            y_range: [0.0, 1.0],
            y_auto: true,
        }
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct WaveCursor {
    pub x: f64,
    pub visible: bool,
}

#[derive(Debug, Clone)]
pub struct WaveFileEntry {
    pub path: PathBuf,
    /// File stem, for trace labels.
    pub name: String,
    pub plots: Vec<RawPlot>,
}

// ════════════════════════════════════════════════════════════
// WaveState
// ════════════════════════════════════════════════════════════

#[derive(Debug, Clone, Default)]
pub struct WaveState {
    pub files: Vec<WaveFileEntry>,
    pub panes: Vec<Pane>,
    pub traces: Vec<Trace>,
    pub cursor_a: WaveCursor,
    pub cursor_b: WaveCursor,
    /// Shared X range across all panes.
    pub x_range: [f64; 2],
    /// Autoscale X on next render / zoom-fit.
    pub x_auto: bool,
    pub x_log: bool,
    /// Pane targeted by trace-adding commands.
    pub active_pane: u16,
}

#[derive(Debug, thiserror::Error)]
pub enum WaveError {
    #[error("read {path}: {err}")]
    Io { path: PathBuf, err: std::io::Error },
    #[error("parse {path}: {err}")]
    Parse {
        path: PathBuf,
        err: schemify_wave::RawError,
    },
    #[error("no file loaded")]
    NoFile,
    #[error("bad file index {0}")]
    BadFile(u16),
    #[error("bad block index {0}")]
    BadBlock(u16),
    #[error("bad trace index {0}")]
    BadTrace(u32),
    #[error("bad pane index {0}")]
    BadPane(u16),
    #[error("expression: {0}")]
    Expr(#[from] schemify_wave::ExprError),
}

impl WaveState {
    pub fn new() -> Self {
        Self {
            panes: vec![Pane::default()],
            x_range: [0.0, 1.0],
            x_auto: true,
            ..Default::default()
        }
    }

    /// Load a `.raw` file from disk and append it. Returns the file index.
    pub fn open_file(&mut self, path: &Path) -> Result<u16, WaveError> {
        let bytes = std::fs::read(path).map_err(|err| WaveError::Io {
            path: path.to_owned(),
            err,
        })?;
        let plots = schemify_wave::parse_raw(&bytes).map_err(|err| WaveError::Parse {
            path: path.to_owned(),
            err,
        })?;
        self.files.push(WaveFileEntry {
            path: path.to_owned(),
            name: path
                .file_stem()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned(),
            plots,
        });
        Ok((self.files.len() - 1) as u16)
    }

    /// Re-read every loaded file from disk; trace caches invalidated.
    pub fn reload_files(&mut self) -> Result<(), WaveError> {
        for i in 0..self.files.len() {
            let path = self.files[i].path.clone();
            let bytes = std::fs::read(&path).map_err(|err| WaveError::Io {
                path: path.clone(),
                err,
            })?;
            self.files[i].plots =
                schemify_wave::parse_raw(&bytes).map_err(|err| WaveError::Parse { path, err })?;
        }
        for t in &mut self.traces {
            t.cached = None;
        }
        Ok(())
    }

    pub fn block(&self, file: u16, block: u16) -> Result<&RawPlot, WaveError> {
        let f = self
            .files
            .get(file as usize)
            .ok_or(WaveError::BadFile(file))?;
        f.plots
            .get(block as usize)
            .ok_or(WaveError::BadBlock(block))
    }

    /// Add a trace to `pane` (or the active pane). The expression is parsed
    /// and evaluated immediately so errors surface at the command, not at
    /// render. Returns the trace index.
    pub fn add_trace(
        &mut self,
        expr: &str,
        file: Option<u16>,
        block: u16,
        pane: Option<u16>,
    ) -> Result<u32, WaveError> {
        if self.files.is_empty() {
            return Err(WaveError::NoFile);
        }
        let file = file.unwrap_or((self.files.len() - 1) as u16);
        let pane = pane.unwrap_or(self.active_pane);
        if pane as usize >= self.panes.len() {
            return Err(WaveError::BadPane(pane));
        }
        let ast = parse_expr(expr)?;
        let result = eval(&ast, self.block(file, block)?)?;
        self.traces.push(Trace {
            expr: expr.to_string(),
            file,
            block,
            pane,
            style: TraceStyle::default(),
            cached: Some(result),
        });
        Ok((self.traces.len() - 1) as u32)
    }

    pub fn remove_trace(&mut self, idx: u32) -> Result<(), WaveError> {
        if (idx as usize) < self.traces.len() {
            self.traces.remove(idx as usize);
            Ok(())
        } else {
            Err(WaveError::BadTrace(idx))
        }
    }

    /// Ensure every trace has a fresh evaluation (after reload).
    pub fn reeval_traces(&mut self) {
        for i in 0..self.traces.len() {
            if self.traces[i].cached.is_some() {
                continue;
            }
            let t = &self.traces[i];
            let Ok(block) = self.block(t.file, t.block) else {
                continue;
            };
            let cached = parse_expr(&t.expr).ok().and_then(|a| eval(&a, block).ok());
            self.traces[i].cached = cached;
        }
    }

    /// Effective draw color for trace `idx` (style color or palette).
    pub fn trace_color(&self, idx: usize) -> Color {
        let c = self.traces[idx].style.color;
        if c.is_none() {
            TRACE_PALETTE[idx % TRACE_PALETTE.len()]
        } else {
            c
        }
    }

    /// The X column a trace plots against (fft overrides the file scale).
    pub fn trace_x<'a>(&'a self, t: &'a Trace) -> Option<&'a [f64]> {
        let cached = t.cached.as_ref()?;
        if let Some(x) = &cached.x {
            return Some(x);
        }
        Some(self.block(t.file, t.block).ok()?.scale())
    }

    /// Step ranges for a trace (fft remaps them).
    pub fn trace_steps<'a>(&'a self, t: &'a Trace) -> Option<&'a [std::ops::Range<u32>]> {
        let cached = t.cached.as_ref()?;
        if let Some(s) = &cached.steps {
            return Some(s);
        }
        Some(&self.block(t.file, t.block).ok()?.steps)
    }

    /// Zoom fit: X to the union of trace X extents, panes to autoscale.
    pub fn zoom_fit(&mut self) {
        let (mut lo, mut hi) = (f64::INFINITY, f64::NEG_INFINITY);
        for t in &self.traces {
            if let Some(x) = self.trace_x(t) {
                for &v in x {
                    if v.is_finite() {
                        lo = lo.min(v);
                        hi = hi.max(v);
                    }
                }
            }
        }
        if lo < hi {
            self.x_range = [lo, hi];
            self.x_auto = false;
        } else {
            self.x_auto = true;
        }
        for p in &mut self.panes {
            p.y_auto = true;
        }
    }

    /// Y value of a trace at X (linear interpolation within the step that
    /// contains x). Cursor readout + MCP query.
    pub fn value_at(&self, trace: u32, x: f64) -> Option<f64> {
        let t = self.traces.get(trace as usize)?;
        let cached = t.cached.as_ref()?;
        let xs = self.trace_x(t)?;
        let steps = self.trace_steps(t)?;
        let y = &cached.re;
        // First step whose x-extent contains x; fall back to nearest.
        for s in steps {
            let (a, b) = (s.start as usize, (s.end as usize).min(xs.len()));
            if b - a < 1 {
                continue;
            }
            let (x0, x1) = (xs[a], xs[b - 1]);
            if x >= x0.min(x1) && x <= x0.max(x1) {
                return interp(&xs[a..b], &y[a..b.min(y.len())], x);
            }
        }
        None
    }

    /// CSV of the traces in all panes: header `x,expr1,expr2,…`, one row per
    /// sample of the first trace's X column, other traces interpolated.
    /// Clipped to the cursor window when both cursors are visible.
    pub fn export_csv(&self) -> String {
        let mut out = String::new();
        let Some(first) = self.traces.first() else {
            return out;
        };
        let Some(xs) = self.trace_x(first) else {
            return out;
        };
        let clip = (self.cursor_a.visible && self.cursor_b.visible).then(|| {
            let (a, b) = (self.cursor_a.x, self.cursor_b.x);
            (a.min(b), a.max(b))
        });
        out.push('x');
        for t in &self.traces {
            out.push(',');
            // Quote expressions containing commas.
            if t.expr.contains(',') {
                out.push('"');
                out.push_str(&t.expr);
                out.push('"');
            } else {
                out.push_str(&t.expr);
            }
        }
        out.push('\n');
        for &x in xs {
            if let Some((lo, hi)) = clip {
                if x < lo || x > hi {
                    continue;
                }
            }
            out.push_str(&format!("{x:e}"));
            for ti in 0..self.traces.len() {
                out.push(',');
                match self.value_at(ti as u32, x) {
                    Some(v) => out.push_str(&format!("{v:e}")),
                    None => {}
                }
            }
            out.push('\n');
        }
        out
    }
}

/// Linear interp of y(x) on a monotonic slice. Nearest endpoint outside.
fn interp(xs: &[f64], ys: &[f64], x: f64) -> Option<f64> {
    if xs.is_empty() || ys.is_empty() {
        return None;
    }
    let n = xs.len().min(ys.len());
    let asc = xs[n - 1] >= xs[0];
    let pos = xs[..n].partition_point(|&v| if asc { v < x } else { v > x });
    if pos == 0 {
        return Some(ys[0]);
    }
    if pos >= n {
        return Some(ys[n - 1]);
    }
    let (x0, x1, y0, y1) = (xs[pos - 1], xs[pos], ys[pos - 1], ys[pos]);
    if x1 == x0 {
        return Some(y0);
    }
    Some(y0 + (y1 - y0) * (x - x0) / (x1 - x0))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_test_raw() -> tempfile_path::TempRaw {
        // 4-point transient: v(out) ramps 0→3.
        let content = b"Title: t
Plotname: Transient Analysis
Flags: real
No. Variables: 2
No. Points: 4
Variables:
\t0\ttime\ttime
\t1\tv(out)\tvoltage
Values:
0\t0.0
\t0.0
1\t1.0
\t1.0
2\t2.0
\t2.0
3\t3.0
\t3.0
";
        tempfile_path::TempRaw::new(content)
    }

    /// Minimal self-cleaning temp file (std-only).
    mod tempfile_path {
        use std::path::PathBuf;

        pub struct TempRaw(pub PathBuf);

        impl TempRaw {
            pub fn new(content: &[u8]) -> Self {
                let mut p = std::env::temp_dir();
                p.push(format!(
                    "schemify_wave_test_{}_{:?}.raw",
                    std::process::id(),
                    std::thread::current().id()
                ));
                std::fs::write(&p, content).unwrap();
                Self(p)
            }
        }

        impl Drop for TempRaw {
            fn drop(&mut self) {
                let _ = std::fs::remove_file(&self.0);
            }
        }
    }

    #[test]
    fn open_add_trace_readout() {
        let tmp = write_test_raw();
        let mut w = WaveState::new();
        let f = w.open_file(&tmp.0).unwrap();
        assert_eq!(f, 0);
        let t = w.add_trace("v(out)", None, 0, None).unwrap();
        assert_eq!(t, 0);
        // Interpolated readout between samples.
        assert_eq!(w.value_at(0, 1.5), Some(1.5));
        w.zoom_fit();
        assert_eq!(w.x_range, [0.0, 3.0]);
    }

    #[test]
    fn derived_trace_and_errors() {
        let tmp = write_test_raw();
        let mut w = WaveState::new();
        w.open_file(&tmp.0).unwrap();
        w.add_trace("v(out) * 2 + 1", None, 0, None).unwrap();
        assert_eq!(w.value_at(0, 2.0), Some(5.0));
        assert!(matches!(
            w.add_trace("v(nope)", None, 0, None),
            Err(WaveError::Expr(_))
        ));
        assert!(matches!(
            w.add_trace("v(out)", Some(9), 0, None),
            Err(WaveError::BadFile(9))
        ));
    }

    #[test]
    fn csv_cursor_clip() {
        let tmp = write_test_raw();
        let mut w = WaveState::new();
        w.open_file(&tmp.0).unwrap();
        w.add_trace("v(out)", None, 0, None).unwrap();
        w.cursor_a = WaveCursor {
            x: 1.0,
            visible: true,
        };
        w.cursor_b = WaveCursor {
            x: 2.0,
            visible: true,
        };
        let csv = w.export_csv();
        let lines: Vec<&str> = csv.lines().collect();
        assert_eq!(lines[0], "x,v(out)");
        assert_eq!(lines.len(), 3); // header + points at x=1,2
        let _ = std::io::sink().write_all(csv.as_bytes());
    }
}
