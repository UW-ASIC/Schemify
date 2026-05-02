{
  description = "Schemify Rust plugin example";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; }; in {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.rustc
            pkgs.cargo
            pkgs.lld
          ];
          shellHook = ''
            echo "Schemify Rust Plugin Dev Shell"
            echo "  cargo build --release                              - build native .so"
            echo "  cargo build --release --target wasm32-unknown-unknown  - build .wasm"
          '';
        };
      }
    );
}
