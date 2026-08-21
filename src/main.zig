const std = @import("std");
const config = @import("config.zig");
const sandbox = @import("sandbox.zig");
const denials = @import("denials.zig");
const nix = @import("nix.zig");
const confirm = @import("confirm.zig");
const lock = @import("lock.zig");
const env_mod = @import("env.zig");

const usage_text =
    \\moat - sandboxed dev environments
    \\
    \\usage:
    \\  moat shell [name...]         enter a sandboxed shell (detected if unnamed)
    \\  moat run [name...] -- <cmd>  run one command sandboxed, then exit
    \\  moat allow [bin path]        list grants, or add one (--write, --exec)
    \\  moat link [dir name...]      list directory associations, or add one
    \\  moat approvals               list remembered confirm answers
    \\  moat update [name...]        move pinned shells to the current revision
    \\  moat detect [dir]            show which shells would activate
    \\  moat check                   validate config (paths, shells)
    \\  moat help                    show this message
    \\
    \\flags:
    \\  -r, --remove                 remove instead of add (allow, link, approvals)
    \\  -v, --verbose                show build progress
    \\  --trace                      report denied paths on exit (run only)
    \\
    \\environment:
    \\  MOAT_FLAKE    flake reference for shells (default: github:q-uint/moat)
    \\  MOAT_ROOT     sandbox boundary (set automatically by shell)
    \\  MOAT_CONFIRM  never | always (default: ask for binaries listed in `confirm`)
    \\
;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var args_it = init.minimal.args.iterate();
    _ = args_it.next(); // skip argv[0]

    var verbose = false;
    var trace = false;
    var cmd: ?[]const u8 = null;
    while (args_it.next()) |arg| {
        if (isFlag(arg, &verbose, &trace)) continue;
        cmd = arg;
        break;
    }
    const command = cmd orelse {
        printUsage(io);
        std.process.exit(1);
    };

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const cmd_alloc = arena.allocator();

    // Read once, up front: every later lookup goes through this. From the arena,
    // since a command that returns instead of exec'ing would otherwise leak it.
    const env = try env_mod.from(cmd_alloc, init.environ_map);
    const home = env.home orelse usageError("HOME not set", .{});

    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(alloc);
    // Everything after `--` is the child command; its flags are not ours.
    var passthrough = false;
    while (args_it.next()) |a| {
        if (!passthrough) {
            if (std.mem.eql(u8, a, "--")) passthrough = true;
            if (isFlag(a, &verbose, &trace)) continue;
        }
        try rest.append(alloc, a);
    }

    if (std.mem.eql(u8, command, "shell")) return cmdShell(cmd_alloc, io, init.environ_map, env, rest.items, verbose);
    if (std.mem.eql(u8, command, "run")) return cmdRun(cmd_alloc, io, init.environ_map, env, rest.items, verbose, trace);
    if (std.mem.eql(u8, command, "update")) return cmdUpdate(cmd_alloc, io, home, env.flake, rest.items);
    if (std.mem.eql(u8, command, "allow")) return cmdAllow(cmd_alloc, io, home, rest.items);
    if (std.mem.eql(u8, command, "approvals")) return cmdApprovals(cmd_alloc, io, home, rest.items);
    if (std.mem.eql(u8, command, "link")) return cmdLink(cmd_alloc, io, home, rest.items);
    if (std.mem.eql(u8, command, "detect")) return cmdDetect(cmd_alloc, io, home, rest.items);
    if (std.mem.eql(u8, command, "check")) return cmdCheck(cmd_alloc, io, env);
    if (std.mem.eql(u8, command, "help")) return printUsage(io);

    std.debug.print("moat: unknown command '{s}'\n", .{command});
    printUsage(io);
    std.process.exit(1);
}

// Help is output, not a diagnostic, so it goes to stdout.
fn printUsage(io: std.Io) void {
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    stdout.interface.writeAll(usage_text) catch return;
    stdout.flush() catch {};
}

