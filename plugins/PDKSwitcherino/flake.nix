{
  description = "PDKSwitcherino – Schemify Python plugin";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    ihp-sg13g2 = {
      url = "github:IHP-GmbH/IHP-Open-PDK";
      flake = false;
    };
    gf180mcu-pdk = {
      url = "github:google/gf180mcu-pdk";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, ihp-sg13g2, gf180mcu-pdk }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        python = pkgs.python3.withPackages (ps: with ps; [
          numpy
          scipy
          matplotlib
          pyyaml
        ]);
        volare = pkgs.python3Packages.buildPythonPackage rec {
          pname = "volare";
          version = "0.18.1";
          src = pkgs.fetchPypi {
            inherit pname version;
            hash = "sha256-adbCP+CX8PEW4uAn1uqjiCSCECV3C+a7PNUlam6TPFM=";
          };
          format = "setuptools";
          propagatedBuildInputs = with pkgs.python3Packages; [
            click
            httpx
            rich
            pcpp
            pyyaml
            zstandard
          ];
          doCheck = false;
        };
      in {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            python
            volare
            pkgs.gcc
            pkgs.gnumake
            pkgs.ngspice
          ];
          buildInputs = [
            python
          ];
          shellHook = ''
            echo "PDKSwitcherino Plugin Dev Shell"
            echo "  make          - build native .so"
            echo "  make install  - install to ~/.config/Schemify/"
            echo ""
            echo "Testing tools:"
            echo "  volare        - PDK manager (fetch/install PDKs)"
            echo "  ngspice       - SPICE simulator"
            echo "  python3       - with numpy, scipy, matplotlib"
            echo ""
            echo "PDK sources:"
            echo "  IHP:    ${ihp-sg13g2}/ihp-sg13g2"
            echo "  GF180:  ${gf180mcu-pdk}"
            export IHP_PDK_ROOT="${ihp-sg13g2}/ihp-sg13g2"
            export GF180_PDK_ROOT="${gf180mcu-pdk}"
            export SKY130_PDK_ROOT="$HOME/.volare/sky130A"
          '';
        };
      }
    );
}
