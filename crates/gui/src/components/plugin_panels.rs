//! Render plugin panels: one egui container per occupied slot, each panel a
//! collapsing section showing its plugin-pushed widget tree.
//!
//! Widgets are stateless on the host side: interactions are queued as
//! [`PendingUiAction`]s; the owning plugin updates its model and pushes a
//! fresh tree (`panels/update_widgets`).

use eframe::egui::{self, Color32};

use schemify_plugin_host::{AlertLevel, PanelLayout, ThemeColor, WidgetNode};
use serde_json::{json, Value};

use crate::plugin_host::{PendingUiAction, PluginHost};
use crate::state::Theme;

/// Show all visible plugin panels. Must run before the CentralPanel is added
/// (egui side/bottom panels claim screen space first).
pub fn show_panels(ui: &mut egui::Ui, host: &mut PluginHost, theme: &Theme) {
    let mut actions: Vec<PendingUiAction> = Vec::new();

    for slot in [
        PanelLayout::LeftSidebar,
        PanelLayout::RightSidebar,
        PanelLayout::BottomBar,
        PanelLayout::Overlay,
    ] {
        // Indices of visible panels in this slot, highest priority first.
        let mut idxs: Vec<usize> = host
            .panels
            .iter()
            .enumerate()
            .filter(|(_, p)| p.reg.slot == slot && p.visible)
            .map(|(i, _)| i)
            .collect();
        if idxs.is_empty() {
            continue;
        }
        idxs.sort_by_key(|&i| std::cmp::Reverse(host.panels[i].reg.priority));

        let panels = &host.panels;
        let mut body = |ui: &mut egui::Ui| {
            egui::ScrollArea::vertical().show(ui, |ui| {
                for &i in &idxs {
                    let p = &panels[i];
                    let title = format!("{} ({})", p.reg.name, p.reg.plugin_id);
                    egui::CollapsingHeader::new(&p.reg.name)
                        .id_salt(&title)
                        .default_open(true)
                        .show(ui, |ui| {
                            render_widgets(
                                ui,
                                &p.widgets,
                                theme,
                                &p.reg.plugin_id,
                                &mut actions,
                            );
                        });
                }
            });
        };

        match slot {
            PanelLayout::LeftSidebar => {
                egui::Panel::left("plugin_panel_left")
                    .resizable(true)
                    .default_size(260.0)
                    .show(ui, &mut body);
            }
            PanelLayout::RightSidebar => {
                egui::Panel::right("plugin_panel_right")
                    .resizable(true)
                    .default_size(280.0)
                    .show(ui, &mut body);
            }
            PanelLayout::BottomBar => {
                egui::Panel::bottom("plugin_panel_bottom")
                    .resizable(true)
                    .default_size(160.0)
                    .show(ui, &mut body);
            }
            PanelLayout::Overlay => {
                // One floating window per overlay panel.
                for &i in &idxs {
                    let p = &host.panels[i];
                    egui::Window::new(&p.reg.name)
                        .id(egui::Id::new(("plugin_overlay", &p.reg.plugin_id, i)))
                        .default_width(300.0)
                        .show(ui.ctx(), |ui| {
                            render_widgets(
                                ui,
                                &p.widgets,
                                theme,
                                &p.reg.plugin_id,
                                &mut actions,
                            );
                        });
                }
            }
        }
    }

    host.ui_actions.extend(actions);
}

fn resolve_color(c: &ThemeColor, theme: &Theme, fallback: Color32) -> Color32 {
    match c {
        ThemeColor::Token(name) => theme.token_color(name).unwrap_or(fallback),
        ThemeColor::Literal(rgba) => {
            Color32::from_rgba_unmultiplied(rgba[0], rgba[1], rgba[2], rgba[3])
        }
    }
}

fn push(out: &mut Vec<PendingUiAction>, plugin_id: &str, action: &str, payload: Option<Value>) {
    out.push(PendingUiAction {
        plugin_id: plugin_id.to_owned(),
        action: action.to_owned(),
        payload,
    });
}

