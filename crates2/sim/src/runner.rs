//! Simulation runner: netlist rendering via python/pyspice_rs, deck
//! splicing, and batch execution of the SPICE backend. Owns ALL
//! `std::process`/`std::fs`/temp-dir details — plain data in, plain data
//! out, no `App`.
//!
//! ponytail: concrete runner; introduce a trait only when a non-CLI backend
//! (in-process ngspice FFI, remote sim) actually lands.

use std::path::PathBuf;

use schemify_schematic::SpiceBackend;
use crate as ir;
use crate::CircuitIR;

pub struct SimRequest {
    pub ir: CircuitIR,
    /// Analysis directives (`.tran 1n 1u` …) spliced in before `.end`.
    pub spice_body: String,
    pub backend: SpiceBackend,
    /// Directory relative paths (Verilog-A sources, includes) resolve
    /// against; `None` = process cwd.
    pub work_dir: Option<PathBuf>,
}

pub struct SimOutput {
    /// Rawfile the backend wrote (existence not guaranteed — a deck without
    /// analysis output produces none).
    pub raw_path: PathBuf,
    /// The final spliced deck that was run.
    pub deck: String,
    /// Combined backend stdout + stderr.
    pub log: String,
}

#[derive(Debug, thiserror::Error)]
pub enum SimError {
    #[error("PySpice not available (build inside the nix devshell so it gets bundled)")]
    PySpiceMissing,
    #[error("Sim: cannot create {path}: {err}")]
    CreateDir { path: String, err: String },
    #[error("Sim: cannot write netlist script: {0}")]
    WriteScript(String),
    #[error("Failed to run python: {0}")]
    PythonLaunch(String),
    /// Netlist generation failed; `log` is the full python stderr, kept
    /// inspectable next to the netlist JSON.
    #[error("Netlist generation failed: {msg}")]
    NetlistGen { msg: String, log: String },
    #[error("Sim: cannot write netlist: {0}")]
    WriteDeck(String),
    #[error("Failed to run {backend}: {err} (is it installed?)")]
    BackendLaunch { backend: &'static str, err: String },
    /// The backend ran but reported an error; deck + log preserved for the
    /// netlist inspector.
    #[error("Simulation failed: {err}")]
    SimFailed {
        err: String,
        deck: String,
        log: String,
    },
}

/// Render the netlist (python/pyspice_rs), splice in the analysis
/// directives, and batch-run the selected SPICE backend.
pub fn run(req: &SimRequest) -> Result<SimOutput, SimError> {
    use std::process::Command as Proc;

    // 1. Python renders the netlist — pyspice_rs owns PDK resolution and
    //    backend dialect quirks, so we don't emit SPICE directly.
    let pypath = ir::pyspice::python_path().ok_or(SimError::PySpiceMissing)?;
    let dir = std::env::temp_dir().join("schemify_sim");
    std::fs::create_dir_all(&dir).map_err(|e| SimError::CreateDir {
        path: dir.display().to_string(),
        err: e.to_string(),
    })?;
    let script_path = dir.join("netlist_gen.py");
    std::fs::write(&script_path, ir::codegen::emit_netlist_script(&req.ir))
        .map_err(|e| SimError::WriteScript(e.to_string()))?;
    let mut py_cmd = Proc::new(ir::pyspice::python_bin());
    py_cmd.arg(&script_path).env("PYTHONPATH", &pypath);
    if let Some(d) = &req.work_dir {
        py_cmd.current_dir(d);
    }
    let netlist = match py_cmd.output() {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).into_owned(),
        Ok(out) => {
            let stderr = String::from_utf8_lossy(&out.stderr);
            // Tracebacks bury the message (e.g. openvaf compile errors from
            // veriloga()): prefer a line mentioning an error, keep the full
            // log inspectable.
            let msg = stderr
                .lines()
                .find(|l| l.contains("Error") || l.contains("error"))
                .or_else(|| stderr.lines().rev().find(|l| !l.trim().is_empty()))
                .unwrap_or("unknown error");
            return Err(SimError::NetlistGen {
                msg: msg.to_owned(),
                log: stderr.into_owned(),
            });
        }
        Err(e) => return Err(SimError::PythonLaunch(e.to_string())),
    };

    // 2. Splice the analysis directives in before `.end`.
    let mut deck = netlist.trim_end().to_string();
    if let Some(stripped) = deck.strip_suffix(".end") {
        deck.truncate(stripped.trim_end().len());
    }
    deck.push_str("\n\n");
    for line in req.spice_body.lines() {
        deck.push_str(line);
        deck.push('\n');
    }
    deck.push_str(".end\n");

    // 3. Batch-run the selected backend, writing a rawfile.
    let cir_path = dir.join("circuit.cir");
    let raw_path = dir.join("circuit.raw");
    let _ = std::fs::remove_file(&raw_path);
    std::fs::write(&cir_path, &deck).map_err(|e| SimError::WriteDeck(e.to_string()))?;
    let mut cmd = match req.backend {
        SpiceBackend::NgSpice => {
            let mut c = Proc::new("ngspice");
            c.arg("-b").arg("-r").arg(&raw_path).arg(&cir_path);
            c
        }
        SpiceBackend::Xyce => {
            let mut c = Proc::new("Xyce");
            c.arg("-r").arg(&raw_path).arg(&cir_path);
            c
        }
    };
    if let Some(d) = &req.work_dir {
        cmd.current_dir(d);
    }
    let out = cmd.output().map_err(|e| SimError::BackendLaunch {
        backend: req.backend.as_str(),
        err: e.to_string(),
    })?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    let log = format!("{stdout}\n{stderr}");
    if !out.status.success() {
        let err = stdout
            .lines()
            .chain(stderr.lines())
            .find(|l| l.to_ascii_lowercase().contains("error"))
            .unwrap_or("unknown error")
            .to_owned();
        return Err(SimError::SimFailed { err, deck, log });
    }

    Ok(SimOutput {
        raw_path,
        deck,
        log,
    })
}
