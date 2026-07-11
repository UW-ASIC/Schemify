//! Documentation view: simple markdown + RaTeX math rendering.

use eframe::egui;

use schemify_core::handler::App;
use schemify_core::schemify::Command;


use crate::state::GuiState;


// ════════════════════════════════════════════════════════════
// Documentation view (simple markdown; LaTeX math deferred)
// ════════════════════════════════════════════════════════════

pub fn doc_view(ui: &mut egui::Ui, app: &mut App, gui: &mut GuiState) {
    if !gui.doc_loaded {
        gui.doc_buf = app.schematic().documentation.clone();
        gui.doc_loaded = true;
    }

    let mut save_requested = false;
    ui.horizontal(|ui| {
        if ui.button("Save").clicked() {
            save_requested = true;
        }
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            ui.weak(format!("{} words", gui.doc_buf.split_whitespace().count()));
        });
    });
    ui.separator();

    // Editor on top, rendered view always live in a resizable bottom pane.
    // The bottom panel must be laid out before the central editor fills
    // the rest.
    egui::Panel::bottom("doc_preview_pane")
        .resizable(true)
        .default_size(ui.available_height() * 0.45)
        .show(ui, |ui| {
            // Live value refs: {{R1}} / {{R1.value}} re-expand every
            // frame, so schematic edits show up immediately. Expansion
            // runs before math conversion, so refs inside $...$ work.
            let rendered = schemify_core::handler::expand_doc_vars(
                &gui.doc_buf,
                app.schematic(),
                &app.state.interner,
            );
            egui::ScrollArea::vertical()
                .id_salt("doc_preview_scroll")
                .auto_shrink([false, false])
                .show(ui, |ui| {
                    render_simple_markdown(ui, &mut gui.doc_math_cache, &rendered);
                });
        });
    egui::CentralPanel::default().show(ui, |ui| {
        egui::ScrollArea::vertical()
            .id_salt("doc_edit_scroll")
            .auto_shrink([false, false])
            .show(ui, |ui| {
                ui.add(
                    egui::TextEdit::multiline(&mut gui.doc_buf)
                        .font(egui::FontId::monospace(14.0))
                        .desired_width(f32::INFINITY)
                        .desired_rows(30),
                );
            });
    });

    if save_requested {
        app.dispatch(Command::SetDocumentation(gui.doc_buf.clone())).or_status(app);
    }
}

/// LaTeX → PNG render cache; `Err` keeps the parse error for display.
pub type MathCache = std::collections::HashMap<u64, Result<std::sync::Arc<[u8]>, String>>;

fn render_simple_markdown(ui: &mut egui::Ui, cache: &mut MathCache, text: &str) {
    let mut in_code_block = false;
    let mut math_block: Option<String> = None;
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("```") {
            in_code_block = !in_code_block;
            ui.add_space(4.0);
            continue;
        }
        if in_code_block {
            ui.label(egui::RichText::new(line).monospace());
            continue;
        }
        // $$ … $$ display math: single-line or accumulated block.
        if let Some(buf) = &mut math_block {
            if trimmed == "$$" {
                let expr = std::mem::take(buf);
                math_block = None;
                display_math(ui, cache, expr.trim());
            } else {
                buf.push_str(line);
                buf.push(' ');
            }
            continue;
        }
        if trimmed == "$$" {
            math_block = Some(String::new());
            continue;
        }
        if trimmed.len() > 4 && trimmed.starts_with("$$") && trimmed.ends_with("$$") {
            display_math(ui, cache, trimmed[2..trimmed.len() - 2].trim());
            continue;
        }
        if trimmed.is_empty() {
            ui.add_space(8.0);
        } else if let Some(h) = trimmed.strip_prefix("### ") {
            ui.label(egui::RichText::new(h).strong().size(15.0));
        } else if let Some(h) = trimmed.strip_prefix("## ") {
            ui.label(egui::RichText::new(h).strong().size(18.0));
        } else if let Some(h) = trimmed.strip_prefix("# ") {
            ui.heading(h);
        } else if let Some(item) = trimmed.strip_prefix("- ").or(trimmed.strip_prefix("* ")) {
            ui.horizontal_wrapped(|ui| {
                ui.label("  \u{2022}");
                math_line(ui, cache, item);
            });
        } else {
            math_line_wrapped(ui, cache, line);
        }
    }
    if let Some(buf) = math_block {
        // Unterminated $$ block: render what we have.
        display_math(ui, cache, buf.trim());
    }
}