// Usage errors must be detectable by anything scripting moat.
fn usageError(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("moat: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

// One nix session per moat run, created only when something actually needs
// evaluating: a lock hit whose store path is present never gets here.
const NixSession = struct {
    handle: ?nix.Nix = null,

    fn get(self: *NixSession, alloc: std.mem.Allocator) !*nix.Nix {
        if (self.handle == null) {
            const running = nix.runningVersion();
            if (!nix.versionMatches(nix.tested_version, running)) {
                std.debug.print("moat: linked against nix {s}, built for {s}; the C API has no ABI promise\n", .{ running, nix.tested_version });
            }
            self.handle = nix.Nix.init(alloc) catch |err| {
                std.debug.print("moat: cannot initialise nix: {s}\n", .{@errorName(err)});
                return err;
            };
        }
        return &self.handle.?;
    }

    fn deinit(self: *NixSession) void {
        if (self.handle) |*h| h.deinit();
    }
};

fn nixBuild(session: *NixSession, alloc: std.mem.Allocator, flake_ref: []const u8, attr: []const u8) ![]const u8 {
    const n = try session.get(alloc);
    return n.build(flake_ref, attr, nix.system) catch |err| {
        std.debug.print("moat: cannot build {s}#{s}: {s}\n", .{ flake_ref, attr, n.lastError() });
        return err;
    };
}

// Empty when the ref cannot be pinned or nix cannot resolve a revision for it.
fn resolveRev(session: *NixSession, alloc: std.mem.Allocator, flake: []const u8) []const u8 {
    if (!lock.pinnable(flake)) return "";
    const n = session.get(alloc) catch return "";
    return n.rev(flake) orelse "";
}

// Builds from the locked ref when there is one, so a moving branch is followed
// only by `moat update`. A recorded store path that still exists skips nix
// entirely, which is also the fast path.
fn buildShell(session: *NixSession, alloc: std.mem.Allocator, io: std.Io, flake: []const u8, current: lock.Lock, name: []const u8, verbose: bool) !struct { out: []const u8, entry: ?lock.Lock.Entry } {
    const parts = lock.split(name);
    const base = parts.flake orelse flake;

    if (current.lookup(name)) |e| {
        if (e.out.len > 0) {
            if (std.Io.Dir.cwd().access(io, e.out, .{})) |_| {
                if (verbose) std.debug.print("moat: {s} pinned{s}{s}\n", .{ name, if (e.rev.len > 0) " at " else " (unpinned source)", e.rev });
                return .{ .out = e.out, .entry = null };
            } else |_| {}
        }
        // Gone from the store: rebuild from the same ref, not from the branch.
        if (verbose) std.debug.print("moat: rebuilding {s}...\n", .{name});
        const ref = if (e.ref.len > 0) e.ref else base;
        const out = try nixBuild(session, alloc, ref, parts.attr);
        return .{ .out = out, .entry = .{ .name = name, .ref = e.ref, .rev = e.rev, .out = out } };
    }

    // First use: resolve the mutable ref once, and record what it resolved to.
    if (verbose) std.debug.print("moat: building {s}...\n", .{name});
    const rev = resolveRev(session, alloc, base);
    const pinned = try lock.withRev(alloc, base, rev);
    const out = try nixBuild(session, alloc, pinned, parts.attr);
    if (rev.len > 0) {
        std.debug.print("moat: pinned {s} to {s}\n", .{ name, lock.shortRev(rev) });
    } else {
        std.debug.print("moat: {s} cannot be pinned ({s}); `moat update` will not help\n", .{ name, base });
    }
    return .{ .out = out, .entry = .{ .name = name, .ref = pinned, .rev = rev, .out = out } };
}

fn buildShells(alloc: std.mem.Allocator, io: std.Io, home: []const u8, flake: []const u8, shells: []const []const u8, verbose: bool) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    var current = try lock.load(alloc, io, home);
    var session: NixSession = .{};
    defer session.deinit();
    var dirty = false;
    for (shells) |name| {
        const built = try buildShell(&session, alloc, io, flake, current, name, verbose);
        try paths.append(alloc, built.out);
        if (built.entry) |e| {
            current = try lock.upsert(alloc, current, e);
            dirty = true;
        }
    }
    if (dirty) lock.save(alloc, io, home, current) catch |err| {
        std.debug.print("moat: cannot write lock: {s}\n", .{@errorName(err)});
    };
    return paths.items;
}

fn nowSeconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

fn indexOfArg(args: []const []const u8, needle: []const u8) ?usize {
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, needle)) return i;
    }
    return null;
}

