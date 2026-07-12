//! Waveform data model — SoA, column-major.
//!
//! One `RawPlot` per analysis block in a `.raw` file. All samples live in a
//! single flat `Vec<f64>` per domain (re / im), column-major: variable `v`
//! occupies `re[v*n .. (v+1)*n]`. Contiguous columns → stride-1 trace
//! rendering and autovectorizable expression evaluation.
//!
//! Parametric sweep steps are index ranges into the columns — zero copy.

use core::ops::Range;

/// Variable classification, derived from the `Variables:` header type field.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum VarKind {
    Time = 0,
    Frequency,
    Voltage,
    Current,
    Other,
}

impl VarKind {
    pub(crate) fn from_type_str(s: &str) -> Self {
        let s = s.trim();
        if s.eq_ignore_ascii_case("time") {
            VarKind::Time
        } else if s.eq_ignore_ascii_case("frequency") {
            VarKind::Frequency
        } else if s.eq_ignore_ascii_case("voltage") {
            VarKind::Voltage
        } else if s.eq_ignore_ascii_case("current")
            || s.eq_ignore_ascii_case("device_current")
            || s.eq_ignore_ascii_case("subckt_current")
        {
            VarKind::Current
        } else {
            VarKind::Other
        }
    }

    /// Display unit for this kind ("V", "A", "s", "Hz", "").
    pub fn unit(self) -> &'static str {
        match self {
            VarKind::Time => "s",
            VarKind::Frequency => "Hz",
            VarKind::Voltage => "V",
            VarKind::Current => "A",
            VarKind::Other => "",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Variable {
    pub name: String,
    pub kind: VarKind,
}

/// One analysis block of a `.raw` file (a file may contain several, e.g.
/// ngspice appends one block per `.step` or per analysis command).
#[derive(Debug, Clone)]
pub struct RawPlot {
    pub plotname: String,
    /// AC analysis: every column has a matching imaginary column in `im`.
    pub complex: bool,
    pub variables: Vec<Variable>,
    /// Points per *file block* (sum over steps).
    pub n_points: u32,
    /// Column-major real samples: var `v` = `re[v*n .. (v+1)*n]`.
    pub re: Vec<f64>,
    /// Column-major imaginary samples; empty when `!complex`.
    pub im: Vec<f64>,
    /// Sweep step ranges over point indices. Always ≥ 1 entry; a non-swept
    /// plot has a single `0..n_points` range.
    pub steps: Vec<Range<u32>>,
}

impl RawPlot {
    /// Real column for variable `v`.
    #[inline]
    pub(crate) fn col(&self, v: usize) -> &[f64] {
        let n = self.n_points as usize;
        &self.re[v * n..(v + 1) * n]
    }

    /// Imaginary column for variable `v`. Panics if `!complex`.
    #[inline]
    pub(crate) fn col_im(&self, v: usize) -> &[f64] {
        let n = self.n_points as usize;
        &self.im[v * n..(v + 1) * n]
    }

    /// The scale (sweep) variable — always column 0.
    #[inline]
    pub fn scale(&self) -> &[f64] {
        self.col(0)
    }

    /// Case-insensitive variable lookup. `.raw` tools disagree on case
    /// (`V(out)` vs `v(out)`), so lookups never compare case-sensitively.
    pub(crate) fn find_var(&self, name: &str) -> Option<usize> {
        self.variables
            .iter()
            .position(|v| v.name.eq_ignore_ascii_case(name))
    }

    /// Detect sweep steps: the scale variable restarting (x[i] < x[i-1])
    /// marks a step boundary. Called once by the parser after columns are
    /// built; result cached in `steps`.
    pub(crate) fn detect_steps(&mut self) {
        let scale = self.scale();
        let mut steps: Vec<Range<u32>> = Vec::new();
        let mut start = 0u32;
        for i in 1..scale.len() {
            if scale[i] < scale[i - 1] {
                steps.push(start..i as u32);
                start = i as u32;
            }
        }
        steps.push(start..scale.len() as u32);
        self.steps = steps;
    }
}
