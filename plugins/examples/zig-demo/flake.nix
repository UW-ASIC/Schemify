{
  description = "Schemify Zig plugin example";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; }; in {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.zig_0_15
            pkgs.zls_0_15
          ];
          shellHook = ''
            echo "Schemify Zig Plugin Dev Shell (Zig $(zig version))"
            echo "  zig build                - build native .so"
            echo "  zig build -Dbackend=web  - build .wasm"
          '';
        };
      }
    );
}
