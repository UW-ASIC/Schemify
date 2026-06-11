{
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

        sky130Version = "ff08c23db8359afce3f134c454e7930586d0641c";
        sky130Url = "https://github.com/fossi-foundation/ciel-releases/releases/download/sky130-${sky130Version}";
        sky130Common = pkgs.fetchurl {
          url = "${sky130Url}/common.tar.zst";
          hash = "sha256-f36Ny7e5irFaX57QrNO9P5M/GSUXFySpryWxihzW9Fc=";
        };
        sky130FdPr = pkgs.fetchurl {
          url = "${sky130Url}/sky130_fd_pr.tar.zst";
          hash = "sha256-pr2rLm/4+O64GImLK0hB2dU/o9/vbdJUg4CuMvNE608=";
        };
        sky130Pdk = pkgs.runCommand "sky130-pdk-${sky130Version}" { nativeBuildInputs = [ pkgs.zstd ]; } ''
          mkdir -p $out
          # sky130A only; the archives also carry the sky130B variant.
          tar --zstd -C $out -xf ${sky130Common} sky130A
          tar --zstd -C $out -xf ${sky130FdPr} sky130A
        '';

        pyspicePkg = pyspice.packages.${system}.default;
        pyspiceSitePackages = "${pyspicePkg}/${pyspicePkg.passthru.pythonModule.sitePackages}";

        nativeBuildInputs = with pkgs; [
          pkg-config
          clang
        ];

        buildInputs = with pkgs; [
          # Windowing / input
          libxkbcommon
          libGL

          # Wayland
          wayland
          libdecor

          # X11 stack (for XWayland / non-Wayland sessions)
          libx11
          libxcursor
          libxrandr
          libxi
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
            mdbook

            python312
          ];

          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath buildInputs;
          PYSPICE_MODULE_DIR = pyspiceSitePackages;
          PDK_ROOT = "${sky130Pdk}";
        };
      }
    );
}
