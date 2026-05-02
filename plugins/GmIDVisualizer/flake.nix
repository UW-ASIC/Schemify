{
  description = "GmIDVisualizer – Schemify C++ plugin";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        llvm = pkgs.llvmPackages;
      in {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.gcc
            pkgs.gnumake
            llvm.clang-unwrapped
            pkgs.lld
            pkgs.emscripten
          ];
          shellHook = ''
            export WASM_CC="${llvm.clang-unwrapped}/bin/clang"
            echo "GmIDVisualizer Plugin Dev Shell"
            echo "  make          - build native .so"
            echo "  make web      - build .wasm"
            echo "  make runner   - build standalone CLI"
            echo "  make install  - install to ~/.config/Schemify/"
          '';
        };
      }
    );
}
