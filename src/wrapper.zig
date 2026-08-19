const std = @import("std");
const config = @import("config.zig");
const sandbox = @import("sandbox.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var args_it = init.minimal.args.iterate();
    const argv0 = args_it.next() orelse fatal("no argv[0]");

    const exe_name = std.fs.path.basename(argv0);
    const manifest = readManifest(alloc, io, argv0, init.environ_map) catch fatal("cannot read manifest");
    const real_path = lookupManifest(manifest, exe_name) orelse fatal("not in manifest");

    const root_env = init.environ_map.get("MOAT_ROOT") orelse fatal("MOAT_ROOT not set");
    const home_env = init.environ_map.get("HOME") orelse fatal("HOME not set");

    // Duped: put() below frees the old value storage these would borrow.
    const root = try alloc.dupe(u8, root_env);
    const home = try alloc.dupe(u8, home_env);

    // Collect jailbreak list.
    var jailbreaks: std.ArrayList([]const u8) = .empty;
    if (init.environ_map.get("MOAT_JAILBREAK")) |jb_borrowed| {
        const jb = try alloc.dupe(u8, jb_borrowed);
        var it = std.mem.splitScalar(u8, jb, ':');
        while (it.next()) |path| {
            if (path.len > 0) try jailbreaks.append(alloc, path);
        }
    }

    // Process MOAT_ENV_* variables.
    var to_set: std.ArrayList(struct { key: []const u8, val: []const u8 }) = .empty;
    var to_remove: std.ArrayList([]const u8) = .empty;
    var env_home: ?[]const u8 = null;
    var env_it = init.environ_map.iterator();
    while (env_it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, "MOAT_ENV_")) {
            // Duped: swapRemove below may free the map's own key/value memory.
            const stripped = try alloc.dupe(u8, entry.key_ptr.*["MOAT_ENV_".len..]);
            const val = try alloc.dupe(u8, entry.value_ptr.*);
            if (std.mem.eql(u8, stripped, "HOME")) env_home = val;
            try to_set.append(alloc, .{ .key = stripped, .val = val });
            try to_remove.append(alloc, try alloc.dupe(u8, entry.key_ptr.*));
        }
    }
    for (to_remove.items) |key| _ = init.environ_map.*.swapRemove(key);
    for (to_set.items) |kv| try init.environ_map.put(kv.key, kv.val);

    // Check if this binary is jailbroken -- skip sandbox.
    for (jailbreaks.items) |jb_path| {
        if (std.mem.eql(u8, jb_path, real_path) or
            std.mem.eql(u8, std.fs.path.basename(jb_path), exe_name))
        {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(alloc, real_path);
            while (args_it.next()) |a| try argv.append(alloc, a);
            return std.process.replace(io, .{
                .argv = argv.items,
                .environ_map = init.environ_map,
            });
        }
    }

    // Under `moat shell` the session profile already confines this process, and
    // re-applying would fail. Config lives under $HOME, which that profile
    // denies, so this check must come before reading it.
    if (!sandbox.alreadySandboxed()) {
        // MOAT_JAILBREAK may carry bare names; SBPL needs absolute exec paths.
        const path_env = init.environ_map.get("PATH") orelse "";
        var abs_jailbreaks: std.ArrayList([]const u8) = .empty;
        for (jailbreaks.items) |name| {
            if (try sandbox.resolveJailbreak(alloc, io, path_env, name)) |abs| {
                try abs_jailbreaks.append(alloc, abs);
            }
        }

        try sandbox.prepareTmpDir(alloc, io, init.environ_map, root);

        // This process runs exactly one binary, so it gets only that binary's grants.
        const loaded = config.load(alloc, io, home) catch |err| {
            std.debug.print("moat-wrapper: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        const grants = try sandbox.collectGrants(alloc, io, loaded.config.allow, exe_name, root, home);

        // An unwritable HOME fails deep inside the tool, so refuse it up front
        // rather than hand it over.
        if (env_home) |h_raw| {
            // Grants are canonicalized, so this must be too or a matching grant
            // is missed and the message below advises a no-op.
            const h = try sandbox.canonicalize(alloc, io, h_raw);
            if (!sandbox.writableIn(h, root, grants)) {
                std.debug.print(
                    \\moat-wrapper: MOAT_ENV_HOME={s} is not writable in the sandbox.
                    \\  Put it under $MOAT_ROOT ({s}), e.g. $MOAT_ROOT/.moat/home,
                    \\  or grant it explicitly:  moat allow {s} {s} --write
                    \\
                , .{ h, root, exe_name, h });
                std.process.exit(1);
            }
        }

        sandbox.apply(.{
            .root = root,
            .home = home,
            .grants = grants,
            .jailbreaks = abs_jailbreaks.items,
        }, alloc) catch |err| {
            std.debug.print("moat-wrapper: cannot apply sandbox: {s} (root={s} home={s} grants={d})\n", .{ @errorName(err), root, home, grants.len });
            std.process.exit(1);
        };
    }

    // After the profile is applied, so a failure here is the same failure the
    // tool would have hit. Covers `moat shell` too, which skips the block above.
    if (env_home) |h| {
        std.Io.Dir.cwd().createDirPath(io, h) catch |err| {
            std.debug.print("moat-wrapper: cannot create MOAT_ENV_HOME={s}: {s}\n", .{ h, @errorName(err) });
            std.process.exit(1);
        };
    }

    // Exec the real binary.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(alloc, real_path);
    while (args_it.next()) |a| try argv.append(alloc, a);
    return std.process.replace(io, .{
        .argv = argv.items,
        .environ_map = init.environ_map,
    });
}

fn readManifest(alloc: std.mem.Allocator, io: std.Io, argv0: []const u8, environ: *std.process.Environ.Map) ![]const u8 {
    // Resolve argv[0] to absolute path so we can find the manifest
    // relative to the symlink's location (not the wrapper binary's location).
    const abs_argv0 = if (std.fs.path.isAbsolute(argv0))
        argv0
    else if (std.mem.indexOfScalar(u8, argv0, '/') != null) blk: {
        // Relative path with directory component -- resolve against cwd.
        var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.realPathFileAbsolute(io, argv0, &real_buf) catch return error.ManifestNotFound;
        break :blk try alloc.dupe(u8, real_buf[0..n]);
    } else blk: {
        // Bare name -- search PATH.
        const path_env = environ.get("PATH") orelse return error.ManifestNotFound;
        var dirs = std.mem.splitScalar(u8, path_env, ':');
        while (dirs.next()) |dir| {
            const candidate = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, argv0 });
            std.Io.Dir.cwd().access(io, candidate, .{}) catch continue;
            // Must be a moat shell entry, not merely a same-named binary
            // earlier in PATH, which would fail later as "cannot read manifest".
            const sibling = try std.fmt.allocPrint(alloc, "{s}/../share/moat/manifest", .{dir});
            std.Io.Dir.cwd().access(io, sibling, .{}) catch continue;
            break :blk candidate;
        }
        return error.ManifestNotFound;
    };
    const bin_dir = std.fs.path.dirname(abs_argv0) orelse return error.ManifestNotFound;
    const manifest_path = try std.fmt.allocPrint(alloc, "{s}/../share/moat/manifest", .{bin_dir});
    var buf: [1024 * 1024]u8 = undefined;
    const content = try std.Io.Dir.cwd().readFile(io, manifest_path, &buf);
    return try alloc.dupe(u8, content);
}

fn lookupManifest(manifest: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOfScalar(u8, line, '\t')) |tab| {
            if (std.mem.eql(u8, line[0..tab], name)) return line[tab + 1 ..];
        }
    }
    return null;
}

fn fatal(msg: []const u8) noreturn {
    std.debug.print("moat-wrapper: {s}\n", .{msg});
    std.process.exit(1);
}

test "lookupManifest" {
    const manifest = "rustc\t/nix/store/abc/bin/rustc\ncargo\t/nix/store/abc/bin/cargo\n";
    try std.testing.expectEqualStrings("/nix/store/abc/bin/rustc", lookupManifest(manifest, "rustc").?);
    try std.testing.expectEqualStrings("/nix/store/abc/bin/cargo", lookupManifest(manifest, "cargo").?);
    try std.testing.expect(lookupManifest(manifest, "gcc") == null);
}
