#!/usr/bin/env bash
# Example: building a moat shell by hand, without nix.
#
# `sandbox.wrap` is convenience, not a requirement. A shell is a directory with
# two things in it:
#
#   bin/<name>            symlink to moat-wrapper, one per binary
#   share/moat/manifest   "<name>\t<absolute path to the real binary>" per line
#
# The wrapper resolves its own name in the manifest, applies the profile for
# that binary, and execs the real one. Anything that produces that layout works,
# so a Homebrew or system binary can be wrapped the same way as a nix one.
#
# Usage:
#   ./wrap-without-nix.sh ~/.local/share/moat-shells/node $(which node) $(which npm)
#   export PATH="$HOME/.local/share/moat-shells/node/bin:$PATH"
#   cd ~/git/some-project
#   MOAT_ROOT="$PWD" npm install
#
# MOAT_ROOT has to be set, since nothing else tells the wrapper where the
# boundary is. `moat shell` and `moat run` set it for you; on this path it is
# yours to set, and a wrapped binary refuses to start without it.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <shell-dir> <binary>..." >&2
  exit 1
fi

shell_dir=$1
shift

wrapper=$(command -v moat-wrapper || true)
if [ -z "$wrapper" ]; then
  echo "moat-wrapper not on PATH; build it with 'zig build' and add zig-out/bin" >&2
  exit 1
fi
# The manifest is found relative to the symlink, so the wrapper's own location
# does not matter, but it must stay readable: keep it out of a project root.
wrapper=$(cd "$(dirname "$wrapper")" && pwd)/$(basename "$wrapper")

mkdir -p "$shell_dir/bin" "$shell_dir/share/moat"
manifest="$shell_dir/share/moat/manifest"
: >"$manifest"

for bin in "$@"; do
  if [ ! -x "$bin" ]; then
    echo "not executable: $bin" >&2
    exit 1
  fi
  # Resolve to an absolute path: the manifest is read from a different cwd.
  real=$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")
  name=$(basename "$real")
  printf '%s\t%s\n' "$name" "$real" >>"$manifest"
  ln -sfn "$wrapper" "$shell_dir/bin/$name"
  echo "wrapped $name -> $real"
done

echo
echo "add to PATH:  export PATH=\"$shell_dir/bin:\$PATH\""
echo "then run:     MOAT_ROOT=\"\$PWD\" $(basename "$1")"
