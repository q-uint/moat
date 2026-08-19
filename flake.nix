{
  description = "Moat - sandboxed dev environments for macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, zig-overlay }:
  let
    system = "aarch64-darwin";
    pkgs = nixpkgs.legacyPackages.${system};
    zig-master = zig-overlay.packages.${system}.master;

    wrapper = pkgs.stdenv.mkDerivation {
      name = "moat-wrapper";
      src = self;
      nativeBuildInputs = [ zig-master ];
      dontConfigure = true;
      buildPhase = ''
        export HOME=$TMPDIR
        zig build -Doptimize=ReleaseSafe --prefix $out
      '';
      installPhase = "true";
    };
    sandbox = import ./nix/sandbox.nix { inherit pkgs wrapper; };
  in {
    lib.${system} = { inherit sandbox; };

    packages.${system} = rec {
      default = moat;

      zig = sandbox.wrap {
        name = "zig";
        paths = [ "${zig-master}/bin" ];
      };

      moat = pkgs.stdenv.mkDerivation {
        name = "moat";
        src = self;
        nativeBuildInputs = [ zig-master ];
        dontConfigure = true;
        buildPhase = ''
          export HOME=$TMPDIR
          zig build -Doptimize=ReleaseSafe --prefix $out
        '';
        installPhase = "true";
      };
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ zig-master ];
    };
  };
}
