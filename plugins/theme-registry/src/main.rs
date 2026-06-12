//! Theme Registry plugin: browse the tinted-theming base16/base24 registry
//! (230+ schemes incl. Catppuccin) and hot-swap the Schemify theme.
//!
//! State model: the plugin owns everything (scheme list, filter, applied
//! slug); every change re-renders the whole panel via `update_widgets`.

mod mapping;
mod registry;

use schemify_plugins::sdk::{
    AlertLevel, CommandInvocation, InitializeEvent, PanelLayout, Plugin, PluginRuntime,
    RuntimeError, ThemeColor, UiAction, WidgetNode,
};

use registry::Scheme;

const PANEL: &str = "Themes";
const OVERRIDE_PRIORITY: i32 = 10;
/// Plugin cwd = plugin dir (host contract), so a bare filename persists.
const STATE_FILE: &str = "theme_state.json";

#[derive(Default)]
struct ThemeRegistry {
    schemes: Vec<Scheme>,
    filter: String,
    applied: Option<String>,
    error: Option<String>,
}

impl ThemeRegistry {
    fn filtered(&self) -> Vec<usize> {
        let needle = self.filter.to_lowercase();
        (0..self.schemes.len())
            .filter(|&i| {
                needle.is_empty()
                    || self.schemes[i].slug.contains(&needle)
                    || self.schemes[i].name.to_lowercase().contains(&needle)
            })
            .collect()
    }

    fn render(&self, rt: &mut PluginRuntime) -> Result<(), RuntimeError> {
        let mut widgets = vec![
            WidgetNode::Heading("Themes".into()),
            WidgetNode::TextInput {
                label: String::new(),
                value: self.filter.clone(),
                placeholder: Some("filter (e.g. catppuccin)".into()),
                action: "filter".into(),
            },
        ];

        if let Some(err) = &self.error {
            widgets.push(WidgetNode::Alert {
                level: AlertLevel::Error,
                message: err.clone(),
            });
            widgets.push(WidgetNode::Button {
                label: "Retry download".into(),
                action: "refresh".into(),
            });
        }

        // Applied-scheme swatch strip.
        if let Some(slug) = &self.applied {
            if let Some(s) = self.schemes.iter().find(|s| &s.slug == slug) {
                widgets.push(WidgetNode::Label(format!("Applied: {}", s.name)));
                widgets.push(WidgetNode::Horizontal {
                    children: s
                        .palette
                        .iter()
                        .take(16)
                        .map(|c| WidgetNode::Badge {
                            text: " ".into(),
                            color: Some(ThemeColor::Literal([c[0], c[1], c[2], 255])),
                        })
                        .collect(),
                });
            }
        }

        let visible = self.filtered();
        widgets.push(WidgetNode::Badge {
            text: format!("{} / {} schemes", visible.len(), self.schemes.len()),
            color: None,
        });
        widgets.push(WidgetNode::Separator);
        widgets.push(WidgetNode::Table {
            headers: vec!["Name".into(), "Variant".into()],
            rows: visible
                .iter()
                .map(|&i| {
                    let s = &self.schemes[i];
                    vec![
                        s.name.clone(),
                        if s.dark { "dark" } else { "light" }.into(),
                    ]
                })
                .collect(),
            action: Some("select".into()),
        });
        widgets.push(WidgetNode::Separator);
        widgets.push(WidgetNode::Horizontal {
            children: vec![
                WidgetNode::Button {
                    label: "Reset to default".into(),
                    action: "reset".into(),
                },
                WidgetNode::Button {
                    label: "Refresh registry".into(),
                    action: "refresh".into(),
                },
            ],
        });

        rt.update_widgets(PANEL, widgets)
    }

    fn apply(&mut self, rt: &mut PluginRuntime, idx_in_filtered: usize) -> Result<(), RuntimeError> {
        let visible = self.filtered();
        let Some(&i) = visible.get(idx_in_filtered) else {
            return Ok(());
        };
        let scheme = &self.schemes[i];
        rt.set_theme_override(OVERRIDE_PRIORITY, mapping::map_scheme(scheme))?;
        rt.set_status(format!("Theme: {}", scheme.name))?;
        self.applied = Some(scheme.slug.clone());
        self.persist();
        self.render(rt)
    }

    fn reset(&mut self, rt: &mut PluginRuntime) -> Result<(), RuntimeError> {
        // Empty override map = host removes this plugin's entry.
        rt.set_theme_override(OVERRIDE_PRIORITY, Vec::<(String, _)>::new())?;
        rt.set_status("Theme reset to default")?;
        self.applied = None;
        let _ = std::fs::remove_file(STATE_FILE);
        self.render(rt)
    }

    fn load_schemes(&mut self, refresh: bool) {
        let result = if refresh {
            registry::refresh()
        } else {
            registry::ensure_schemes()
        };
        match result {
            Ok(schemes) => {
                self.schemes = schemes;
                self.error = None;
            }
            Err(e) => self.error = Some(e),
        }
    }

    fn persist(&self) {
        if let Some(slug) = &self.applied {
            let _ = std::fs::write(
                STATE_FILE,
                serde_json::json!({ "applied": slug }).to_string(),
            );
        }
    }

    fn restore(&mut self, rt: &mut PluginRuntime) -> Result<(), RuntimeError> {
        let Ok(content) = std::fs::read_to_string(STATE_FILE) else {
            return Ok(());
        };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&content) else {
            return Ok(());
        };
        let Some(slug) = v.get("applied").and_then(|s| s.as_str()) else {
            return Ok(());
        };
        if let Some(s) = self.schemes.iter().find(|s| s.slug == slug) {
            rt.set_theme_override(OVERRIDE_PRIORITY, mapping::map_scheme(s))?;
            self.applied = Some(slug.to_owned());
        }
        Ok(())
    }
}

impl Plugin for ThemeRegistry {
    fn on_initialize(
        &mut self,
        rt: &mut PluginRuntime,
        _event: InitializeEvent,
    ) -> Result<(), RuntimeError> {
        rt.register_panel(PANEL, PanelLayout::RightSidebar, 20, true)?;
        rt.register_command("refresh_themes", "Re-download the scheme registry", None)?;
        rt.register_command("reset_theme", "Restore the default theme", None)?;
        self.load_schemes(false);
        self.restore(rt)?; // re-apply persisted theme on every start
        self.render(rt)
    }

    fn on_ui_action(
        &mut self,
        rt: &mut PluginRuntime,
        action: UiAction,
    ) -> Result<(), RuntimeError> {
        match action.action.as_str() {
            "filter" => {
                self.filter = action
                    .payload
                    .and_then(|v| v.as_str().map(str::to_owned))
                    .unwrap_or_default();
                self.render(rt)
            }
            "select" => {
                let idx = action
                    .payload
                    .and_then(|v| v.as_u64())
                    .unwrap_or(u64::MAX) as usize;
                self.apply(rt, idx)
            }
            "reset" => self.reset(rt),
            "refresh" => {
                self.load_schemes(true);
                self.render(rt)
            }
            _ => Ok(()),
        }
    }

    fn on_command(
        &mut self,
        rt: &mut PluginRuntime,
        command: CommandInvocation,
    ) -> Result<(), RuntimeError> {
        match command.command.as_str() {
            "refresh_themes" => {
                self.load_schemes(true);
                self.render(rt)
            }
            "reset_theme" => self.reset(rt),
            _ => Ok(()),
        }
    }
}

fn main() -> Result<(), RuntimeError> {
    PluginRuntime::stdio().run(&mut ThemeRegistry::default())
}
