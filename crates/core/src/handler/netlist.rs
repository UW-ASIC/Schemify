//! Sim control methods on App: circuit-IR build, netlist generation, and
//! simulation kick-off.


use rustc_hash::FxHashSet;

use crate::schemify::{
    DeviceKind, Schematic,
};
use crate::sim as ir;

use super::*;

impl App {
    /// Project symbols instanced by `top` (transitively), cloned so their
    /// subcircuit defs can be emitted alongside the top-level circuit.
    pub(crate) fn project_symbol_children(&self, top: &Schematic) -> Vec<Schematic> {
        let pool = &self.state.project_symbol_schematics;
        if pool.is_empty() {
            return Vec::new();
        }
        let mut included: Vec<Schematic> = Vec::new();
        let mut seen: FxHashSet<&str> = FxHashSet::default();
        let mut work: Vec<&Schematic> = vec![top];
        while let Some(sch) = work.pop() {
            for i in 0..sch.instances.len() {
                if sch.instances.kind[i] != DeviceKind::Subckt {
                    continue;
                }
                let sym = self.state.interner.resolve(&sch.instances.symbol[i]);
                if seen.contains(sym) {
                    continue;
                }
                if let Some(child) = pool.iter().find(|c| c.name == sym) {
                    seen.insert(&child.name);
                    included.push(child.clone());
                    work.push(child);
                }
            }
        }
        included
    }

    pub fn build_circuit_ir(&self) -> ir::CircuitIR {
        let sch = &self.state.active_document().schematic;
        let children = self.project_symbol_children(sch);
        if children.is_empty() {
            to_circuit_ir(sch, &self.state.interner, self.state.pdk.as_ref())
        } else {
            to_circuit_ir_with_children(
                sch,
                &children,
                &self.state.interner,
                self.state.pdk.as_ref(),
            )
        }
    }

    pub(crate) fn generate_netlist(&mut self) {
        let circuit = self.build_circuit_ir();
        self.state.last_netlist = match serde_json::to_string_pretty(&circuit) {
            Ok(json) => json,
            Err(e) => format!("Failed to serialize circuit IR: {e}"),
        };
    }

    /// Run a simulation: Python (pyspice_rs) renders the netlist from the
    /// circuit IR, the schematic's analysis directives (`spice_body`) are
    /// spliced in before `.end`, the selected SPICE backend runs it in batch
    /// mode, and the resulting `.raw` opens in the waveform viewer.
    #[cfg(not(target_arch = "wasm32"))]
    pub(crate) fn run_simulation(&mut self) {
        use crate::sim::runner::{self, SimError, SimRequest};

        let sch = &self.state.active_document().schematic;
        let spice_body = sch.spice_body.clone();
        let backend = sch.sim_backend;

        if spice_body.trim().is_empty() {
            self.state.status_msg = "No analysis directives. Open the SPICE Code editor and add e.g. `.tran 1n 1u`.".into();
            return;
        }

        let ir = self.build_circuit_ir();
        self.state.last_netlist = match serde_json::to_string_pretty(&ir) {
            Ok(json) => json,
            Err(e) => format!("Failed to serialize circuit IR: {e}"),
        };

        // Relative paths (Verilog-A sources, includes, .osdi cards) resolve
        // against the schematic's directory: both the netlist-gen python
        // (which runs openvaf via veriloga()) and the SPICE backend get it
        // as cwd. Unsaved documents fall back to the process cwd.
        let work_dir = match &self.state.active_document().origin {
            Origin::File(p) => p.parent().map(std::path::Path::to_path_buf),
            _ => None,
        };

        self.state.status_msg = "Running simulation...".into();
        match runner::run(&SimRequest { ir, spice_body, backend, work_dir }) {
            Ok(out) => {
                // Keep the full deck + log inspectable next to the netlist JSON.
                self.state.last_netlist = format!(
                    "{}\n\n* === Netlist ===\n{}\n* === Simulation log ===\n{}",
                    self.state.last_netlist, out.deck, out.log
                );
                if out.raw_path.exists() {
                    self.handle_wave_open(&out.raw_path.to_string_lossy());
                } else {
                    self.state.status_msg =
                        "Simulation finished but produced no rawfile (missing analysis output?)"
                            .into();
                }
            }
            Err(SimError::NetlistGen { msg, log }) => {
                self.state.status_msg = format!("Netlist generation failed: {msg}");
                self.state.last_netlist = format!(
                    "{}\n\n* === Netlist generation log ===\n{log}",
                    self.state.last_netlist
                );
            }
            Err(SimError::SimFailed { err, deck, log }) => {
                self.state.last_netlist = format!(
                    "{}\n\n* === Netlist ===\n{deck}\n* === Simulation log ===\n{log}",
                    self.state.last_netlist
                );
                self.state.status_msg = format!("Simulation failed: {err}");
            }
            Err(e) => self.state.status_msg = e.to_string(),
        }
    }

    #[cfg(target_arch = "wasm32")]
    pub(crate) fn run_simulation(&mut self) {
        self.state.status_msg = "Simulation not available in web mode".into();
    }
}
