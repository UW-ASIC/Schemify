{
  description = "Schemify – schematic capture & SPICE simulation";

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
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        py = pkgs.python3;
        pyPkgs = pkgs.python3Packages;

        # ── Python packages not in nixpkgs ─────────────────────────
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

        python-env = py.withPackages (
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

        # ── Runtime libraries (what the built executable needs) ────
        # dvui uses raylib with X11/OpenGL backend (see build.zig)
        runtimeLibs = [
          pkgs.libGL
          pkgs.libx11
          pkgs.libxcursor
          pkgs.libxrandr
          pkgs.libxi
          pkgs.libxext
          pkgs.libxinerama
          pkgs.libxrender
          pkgs.libxfixes
        ];
      in
      {
        # ══════════════════════════════════════════════════════════
        #  devShells.default — full build environment
        # ══════════════════════════════════════════════════════════
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.zig
            pkgs.zls
            pkgs.psmisc
            pkgs.cmake
            pkgs.gnumake
            # NGSpice build-from-source
            pkgs.autoconf
            pkgs.automake
            pkgs.libtool
            pkgs.bison
            pkgs.flex
            # Xyce / Trilinos
            pkgs.gfortran
            # ── Digital EDA tools ──────────────────────────────────
            # Required at build-time (tests) AND at runtime (subprocess calls
            # from verilatorHarness.zig and synthesisHandler.zig).
            pkgs.verilator
            pkgs.yosys
            pkgs.xschem

            # ── Docs toolchain ─────────────────────────────────────
            # bun: run `cd docs && bun install && bun run dev` to preview locally
            pkgs.bun
          ];

          buildInputs = runtimeLibs ++ [
            python-env
            # NGSpice build deps
            pkgs.readline
            pkgs.libffi
            # Xyce / Trilinos build deps
            pkgs.fftw
            pkgs.suitesparse
            pkgs.lapack
            pkgs.blas
            pkgs.openmpi
          ];

          LD_LIBRARY_PATH = lib.makeLibraryPath (
            runtimeLibs
            ++ [
              pkgs.fftw
              pkgs.suitesparse
              pkgs.lapack
              pkgs.blas
            ]
          );

          PDK_ROOT = "$HOME/.volare";
          PDK = "sky130A";

          shellHook = ''
            export PDK_ROOT="$HOME/.volare"
            export PDK="sky130A"
            echo "Zig $(zig version), ZLS $(zls --version)"
            echo "Python $(python3 --version | cut -d' ' -f2)"
            echo "volare $(volare --version 2>&1 | head -1)"
            echo ""
            echo "Schemify Development Environment"
            echo "  zig build                - build native"
            echo "  zig build -Dbackend=web  - build WASM"
          '';
        };

        # ══════════════════════════════════════════════════════════
        #  packages.default — just the runtime wrapper
        # ══════════════════════════════════════════════════════════
        #
        #  For someone who already has the compiled binary and just
        #  wants to run it, this FHS environment provides everything
        #  the executable dynamically links against.
        #
        #  Usage:
        #    nix shell .#default
        #    schemify            # binary must be on PATH or invoked directly
        #
        packages.default = pkgs.buildFHSEnv {
          name = "schemify-env";
          targetPkgs =
            _:
            runtimeLibs
            ++ [
              # Digital EDA tools — spawned as subprocesses at runtime by
              # verilatorHarness.zig and synthesisHandler.zig.
              pkgs.verilator
              pkgs.yosys
              # Optional: uncomment if the binary was built with ngspice/xyce
              # pkgs.ngspice
            ];
          runScript = "$SHELL";
          meta.description = "Minimal runtime environment for the Schemify binary";
        };
      }
    );
}
