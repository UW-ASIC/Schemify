{
  description = "Optimizer – Bayesian circuit optimization plugin";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          name = "optimizer-dev";

          nativeBuildInputs = [
            pkgs.zig
            pkgs.zls
          ];

          shellHook = ''
            echo "Optimizer dev shell — Zig $(zig version)"
            echo "  zig build        - build plugin (.so)"
            echo "  zig build test   - run tests"
          '';
        };
      }
    );
}
