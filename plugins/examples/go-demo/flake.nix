{
  description = "Schemify Go plugin example";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; }; in {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.go
            pkgs.tinygo
            pkgs.gnumake
          ];
          shellHook = ''
            echo "Schemify Go Plugin Dev Shell"
            echo "  make          - build native .so  (CGo)"
            echo "  make wasm     - build .wasm       (TinyGo)"
            echo "  make install  - install to ~/.config/Schemify/"
          '';
        };
      }
    );
}
