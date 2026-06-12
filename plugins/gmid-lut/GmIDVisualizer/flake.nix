{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      volare = pkgs.python3Packages.buildPythonPackage rec {
        pname = "volare";
        version = "0.20.6";
        pyproject = true;
        src = pkgs.fetchPypi {
          inherit pname version;
          sha256 = "a2ebd9b8a81de144dbc352eab71670e7e4b3e4713272387479a75935569e076a";
        };
        build-system = with pkgs.python3Packages; [ poetry-core ];
        dependencies = with pkgs.python3Packages; [
          click
          httpx
          pcpp
          pyyaml
          rich
          zstandard
        ];
        pythonRelaxDeps = [ "rich" ];
        doCheck = false;
      };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        CC = "clang";
        CXX = "clang++";

        packages = with pkgs; [
          cmake
          ninja
          clang_19
          llvmPackages_19.libcxx

          # Simulators (optional — needed to actually run sweeps)
          ngspice
          (xyce.override { enableDocs = false; enableTests = false; })

          # PDK installer (optional — needed to test with real process models)
          volare
        ];
      };
    };
}