fn isFlag(arg: []const u8, verbose: *bool, trace: *bool) bool {
    if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
        verbose.* = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--trace")) {
        trace.* = true;
        return true;
    }
    return false;
}

// Named shells, or the detected ones when none are named, plus the configured
// defaults. Defaults go last so a named shell wins on PATH.
fn resolveShells(alloc: std.mem.Allocator, io: std.Io, home: []const u8, args: []const []const u8) ![]const []const u8 {
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &cwd_buf);
    const dir = cwd_buf[0..n];

    const loaded = try config.load(alloc, io, home);
    var out: std.ArrayList([]const u8) = .empty;

    if (args.len > 0) {
        try config.appendUnique(alloc, &out, args);
    } else if (try config.resolve(alloc, io, &loaded, dir)) |found| {
        try config.appendUnique(alloc, &out, found.shells);
        // The profile depends on this, so never pick silently.
        std.debug.print("moat: using", .{});
        for (found.shells) |s| std.debug.print(" {s}", .{s});
        std.debug.print(" (via {s})\n", .{switch (found.source) {
            .link => "link",
            .detect => "detect rule",
        }});
    }
    try config.appendUnique(alloc, &out, loaded.config.default);

    if (out.items.len == 0) {
        std.debug.print("moat: no shells configured for {s}\n", .{dir});
        std.debug.print("hint: name one, or 'moat link {s} <shell>', or add a detect rule\n", .{dir});
        std.process.exit(1);
    }
    return out.items;
}

// Re-execs moat as a child; the parent stays unsandboxed to read the log.
fn traceChild(alloc: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map, tail: []const []const u8) !void {
    const self_exe = try std.process.executablePathAlloc(io, alloc);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(alloc, self_exe);
    try argv.appendSlice(alloc, tail);

    // pid floor for attribution.
    const min_pid: u32 = @intCast(std.c.getpid());
    const started = nowSeconds(io);

    var child = try std.process.spawn(io, .{ .argv = argv.items, .environ_map = environ });
    const term = try child.wait(io);

    std.debug.print("\n", .{});
    var found = settledCollect(alloc, io, started, min_pid) catch {
        std.debug.print("moat: cannot read denials (log unavailable)\n", .{});
        if (!term.success()) std.process.exit(1);
        return;
    };
    // A failed command usually has a denial behind it, so wait out the lag.
    // A clean run never pays this.
    var tries: u8 = 0;
    while (found.len == 0 and !term.success() and tries < 3) : (tries += 1) {
        found = settledCollect(alloc, io, started, min_pid) catch break;
    }

    if (found.len > 0) {
        var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = std.process.currentPath(io, &cwd_buf) catch 0;
        denials.report(found, cwd_buf[0..n]);
    } else if (!term.success()) {
        std.debug.print("moat: command failed, no denials found -- log entries can lag, so rerun to confirm\n", .{});
    } else {
        std.debug.print("moat: no denials recorded\n", .{});
    }
    if (!term.success()) std.process.exit(1);
}

// Entries reach the log after the event.
fn settledCollect(alloc: std.mem.Allocator, io: std.Io, started: i64, min_pid: u32) ![]denials.Denial {
    std.Io.sleep(io, .{ .nanoseconds = 1500 * std.time.ns_per_ms }, .awake) catch {};
    const elapsed: u64 = @intCast(@max(0, nowSeconds(io) - started));
    const window = try std.fmt.allocPrint(alloc, "{d}s", .{elapsed + 5});
    return denials.collect(alloc, io, window, min_pid);
}

