//! Optimizer windows — each instance is its own native window (egui
//! immediate viewport); any number may be open at once. Created from the
//! Simulate menu ("New Optimizer"): every activation makes a NEW instance.
//!
//! Closing the viewport only hides it (`OptimizerSetWindowOpen`) — the
//! instance and its history survive; the in-window "Close instance"
//! button (`OptimizerClose`) is what drops the state for good.
//!
//! All mutation goes through `Optimizer*` commands (the scriptable/MCP
//! surface); the window only reads `inst.opt` and queues commands, so
//! GUI and MCP drive the exact same state.

use eframe::egui::{self, RichText};

use schemify_core::handler::App;
use schemify_core::schemify::Command;
use schemify_core::wave::format_si;
use schemify_optimizer::{Optimizer, Target};

use crate::state::{GuiState, OptimizerViewState};

// ════════════════════════════════════════════════════════════
// Entry point (Simulate menu)
// ════════════════════════════════════════════════════════════

/// Create a fresh optimizer instance; its window opens via `window_open`.
/// Unlike the wave viewer there is no toggle: every call is a new window.
pub fn open_new(app: &mut App) {
    app.dispatch(Command::OptimizerNew {
        name: String::new(),
    });
}

// ════════════════════════════════════════════════════════════
// Windows (immediate viewports, one per open instance)
// ════════════════════════════════════════════════════════════

pub fn optimizer_windows(ctx: &egui::Context, app: &mut App, gui: &mut GuiState) {
    // Prune scratch for instances dropped by OptimizerClose (any source).
    gui.optimizer
        .retain(|id, _| app.state.optimizers.iter().any(|o| o.id == *id));

    // Collect ids first: window contents dispatch commands that may grow,
    // shrink, or reorder the optimizer list, so never hold a borrow of it
    // across the UI. Each id is re-looked-up below.
    let open_ids: Vec<u32> = app
        .state
        .optimizers
        .iter()
        .filter(|o| o.window_open)
        .map(|o| o.id)
        .collect();

    for id in open_ids {
        let Some(title) = app
            .state
            .optimizers
            .iter()
            .find(|o| o.id == id)
            .map(|o| format!("{} — Schemify", o.opt.name()))
        else {
            continue; // dropped by a command from an earlier window
        };
        let viewport_id = egui::ViewportId::from_hash_of(("schemify_optimizer", id));
        let builder = egui::ViewportBuilder::default()
            .with_title(title)
            .with_inner_size([700.0, 500.0]);

        // Immediate viewport: runs inline on this thread, same App borrow.
        let mut close = false;
        ctx.show_viewport_immediate(viewport_id, builder, |ctx2, _class| {
            if ctx2.input(|i| i.viewport().close_requested()) {
                close = true;
            }
            window_contents(ctx2, app, gui, id);
        });
        if close {
            // Hide only — params/objectives/history survive. The
            // "Close instance" button dispatches OptimizerClose instead.
            app.dispatch(Command::OptimizerSetWindowOpen { id, open: false });
        }
    }
}

fn window_contents(ctx: &egui::Context, app: &mut App, gui: &mut GuiState, id: u32) {
    // Read `inst.opt` immutably while the UI runs; queue commands and
    // dispatch them after the borrow ends (dispatch needs &mut App).
    let mut cmds: Vec<Command> = Vec::new();
    {
        let Some(inst) = app.state.optimizers.iter().find(|o| o.id == id) else {
            return;
        };
        let st = gui.optimizer.entry(id).or_default();
        top_bar(ctx, &inst.opt, id, &mut cmds);
        status_line(ctx, &inst.opt, id, &app.state.status_msg);
        egui::CentralPanel::default().show(ctx, |ui| {
            egui::ScrollArea::vertical()
                .auto_shrink([false, false])
                .show(ui, |ui| {
                    params_section(ui, &inst.opt, id, st, &mut cmds);
                    ui.separator();
                    objectives_section(ui, &inst.opt, id, st, &mut cmds);
                    ui.separator();
                    suggestion_section(ui, &inst.opt, id, st, &mut cmds);
                    ui.separator();
                    history_section(ui, &inst.opt, id);
                });
        });
    }
    for cmd in cmds {
        app.dispatch(cmd);
    }
}

// ════════════════════════════════════════════════════════════
// Top bar — algorithm, reset, close
// ════════════════════════════════════════════════════════════

