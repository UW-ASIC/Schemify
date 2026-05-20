use std::collections::HashMap;
use std::path::PathBuf;

use crate::types::DeviceKind;

// ====================================================
// Process Design Kit (cell library)
// Uses String (not Sym) — loaded once, not hot path.
// Display reads CellInfo for library browser.
// ====================================================

#[derive(Debug, Clone)]
pub struct Pdk {
    pub name: String,
    pub cells: HashMap<String, CellInfo>,
}

#[derive(Debug, Clone)]
pub struct CellInfo {
    pub file: PathBuf,
    pub library: String,
    pub kind: DeviceKind,
    /// SPICE prefix character ('M', 'C', 'R', etc.)
    pub prefix: char,
    pub pin_order: Vec<String>,
    pub model_name: String,
    pub default_params: Vec<(String, String)>,
    pub lib_includes: Vec<PathBuf>,
}