// A session profile is one grant set for many binaries, so a confirm entry for
// the command being run or for any shell in it applies.
fn confirmNeeded(list: []const []const u8, label: []const u8, shells: []const []const u8, mode: confirm.Mode) bool {
    if (confirm.required(list, label, mode)) return true;
    if (mode != .config) return false;
    for (shells) |s| {
        if (confirm.required(list, s, .config)) return true;
    }
    return false;
}

// Builds the shells, installs the profile, and leaves the caller to exec.
fn prepareSession(alloc: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map, env: env_mod.Env, shells: []const []const u8, verbose: bool, label: []const u8) ![]const u8 {
    const home = env.home.?;
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &cwd_buf);
    const cwd = try alloc.dupe(u8, cwd_buf[0..n]);
    const args = shells;

    const profile = sandbox.Profile{ .root = cwd, .home = home };
    profile.validate() catch {
        std.debug.print("moat: refusing to sandbox from {s}: root contains HOME ({s}), which would grant full home access\n", .{ cwd, home });
        std.process.exit(1);
    };

    const loaded = try config.load(alloc, io, home);
    // buildShells already reported; a stack trace on top is noise.
    const store_paths = buildShells(alloc, io, home, env.flake, args, verbose) catch std.process.exit(1);

    var path_buf: std.ArrayList(u8) = .empty;
    for (store_paths) |p| {
        if (path_buf.items.len > 0) try path_buf.append(alloc, ':');
        try path_buf.appendSlice(alloc, p);
        try path_buf.appendSlice(alloc, "/bin");
    }
    if (env.path.len > 0) {
        try path_buf.append(alloc, ':');
        try path_buf.appendSlice(alloc, env.path);
    }

    try environ.put("PATH", path_buf.items);
    try environ.put("MOAT_ROOT", cwd);

    // Config names jailbreaks; SBPL matches absolute exec paths only.
    var jailbreaks: std.ArrayList([]const u8) = .empty;
    for (loaded.config.jailbreak) |name| {
        const abs = (try sandbox.resolveInPath(alloc, io, path_buf.items, name)) orelse {
            std.debug.print("moat: jailbreak '{s}' not found in PATH -- ignored\n", .{name});
            continue;
        };
        try jailbreaks.append(alloc, abs);
    }

    if (jailbreaks.items.len > 0) {
        var jb_buf: std.ArrayList(u8) = .empty;
        for (jailbreaks.items) |path| {
            if (jb_buf.items.len > 0) try jb_buf.append(alloc, ':');
            try jb_buf.appendSlice(alloc, path);
        }
        try environ.put("MOAT_JAILBREAK", jb_buf.items);
    }

    try sandbox.prepareTmpDir(alloc, io, environ, profile.root);

    // One profile covers the whole session, so per-binary grants are unioned.
    const grants = try sandbox.collectGrants(alloc, io, loaded.config.allow, "*", profile.root, home);

    // The wrapped binaries in this session skip their own check, since the
    // session profile is already applied by the time they run.
    const mode = confirm.modeFromEnv(env.confirm);
    if (confirmNeeded(loaded.config.confirm, label, args, mode)) {
        confirm.ensure(alloc, io, .{
            .bin = label,
            .root = profile.root,
            .env_home = env.env_home,
            .grants = grants,
            .jailbreaks = jailbreaks.items,
        }, home, mode) catch {
            std.debug.print("moat: not starting {s}\n", .{label});
            std.process.exit(1);
        };
    }

    // Apply sandbox to the shell session so all child processes are confined.
    sandbox.apply(.{
        .root = profile.root,
        .home = profile.home,
        .grants = grants,
        .jailbreaks = jailbreaks.items,
    }, alloc) catch |err| {
        std.debug.print("moat: cannot apply sandbox: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    return profile.root;
}

fn cmdShell(alloc: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map, env: env_mod.Env, args: []const []const u8, verbose: bool) !void {
    const shells = try resolveShells(alloc, io, env.home.?, args);
    _ = try prepareSession(alloc, io, environ, env, shells, verbose, "shell");
    return std.process.replace(io, .{
        .argv = &.{env.shell},
        .environ_map = environ,
    });
}

fn cmdRun(alloc: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map, env: env_mod.Env, args: []const []const u8, verbose: bool, trace: bool) !void {
    const sep = indexOfArg(args, "--") orelse
        usageError("usage: moat run [name...] -- <cmd> [args...]", .{});
    const named = args[0..sep];
    const command = args[sep + 1 ..];
    if (command.len == 0) {
        usageError("usage: moat run [name...] -- <cmd> [args...]", .{});
    }
    const shells = try resolveShells(alloc, io, env.home.?, named);
    if (trace) {
        var tail: std.ArrayList([]const u8) = .empty;
        try tail.append(alloc, "run");
        try tail.appendSlice(alloc, args);
        return traceChild(alloc, io, environ, tail.items);
    }

    _ = try prepareSession(alloc, io, environ, env, shells, verbose, std.fs.path.basename(command[0]));

    // replace() resolves argv[0] against the pre-existing PATH, which would run
    // the unwrapped host binary instead of the shell's. prepareSession put the
    // shell's PATH on the map, so read it from there rather than from `env`.
    const path_env = environ.get("PATH") orelse "";
    const exe = (try sandbox.findInPath(alloc, io, path_env, command[0])) orelse {
        std.debug.print("moat: '{s}' not found in the shell's PATH\n", .{command[0]});
        std.process.exit(1);
    };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(alloc, exe);
    try argv.appendSlice(alloc, command[1..]);
    return std.process.replace(io, .{
        .argv = argv.items,
        .environ_map = environ,
    });
}

// Pulls -r/--remove out of the argument list, so one command covers add, remove
// and list instead of a pair of commands plus no way to see what is there.
fn takeRemoveFlag(alloc: std.mem.Allocator, args: []const []const u8) !struct { remove: bool, rest: []const []const u8 } {
    var rest: std.ArrayList([]const u8) = .empty;
    var remove = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "-r") or std.mem.eql(u8, a, "--remove")) {
            remove = true;
        } else try rest.append(alloc, a);
    }
    return .{ .remove = remove, .rest = rest.items };
}

