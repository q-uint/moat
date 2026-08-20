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

    # Both outputs come from the same `zig build`, so they share one definition:
    # two copies drifted apart once already.
    build = name: pkgs.stdenv.mkDerivation {
      inherit name;
      src = self;
      # The CLI links nix's C API; nix.dev carries its headers and .pc files.
      nativeBuildInputs = [ zig-master pkgs.pkg-config ];
      buildInputs = [ pkgs.nix.dev ];
      dontConfigure = true;
      buildPhase = ''
        export HOME=$TMPDIR
        zig build -Doptimize=ReleaseSafe --prefix $out
      '';
      installPhase = "true";
    };
    wrapper = build "moat-wrapper";
    sandbox = import ./nix/sandbox.nix { inherit pkgs wrapper; };
  in {
    lib.${system} = { inherit sandbox; };

    packages.${system} = rec {
      default = moat;

      zig = sandbox.wrap {
        name = "zig";
        paths = [ "${zig-master}/bin" ];
      };

      moat = build "moat";
    };

    # zig-out/bin first, so `moat` is the tree you just built and not a
    # profile-installed copy.
    devShells.${system}.default = pkgs.mkShell {
      # nix.dev carries the C API headers and .pc files the CLI links against.
      # The `nix` CLI itself stays the system one, so the daemon it talks to and
      # the client speaking to it are not two different versions.
      packages = [ zig-master pkgs.pkg-config pkgs.nix.dev ];
      shellHook = ''
        export PATH="$PWD/zig-out/bin:$PATH"
      '';
    };
  };
}
