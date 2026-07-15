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
        schemify = (pkgs.makeRustPlatform {
          cargo = rustToolchain;
          rustc = rustToolchain;
        }).buildRustPackage {
          pname = "schemify";
          version = "0.1.0";
          src = pkgs.lib.cleanSource ./.;
          cargoLock.lockFile = ./Cargo.lock;
          cargoLock.outputHashes = {
            "cktimg-0.1.0" = "sha256-An8flQdF76uEfVOvEamMSgupymI8hfLGoeATPx70WIU=";
          };

          # Plugins are excluded workspace members with their own
          # lockfiles; build just the app binary.
          cargoBuildFlags = [ "--bin" "schemify" ];

          inherit buildInputs;
          nativeBuildInputs = nativeBuildInputs ++ [ pkgs.makeWrapper ];

          # core/build.rs bakes this store path in directly (no copy), so
          # the binary finds the pyspice_rs module at runtime.
          PYSPICE_BUNDLE_DIR = pyspiceSitePackages;

          # Tests need ngspice + a writable HOME; covered by `cargo test`
          # in the devshell and CI instead.
          doCheck = false;

          postFixup = ''
            wrapProgram $out/bin/schemify \
              --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath buildInputs} \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.ngspice ]} \
              --set-default PYTHON ${pkgs.python312}/bin/python3.12 \
              --set-default PDK_ROOT ${sky130Pdk}
          '';

          meta = {
            description = "Schematic capture for circuit design with sim runner, MCP server, and plugins";
            homepage = "https://github.com/UW-ASIC/Schemify";
            mainProgram = "schemify";
          };
        };
      in
      {
        packages.default = schemify;
        packages.schemify = schemify;

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