fn listAllow(alloc: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    const loaded = try config.load(alloc, io, home);
    if (loaded.config.allow.len == 0) {
        std.debug.print("no grants\n", .{});
        return;
    }
    for (loaded.config.allow) |r| {
        for (r.paths) |p| {
            std.debug.print("  {s: <12} {s: <16} {s}", .{ r.bin, sandbox.accessLabel(r.write, r.exec), p });
            if (r.dirs.len > 0) {
                std.debug.print("  in", .{});
                for (r.dirs) |d| std.debug.print(" {s}", .{d});
            }
            std.debug.print("\n", .{});
        }
    }
    std.debug.print("{s}\n", .{loaded.path});
}

fn cmdAllow(alloc: std.mem.Allocator, io: std.Io, home: []const u8, argv: []const []const u8) !void {
    const parsed = try takeRemoveFlag(alloc, argv);
    const args = parsed.rest;
    if (parsed.remove) {
        if (args.len < 2) usageError("usage: moat allow -r <bin|*> <path>", .{});
        const removed = try config.removeAllow(alloc, io, home, args[0], args[1]);
        if (removed == 0) {
            std.debug.print("moat: no rule for {s}: {s}\n", .{ args[0], args[1] });
            std.process.exit(1);
        }
        std.debug.print("removed {s}: {s}\n", .{ args[0], args[1] });
        return;
    }
    if (args.len == 0) return listAllow(alloc, io, home);
    if (args.len < 2) {
        usageError("usage: moat allow [<bin|*> <path> [--write] [--exec]]", .{});
    }
    var write = false;
    var exec = false;
    var path: ?[]const u8 = null;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--write")) write = true else if (std.mem.eql(u8, a, "--exec")) exec = true else path = a;
    }
    const target = path orelse {
        usageError("usage: moat allow [<bin|*> <path> [--write] [--exec]]", .{});
    };

    // Stored unexpanded so the rule stays portable across machines.
    const expanded = try sandbox.expandTilde(alloc, home, target);
    sandbox.validateGrant(.{ .path = expanded, .write = write, .exec = exec }, home) catch |err| {
        std.debug.print("moat: refusing to allow {s}: {s}\n", .{ target, @errorName(err) });
        std.process.exit(1);
    };

    const granted = try config.addAllow(alloc, io, home, args[0], target, write, exec);

    // The profile matches the canonical path, so show it when it differs.
    const canon = try sandbox.canonicalize(alloc, io, expanded);
    const mode: []const u8 = if (granted.write) "read/write" else "read-only";
    const ex: []const u8 = if (granted.exec) ", exec" else "";

    std.debug.print("allowed {s}: {s}\n", .{ args[0], target });
    if (!std.mem.eql(u8, canon, target)) {
        std.debug.print("  resolves to  {s}\n", .{canon});
    }
    std.debug.print("  access       {s}{s}\n", .{ mode, ex });
    std.debug.print("  applies to   every project\n", .{});
    std.debug.print("  remove       moat allow -r {s} {s}\n", .{ args[0], target });
    std.debug.print("  config       {s}\n", .{granted.config_path});
}

