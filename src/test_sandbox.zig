const std = @import("std");

var moat_path: []const u8 = undefined;
var flake_path: []const u8 = undefined;
var real_home: []const u8 = undefined;
var io: std.Io = undefined;
var test_counter: usize = 0;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    io = init.io;

    var args_it = init.minimal.args.iterate();
    _ = args_it.next();
    moat_path = args_it.next() orelse @panic("usage: test_sandbox <moat-binary-path>");

    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &cwd_buf);
    flake_path = try alloc.dupe(u8, cwd_buf[0..n]);

    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // Returning here would run zero tests and still exit 0.
    const hn = std.Io.Dir.realPathFileAbsolute(io, init.environ_map.get("HOME") orelse "/Users", &home_buf) catch
        @panic("cannot resolve HOME");
    real_home = try alloc.dupe(u8, home_buf[0..hn]);

    const tests = .{
        .{ "wrapped zig --version", testWrappedZigVersion },
        .{ "wrapped zig: HOME denied", testWrappedZigHomeDenied },
        .{ "wrapped zig: ~/Library denied", testWrappedZigLibraryDenied },
        .{ "wrapped binary runs inside moat shell", testWrappedInsideShell },
        .{ "wrapped zig: shared paths denied", testStrictDenials },
        .{ "allow rule grants exactly its path", testAllowGrant },
        .{ "wrapped zig: project root allowed", testWrappedZigRootAllowed },
        .{ "moat shell starts clean", testShellStartsClean },
        .{ "MOAT_ENV_HOME inside root is writable", testEnvHomeInsideRoot },
        .{ "MOAT_ENV_HOME outside root is refused", testEnvHomeRefused },
        .{ "MOAT_ENV_HOME outside root works with a write grant", testEnvHomeGranted },
        .{ "MOAT_ENV_HOME via symlinked /tmp matches its grant", testEnvHomeSymlinked },
        .{ "MOAT_ENV_HOME is created when missing", testEnvHomeCreated },
    };

    var passed: usize = 0;
    var failed: usize = 0;
    inline for (tests) |t| {
        if (t[1](alloc)) {
            std.debug.print("  pass: {s}\n", .{t[0]});
            passed += 1;
        } else |err| {
            std.debug.print("  FAIL: {s} ({})\n", .{ t[0], err });
            failed += 1;
        }
    }
    std.debug.print("\n{d} passed, {d} failed\n", .{ passed, failed });
    if (failed > 0) std.process.exit(1);
}

fn nixPath() []const u8 {
    return "/usr/bin:/bin:/usr/sbin:/sbin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin";
}

const TestHome = struct {
    path: []const u8,

    fn init(alloc: std.mem.Allocator) !TestHome {
        test_counter += 1;
        const path = try std.fmt.allocPrint(alloc, "{s}/zig-out/tmp/sandbox-e2e-{d}", .{ flake_path, test_counter });
        std.Io.Dir.cwd().createDirPath(io, path) catch {};
        return .{ .path = path };
    }

    fn deinit(self: TestHome) void {
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
    }
};

fn buildZigShell(alloc: std.mem.Allocator) ![]const u8 {
    var env = std.process.Environ.Map.init(alloc);
    try env.put("HOME", real_home);
    try env.put("PATH", nixPath());
    const result = try std.process.run(alloc, io, .{
        .argv = &.{ "nix", "build", try std.fmt.allocPrint(alloc, "{s}#zig", .{flake_path}), "--no-link", "--print-out-paths" },
        .environ_map = &env,
    });
    if (!result.term.success()) return error.NixBuildFailed;
    return std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    var buf: [4096]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(content);
    try w.flush();
    f.close(io);
}

fn writeScript(alloc: std.mem.Allocator, name: []const u8, content: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "{s}/zig-out/tmp/{s}", .{ flake_path, name });
    try writeFile(path, content);
    _ = try std.process.run(alloc, io, .{ .argv = &.{ "/bin/chmod", "+x", path } });
    return path;
}

fn runMoat(alloc: std.mem.Allocator, home: []const u8, argv: []const []const u8) !std.process.RunResult {
    var env = std.process.Environ.Map.init(alloc);
    try env.put("HOME", home);
    try env.put("MOAT_FLAKE", flake_path);
    try env.put("PATH", nixPath());
    return std.process.run(alloc, io, .{
        .argv = argv,
        .environ_map = &env,
    });
}

