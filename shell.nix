{
  pkgs ? import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz") { },
  lib ? pkgs.lib,
}:
let
  py = pkgs.python3;
  pyPkgs = pkgs.python3Packages;
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
    pkgs.zig
    pkgs.zls
    pkgs.xschem
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
    pkgs.pkg-config
    pkgs.autoconf
    pkgs.gnumake
    pkgs.automake
    pkgs.libtool
    pkgs.bison
    pkgs.flex
    pkgs.readline
    pkgs.libffi
    # ── Xyce / Trilinos build-from-source deps ───────────────────
    pkgs.cmake # Trilinos + Xyce
    pkgs.gfortran
    pkgs.fftw
    pkgs.suitesparse
    pkgs.lapack
    pkgs.blas
  ];
  LD_LIBRARY_PATH = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib # libstdc++.so — needed by Python C extensions and Zig C++ interop
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
    export NIX_CFLAGS_COMPILE="$(printf '%s' "$NIX_CFLAGS_COMPILE" | sed -E 's@(^| )-idirafter /usr/include( |$)@ @g' | tr -s ' ')"
    export NIX_LDFLAGS="$(printf '%s' "$NIX_LDFLAGS" | sed -E 's@(^| )-L/usr/lib( |$)@ @g; s@(^| )-L/usr/lib32( |$)@ @g' | tr -s ' ')"

    echo "Zig $(zig version), ZLS $(zls --version)"
    echo "Python $(python3 --version | cut -d' ' -f2)"
  '';
}
