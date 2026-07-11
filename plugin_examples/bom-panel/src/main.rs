use std::collections::BTreeMap;

use schemify_plugin_api::sdk::{
    CommandInvocation, InitializeEvent, InstanceRecord, PanelLayout, Plugin, PluginRuntime,
    RuntimeError, WidgetNode,
};

struct BomPanel;

impl BomPanel {
    fn refresh(&mut self, runtime: &mut PluginRuntime) -> Result<(), RuntimeError> {
        let instances = runtime.query_instances()?;
        let widgets = build_bom_widgets(&instances);
        runtime.update_widgets("Bill of Materials", widgets)?;
        runtime.set_status(format!("{} components", instances.len()))?;
        Ok(())
    }
}

fn build_bom_widgets(instances: &[InstanceRecord]) -> Vec<WidgetNode> {
    let mut counts: BTreeMap<&str, (u32, &str)> = BTreeMap::new();
    for inst in instances {
        let entry = counts.entry(&inst.symbol).or_insert((0, &inst.kind));
        entry.0 += 1;
    }

    let headers = vec!["Symbol".into(), "Kind".into(), "Qty".into()];
    let rows: Vec<Vec<String>> = counts
        .iter()
        .map(|(symbol, (qty, kind))| vec![symbol.to_string(), kind.to_string(), qty.to_string()])
        .collect();

    let total = instances.len();
    let unique = counts.len();

    vec![
        WidgetNode::Heading("Bill of Materials".into()),
        WidgetNode::KeyValue {
            entries: vec![
                ["Total components".into(), total.to_string()],
                ["Unique symbols".into(), unique.to_string()],
            ],
        },
        WidgetNode::Separator,
        WidgetNode::Table {
            headers,
            rows,
            action: None,
        },
    ]
}

impl Plugin for BomPanel {
    fn on_initialize(
        &mut self,
        runtime: &mut PluginRuntime,
        _event: InitializeEvent,
    ) -> Result<(), RuntimeError> {
        runtime.register_panel("Bill of Materials", PanelLayout::RightSidebar, 10, true)?;
        runtime.register_command("refresh_bom", "Manually refresh the BOM table", Some("Ctrl+Shift+B"))?;
        self.refresh(runtime)
    }

    fn on_schematic_changed(&mut self, runtime: &mut PluginRuntime) -> Result<(), RuntimeError> {
        self.refresh(runtime)
    }

    fn on_command(
        &mut self,
        runtime: &mut PluginRuntime,
        command: CommandInvocation,
    ) -> Result<(), RuntimeError> {
        if command.command == "refresh_bom" {
            self.refresh(runtime)?;
        }
        Ok(())
    }
}

fn main() -> Result<(), RuntimeError> {
    PluginRuntime::stdio().run(&mut BomPanel)
}
