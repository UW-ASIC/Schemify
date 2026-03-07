{
  pkgs ? import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz") { },
  lib ? pkgs.lib,
}:
let
  py = pkgs.python3;
  pyPkgs = pkgs.python3Packages;
  # ── pcpp: C preprocessor in Python (not in nixpkgs) ───────────
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
  # ── volare: PDK version manager (not in nixpkgs) ──────────────
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
  # ── Python environment with everything ─────────────────────────
  python-env = py.withPackages (
    ps: with ps; [
      toml
      pyyaml
      click
      rich
      httpx
      # PDK management
      volare
    ]
  );
in
pkgs.mkShell {
  nativeBuildInputs = [
    pkgs.pkg-config
    pkgs.zig
    pkgs.zls
    pkgs.psmisc
    pkgs.cmake # Trilinos + Xyce
    pkgs.gnumake
    pkgs.xschem
    pkgs.ngspice
    # ── Digital EDA tools ────────────────────────────────────────
    pkgs.verilator
    pkgs.yosys
    # ── Docs toolchain ───────────────────────────────────────────
    # bun: cd docs && bun install && bun run dev  (preview locally)
    #      bun run build                          (production build)
    pkgs.bun
  ];
  buildInputs = [
    python-env
    # ── Raylib backend (X11/OpenGL) ─────────────────────────────
    pkgs.libGL
    pkgs.libx11
    pkgs.libxcursor
    pkgs.libxrandr
    pkgs.libxi
    pkgs.libxext
    pkgs.libxinerama
    pkgs.libxrender
    pkgs.libxfixes
    # ── NGSpice build-from-source deps ───────────────────────────
    pkgs.autoconf
    pkgs.automake
    pkgs.libtool
    pkgs.bison
    pkgs.flex
    pkgs.readline
    pkgs.libffi
    # ── Xyce / Trilinos build-from-source deps ───────────────────
    pkgs.gfortran
    pkgs.fftw
    pkgs.suitesparse
    pkgs.lapack
    pkgs.blas
  ];
  LD_LIBRARY_PATH = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib  # libstdc++.so — needed by Python C extensions and Zig C++ interop
    pkgs.libGL
    pkgs.libx11
    pkgs.libxcursor
    pkgs.libxi
    pkgs.fftw
    pkgs.suitesparse
    pkgs.lapack
    pkgs.blas
  ];
  # PDK paths
  PDK_ROOT = "$HOME/.volare";
  PDK = "sky130A";
  shellHook = ''
    # Zig's clang frontend does not accept the split token pair "-idirafter /usr/include"
    # that leaks from Nix wrappers; trim it to avoid noisy warnings in raylib builds.
    export NIX_CFLAGS_COMPILE="$(printf '%s' "$NIX_CFLAGS_COMPILE" | sed -E 's@(^| )-idirafter /usr/include( |$)@ @g' | tr -s ' ')"
    # Avoid embedding host /usr libc search paths in Zig-linked binaries.
    # On non-NixOS this can mix system libc with Nix ld-linux and cause GLIBC_PRIVATE errors.
    export NIX_LDFLAGS="$(printf '%s' "$NIX_LDFLAGS" | sed -E 's@(^| )-L/usr/lib( |$)@ @g; s@(^| )-L/usr/lib32( |$)@ @g' | tr -s ' ')"

    export PDK_ROOT="$HOME/.volare"
    export PDK="sky130A"
    echo "Zig $(zig version), ZLS $(zls --version)"
    echo "Python $(python3 --version | cut -d' ' -f2)"
    echo "volare $(volare --version 2>&1 | head -1)"
    echo ""
    echo "N1Schem Development Environment"
    echo "  zig build                - build native"
    echo "  zig build -Dbackend=web  - build WASM"
    echo ""
    echo "  Docs (VitePress + bun):"
    echo "  cd docs && bun install   - install deps (first time)"
    echo "  cd docs && bun run dev   - live preview at http://localhost:5173"
    echo "  cd docs && bun run build - production build"
  '';
}
