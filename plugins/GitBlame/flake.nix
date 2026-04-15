{
  description = "GitBlame – git blame annotations plugin";

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
          name = "gitblame-dev";

          nativeBuildInputs = [
            pkgs.zig
            pkgs.zls
            pkgs.git
          ];

          shellHook = ''
            echo "GitBlame dev shell — Zig $(zig version), git $(git --version | cut -d' ' -f3)"
            echo "  zig build        - build plugin (.so)"
            echo "  zig build test   - run tests"
          '';
        };
      }
    );
}