// Runs `body` as the user shell inside `moat shell zig` and returns its stdout.
fn runInSandbox(alloc: std.mem.Allocator, name: []const u8, body: []const u8) ![]const u8 {
    return runInSandboxHome(alloc, name, body, real_home);
}

fn runInSandboxHome(alloc: std.mem.Allocator, name: []const u8, body: []const u8, home: []const u8) ![]const u8 {
    const store_path = try buildZigShell(alloc);
    const script = try writeScript(alloc, name, try std.fmt.allocPrint(alloc, "#!/bin/sh\n{s}", .{body}));

    var env = std.process.Environ.Map.init(alloc);
    try env.put("HOME", home);
    try env.put("MOAT_FLAKE", flake_path);
    try env.put("MOAT_ROOT", flake_path);
    try env.put("PATH", try std.fmt.allocPrint(alloc, "{s}/bin:{s}", .{ store_path, nixPath() }));
    try env.put("SHELL", script);
    const result = try std.process.run(alloc, io, .{
        .argv = &.{ moat_path, "shell", "zig" },
        .environ_map = &env,
    });
    return result.stdout;
}

fn probe(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "ls \"{s}\" >/dev/null 2>&1 && echo ACCESSIBLE || echo DENIED\n", .{path});
}

fn expectAllDenied(out: []const u8) !void {
    if (std.mem.indexOf(u8, out, "ACCESSIBLE") != null) {
        std.debug.print("    expected all DENIED, got: \"{s}\"\n", .{out});
        return error.ExpectDenied;
    }
    try expectContains(out, "DENIED");
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("    expected to contain: \"{s}\"\n    got: \"{s}\"\n", .{ needle, haystack });
        return error.ExpectContains;
    }
}

// --- sandbox enforcement tests ---

fn testWrappedZigVersion(alloc: std.mem.Allocator) !void {
    const store_path = try buildZigShell(alloc);
    const wrapped_zig = try std.fmt.allocPrint(alloc, "{s}/bin/zig", .{store_path});

    var env = std.process.Environ.Map.init(alloc);
    try env.put("HOME", real_home);
    try env.put("MOAT_ROOT", flake_path);
    try env.put("PATH", nixPath());
    const result = try std.process.run(alloc, io, .{
        .argv = &.{ wrapped_zig, "version" },
        .environ_map = &env,
    });
    if (!result.term.success()) {
        std.debug.print("    stderr: {s}\n", .{result.stderr});
        return error.WrappedZigFailed;
    }
    try expectContains(result.stdout, "0.17.0");
}

fn testWrappedZigHomeDenied(alloc: std.mem.Allocator) !void {
    const out = try runInSandbox(alloc, "test-home-deny.sh", try probe(alloc, try std.fmt.allocPrint(alloc, "{s}/Desktop", .{real_home})));
    try expectAllDenied(out);
}

fn testWrappedZigLibraryDenied(alloc: std.mem.Allocator) !void {
    const body = try std.fmt.allocPrint(alloc, "{s}{s}", .{
        try probe(alloc, try std.fmt.allocPrint(alloc, "{s}/Library/Application Support", .{real_home})),
        try probe(alloc, try std.fmt.allocPrint(alloc, "{s}/Library/Caches", .{real_home})),
    });
    try expectAllDenied(try runInSandbox(alloc, "test-library-deny.sh", body));
}

// sandbox_apply fails once a profile is active, so a wrapped binary invoked
// inside `moat shell` must skip re-applying instead of dying.
fn testWrappedInsideShell(alloc: std.mem.Allocator) !void {
    const out = try runInSandbox(alloc, "test-nested-wrapped.sh", "zig version >/dev/null 2>&1 && echo WRAPPED_OK || echo WRAPPED_FAILED\n");
    try expectContains(out, "WRAPPED_OK");
}