/// Recursive widget-tree renderer: one match arm per [`WidgetNode`] variant.
pub fn render_widgets(
    ui: &mut egui::Ui,
    nodes: &[WidgetNode],
    theme: &Theme,
    plugin_id: &str,
    out: &mut Vec<PendingUiAction>,
) {
    use WidgetNode as W;
    for node in nodes {
        match node {
            // ── Text ──
            W::Label(text) => {
                ui.label(text);
            }
            W::Heading(text) => {
                ui.heading(text);
            }
            W::RichText {
                text,
                color,
                bold,
                italic,
                size,
            } => {
                let mut rt = egui::RichText::new(text);
                if let Some(c) = color {
                    rt = rt.color(resolve_color(c, theme, ui.visuals().text_color()));
                }
                if *bold {
                    rt = rt.strong();
                }
                if *italic {
                    rt = rt.italics();
                }
                if let Some(s) = size {
                    rt = rt.size(*s);
                }
                ui.label(rt);
            }
            W::Code(text) => {
                ui.code(text);
            }

            // ── Actions ──
            W::Button { label, action } => {
                if ui.button(label).clicked() {
                    push(out, plugin_id, action, None);
                }
            }
            W::LinkButton { label, action } => {
                if ui.link(label).clicked() {
                    push(out, plugin_id, action, None);
                }
            }

            // ── Toggles & selection ──
            W::Toggle {
                label,
                value,
                action,
            } => {
                let mut v = *value;
                if ui.checkbox(&mut v, label).changed() {
                    push(out, plugin_id, action, Some(json!(v)));
                }
            }
            W::RadioGroup {
                label,
                options,
                selected,
                action,
            } => {
                if !label.is_empty() {
                    ui.label(label);
                }
                for (i, opt) in options.iter().enumerate() {
                    if ui.radio(i == *selected, opt).clicked() && i != *selected {
                        push(out, plugin_id, action, Some(json!(i)));
                    }
                }
            }
            W::Dropdown {
                label,
                options,
                selected,
                action,
            } => {
                let mut sel = (*selected).min(options.len().saturating_sub(1));
                let current = options.get(sel).map(String::as_str).unwrap_or("");
                egui::ComboBox::from_label(label.as_str())
                    .selected_text(current)
                    .show_ui(ui, |ui| {
                        for (i, opt) in options.iter().enumerate() {
                            ui.selectable_value(&mut sel, i, opt);
                        }
                    });
                if sel != *selected {
                    push(out, plugin_id, action, Some(json!(sel)));
                }
            }

            // ── Numeric ──
            W::Slider {
                label,
                min,
                max,
                value,
                step,
                action,
            } => {
                let mut v = *value;
                let mut slider = egui::Slider::new(&mut v, *min..=*max).text(label.as_str());
                if let Some(s) = step {
                    slider = slider.step_by(*s);
                }
                if ui.add(slider).changed() {
                    push(out, plugin_id, action, Some(json!(v)));
                }
            }
            W::NumberInput {
                label,
                value,
                min,
                max,
                step,
                action,
            } => {
                let mut v = *value;
                let (min, max, step) = (*min, *max, *step);
                let changed = ui
                    .horizontal(|ui| {
                        if !label.is_empty() {
                            ui.label(label);
                        }
                        let mut drag = egui::DragValue::new(&mut v);
                        if let (Some(lo), Some(hi)) = (min, max) {
                            drag = drag.range(lo..=hi);
                        }
                        if let Some(s) = step {
                            drag = drag.speed(s);
                        }
                        ui.add(drag).changed()
                    })
                    .inner;
                if changed {
                    push(out, plugin_id, action, Some(json!(v)));
                }
            }

            // ── Text entry ──
            W::TextInput {
                label,
                value,
                placeholder,
                action,
            } => {
                // Local edit buffer keyed by (plugin, action); committed on
                // enter / focus loss so the plugin round-trip doesn't fight
                // the user's typing.
                let id = egui::Id::new(("plugin_text", plugin_id, action));
                let mut buf = ui
                    .ctx()
                    .data_mut(|d| d.get_temp::<String>(id))
                    .unwrap_or_else(|| value.clone());
                ui.horizontal(|ui| {
                    if !label.is_empty() {
                        ui.label(label);
                    }
                    let mut edit = egui::TextEdit::singleline(&mut buf);
                    if let Some(hint) = placeholder {
                        edit = edit.hint_text(hint.as_str());
                    }
                    let resp = ui.add(edit);
                    if resp.changed() {
                        ui.ctx().data_mut(|d| d.insert_temp(id, buf.clone()));
                    }
                    if resp.lost_focus() && buf != *value {
                        push(out, plugin_id, action, Some(json!(buf)));
                    }
                });
            }

            // ── Color ──
            W::ColorPicker {
                label,
                color,
                action,
            } => {
                let mut c = Color32::from_rgba_unmultiplied(
                    color[0], color[1], color[2], color[3],
                );
                ui.horizontal(|ui| {
                    if !label.is_empty() {
                        ui.label(label);
                    }
                    if ui.color_edit_button_srgba(&mut c).changed() {
                        let arr = c.to_srgba_unmultiplied();
                        push(out, plugin_id, action, Some(json!(arr)));
                    }
                });
            }

            // ── Display ──
            W::ProgressBar { label, value, color } => {
                let mut bar = egui::ProgressBar::new(*value).show_percentage();
                if let Some(l) = label {
                    bar = bar.text(l.as_str());
                }
                if let Some(c) = color {
                    bar = bar.fill(resolve_color(c, theme, theme.accent));
                }
                ui.add(bar);
            }
            W::KeyValue { entries } => {
                egui::Grid::new(("plugin_kv", plugin_id, entries.len()))
                    .num_columns(2)
                    .striped(true)
                    .show(ui, |ui| {
                        for [k, v] in entries {
                            ui.label(k);
                            ui.label(v);
                            ui.end_row();
                        }
                    });
            }
            W::Table {
                headers,
                rows,
                action,
            } => {
                egui::Grid::new(("plugin_table", plugin_id, headers.len(), rows.len()))
                    .num_columns(headers.len())
                    .striped(true)
                    .show(ui, |ui| {
                        for h in headers {
                            ui.strong(h);
                        }
                        ui.end_row();
                        for (ri, row) in rows.iter().enumerate() {
                            for (ci, cell) in row.iter().enumerate() {
                                match action {
                                    // Clickable rows: first column is the
                                    // row's click target.
                                    Some(act) if ci == 0 => {
                                        if ui.selectable_label(false, cell).clicked() {
                                            push(out, plugin_id, act, Some(json!(ri)));
                                        }
                                    }
                                    _ => {
                                        ui.label(cell);
                                    }
                                }
                            }
                            ui.end_row();
                        }
                    });
            }
            W::Alert { level, message } => {
                let (color, icon) = match level {
                    AlertLevel::Info => (theme.accent, "ℹ"),
                    AlertLevel::Warn => (theme.warn, "⚠"),
                    AlertLevel::Error => (theme.error, "✘"),
                    AlertLevel::Success => (theme.wire, "✔"),
                };
                egui::Frame::group(ui.style())
                    .stroke(egui::Stroke::new(1.0_f32, color))
                    .show(ui, |ui| {
                        ui.colored_label(color, format!("{icon} {message}"));
                    });
            }
            W::Badge { text, color } => {
                let c = color
                    .as_ref()
                    .map(|c| resolve_color(c, theme, theme.accent))
                    .unwrap_or(theme.accent);
                egui::Frame::new()
                    .fill(c.linear_multiply(0.25))
                    .corner_radius(4.0)
                    .inner_margin(egui::Margin::symmetric(6, 2))
                    .show(ui, |ui| {
                        ui.colored_label(c, text);
                    });
            }

            // ── Layout ──
            W::Separator => {
                ui.separator();
            }
            W::Spacer(h) => {
                ui.add_space(*h);
            }
            W::Section {
                label,
                collapsed,
                children,
            } => {
                egui::CollapsingHeader::new(label)
                    .id_salt(("plugin_section", plugin_id, label))
                    .default_open(!collapsed)
                    .show(ui, |ui| {
                        render_widgets(ui, children, theme, plugin_id, out);
                    });
            }
            W::Tabs {
                labels,
                selected,
                action,
                children,
            } => {
                let sel = (*selected).min(labels.len().saturating_sub(1));
                ui.horizontal_wrapped(|ui| {
                    for (i, l) in labels.iter().enumerate() {
                        if ui.selectable_label(i == sel, l).clicked() && i != sel {
                            push(out, plugin_id, action, Some(json!(i)));
                        }
                    }
                });
                ui.separator();
                if let Some(tab) = children.get(sel) {
                    render_widgets(ui, tab, theme, plugin_id, out);
                }
            }
            W::Horizontal { children } => {
                ui.horizontal_wrapped(|ui| {
                    render_widgets(ui, children, theme, plugin_id, out);
                });
            }
            W::Group { label, children } => {
                egui::Frame::group(ui.style()).show(ui, |ui| {
                    if let Some(l) = label {
                        ui.strong(l);
                    }
                    render_widgets(ui, children, theme, plugin_id, out);
                });
            }

            // ── Media ──
            W::Image {
                path,
                width,
                action,
            } => {
                let uri = format!("file://{path}");
                let mut img = egui::Image::new(uri).shrink_to_fit();
                if let Some(w) = width {
                    img = img.max_width(*w);
                }
                if action.is_some() {
                    img = img.sense(egui::Sense::click());
                }
                let resp = ui.add(img);
                if let Some(act) = action {
                    if resp.clicked() {
                        // Relative click position (0.0–1.0) for cursors.
                        let rel = resp
                            .interact_pointer_pos()
                            .map(|p| {
                                let r = resp.rect;
                                [
                                    ((p.x - r.left()) / r.width()).clamp(0.0, 1.0),
                                    ((p.y - r.top()) / r.height()).clamp(0.0, 1.0),
                                ]
                            })
                            .unwrap_or([0.5, 0.5]);
                        push(out, plugin_id, act, Some(json!(rel)));
                    }
                }
            }
        }
    }
}
