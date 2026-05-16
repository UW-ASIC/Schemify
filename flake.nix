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
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;

        # dvui uses SDL3 GPU backend (see build.zig)
        runtimeLibs = [
          pkgs.sdl3
          pkgs.libglvnd
          pkgs.vulkan-loader
        ];

        # PySpice-rs runtime: python3 + numpy + pyspice-rs from GitHub
        pyEnv = pkgs.python3.withPackages (ps: [
          ps.pip
          ps.numpy
        ]);
      in
      {
        # ══════════════════════════════════════════════════════════
        #  devShells.default — core Schemify build environment
        # ══════════════════════════════════════════════════════════
        devShells.default = pkgs.mkShell {
          name = "schemify-dev";

          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.zig
            pkgs.zls

            # Rust toolchain (needed to build pyspice-rs from source)
            pkgs.rustc
            pkgs.cargo
            pkgs.maturin

            # Docs toolchain
            pkgs.bun
          ];

          buildInputs = runtimeLibs ++ [
            pyEnv
            pkgs.ngspice
          ];

          shellHook = ''
            export LD_LIBRARY_PATH="${lib.makeLibraryPath runtimeLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

            # Auto-install pyspice-rs from GitHub into a local venv
            if [ ! -d .venv ]; then
              echo "Creating Python venv and installing pyspice-rs from GitHub..."
              python3 -m venv .venv
              .venv/bin/pip install --quiet git+https://github.com/OmarSiwy/PySpice.git
            fi
            source .venv/bin/activate

            echo "Zig $(zig version), Python $(python3 --version 2>&1 | cut -d' ' -f2), ngspice $(ngspice --version 2>&1 | head -1 | grep -oP '[\d.]+')"
            echo ""
            echo "Schemify Development Environment"
            echo "  zig build                - build native"
            echo "  zig build -Dbackend=web  - build WASM"
          '';
        };

        # ══════════════════════════════════════════════════════════
        #  packages.default — runtime wrapper (FHS env)
        # ══════════════════════════════════════════════════════════
        packages.default = pkgs.buildFHSEnv {
          name = "schemify-env";
          targetPkgs = _: runtimeLibs ++ [
            pyEnv
            pkgs.ngspice
          ];
          runScript = "$SHELL";
          meta.description = "Minimal runtime environment for the Schemify binary";
        };
      }
    );
}