// The only thing that moves a pin, so a moving branch is followed when you say
// so rather than on every launch.
fn cmdUpdate(alloc: std.mem.Allocator, io: std.Io, home: []const u8, flake: []const u8, args: []const []const u8) !void {
    var current = try lock.load(alloc, io, home);
    if (current.shells.len == 0) {
        std.debug.print("no shells pinned yet; they pin themselves on first use\n", .{});
        return;
    }

    var session: NixSession = .{};
    defer session.deinit();

    var changed: usize = 0;
    for (current.shells) |e| {
        if (args.len > 0 and indexOfArg(args, e.name) == null) continue;
        const parts = lock.split(e.name);
        const base = parts.flake orelse flake;
        if (!lock.pinnable(base)) {
            std.debug.print("  {s: <20} unpinned source ({s}), tracks the working tree\n", .{ e.name, base });
            continue;
        }
        const rev = resolveRev(&session, alloc, base);
        const pinned = try lock.withRev(alloc, base, rev);
        const out = nixBuild(&session, alloc, pinned, parts.attr) catch continue;

        if (std.mem.eql(u8, out, e.out)) {
            std.debug.print("  {s: <20} unchanged\n", .{e.name});
        } else {
            std.debug.print("  {s: <20} {s} -> {s}\n", .{
                e.name,
                lock.shortRev(e.rev),
                lock.shortRev(rev),
            });
            changed += 1;
        }
        current = try lock.upsert(alloc, current, .{ .name = e.name, .ref = pinned, .rev = rev, .out = out });
    }
    try lock.save(alloc, io, home, current);
    if (changed == 0) std.debug.print("nothing moved\n", .{});
}

fn cmdApprovals(alloc: std.mem.Allocator, io: std.Io, home: []const u8, argv: []const []const u8) !void {
    const parsed = try takeRemoveFlag(alloc, argv);
    if (parsed.remove) return forgetApprovals(alloc, io, home, parsed.rest);

    const path = try confirm.approvalsPath(alloc, home);
    const entries = try confirm.parseEntries(alloc, try confirm.readApprovals(alloc, io, path));
    if (entries.len == 0) {
        std.debug.print("no approvals recorded\n", .{});
        return;
    }
    for (entries) |e| std.debug.print("  {s: <14} {s}\n", .{ e.bin, e.root });
    std.debug.print("{s}\n", .{path});
}

