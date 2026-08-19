# Moat

Sandboxed dev environments for macOS (aarch64).

Every dev tool runs inside a macOS sandbox that denies filesystem access by default. Your project root is writable; your home directory, other projects, `/Library`, `/Volumes`, `/tmp`, and other users' files are not readable at all.

## What the sandbox allows

The profile is `(deny default)` plus an explicit allowlist. A missing rule shows up as a tool that breaks loudly, not as a hole nobody notices.

Allowed:

- full read/write under `$MOAT_ROOT` (your project root)
- read + execute of `/nix/store`, `/bin`, `/sbin`, `/usr/bin`, `/usr/sbin`, `/usr/lib`, `/usr/libexec`, `/System`
- read of `/etc` and `/usr/share`; the null/zero/random devices; the controlling terminal
- the system base profile `bsd.sb`, which supplies dyld, `sysctl-read` and `mach-lookup` plumbing (it grants no data reads under `/Users`)
- **unrestricted network access**

Denied, including silently to processes that expect them:

- everything under `$HOME` outside the project root: SSH keys, dotfiles, browser profiles, `~/Library`
- `/tmp` and `/private/tmp`, which are shared with every other user and process on the machine
- `/Library`, `/Volumes`, `/Applications`, other entries under `/Users`

Because `/tmp` is denied, moat points `TMPDIR` at `$MOAT_ROOT/.moat/tmp`. That directory contains a `.gitignore` of `*`, so it ignores its own contents and itself; your `.gitignore` is not modified.

Network access is deliberately unrestricted, because dev tools fetch dependencies constantly. A compromised tool inside the moat can still send anything it can read to a remote host. The sandbox limits *what it can read*, not whether it can talk.

Inspired by [nmattia/dune](https://github.com/nmattia/dune).

## Quick start

```bash
moat shell zig         # enter a sandboxed zig shell
moat shell rust go     # combine multiple shells
moat link . rust go    # associate current dir with shells
moat detect            # show what shells would activate
moat check             # validate config (paths, shells, flake)
moat -v shell rust     # verbose: show build progress
```

## How it works

1. You define shells in your own nix flake using `moat.lib.<system>.sandbox.wrap`
2. `wrap` takes a list of binary paths and the zig-built `moat-wrapper`
3. Each binary becomes a symlink to `moat-wrapper`, which reads `argv[0]`, looks up the real binary in a manifest, generates an SBPL sandbox profile, and applies it via the private libsandbox API before exec'ing the real binary
4. The profile is `(deny default)` plus the allowlist above: full access under `$MOAT_ROOT`, read+execute of system and nix store paths, and network

`moat shell` refuses to start when the sandbox root is `$HOME` or an ancestor of it, since a root containing home would grant access to everything home is meant to withhold.

## Configuration

`~/.config/moat/config.zon`:

```zig
.{
    .jailbreak = .{ "git" },
    .links = .{
        .{ .dir = "/Users/you/git/project-a", .shells = .{ "rust" } },
        .{ .dir = "/Users/you/git/project-b", .shells = .{ "rust", "go" } },
    },
    .detect = .{
        .{ .markers = .{ "Cargo.toml" }, .shells = .{ "rust" } },
        .{ .markers = .{ "go.mod" }, .shells = .{ "go" } },
        .{ .markers = .{ "build.zig.zon" }, .shells = .{ "zig" } },
    },
}
```

### allow

Grants a binary access to a path outside the root, without giving it a full escape:

```bash
moat allow git ~/.gitconfig            # read-only
moat allow cargo ~/.cargo --write      # read/write
moat allow '*' ~/.config/nvim          # every binary
```

Which writes:

```zig
.allow = .{
    .{ .bin = "git", .paths = .{ "~/.gitconfig" } },
    .{ .bin = "cargo", .paths = .{ "~/.cargo" }, .write = true },
    .{ .bin = "cargo", .paths = .{ "~/work-cargo" }, .write = true, .dirs = .{ "/Users/you/work" } },
},
```

Read-only unless `write = true`. `dirs` restricts a rule to certain project roots, so the same binary can have read access in one project and write access in another; an empty `dirs` applies everywhere. Paths are stored with `~` unexpanded so the config stays portable.

`moat shell` applies one profile to the whole session, so grants are unioned: a rule for `git` is in effect for everything in that shell. Per-binary enforcement would need each wrapped binary to sandbox itself, which no current entry point does.

Prefer `allow` over `jailbreak`. A grant is a specific path at a specific access level; a jailbreak is unlimited access to everything.

A path that is `$HOME` or an ancestor of it is refused, since it would undo the profile. So are relative paths, paths containing `..`, and paths with quotes or control characters. Each of those would otherwise produce a rule that silently matches nothing, or a malformed profile.

### jailbreak

`jailbreak` lists binaries that skip the sandbox entirely (e.g. tools that need full HOME access, like `git` reading `~/.gitconfig`).

Names are resolved against `PATH` to an absolute path before being written into the profile, because SBPL matches exec paths, not names. A name that cannot be resolved is reported and skipped rather than silently ignored.

**A jailbreak is a total escape, not a widened permission.** The exempted binary runs with no sandbox at all, and so does everything it execs, including git hooks, subprocesses, and anything a config file tells it to run. Jailbreaking `git` in a repository whose hooks you do not control gives those hooks unsandboxed access to your entire machine. Keep the list as short as you can.

Detection rules match when all listed markers exist in the directory. Multiple matching rules stack their shells.

Per-project override: create a `.moat-shell` file (gitignored) with one shell name per line.

## Defining shells

Moat ships a `zig` shell. To define your own, create a nix flake (see `examples/flake.nix`):

```nix
{
  inputs.moat.url = "github:q-uint/moat";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { moat, nixpkgs, ... }:
  let
    pkgs = nixpkgs.legacyPackages.aarch64-darwin;
    sandbox = moat.lib.aarch64-darwin.sandbox;
  in {
    packages.aarch64-darwin.rust = sandbox.wrap {
      name = "rust";
      paths = [ "${pkgs.rustc}/bin" "${pkgs.cargo}/bin" ];
    };
  };
}
```

Point `MOAT_FLAKE` at your flake and `moat shell rust` just works.

## Environment

| Variable | Meaning |
| --- | --- |
| `MOAT_FLAKE` | flake reference for shells (default `github:q-uint/moat`) |
| `MOAT_ROOT` | sandbox boundary; set by `moat shell` |
| `MOAT_JAILBREAK` | colon-separated binaries that skip the sandbox |
| `MOAT_ENV_<NAME>` | sets `<NAME>=value` inside the sandbox, then removes the prefixed variable |
| `TMPDIR` | pointed at `$MOAT_ROOT/.moat/tmp`, since `/tmp` is denied |

`MOAT_ENV_*` is applied by the wrapper before the sandbox is installed, so it can pass values to a wrapped binary without leaking the prefixed name into its environment. For example `MOAT_ENV_HOME=/somewhere` runs the binary with `HOME=/somewhere`.

## Development

```bash
nix develop            # enter dev shell with zig
zig build              # build moat + moat-wrapper
zig build test         # unit tests
zig build e2e          # CLI integration tests (fast, no nix)
zig build e2e-sandbox  # sandbox enforcement tests (requires nix)
```

## License

[MPL-2.0](LICENSE)
