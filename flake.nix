{
  description = "Nightly Rust dev shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
    pyspice = {
      url = "github:OmarSiwy/PySpice";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
      flake-utils,
      pyspice,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs { inherit system overlays; };

        # Nightly toolchain with wasm target + common components.
        rustToolchain = pkgs.rust-bin.nightly.latest.default.override {
          extensions = [
            "rust-src"
            "rust-analyzer"
            "clippy"
            "rustfmt"
          ];
          targets = [ "wasm32-unknown-unknown" ];
        };

        pyspicePkg = pyspice.packages.${system}.default;
        pyspiceSitePackages = "${pyspicePkg}/${pyspicePkg.passthru.pythonModule.sitePackages}";

        # Native libraries egui/eframe (glow backend) needs at runtime/link time.
        nativeBuildInputs = with pkgs; [
          pkg-config
          clang
        ];

        buildInputs = with pkgs; [
          # Windowing / input
          libxkbcommon
          libGL

          # X11 stack (for XWayland / non-Wayland sessions)
          xorg.libX11
          xorg.libXcursor
          xorg.libXrandr
          xorg.libXi

          # alsa-lib # BROKEN ON MAC

          # Misc
          openssl
          fontconfig
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          inherit nativeBuildInputs buildInputs;

          packages = with pkgs; [
            rustToolchain
            trunk # for `trunk serve` / wasm builds
            wasm-bindgen-cli
            binaryen # wasm-opt
            cargo-watch

            # broken on mac (NEED TO FIX)
            xschem # for roundtrip netlist tests
          ];

          # Use clang as the linker for native builds.
          # Override per-target rather than globally so wasm builds aren't affected.
          CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER = "${pkgs.clang}/bin/clang";

          CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER = "${pkgs.clang}/bin/clang";

          # Runtime library path so dynamically-linked deps (libGL, wayland, etc.)
          # are findable when you `cargo run` from the shell.
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath buildInputs;

          # PySpice module dir for sim crate build.rs (optional bundling).
          PYSPICE_MODULE_DIR = pyspiceSitePackages;

          shellHook = ''
            echo "Rust $(rustc --version)"
            echo "Targets: $(rustc --print target-list | grep -E '^(wasm32-unknown-unknown|x86_64-unknown-linux-gnu)$' | tr '\n' ' ')"
          '';
        };
      }
    );
}