fn top_bar(ctx: &egui::Context, opt: &Optimizer, id: u32, cmds: &mut Vec<Command>) {
    egui::TopBottomPanel::top(egui::Id::new(("opt_top", id))).show(ctx, |ui| {
        ui.horizontal(|ui| {
            ui.label("Algorithm:");
            let cur = opt.algorithm().as_str();
            egui::ComboBox::from_id_salt(("opt_algo", id))
                .selected_text(cur)
                .width(110.0)
                .show_ui(ui, |ui| {
                    for name in ["random", "nelder-mead"] {
                        if ui.selectable_label(cur == name, name).clicked() && cur != name {
                            cmds.push(Command::OptimizerSetAlgorithm {
                                id,
                                algorithm: name.to_string(),
                            });
                        }
                    }
                });
            ui.separator();

            if ui
                .button("Reset")
                .on_hover_text("Clear history + algorithm state; keep params/objectives")
                .clicked()
            {
                cmds.push(Command::OptimizerReset { id });
            }
            if ui
                .button("Close instance")
                .on_hover_text(
                    "Drop this optimizer and its history.\n\
                     (The window ✕ only hides it — state survives.)",
                )
                .clicked()
            {
                cmds.push(Command::OptimizerClose { id });
            }
            ui.separator();
            ui.weak(format!("#{id}"));
        });
    });
}

fn status_line(ctx: &egui::Context, opt: &Optimizer, id: u32, status: &str) {
    egui::TopBottomPanel::bottom(egui::Id::new(("opt_status", id))).show(ctx, |ui| {
        ui.horizontal(|ui| {
            ui.weak(format!(
                "{} param(s) · {} objective(s) · {} eval(s)",
                opt.params().len(),
                opt.objectives().len(),
                opt.n_evals()
            ));
            ui.separator();
            ui.weak(status);
        });
    });
}

// ════════════════════════════════════════════════════════════
// Parameters — table + add row
// ════════════════════════════════════════════════════════════

fn params_section(
    ui: &mut egui::Ui,
    opt: &Optimizer,
    id: u32,
    st: &mut OptimizerViewState,
    cmds: &mut Vec<Command>,
) {
    ui.heading("Parameters");
    egui::Grid::new(("opt_params", id))
        .striped(true)
        .min_col_width(60.0)
        .show(ui, |ui| {
            ui.strong("name");
            ui.strong("min");
            ui.strong("max");
            ui.strong("init");
            ui.label("");
            ui.end_row();

            for p in opt.params() {
                ui.label(&p.name);
                ui.label(format_si(p.min, 4));
                ui.label(format_si(p.max, 4));
                ui.label(format_si(p.init, 4));
                if ui
                    .small_button("🗑")
                    .on_hover_text("Remove param (clears history)")
                    .clicked()
                {
                    cmds.push(Command::OptimizerRemoveParam {
                        id,
                        name: p.name.clone(),
                    });
                }
                ui.end_row();
            }

            // Add row: parse on commit; invalid input → no dispatch.
            text_cell(ui, &mut st.param_name, "name", 90.0);
            text_cell(ui, &mut st.param_min, "min", 60.0);
            text_cell(ui, &mut st.param_max, "max", 60.0);
            text_cell(ui, &mut st.param_init, "init", 60.0);
            if ui.button("Add").clicked() {
                if let (false, Ok(min), Ok(max), Ok(init)) = (
                    st.param_name.trim().is_empty(),
                    st.param_min.trim().parse::<f64>(),
                    st.param_max.trim().parse::<f64>(),
                    st.param_init.trim().parse::<f64>(),
                ) {
                    cmds.push(Command::OptimizerAddParam {
                        id,
                        name: st.param_name.trim().to_string(),
                        min,
                        max,
                        init,
                    });
                    st.param_name.clear();
                    st.param_min.clear();
                    st.param_max.clear();
                    st.param_init.clear();
                }
            }
            ui.end_row();
        });
}

// ════════════════════════════════════════════════════════════
// Objectives — table + add row
// ════════════════════════════════════════════════════════════

fn target_str(t: Target) -> String {
    match t {
        Target::Minimize => "min".to_string(),
        Target::Maximize => "max".to_string(),
        Target::Approach(v) => format_si(v, 4),
    }
}

fn objectives_section(
    ui: &mut egui::Ui,
    opt: &Optimizer,
    id: u32,
    st: &mut OptimizerViewState,
    cmds: &mut Vec<Command>,
) {
    ui.heading("Objectives");
    egui::Grid::new(("opt_objectives", id))
        .striped(true)
        .min_col_width(60.0)
        .show(ui, |ui| {
            ui.strong("name");
            ui.strong("target");
            ui.strong("weight");
            ui.label("");
            ui.end_row();

            for o in opt.objectives() {
                ui.label(&o.name);
                ui.label(target_str(o.target));
                ui.label(format_si(o.weight, 4));
                if ui
                    .small_button("🗑")
                    .on_hover_text("Remove objective (clears history)")
                    .clicked()
                {
                    cmds.push(Command::OptimizerRemoveObjective {
                        id,
                        name: o.name.clone(),
                    });
                }
                ui.end_row();
            }

            // Add row: target accepts min / max / a number to approach.
            text_cell(ui, &mut st.obj_name, "name", 90.0);
            text_cell(ui, &mut st.obj_target, "min | max | number", 110.0);
            text_cell(ui, &mut st.obj_weight, "weight", 60.0);
            if ui.button("Add").clicked() {
                let target = st.obj_target.trim();
                let target_ok =
                    target == "min" || target == "max" || target.parse::<f64>().is_ok();
                if let (false, true, Ok(weight)) = (
                    st.obj_name.trim().is_empty(),
                    target_ok,
                    st.obj_weight.trim().parse::<f64>(),
                ) {
                    cmds.push(Command::OptimizerAddObjective {
                        id,
                        name: st.obj_name.trim().to_string(),
                        target: target.to_string(),
                        weight,
                    });
                    st.obj_name.clear();
                    st.obj_target.clear();
                    st.obj_weight.clear();
                }
            }
            ui.end_row();
        });
}

