use schemify_plugins::sdk::{
    CommandInvocation, InitializeEvent, Plugin, PluginRuntime, RuntimeError,
};

struct HelloWorld;

impl Plugin for HelloWorld {
    fn on_initialize(
        &mut self,
        runtime: &mut PluginRuntime,
        event: InitializeEvent,
    ) -> Result<(), RuntimeError> {
        runtime.info(format!("hello-world initialized as {}", event.plugin_id))?;
        runtime.register_command("greet", "Log a greeting to the host", None)?;
        Ok(())
    }

    fn on_schematic_changed(&mut self, runtime: &mut PluginRuntime) -> Result<(), RuntimeError> {
        runtime.info("schematic changed!")?;
        Ok(())
    }

    fn on_command(
        &mut self,
        runtime: &mut PluginRuntime,
        command: CommandInvocation,
    ) -> Result<(), RuntimeError> {
        if command.command == "greet" {
            runtime.set_status("Hello from the plugin!")?;
        }
        Ok(())
    }
}

fn main() -> Result<(), RuntimeError> {
    PluginRuntime::stdio().run(&mut HelloWorld)
}