fn forgetApprovals(alloc: std.mem.Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    const all = args.len > 0 and std.mem.eql(u8, args[0], "--all");
    const target: ?[]const u8 = if (all)
        null
    else if (args.len > 0)
        try resolvePathArg(alloc, io, args[0])
    else blk: {
        var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try std.process.currentPath(io, &cwd_buf);
        break :blk try alloc.dupe(u8, cwd_buf[0..n]);
    };

    const path = try confirm.approvalsPath(alloc, home);
    const filtered = try confirm.withoutRoot(alloc, try confirm.readApprovals(alloc, io, path), target);
    if (filtered.removed == 0) {
        std.debug.print("moat: no approvals for {s}\n", .{target orelse "any project"});
        std.process.exit(1);
    }
    try confirm.writeApprovals(io, path, filtered.content);
    std.debug.print("dropped {d} approval(s) for {s}\n", .{ filtered.removed, target orelse "every project" });
}

fn cmdLink(alloc: std.mem.Allocator, io: std.Io, home: []const u8, argv: []const []const u8) !void {
    const parsed = try takeRemoveFlag(alloc, argv);
    const args = parsed.rest;
    if (parsed.remove) {
        if (args.len < 1) usageError("usage: moat link -r <dir>", .{});
        const dir = try resolvePathArg(alloc, io, args[0]);
        try config.removeLink(alloc, io, home, dir);
        std.debug.print("unlinked {s}\n", .{dir});
        return;
    }
    if (args.len == 0) {
        const loaded = try config.load(alloc, io, home);
        if (loaded.config.links.len == 0) {
            std.debug.print("no links\n", .{});
            return;
        }
        for (loaded.config.links) |l| {
            std.debug.print("  {s} ->", .{l.dir});
            for (l.shells) |s| std.debug.print(" {s}", .{s});
            std.debug.print("\n", .{});
        }
        return;
    }
    if (args.len < 2) usageError("usage: moat link [<dir> <name...>]", .{});
    const dir = try resolvePathArg(alloc, io, args[0]);
    try config.addLink(alloc, io, home, dir, args[1..]);
    std.debug.print("linked {s} ->", .{dir});
    for (args[1..]) |s| std.debug.print(" {s}", .{s});
    std.debug.print("\n", .{});
}

fn resolvePathArg(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const abs = if (std.fs.path.isAbsolute(path)) path else blk: {
        var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try std.process.currentPath(io, &cwd_buf);
        break :blk try std.fmt.allocPrint(alloc, "{s}/{s}", .{ cwd_buf[0..n], path });
    };
    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.realPathFileAbsolute(io, abs, &real_buf) catch return try alloc.dupe(u8, abs);
    return try alloc.dupe(u8, real_buf[0..n]);
}

fn resolveDir(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) ![]const u8 {
    if (args.len > 0) return resolvePathArg(alloc, io, args[0]);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &buf);
    return try alloc.dupe(u8, buf[0..n]);
}

fn cmdDetect(alloc: std.mem.Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    const dir = try resolveDir(alloc, io, args);
    const loaded = try config.load(alloc, io, home);
    const result = try config.resolve(alloc, io, &loaded, dir);
    if (result) |r| {
        const source_label: []const u8 = switch (r.source) {
            .link => "link",
            .detect => "detect rule",
        };
        std.debug.print("{s} (via {s}):", .{ dir, source_label });
        for (r.shells) |s| std.debug.print(" {s}", .{s});
        std.debug.print("\n", .{});
    } else if (loaded.config.default.len == 0) {
        std.debug.print("no shells detected for {s}\n", .{dir});
        std.debug.print("hint: use 'moat link {s} <shell>' or add a detect rule\n", .{dir});
    } else {
        std.debug.print("no shells detected for {s}\n", .{dir});
    }
    if (loaded.config.default.len > 0) {
        std.debug.print("default (always):", .{});
        for (loaded.config.default) |s| std.debug.print(" {s}", .{s});
        std.debug.print("\n", .{});
    }
}

