class CircuitDefinitionError(Exception):
    def __init__(self, circuit_name: str, reason: str):
        self.circuit_name = circuit_name
        self.reason = reason
        super().__init__(f"[{circuit_name}] {reason}")


class ToolNotFoundError(Exception):
    def __init__(self, tool_name: str, install_hint: str = "run `nix develop` from repo root to get all required tools"):
        self.tool_name = tool_name
        super().__init__(f"External tool '{tool_name}' not found. {install_hint}")


class SimulationError(Exception):
    def __init__(self, circuit_name: str, tool: str, stderr: str):
        self.circuit_name = circuit_name
        self.tool = tool
        super().__init__(f"[{circuit_name}] Simulation failed via {tool}:\n{stderr}")
