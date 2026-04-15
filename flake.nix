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
        #  devShells.default — core Schemify build environment
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

            # Digital EDA tools (for tests)
            pkgs.verilator
            pkgs.yosys

            # Docs toolchain
            pkgs.bun
          ];

          buildInputs = runtimeLibs;

          shellHook = ''
            export LD_LIBRARY_PATH="${lib.makeLibraryPath runtimeLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            echo "Zig $(zig version), ZLS $(zls --version)"
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
          targetPkgs =
            _:
            runtimeLibs
            ++ [
              pkgs.verilator
              pkgs.yosys
            ];
          runScript = "$SHELL";
          meta.description = "Minimal runtime environment for the Schemify binary";
        };
      }
    );
}
