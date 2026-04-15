{
  description = "PDKLoader – PDK path resolver and sky130/gf180 fetcher plugin";

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
        pyPkgs = pkgs.python3Packages;

        # pcpp is a volare transitive dep not in nixpkgs
        pcpp = pyPkgs.buildPythonPackage rec {
          pname = "pcpp";
          version = "1.30";
          format = "setuptools";
          src = pyPkgs.fetchPypi {
            inherit pname version;
            hash = "sha256-Wvn7zlXxNteTGukV+uA8NAMKOzbEluctljbO3I4lQ6E=";
          };
          doCheck = false;
          meta.description = "A C99 preprocessor written in Python";
        };

        volare = pyPkgs.buildPythonPackage rec {
          pname = "volare";
          version = "0.20.6";
          format = "pyproject";
          src = pyPkgs.fetchPypi {
            inherit pname version;
            hash = "sha256-ouvZuKgd4UTbw1LqtxZw5+Sz5HEycjh0eadZNVaeB2o=";
          };
          nativeBuildInputs = [
            pyPkgs.poetry-core
            pyPkgs.pythonRelaxDepsHook
          ];
          pythonRelaxDeps = [ "rich" ];
          propagatedBuildInputs = with pyPkgs; [
            click
            httpx
            pcpp
            pyyaml
            rich
            zstandard
          ];
          doCheck = false;
          meta.description = "Version manager for Google open-source PDKs";
        };

        python-env = pkgs.python3.withPackages (
          ps: with ps; [
            toml
            pyyaml
            click
            rich
            pip
            httpx
            requests
            volare
          ]
        );
      in
      {
        devShells.default = pkgs.mkShell {
          name = "pdkloader-dev";

          nativeBuildInputs = [
            pkgs.zig
            pkgs.zls
            python-env
          ];

          shellHook = ''
            export PDK_ROOT="$HOME/.volare"
            export PDK="sky130A"
            echo "PDKLoader dev shell — Zig $(zig version)"
            echo "Python $(python3 --version | cut -d' ' -f2), volare $(volare --version 2>&1 | head -1)"
            echo "  zig build        - build plugin (.so)"
            echo "  zig build test   - run tests"
          '';
        };
      }
    );
}
