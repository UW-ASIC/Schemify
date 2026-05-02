{
  description = "CCreator – Schemify Python plugin (circuit design + PDK switching + optimization + Schemify export)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        python = pkgs.python3.withPackages (ps: with ps; [
          numpy
          sympy
          scipy
          matplotlib
          pip
          pyyaml
          scikit-learn
        ]);
      in {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            python
            pkgs.gcc
            pkgs.gnumake
            pkgs.ngspice
            pkgs.libngspice
          ];
          buildInputs = [
            python
            pkgs.libngspice
          ];
          shellHook = ''
            export LD_LIBRARY_PATH="${pkgs.libngspice}/lib:$LD_LIBRARY_PATH"
            echo "CCreator Plugin Dev Shell"
            echo "  make          - build native .so"
            echo "  make install  - install to ~/.config/Schemify/"
            echo ""
            echo "  Integrated: PDKSwitcherino, GMIDOptimizer, SpiceImport"
          '';
        };
      }
    );
}
