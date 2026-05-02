{
  description = "Schemify C++ plugin example";

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
          ];
          shellHook = ''
            # The Makefile overrides CC=c++ and includes the C Makefile,
            # which uses WASM_CC for WASM builds.
            export WASM_CC="${llvm.clang-unwrapped}/bin/clang"
            echo "Schemify C++ Plugin Dev Shell"
            echo "  make          - build native .so"
            echo "  make web      - build .wasm"
            echo "  make install  - install to ~/.config/Schemify/"
          '';
        };
      }
    );
}
