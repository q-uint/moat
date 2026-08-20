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
moat shell zig                    # enter a sandboxed zig shell
moat shell rust go                # combine multiple shells
moat shell                        # shells detected for this directory
moat run zig -- zig build         # run one command sandboxed, then exit
moat run -- zig build             # same, shells detected
moat run --trace zig -- zig build # report what the sandbox blocked
moat link . rust go               # associate current dir with shells
moat detect                       # show what shells would activate
moat check                        # validate config (paths, shells, flake)
moat -v shell rust                # verbose: show build progress
```

With no shell names, `shell` and `run` use whatever `moat detect` reports for the current directory, and say which shells they picked.

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
    .default = .{ "just", "jq" },
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

### default

`default` names shells added to every session, on top of whatever is named or detected — a place for tools you want everywhere, like `just` or `jq`.

They come last on `PATH`, so a named or detected shell wins when both provide the same binary. Adding a tool to `default` cannot change which one an existing project already resolves to.

`moat detect` lists them separately, since they apply regardless of directory.

### allow

Grants a binary access to a path outside the root, without giving it a full escape:

```bash
moat allow git ~/.gitconfig            # read-only
moat allow cargo ~/.cargo --write      # read/write
moat allow cargo ~/.rustup --exec      # read + run binaries from there
moat allow '*' ~/.config/nvim          # every binary
moat unallow zig ~/.cache/zig          # remove a grant
```

Re-granting a path widens the existing rule rather than adding a second one, and `~/x` and `/Users/you/x` are treated as the same path. Rules scoped by `dirs` are left alone by both commands.

Which writes:

```zig
.allow = .{
    .{ .bin = "git", .paths = .{ "~/.gitconfig" } },
    .{ .bin = "cargo", .paths = .{ "~/.cargo" }, .write = true },
    .{ .bin = "cargo", .paths = .{ "~/work-cargo" }, .write = true, .dirs = .{ "/Users/you/work" } },
},
```

Read-only unless `write = true`. `dirs` restricts a rule to certain project roots, so the same binary can have read access in one project and write access in another; an empty `dirs` applies everywhere. Paths are stored with `~` unexpanded so the config stays portable.

`exec = true` adds `process-exec` and `file-map-executable`. Neither `file-read*` nor `file*` implies them, so a toolchain that runs binaries out of a granted directory — `cargo` launching a `~/.rustup` toolchain, `zig` running a build helper from its cache — needs it. `write` and `exec` are independent.

Under `$MOAT_ROOT` exec is already allowed, so a tool whose cache can move inside the root needs [`MOAT_ENV_HOME`](#moat_env_home) rather than this.

`moat shell` applies one profile to the whole session, so grants are unioned: a rule for `git` is in effect for everything in that shell. Per-binary enforcement would need each wrapped binary to sandbox itself, which no current entry point does.

Prefer `allow` over `jailbreak`. A grant is a specific path at a specific access level; a jailbreak is unlimited access to everything.

A path that is `$HOME` or an ancestor of it is refused, since it would undo the profile. So are relative paths, paths containing `..`, and paths with quotes or control characters. Each of those would otherwise produce a rule that silently matches nothing, or a malformed profile.

### jailbreak

`jailbreak` lists binaries that skip the sandbox entirely (e.g. tools that need full HOME access, like `git` reading `~/.gitconfig`).

Names are resolved against `PATH` to an absolute path before being written into the profile, because SBPL matches exec paths, not names. A name that cannot be resolved is reported and skipped rather than silently ignored.

**A jailbreak is a total escape, not a widened permission.** The exempted binary runs with no sandbox at all, and so does everything it execs, including git hooks, subprocesses, and anything a config file tells it to run. Jailbreaking `git` in a repository whose hooks you do not control gives those hooks unsandboxed access to your entire machine. Keep the list as short as you can.

Detection rules match when all listed markers exist in the directory. Multiple matching rules stack their shells.

Per-project override: create a `.moat-shell` file (gitignored) with one shell name per line.

## Running one command

`moat run` builds the same profile as `moat shell`, runs a single command inside it, and exits with that command's status:

```bash
moat run zig -- zig build
moat run rust go -- cargo test
```

Shell names come before `--`, the command after it. The command is resolved against the shell's `PATH`, so `zig` is the wrapped binary, not one already on your `PATH`.

## Finding what the sandbox blocked

`--trace` reports the paths the sandbox denied during the run, and prints a `moat allow` line for each:

```
$ moat run --trace zig -- zig build
error: unable to open global cache directory "/Users/you/.cache/zig": PermissionDenied

moat: 1 path(s) denied by the sandbox
  zig            file-read-data         /Users/you/.cache/zig

to grant, pick the ones you actually need:
  moat allow zig /Users/you/.cache/zig
```

The suggested grant is read-only, matching the operation that was denied. A tool that also writes there needs `--write`, and a tool whose cache lives under `$HOME` is usually better served by [`MOAT_ENV_HOME`](#moat_env_home) than by a grant.

Attribution is by process id: anything sandboxed that starts after moat is attributed to the run, including unrelated processes running concurrently. Check the process column before acting on a line.

Denials come from the macOS unified log, which the sandbox itself denies access to, so `--trace` runs the command in a child and reads the log from the unconfined parent.

Entries reach the log a moment after the event, so `--trace` waits briefly before reading. A heavily loaded log daemon can still lag; a run that reports nothing is not proof that nothing was denied.

The longer the command runs, the more unrelated processes fall inside the window, which is why `--trace` covers a single command rather than `moat shell`. To investigate a failure inside a shell, re-run the command that failed under `moat run --trace`.

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
| `MOAT_ENV_<NAME>` | sets `<NAME>=value` inside the sandbox, then removes the prefixed variable (`HOME` is [special-cased](#moat_env_home)) |
| `TMPDIR` | pointed at `$MOAT_ROOT/.moat/tmp`, since `/tmp` is denied |

`MOAT_ENV_*` is applied by the wrapper before the sandbox is installed, so it can pass values to a wrapped binary without leaking the prefixed name into its environment. For example `MOAT_ENV_FOO=bar` runs the binary with `FOO=bar`.

### MOAT_ENV_HOME

Many tools keep a cache or config under `$HOME`, which the sandbox denies. Pointing `HOME` somewhere writable is the usual fix:

```bash
MOAT_ENV_HOME=$MOAT_ROOT/.moat/home zig build
```

Without it, a tool that needs its home cache fails on a path it cannot reach:

```
error: unable to open global cache directory "/Users/you/.cache/zig": PermissionDenied
```

`MOAT_ENV_HOME` is refused unless the path is actually writable inside the sandbox: either under `$MOAT_ROOT`, or covered by a write grant. A fake `HOME` the tool cannot write to breaks it further in, with an error that points at the tool rather than at the override. The refusal names both ways out:

```
moat-wrapper: MOAT_ENV_HOME=/private/tmp/elsewhere is not writable in the sandbox.
  Put it under $MOAT_ROOT (/Users/you/git/project), e.g. $MOAT_ROOT/.moat/home,
  or grant it explicitly:  moat allow zig /private/tmp/elsewhere --write
```

The directory is created if missing, so tools that expect `$HOME` to exist but do not create it work too.

`$MOAT_ROOT/.moat/home` is the suggested location: it sits inside the root, so it is writable without a grant, and `.moat/.gitignore` already ignores its own contents.

Only the real `HOME` is used to find `~/.config/moat/config.zon` and to check that the root does not contain home. An override cannot satisfy those guards.

Inside `moat shell` the session profile is already active and the wrapper does not compile its own, so the writability check is skipped there; the override and the directory creation still apply.

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
