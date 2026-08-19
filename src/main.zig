const std = @import("std");
const config = @import("config.zig");
const sandbox = @import("sandbox.zig");

const usage_text =
    \\moat - sandboxed dev environments
    \\
    \\usage:
    \\  moat shell <name...>         enter a sandboxed shell combining given shells
    \\  moat allow <bin> <path>      grant a binary access to a path (--write for rw)
    \\  moat link <dir> <name...>    associate a directory with shell(s)
    \\  moat unlink <dir>            remove a directory association
    \\  moat detect [dir]            show which shells would activate
    \\  moat check                   validate config (paths, shells)
    \\  moat help                    show this message
    \\
    \\flags:
    \\  -v, --verbose                show build progress
    \\
    \\environment:
    \\  MOAT_FLAKE    flake reference for shells (default: github:q-uint/moat)
    \\  MOAT_ROOT     sandbox boundary (set automatically by shell)
    \\
;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var args_it = init.minimal.args.iterate();
    _ = args_it.next(); // skip argv[0]

    var verbose = false;
    var cmd: ?[]const u8 = null;
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else {
            cmd = arg;
            break;
        }
    }
    const command = cmd orelse {
        printUsage(io);
        std.process.exit(1);
    };

    const home = init.environ_map.get("HOME") orelse usageError("HOME not set", .{});

    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(alloc);
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else {
            try rest.append(alloc, a);
        }
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const cmd_alloc = arena.allocator();

    if (std.mem.eql(u8, command, "shell")) return cmdShell(cmd_alloc, io, init.environ_map, home, rest.items, verbose);
    if (std.mem.eql(u8, command, "allow")) return cmdAllow(cmd_alloc, io, home, rest.items);
    if (std.mem.eql(u8, command, "link")) return cmdLink(cmd_alloc, io, home, rest.items);
    if (std.mem.eql(u8, command, "unlink")) return cmdUnlink(cmd_alloc, io, home, rest.items);
    if (std.mem.eql(u8, command, "detect")) return cmdDetect(cmd_alloc, io, home, rest.items);
    if (std.mem.eql(u8, command, "check")) return cmdCheck(cmd_alloc, io, init.environ_map, home);
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

fn flakeRef(environ: *std.process.Environ.Map) []const u8 {
    return environ.get("MOAT_FLAKE") orelse "github:q-uint/moat";
}

fn buildShells(alloc: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map, shells: []const []const u8, verbose: bool) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    const flake = flakeRef(environ);
    for (shells) |name| {
        if (verbose) std.debug.print("moat: building {s}...\n", .{name});
        const attr = try std.fmt.allocPrint(alloc, "{s}#{s}", .{ flake, name });
        const result = try std.process.run(alloc, io, .{
            .argv = &.{ "nix", "build", attr, "--no-link", "--print-out-paths" },
        });
        if (!result.term.success()) {
            std.debug.print("moat: nix build failed for '{s}'\n{s}", .{ name, result.stderr });
            return error.NixBuildFailed;
        }
        const path = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
        try paths.append(alloc, path);
    }
    return paths.items;
}