// ── LaTeX math (RaTeX: parse → layout → display list → PNG) ──

/// Render `$…$` segments of a paragraph line inline with the text.
fn math_line_wrapped(ui: &mut egui::Ui, cache: &mut MathCache, line: &str) {
    if !line.contains('$') {
        ui.label(line);
        return;
    }
    ui.horizontal_wrapped(|ui| math_line(ui, cache, line));
}

/// Emit alternating text / inline-math segments split on `$`.
fn math_line(ui: &mut egui::Ui, cache: &mut MathCache, line: &str) {
    let mut rest = line;
    loop {
        let Some(i) = rest.find('$') else {
            if !rest.is_empty() {
                ui.label(rest);
            }
            return;
        };
        let after = &rest[i + 1..];
        let Some(j) = after.find('$') else {
            // Unpaired $: literal.
            ui.label(rest);
            return;
        };
        if i > 0 {
            ui.label(&rest[..i]);
        }
        math_image(ui, cache, after[..j].trim(), false);
        rest = &after[j + 1..];
    }
}

fn display_math(ui: &mut egui::Ui, cache: &mut MathCache, expr: &str) {
    if expr.is_empty() {
        return;
    }
    ui.add_space(4.0);
    ui.vertical_centered(|ui| math_image(ui, cache, expr, true));
    ui.add_space(4.0);
}

/// Cached RaTeX render of one expression, drawn as an egui image.
fn math_image(ui: &mut egui::Ui, cache: &mut MathCache, expr: &str, display: bool) {
    use std::hash::{Hash, Hasher};

    let color = ui.visuals().text_color();
    let dpr = ui.ctx().pixels_per_point().max(1.0) * 2.0; // 2x for crispness
    let mut h = std::collections::hash_map::DefaultHasher::new();
    (expr, display, color.to_array(), dpr.to_bits()).hash(&mut h);
    let key = h.finish();

    let entry = cache
        .entry(key)
        .or_insert_with(|| render_math_png(expr, display, color, dpr).map(Into::into));
    match entry {
        Ok(png) => {
            ui.add(
                egui::Image::from_bytes(
                    format!("bytes://doc-math-{key:016x}.png"),
                    egui::load::Bytes::Shared(png.clone()),
                )
                .fit_to_original_size(1.0 / dpr),
            );
        }
        Err(e) => {
            ui.label(
                egui::RichText::new(format!("${expr}$"))
                    .monospace()
                    .color(egui::Color32::LIGHT_RED),
            )
            .on_hover_text(e.clone());
        }
    }
}

fn render_math_png(
    expr: &str,
    display: bool,
    color: egui::Color32,
    dpr: f32,
) -> Result<Vec<u8>, String> {
    use ratex_types::math_style::MathStyle;

    let ast = ratex_parser::parser::parse(expr).map_err(|e| format!("{e}"))?;
    let style = if display { MathStyle::Display } else { MathStyle::Text };
    let col = ratex_types::color::Color::new(
        color.r() as f32 / 255.0,
        color.g() as f32 / 255.0,
        color.b() as f32 / 255.0,
        1.0,
    );
    let opts = ratex_layout::LayoutOptions::default()
        .with_style(style)
        .with_color(col);
    let lbox = ratex_layout::layout(&ast, &opts);
    let dl = ratex_layout::to_display_list(&lbox);
    ratex_render::render_to_png(
        &dl,
        &ratex_render::RenderOptions {
            font_size: if display { 19.0 } else { 14.0 },
            padding: if display { 4.0 } else { 1.0 },
            background_color: ratex_types::color::Color::new(0.0, 0.0, 0.0, 0.0),
            font_dir: String::new(),
            device_pixel_ratio: dpr,
        },
    )
}


#[cfg(test)]
mod doc_math_tests {
    use super::render_math_png;

    #[test]
    fn latex_renders_to_png() {
        let png = render_math_png(
            r"\frac{-b \pm \sqrt{b^2-4ac}}{2a}",
            true,
            egui::Color32::BLACK,
            2.0,
        )
        .expect("quadratic formula renders");
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n", "PNG magic");
        assert!(png.len() > 500, "non-trivial image: {} bytes", png.len());

        // Values substituted by expand_doc_vars sit inside math fine.
        let png = render_math_png(r"R_1 = 47k\Omega", false, egui::Color32::WHITE, 2.0)
            .expect("inline with substituted value renders");
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");

        // Garbage reports an error instead of panicking.
        assert!(render_math_png(r"\frac{", true, egui::Color32::BLACK, 2.0).is_err());
    }
}

