use schemify_plugins::sdk::{
    AlertLevel, CommandInvocation, InitializeEvent, MarkerKind, OverlayShape, PanelLayout, Plugin,
    PluginRuntime, RuntimeError, WidgetNode,
};

struct DrcOverlay {
    violations: Vec<Violation>,
}

struct Violation {
    message: String,
    x: f32,
    y: f32,
    kind: MarkerKind,
}

impl DrcOverlay {
    fn new() -> Self {
        Self {
            violations: Vec::new(),
        }
    }

    fn run_checks(&mut self, runtime: &mut PluginRuntime) -> Result<(), RuntimeError> {
        let instances = runtime.query_instances()?;
        let nets = runtime.query_nets()?;

        self.violations.clear();

        for inst in &instances {
            if inst.name.is_empty() {
                self.violations.push(Violation {
                    message: format!("{} at ({},{}) has no reference designator", inst.symbol, inst.x, inst.y),
                    x: inst.x as f32,
                    y: inst.y as f32,
                    kind: MarkerKind::Warning,
                });
            }
        }

        for net in &nets {
            if net.name.is_empty() {
                self.violations.push(Violation {
                    message: format!("net {} has no name", net.idx),
                    x: 0.0,
                    y: 0.0,
                    kind: MarkerKind::Info,
                });
            }
        }

        self.update_overlay(runtime)?;
        self.update_panel(runtime)?;

        let count = self.violations.len();
        runtime.set_status(if count == 0 {
            "DRC: clean".into()
        } else {
            format!("DRC: {count} issue(s)")
        })?;
        Ok(())
    }

    fn update_overlay(&self, runtime: &mut PluginRuntime) -> Result<(), RuntimeError> {
        let shapes: Vec<OverlayShape> = self
            .violations
            .iter()
            .map(|v| {
                let color = match v.kind {
                    MarkerKind::Error => [255, 0, 0, 200],
                    MarkerKind::Warning => [255, 180, 0, 200],
                    MarkerKind::Info => [100, 100, 255, 200],
                    MarkerKind::Pin => [0, 200, 0, 200],
                };
                OverlayShape::Marker {
                    x: v.x,
                    y: v.y,
                    kind: v.kind,
                    color,
                }
            })
            .collect();

        runtime.update_overlay("drc-markers", 100, true, shapes)
    }

    fn update_panel(&self, runtime: &mut PluginRuntime) -> Result<(), RuntimeError> {
        let mut widgets: Vec<WidgetNode> = vec![
            WidgetNode::Heading("DRC Results".into()),
            WidgetNode::Button {
                label: "Run DRC".into(),
                action: "run_drc".into(),
            },
            WidgetNode::Separator,
        ];

        if self.violations.is_empty() {
            widgets.push(WidgetNode::Alert {
                level: AlertLevel::Success,
                message: "No violations found".into(),
            });
        } else {
            for v in &self.violations {
                let level = match v.kind {
                    MarkerKind::Error => AlertLevel::Error,
                    MarkerKind::Warning => AlertLevel::Warn,
                    _ => AlertLevel::Info,
                };
                widgets.push(WidgetNode::Alert {
                    level,
                    message: v.message.clone(),
                });
            }
        }

        runtime.update_widgets("DRC Results", widgets)
    }
}

impl Plugin for DrcOverlay {
    fn on_initialize(
        &mut self,
        runtime: &mut PluginRuntime,
        _event: InitializeEvent,
    ) -> Result<(), RuntimeError> {
        runtime.register_panel("DRC Results", PanelLayout::BottomBar, 5, true)?;
        runtime.register_command("run_drc", "Run design rule checks", Some("Ctrl+D"))?;
        self.run_checks(runtime)
    }

    fn on_schematic_changed(&mut self, runtime: &mut PluginRuntime) -> Result<(), RuntimeError> {
        self.run_checks(runtime)
    }

    fn on_command(
        &mut self,
        runtime: &mut PluginRuntime,
        command: CommandInvocation,
    ) -> Result<(), RuntimeError> {
        if command.command == "run_drc" {
            self.run_checks(runtime)?;
        }
        Ok(())
    }

    fn on_ui_action(
        &mut self,
        runtime: &mut PluginRuntime,
        action: schemify_plugins::sdk::UiAction,
    ) -> Result<(), RuntimeError> {
        if action.action == "run_drc" {
            self.run_checks(runtime)?;
        }
        Ok(())
    }
}

fn main() -> Result<(), RuntimeError> {
    PluginRuntime::stdio().run(&mut DrcOverlay::new())
}