// An allow rule must grant exactly its path, and nothing without a rule.
fn testAllowGrant(alloc: std.mem.Allocator) !void {
    test_counter += 1;
    const home = try std.fmt.allocPrint(alloc, "/tmp/moat-allow-test-{d}", .{test_counter});
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    const cfg_dir = try std.fmt.allocPrint(alloc, "{s}/.config/moat", .{home});
    try std.Io.Dir.cwd().createDirPath(io, cfg_dir);

    const granted = try std.fmt.allocPrint(alloc, "{s}/granted.txt", .{home});
    const ungranted = try std.fmt.allocPrint(alloc, "{s}/ungranted.txt", .{home});
    try writeFile(granted, "ok\n");
    try writeFile(ungranted, "ok\n");
    try writeFile(try std.fmt.allocPrint(alloc, "{s}/config.zon", .{cfg_dir}),
        \\.{
        \\    .allow = .{.{ .bin = "*", .paths = .{"~/granted.txt"} }},
        \\}
    );

    const body = try std.fmt.allocPrint(alloc, "cat {s} >/dev/null 2>&1 && echo GRANTED_OK || echo GRANTED_DENIED\ncat {s} >/dev/null 2>&1 && echo LEAK || echo UNGRANTED_DENIED\n", .{ granted, ungranted });
    const out = try runInSandboxHome(alloc, "test-allow.sh", body, home);

    try expectContains(out, "GRANTED_OK");
    try expectContains(out, "UNGRANTED_DENIED");
}

// Paths that (allow default) used to leak; under (deny default) none are reachable.
fn testStrictDenials(alloc: std.mem.Allocator) !void {
    var body: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "/tmp", "/private/tmp", "/Library", "/Volumes", "/Users" }) |p| {
        try body.appendSlice(alloc, try probe(alloc, p));
    }
    try expectAllDenied(try runInSandbox(alloc, "test-strict-denials.sh", body.items));
}

fn testWrappedZigRootAllowed(alloc: std.mem.Allocator) !void {
    const out = try runInSandbox(alloc, "test-root-allow.sh", try probe(alloc, try std.fmt.allocPrint(alloc, "{s}/src/main.zig", .{flake_path})));
    try expectContains(out, "ACCESSIBLE");
}

fn runWrappedZig(alloc: std.mem.Allocator, home: []const u8, env_home: ?[]const u8, argv: []const []const u8) !std.process.RunResult {
    const store_path = try buildZigShell(alloc);
    var full: std.ArrayList([]const u8) = .empty;
    try full.append(alloc, try std.fmt.allocPrint(alloc, "{s}/bin/zig", .{store_path}));
    try full.appendSlice(alloc, argv);

    var env = std.process.Environ.Map.init(alloc);
    try env.put("HOME", home);
    try env.put("MOAT_ROOT", flake_path);
    try env.put("PATH", nixPath());
    if (env_home) |h| try env.put("MOAT_ENV_HOME", h);
    return std.process.run(alloc, io, .{ .argv = full.items, .environ_map = &env });
}

fn testEnvHomeInsideRoot(alloc: std.mem.Allocator) !void {
    test_counter += 1;
    const fake = try std.fmt.allocPrint(alloc, "{s}/zig-out/tmp/envhome-{d}", .{ flake_path, test_counter });
    try std.Io.Dir.cwd().createDirPath(io, fake);
    defer std.Io.Dir.cwd().deleteTree(io, fake) catch {};

    const src = try std.fmt.allocPrint(alloc, "{s}/hello.zig", .{fake});
    try writeFile(src, "pub fn main() void {}\n");

    const r = try runWrappedZig(alloc, real_home, fake, &.{
        "build-exe",                                                    src,
        try std.fmt.allocPrint(alloc, "-femit-bin={s}/hello", .{fake}),
    });
    if (!r.term.success()) {
        std.debug.print("    stderr: {s}\n", .{r.stderr});
        return error.EnvHomeBuildFailed;
    }
    // The cache only exists if the overridden HOME was actually writable.
    std.Io.Dir.cwd().access(io, try std.fmt.allocPrint(alloc, "{s}/.cache/zig", .{fake}), .{}) catch
        return error.NoCacheUnderEnvHome;
}

fn testEnvHomeRefused(alloc: std.mem.Allocator) !void {
    const r = try runWrappedZig(alloc, real_home, "/private/tmp/moat-envhome-outside", &.{"version"});
    if (r.term.success()) {
        std.debug.print("    expected refusal, got stdout: {s}\n", .{r.stdout});
        return error.ExpectedRefusal;
    }
    try expectContains(r.stderr, "is not writable in the sandbox");
    try expectContains(r.stderr, "moat allow");
}

