# Example: using moat in your own flake to define sandboxed shells.
#
# Users create their own flake that imports moat and defines shells
# using moat's sandbox.wrap function. Each shell is a set of tool
# binaries that run inside a macOS sandbox.
#
# Usage:
#   nix build .#rust    -- build sandboxed rust tools
#   nix build .#go      -- build sandboxed go tools
#   moat shell rust go  -- enter a shell with both
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    moat.url = "github:q-uint/moat";
  };

  outputs = { nixpkgs, moat, ... }:
  let
    system = "aarch64-darwin";
    pkgs = nixpkgs.legacyPackages.${system};
    sandbox = moat.lib.${system}.sandbox;
  in {
    packages.${system} = {

      rust = sandbox.wrap {
        name = "rust";
        paths = [
          "${pkgs.rustc}/bin"
          "${pkgs.cargo}/bin"
          "${pkgs.rustfmt}/bin"
          "${pkgs.clippy}/bin"
        ];
      };

      go = sandbox.wrap {
        name = "go";
        paths = [
          "${pkgs.go}/bin"
          "${pkgs.golangci-lint}/bin"
        ];
      };

      zig = sandbox.wrap {
        name = "zig";
        paths = [
          "${pkgs.zig}/bin"
        ];
      };

    };
  };
}
