{
  description = "AgentHarness – Schemify LLM agent plugin";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; }; in {
        devShells = {
          # Default: build the plugin
          default = pkgs.mkShell {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.gcc
              pkgs.gnumake
            ];
            buildInputs = [
              pkgs.python3
            ];
            shellHook = ''
              echo "AgentHarness Plugin Dev Shell"
              echo "  make          - build native .so"
              echo "  make install  - install to ~/.config/Schemify/plugins/"
              echo ""
              echo "To run with a local LLM:"
              echo "  nix develop .#agent"
            '';
          };

          # Agent shell: includes Ollama + socat for testing
          agent = pkgs.mkShell {
            packages = [
              pkgs.python3
              pkgs.ollama
              pkgs.socat
            ];
            shellHook = ''
              echo "Schemify Agent Shell"
              echo ""
              echo "1. Start Ollama (if not running):"
              echo "   ollama serve &"
              echo ""
              echo "2. Pull a model:"
              echo "   ollama pull qwen2.5-coder:7b"
              echo "   ollama pull llama3.1:8b"
              echo "   ollama pull deepseek-coder-v2:16b"
              echo ""
              echo "3. Start Schemify (in another terminal)"
              echo ""
              echo "4. Run the agent:"
              echo "   python3 clients/schemify_agent.py --provider ollama --model qwen2.5-coder:7b"
              echo ""
              echo "Or interactive setup:"
              echo "   python3 clients/schemify_agent.py"
            '';
          };
        };
      }
    );
}