fn cmdCheck(alloc: std.mem.Allocator, io: std.Io, env: env_mod.Env) !void {
    const home = env.home.?;
    const loaded = try config.load(alloc, io, home);
    std.debug.print("config: {s}\n", .{loaded.path});

    var issues: usize = 0;

    // Check links: do directories exist?
    for (loaded.config.links) |link| {
        var dir = std.Io.Dir.openDirAbsolute(io, link.dir, .{}) catch {
            std.debug.print("  link: {s} -- directory not found\n", .{link.dir});
            issues += 1;
            continue;
        };
        dir.close(io);
        std.debug.print("  link: {s} ->", .{link.dir});
        for (link.shells) |s| std.debug.print(" {s}", .{s});
        std.debug.print("\n", .{});
    }

    // Check detect rules.
    for (loaded.config.detect) |rule| {
        std.debug.print("  detect: markers", .{});
        for (rule.markers) |m| std.debug.print(" {s}", .{m});
        std.debug.print(" ->", .{});
        for (rule.shells) |s| std.debug.print(" {s}", .{s});
        std.debug.print("\n", .{});
    }

    // Collect all referenced shell names.
    var shell_set: std.ArrayList([]const u8) = .empty;
    for (loaded.config.links) |link| try config.appendUnique(alloc, &shell_set, link.shells);
    for (loaded.config.detect) |rule| try config.appendUnique(alloc, &shell_set, rule.shells);

    // Resolving the flake and every referenced shell, in process. A shell is
    // "ok" when its attribute evaluates: building it is what a session does.
    const flake = env.flake;
    var session: NixSession = .{};
    defer session.deinit();
    if (session.get(alloc)) |n| {
        // Asking the store, not the filesystem: a path can exist on disk and
        // still be invalid, which is exactly when a rebuild is needed.
        const pins = lock.load(alloc, io, home) catch lock.Lock{};
        for (pins.shells) |e| {
            const short = lock.shortRev(e.rev);
            const present = e.out.len > 0 and n.validPath(e.out);
            std.debug.print("  pin: {s} at {s}{s}\n", .{ e.name, short, if (present) "" else " (not in store, will rebuild)" });
        }

        if (n.evaluates(flake, null, nix.system)) {
            std.debug.print("  flake: {s} -- ok\n", .{flake});
        } else {
            std.debug.print("  flake: {s} -- {s}\n", .{ flake, n.lastError() });
            issues += 1;
        }
        for (shell_set.items) |name| {
            const parts = lock.split(name);
            if (n.evaluates(parts.flake orelse flake, parts.attr, nix.system)) {
                std.debug.print("  shell: {s} -- ok\n", .{name});
            } else {
                std.debug.print("  shell: {s} -- not found in flake\n", .{name});
                issues += 1;
            }
        }
    } else |_| {
        std.debug.print("  nix: cannot initialise the nix C API\n", .{});
        issues += 1;
    }

    // Validate allow rules here rather than at sandbox-apply time.
    for (loaded.config.allow) |r| {
        for (r.paths) |p| {
            const expanded = try sandbox.expandTilde(alloc, home, p);
            sandbox.validateGrant(.{ .path = expanded, .write = r.write }, home) catch |err| {
                std.debug.print("  allow: {s} {s} -- {s}\n", .{ r.bin, p, @errorName(err) });
                issues += 1;
            };
        }
        for (r.dirs) |d| sandbox.validatePath(d) catch |err| {
            std.debug.print("  allow: {s} dir {s} -- {s}\n", .{ r.bin, d, @errorName(err) });
            issues += 1;
        };
    }

    // Additive allows mean a wider rule makes a narrower one dead weight.
    // Reported, not counted: a redundant rule grants nothing extra.
    for (loaded.config.allow, 0..) |b, bi| {
        for (b.paths) |p| {
            for (loaded.config.allow, 0..) |a, ai| {
                if (ai == bi or !config.covers(home, a, b, p)) continue;
                if (config.covers(home, b, a, p) and ai > bi) continue;
                std.debug.print("  allow: {s} {s} -- redundant, already covered by the '{s}' rule\n", .{ b.bin, p, a.bin });
            }
        }
    }

    if (issues == 0) {
        std.debug.print("all ok\n", .{});
    } else {
        std.debug.print("{d} issue(s) found\n", .{issues});
        std.process.exit(1);
    }
}
