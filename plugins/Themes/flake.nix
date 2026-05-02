{
  description = "Themes – Schemify Python plugin";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; }; in {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.python3
            pkgs.gcc
            pkgs.gnumake
          ];
          buildInputs = [
            pkgs.python3
          ];
          shellHook = ''
            echo "Themes Plugin Dev Shell"
            echo "  make          - build native .so"
            echo "  make install  - install to ~/.config/Schemify/"
          '';
        };
      }
    );
}
