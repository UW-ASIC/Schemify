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
        # Pin ngspice to 43 — versions 44+ have a regression where binned
        # MOSFET models (.model nfet_01v8.0, .1, …) fail scoped resolution,
        # breaking sky130 and gf180 PDK simulations.
        ngspice43overlay = final: prev: {
          libngspice = prev.libngspice.overrideAttrs (old: {
            version = "43";
            src = prev.fetchurl {
              url = "mirror://sourceforge/ngspice/ngspice-43.tar.gz";
              hash = "sha256-FN1qbwhTHyBRwTrmN5CkVwi9Q/PneIamqEiYwpexNpk=";
            };
            patches = [ ];
          });
          # ngspice CLI derives from libngspice (withNgshared = false),
          # so it picks up the pinned version automatically.
        };
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ ngspice43overlay ];
        };
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
        # libglvnd provides libGL.so + libGLX.so + libEGL.so (NixOS needs this instead of libGL)
        runtimeLibs = [
          pkgs.libglvnd
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
        #
        #  mkShell sets NIX_CFLAGS_COMPILE with proper -I flags that
        #  zig understands (buildFHSEnv.env used -idirafter which zig
        #  silently ignores, causing X11 headers to be missing).
        # ══════════════════════════════════════════════════════════
        devShells.default = pkgs.mkShell {
          name = "schemify-dev";

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
            # SPICE simulation (pinned to 43.x via overlay)
            pkgs.ngspice
            # Digital EDA tools
            pkgs.verilator
            pkgs.yosys
            pkgs.xschem
            # Docs toolchain
            pkgs.bun
            # Python environment
            python-env
          ];

          buildInputs =
            runtimeLibs
            ++ [
              # NGSpice shared lib (pinned to 43.x via overlay)
              pkgs.libngspice
              # NGSpice / Xyce build deps
              pkgs.readline
              pkgs.libffi
              pkgs.fftw
              pkgs.suitesparse
              pkgs.lapack
              pkgs.blas
              pkgs.openmpi
            ];

          shellHook = ''
            export PDK_ROOT="$HOME/.volare"
            export PDK="sky130A"
            export LD_LIBRARY_PATH="${lib.makeLibraryPath (runtimeLibs ++ [ pkgs.fftw pkgs.suitesparse pkgs.lapack pkgs.blas ])}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            echo "Zig $(zig version), ZLS $(zls --version)"
            echo "Python $(python3 --version | cut -d' ' -f2)"
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