// ════════════════════════════════════════════════════════════
// Suggestion — pending candidate + measured inputs + Report
// ════════════════════════════════════════════════════════════

fn suggestion_section(
    ui: &mut egui::Ui,
    opt: &Optimizer,
    id: u32,
    st: &mut OptimizerViewState,
    cmds: &mut Vec<Command>,
) {
    ui.heading("Suggestion");
    let Some(candidate) = opt.suggest() else {
        ui.weak("No pending candidate — add at least one parameter.");
        return;
    };

    ui.horizontal_wrapped(|ui| {
        for (p, &v) in opt.params().iter().zip(candidate) {
            ui.label(RichText::new(format!("{} = {}", p.name, format_si(v, 5))).monospace());
        }
    });

    let n_obj = opt.objectives().len();
    st.measured.resize(n_obj, String::new());
    if n_obj == 0 {
        ui.weak("Add objectives to report measurements.");
        return;
    }

    // Measured inputs: parse on commit; Report disabled until all valid.
    let mut measured: Vec<f64> = Vec::with_capacity(n_obj);
    let mut all_ok = true;
    ui.horizontal_wrapped(|ui| {
        for (o, buf) in opt.objectives().iter().zip(st.measured.iter_mut()) {
            ui.label(&o.name);
            ui.add(
                egui::TextEdit::singleline(buf)
                    .hint_text("measured")
                    .desired_width(80.0),
            );
            match buf.trim().parse::<f64>() {
                Ok(v) => measured.push(v),
                Err(_) => all_ok = false,
            }
        }
    });
    if ui
        .add_enabled(all_ok, egui::Button::new("Report"))
        .on_hover_text("Record measured values for the suggested candidate")
        .clicked()
    {
        // params: None → evaluate the pending suggested candidate.
        cmds.push(Command::OptimizerReport {
            id,
            params: None,
            measured,
        });
        for b in &mut st.measured {
            b.clear();
        }
    }
}

// ════════════════════════════════════════════════════════════
// History — eval table, best row highlighted
// ════════════════════════════════════════════════════════════

fn history_section(ui: &mut egui::Ui, opt: &Optimizer, id: u32) {
    ui.heading("History");
    let n = opt.n_evals();
    let best_idx = match opt.best() {
        Some(b) => {
            let params = opt
                .params()
                .iter()
                .zip(b.params)
                .map(|(p, &v)| format!("{}={}", p.name, format_si(v, 5)))
                .collect::<Vec<_>>()
                .join("  ");
            ui.label(
                RichText::new(format!(
                    "Best: score {} @ eval {} — {}",
                    format_si(b.score, 5),
                    b.index,
                    params
                ))
                .strong(),
            );
            Some(b.index)
        }
        None => None,
    };
    if n == 0 {
        ui.weak("No evaluations yet.");
        return;
    }

    let highlight = ui.visuals().selection.stroke.color;
    egui::ScrollArea::vertical()
        .id_salt(("opt_history", id))
        .max_height(200.0)
        .stick_to_bottom(true)
        .show(ui, |ui| {
            egui::Grid::new(("opt_history_grid", id))
                .striped(true)
                .min_col_width(40.0)
                .show(ui, |ui| {
                    ui.strong("#");
                    ui.strong("params");
                    ui.strong("objectives");
                    ui.strong("score");
                    ui.end_row();

                    let fmt_list = |vals: &[f64]| {
                        vals.iter()
                            .map(|&v| format_si(v, 4))
                            .collect::<Vec<_>>()
                            .join(", ")
                    };
                    for i in 0..n {
                        let Some(e) = opt.eval(i) else { continue };
                        let is_best = Some(e.index) == best_idx;
                        let cell = |s: String| {
                            let t = RichText::new(s).monospace();
                            if is_best {
                                t.color(highlight).strong()
                            } else {
                                t
                            }
                        };
                        ui.label(cell(e.index.to_string()));
                        ui.label(cell(fmt_list(e.params)));
                        ui.label(cell(fmt_list(e.objectives)));
                        ui.label(cell(format_si(e.score, 5)));
                        ui.end_row();
                    }
                });
        });
}

// ════════════════════════════════════════════════════════════
// Helpers
// ════════════════════════════════════════════════════════════

fn text_cell(ui: &mut egui::Ui, buf: &mut String, hint: &str, width: f32) {
    ui.add(
        egui::TextEdit::singleline(buf)
            .hint_text(hint)
            .desired_width(width),
    );
}