fn cmdShell(alloc: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map, home: []const u8, args: []const []const u8, verbose: bool) !void {
    if (args.len == 0) {
        usageError("usage: moat shell <name...>", .{});
    }

    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &cwd_buf);
    const cwd = cwd_buf[0..n];

    const profile = sandbox.Profile{ .root = cwd, .home = home };
    profile.validate() catch {
        std.debug.print("moat: refusing to sandbox from {s}: root contains HOME ({s}), which would grant full home access\n", .{ cwd, home });
        std.process.exit(1);
    };

    const loaded = try config.load(alloc, io, home);
    const store_paths = try buildShells(alloc, io, environ, args, verbose);

    var path_buf: std.ArrayList(u8) = .empty;
    for (store_paths) |p| {
        if (path_buf.items.len > 0) try path_buf.append(alloc, ':');
        try path_buf.appendSlice(alloc, p);
        try path_buf.appendSlice(alloc, "/bin");
    }
    if (environ.get("PATH")) |existing| {
        try path_buf.append(alloc, ':');
        try path_buf.appendSlice(alloc, existing);
    }

    try environ.put("PATH", path_buf.items);
    try environ.put("MOAT_ROOT", cwd);

    // Config names jailbreaks; SBPL matches absolute exec paths only.
    var jailbreaks: std.ArrayList([]const u8) = .empty;
    for (loaded.config.jailbreak) |name| {
        const abs = (try sandbox.resolveJailbreak(alloc, io, path_buf.items, name)) orelse {
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

    const user_shell = environ.get("SHELL") orelse "/bin/bash";
    return std.process.replace(io, .{
        .argv = &.{user_shell},
        .environ_map = environ,
    });
}

fn cmdAllow(alloc: std.mem.Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    if (args.len < 2) {
        usageError("usage: moat allow <bin|*> <path> [--write]", .{});
    }
    var write = false;
    var path: ?[]const u8 = null;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--write")) write = true else path = a;
    }
    const target = path orelse {
        usageError("usage: moat allow <bin|*> <path> [--write]", .{});
    };

    // Stored unexpanded so the rule stays portable across machines.
    const expanded = try sandbox.expandTilde(alloc, home, target);
    sandbox.validateGrant(.{ .path = expanded, .write = write }, home) catch |err| {
        std.debug.print("moat: refusing to allow {s}: {s}\n", .{ target, @errorName(err) });
        std.process.exit(1);
    };

    try config.addAllow(alloc, io, home, args[0], target, write);
    std.debug.print("allowed {s}: {s} ({s})\n", .{ args[0], target, if (write) "read/write" else "read-only" });
}

fn cmdLink(alloc: std.mem.Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    if (args.len < 2) {
        usageError("usage: moat link <dir> <name...>", .{});
    }
    const dir = try resolvePathArg(alloc, io, args[0]);
    try config.addLink(alloc, io, home, dir, args[1..]);
    std.debug.print("linked {s} ->", .{dir});
    for (args[1..]) |s| std.debug.print(" {s}", .{s});
    std.debug.print("\n", .{});
}

fn cmdUnlink(alloc: std.mem.Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    if (args.len < 1) {
        usageError("usage: moat unlink <dir>", .{});
    }
    const dir = try resolvePathArg(alloc, io, args[0]);
    try config.removeLink(alloc, io, home, dir);
    std.debug.print("unlinked {s}\n", .{dir});
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
            .override => ".moat-shell",
            .link => "link",
            .detect => "detect rule",
        };
        std.debug.print("{s} (via {s}):", .{ dir, source_label });
        for (r.shells) |s| std.debug.print(" {s}", .{s});
        std.debug.print("\n", .{});
    } else {
        std.debug.print("no shells detected for {s}\n", .{dir});
        std.debug.print("hint: use 'moat link {s} <shell>' or create a .moat-shell file\n", .{dir});
    }
}

fn cmdCheck(alloc: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map, home: []const u8) !void {
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

    // Check that nix is available and flake ref resolves. A missing nix skips
    // the flake and shell checks but must still reach the summary below.
    const flake = flakeRef(environ);
    if (std.process.run(alloc, io, .{
        .argv = &.{ "nix", "flake", "metadata", flake, "--json" },
    })) |flake_result| {
        if (flake_result.term.success()) {
            std.debug.print("  flake: {s} -- ok\n", .{flake});
        } else {
            std.debug.print("  flake: {s} -- not found\n", .{flake});
            issues += 1;
        }

        // Check each shell can be built.
        for (shell_set.items) |name| {
            const attr = try std.fmt.allocPrint(alloc, "{s}#{s}", .{ flake, name });
            const result = std.process.run(alloc, io, .{
                .argv = &.{ "nix", "build", attr, "--no-link", "--dry-run" },
            }) catch continue;
            if (result.term.success()) {
                std.debug.print("  shell: {s} -- ok\n", .{name});
            } else {
                std.debug.print("  shell: {s} -- not found in flake\n", .{name});
                issues += 1;
            }
        }
    } else |_| {
        std.debug.print("  nix: not found in PATH\n", .{});
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

    if (issues == 0) {
        std.debug.print("all ok\n", .{});
    } else {
        std.debug.print("{d} issue(s) found\n", .{issues});
        std.process.exit(1);
    }
}
