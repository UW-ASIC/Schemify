{
  description = "EasyImport – XSchem/Virtuoso project bridge plugin";

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
          name = "easyimport-dev";

          nativeBuildInputs = [
            pkgs.zig
            pkgs.zls
            # xschem needed for fixture generation and roundtrip tests
            pkgs.xschem
          ];

          shellHook = ''
            echo "EasyImport dev shell — Zig $(zig version)"
            echo "  zig build        - build plugin (.so)"
            echo "  zig build test   - run tests"
          '';
        };
      }
    );
}
