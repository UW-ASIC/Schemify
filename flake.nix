{
  description = "Nightly Rust dev shell with mold linker";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
      flake-utils,
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

        # Native libraries egui/eframe (glow backend) needs at runtime/link time.
        nativeBuildInputs = with pkgs; [
          pkg-config
          mold
          clang
        ];

        buildInputs = with pkgs; [
          # Windowing / input
          libxkbcommon
          wayland
          libGL

          # X11 stack (for XWayland / non-Wayland sessions)
          xorg.libX11
          xorg.libXcursor
          xorg.libXrandr
          xorg.libXi

          # Audio (some eframe features pull this in)
          alsa-lib

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
            mold
            trunk # for `trunk serve` / wasm builds
            wasm-bindgen-cli
            binaryen # wasm-opt
            cargo-watch
            xschem # for roundtrip netlist tests
          ];

          # Tell cargo to use clang + mold as the linker for native builds.
          # Override per-target rather than globally so wasm builds aren't affected.
          CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER = "${pkgs.clang}/bin/clang";
          CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS = "-C link-arg=-fuse-ld=${pkgs.mold}/bin/mold";

          CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER = "${pkgs.clang}/bin/clang";
          CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS = "-C link-arg=-fuse-ld=${pkgs.mold}/bin/mold";

          # Runtime library path so dynamically-linked deps (libGL, wayland, etc.)
          # are findable when you `cargo run` from the shell.
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath buildInputs;

          shellHook = ''
            echo "Rust $(rustc --version)"
            echo "Linker: mold ($(mold --version | head -n1))"
            echo "Targets: $(rustc --print target-list | grep -E '^(wasm32-unknown-unknown|x86_64-unknown-linux-gnu)$' | tr '\n' ' ')"
          '';
        };
      }
    );
}