fn testEnvHomeGranted(alloc: std.mem.Allocator) !void {
    test_counter += 1;
    const home = try std.fmt.allocPrint(alloc, "/private/tmp/moat-envhome-cfg-{d}", .{test_counter});
    const fake = try std.fmt.allocPrint(alloc, "/private/tmp/moat-envhome-granted-{d}", .{test_counter});
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, fake) catch {};
    const cfg_dir = try std.fmt.allocPrint(alloc, "{s}/.config/moat", .{home});
    try std.Io.Dir.cwd().createDirPath(io, cfg_dir);
    try std.Io.Dir.cwd().createDirPath(io, fake);
    try writeFile(
        try std.fmt.allocPrint(alloc, "{s}/config.zon", .{cfg_dir}),
        try std.fmt.allocPrint(alloc,
            \\.{{
            \\    .allow = .{{.{{ .bin = "*", .paths = .{{"{s}"}}, .write = true }}}},
            \\}}
        , .{fake}),
    );

    const r = try runWrappedZig(alloc, home, fake, &.{"version"});
    if (!r.term.success()) {
        std.debug.print("    stderr: {s}\n", .{r.stderr});
        return error.GrantedEnvHomeRefused;
    }
    try expectContains(r.stdout, "0.17.0");
}

// The grant is canonicalized (/tmp -> /private/tmp); MOAT_ENV_HOME must be too,
// or following the refusal message's own `moat allow` advice still fails.
fn testEnvHomeSymlinked(alloc: std.mem.Allocator) !void {
    test_counter += 1;
    const home = try std.fmt.allocPrint(alloc, "/tmp/moat-envhome-sym-cfg-{d}", .{test_counter});
    const fake = try std.fmt.allocPrint(alloc, "/tmp/moat-envhome-sym-{d}", .{test_counter});
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, fake) catch {};
    const cfg_dir = try std.fmt.allocPrint(alloc, "{s}/.config/moat", .{home});
    try std.Io.Dir.cwd().createDirPath(io, cfg_dir);
    try std.Io.Dir.cwd().createDirPath(io, fake);
    try writeFile(
        try std.fmt.allocPrint(alloc, "{s}/config.zon", .{cfg_dir}),
        try std.fmt.allocPrint(alloc,
            \\.{{
            \\    .allow = .{{.{{ .bin = "*", .paths = .{{"{s}"}}, .write = true }}}},
            \\}}
        , .{fake}),
    );

    const r = try runWrappedZig(alloc, home, fake, &.{"version"});
    if (!r.term.success()) {
        std.debug.print("    stderr: {s}\n", .{r.stderr});
        return error.SymlinkedEnvHomeRefused;
    }
}

// `zig version` never touches HOME, so the directory can only exist if the
// wrapper made it. A tool that does not mkdir its own dotdirs needs this.
fn testEnvHomeCreated(alloc: std.mem.Allocator) !void {
    test_counter += 1;
    const fake = try std.fmt.allocPrint(alloc, "{s}/zig-out/tmp/envhome-new-{d}", .{ flake_path, test_counter });
    defer std.Io.Dir.cwd().deleteTree(io, fake) catch {};

    const r = try runWrappedZig(alloc, real_home, fake, &.{"version"});
    if (!r.term.success()) {
        std.debug.print("    stderr: {s}\n", .{r.stderr});
        return error.EnvHomeCreateRunFailed;
    }
    std.Io.Dir.cwd().access(io, fake, .{}) catch return error.EnvHomeNotCreated;
}

fn testShellStartsClean(alloc: std.mem.Allocator) !void {
    var env = std.process.Environ.Map.init(alloc);
    try env.put("HOME", real_home);
    try env.put("MOAT_FLAKE", flake_path);
    try env.put("PATH", nixPath());
    try env.put("SHELL", "/bin/sh");
    const result = try std.process.run(alloc, io, .{
        .argv = &.{ moat_path, "shell", "zig" },
        .environ_map = &env,
    });
    if (!result.term.success()) {
        std.debug.print("    stderr: {s}\n", .{result.stderr});
        return error.ShellFailed;
    }
}
