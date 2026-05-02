{
  description = "Schemify Python plugin example";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; }; in {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.python3
            pkgs.gcc
            pkgs.gnumake
            pkgs.emscripten
          ];
          buildInputs = [
            pkgs.python3
          ];
          shellHook = ''
            echo "Schemify Python Plugin Dev Shell"
            echo "  make          - build native .so  (requires python3-dev)"
            echo "  make web      - build .wasm       (requires cpython-wasm sysroot)"
            echo "  make install  - install to ~/.config/Schemify/"
          '';
        };
      }
    );
}
