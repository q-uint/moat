const std = @import("std");

var moat_path: []const u8 = undefined;
var io: std.Io = undefined;
var test_counter: usize = 0;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    io = init.io;

    var args_it = init.minimal.args.iterate();
    _ = args_it.next();
    moat_path = args_it.next() orelse @panic("usage: test_e2e <moat-binary-path>");

    const tests = .{
        .{ "help", testHelp },
        .{ "unknown command", testUnknownCommand },
        .{ "usage errors exit non-zero", testUsageErrorsExitNonZero },
        .{ "allow round-trip", testAllowRoundTrip },
        .{ "allow --exec", testAllowExec },
        .{ "allow merges same path", testAllowMergesSamePath },
        .{ "allow keeps dir-scoped rule", testAllowKeepsDirScopedRule },
        .{ "allow -r", testUnallow },
        .{ "link and detect", testLinkAndDetect },
        .{ "link -r", testUnlink },
        .{ "link relative path", testLinkRelative },
        .{ "detect rules (build.zig.zon)", testDetectRules },
        .{ "check", testCheck },
        .{ "check rejects bad allow", testCheckRejectsBadAllow },
        .{ "verbose flag positions", testVerboseFlag },
        .{ "run requires -- separator", testRunRequiresSeparator },
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

const TestHome = struct {
    path: []const u8,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) !TestHome {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try std.process.currentPath(io, &buf);
        test_counter += 1;
        const path = try std.fmt.allocPrint(alloc, "{s}/zig-out/tmp/moat-e2e-{d}", .{ buf[0..n], test_counter });
        std.Io.Dir.cwd().createDirPath(io, path) catch {};
        return .{ .path = path, .alloc = alloc };
    }

    fn deinit(self: TestHome) void {
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
        self.alloc.free(self.path);
    }
};

fn run(alloc: std.mem.Allocator, home: []const u8, argv: []const []const u8) !std.process.RunResult {
    var env = std.process.Environ.Map.init(alloc);
    try env.put("HOME", home);
    try env.put("MOAT_FLAKE", "github:q-uint/moat-nonexistent");
    try env.put("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
    return std.process.run(alloc, io, .{
        .argv = argv,
        .environ_map = &env,
    });
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    var buf: [4096]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(content);
    try w.flush();
    f.close(io);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("    expected to contain: \"{s}\"\n    got: \"{s}\"\n", .{ needle, haystack });
        return error.ExpectContains;
    }
}

fn testHelp(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    const result = try run(alloc, home.path, &.{ moat_path, "help" });
    if (!result.term.success()) return error.NonZeroExit;
    // Help is output, so it belongs on stdout.
    try expectContains(result.stdout, "usage:");
}

fn testUnknownCommand(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    const result = try run(alloc, home.path, &.{ moat_path, "foo" });
    try expectContains(result.stderr, "unknown command");
    if (result.term.success()) return error.ExpectedNonZeroExit;
}

// Without `--`, the shell names and the command are indistinguishable.
fn testRunRequiresSeparator(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    const cases: []const []const []const u8 = &.{
        &.{ moat_path, "run" },
        &.{ moat_path, "run", "zig" },
        &.{ moat_path, "run", "--" },
    };
    for (cases) |argv| {
        const result = try run(alloc, home.path, argv);
        if (result.term.success()) return error.ExpectedNonZeroExit;
        try expectContains(result.stderr, "moat run [name...] -- <cmd>");
    }

    // With a command but no names, shells are resolved instead of erroring;
    // this home has none configured, so it fails on that, not on usage.
    const resolved = try run(alloc, home.path, &.{ moat_path, "run", "--", "ls" });
    if (resolved.term.success()) return error.ExpectedNonZeroExit;
    try expectContains(resolved.stderr, "no shells configured");
}

// Usage errors must be detectable by exit status, not just by their message.
fn testUsageErrorsExitNonZero(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    const cases: []const []const []const u8 = &.{
        &.{moat_path},
        &.{ moat_path, "shell" },
        &.{ moat_path, "link", "-r" },
        &.{ moat_path, "allow", "git" },
        &.{ moat_path, "allow", "-r", "git" },
    };
    for (cases) |argv| {
        const result = try run(alloc, home.path, argv);
        if (result.term.success()) {
            std.debug.print("    expected non-zero exit for: {s}\n", .{argv[argv.len - 1]});
            return error.ExpectedNonZeroExit;
        }
    }

    // The bare forms list instead of erroring, which is what lets one command
    // per noun replace an add/remove pair.
    for ([_][]const u8{ "allow", "link", "approvals" }) |cmd| {
        const result = try run(alloc, home.path, &.{ moat_path, cmd });
        if (!result.term.success()) return error.ExpectedZeroExit;
    }
}

fn testAllowRoundTrip(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    const ok = try run(alloc, home.path, &.{ moat_path, "allow", "git", "~/.gitconfig" });
    if (!ok.term.success()) return error.AllowFailed;

    // A grant of $HOME or above would undo the profile; must be refused.
    const bad = try run(alloc, home.path, &.{ moat_path, "allow", "git", "~" });
    if (bad.term.success()) return error.ExpectedNonZeroExit;

    // Adding a link must not drop the allow rule.
    _ = try run(alloc, home.path, &.{ moat_path, "link", home.path, "zig" });
    const cfg_path = try std.fmt.allocPrint(alloc, "{s}/.config/moat/config.zon", .{home.path});
    var buf: [8192]u8 = undefined;
    const content = try std.Io.Dir.cwd().readFile(io, cfg_path, &buf);
    try expectContains(content, ".gitconfig");
}

// --write and --exec are independent, so they must not merge into one rule.
fn testAllowExec(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    _ = try run(alloc, home.path, &.{ moat_path, "allow", "cargo", "~/.rustup", "--exec" });
    _ = try run(alloc, home.path, &.{ moat_path, "allow", "zig", "~/.cache/zig", "--write", "--exec" });
    _ = try run(alloc, home.path, &.{ moat_path, "allow", "git", "~/.gitconfig" });

    const cfg_path = try std.fmt.allocPrint(alloc, "{s}/.config/moat/config.zon", .{home.path});
    var buf: [8192]u8 = undefined;
    const content = try std.Io.Dir.cwd().readFile(io, cfg_path, &buf);
    try expectContains(content, ".rustup");
    try expectContains(content, ".exec = true");
    try expectContains(content, ".write = true");
    // The read-only rule must not have picked up exec.
    try expectContains(content, ".gitconfig");
    var rules = std.mem.splitSequence(u8, content, ".bin");
    _ = rules.next();
    while (rules.next()) |r| {
        if (std.mem.indexOf(u8, r, ".gitconfig") == null) continue;
        if (std.mem.indexOf(u8, r, ".exec = true") != null) return error.ExecLeakedToReadOnlyRule;
    }
}

// Re-granting the same path must widen the existing rule, not stack parallel
// ones: allows are additive, so duplicates only misdescribe the config.
fn testAllowMergesSamePath(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    _ = try run(alloc, home.path, &.{ moat_path, "allow", "zig", "~/.cache/zig" });
    _ = try run(alloc, home.path, &.{ moat_path, "allow", "zig", "~/.cache/zig", "--write" });
    _ = try run(alloc, home.path, &.{ moat_path, "allow", "zig", "~/.cache/zig", "--exec" });

    const cfg_path = try std.fmt.allocPrint(alloc, "{s}/.config/moat/config.zon", .{home.path});
    var buf: [8192]u8 = undefined;
    const content = try std.Io.Dir.cwd().readFile(io, cfg_path, &buf);

    const n = std.mem.count(u8, content, "~/.cache/zig");
    if (n != 1) {
        std.debug.print("    expected 1 rule for the path, found {d}:\n{s}\n", .{ n, content });
        return error.DuplicateRules;
    }
    try expectContains(content, ".write = true");
    try expectContains(content, ".exec = true");
}

// A rule scoped by dirs is a different scope and must survive untouched.
fn testAllowKeepsDirScopedRule(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    const cfg_dir = try std.fmt.allocPrint(alloc, "{s}/.config/moat", .{home.path});
    try std.Io.Dir.cwd().createDirPath(io, cfg_dir);
    try writeFile(try std.fmt.allocPrint(alloc, "{s}/config.zon", .{cfg_dir}),
        \\.{
        \\    .allow = .{.{ .bin = "zig", .paths = .{"~/.cache/zig"}, .dirs = .{"/Users/x/work"} }},
        \\}
    );
    _ = try run(alloc, home.path, &.{ moat_path, "allow", "zig", "~/.cache/zig", "--write" });

    var buf: [8192]u8 = undefined;
    const content = try std.Io.Dir.cwd().readFile(io, try std.fmt.allocPrint(alloc, "{s}/config.zon", .{cfg_dir}), &buf);
    try expectContains(content, "/Users/x/work");
    try expectContains(content, ".write = true");
}

fn testUnallow(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    _ = try run(alloc, home.path, &.{ moat_path, "allow", "zig", "~/.cache/zig", "--write" });

    // The shell-expanded form names the same rule as the stored tilde form.
    const expanded = try std.fmt.allocPrint(alloc, "{s}/.cache/zig", .{home.path});
    const gone = try run(alloc, home.path, &.{ moat_path, "allow", "-r", "zig", expanded });
    if (!gone.term.success()) return error.UnallowFailed;

    const cfg_path = try std.fmt.allocPrint(alloc, "{s}/.config/moat/config.zon", .{home.path});
    var buf: [8192]u8 = undefined;
    const content = try std.Io.Dir.cwd().readFile(io, cfg_path, &buf);
    if (std.mem.indexOf(u8, content, ".cache/zig") != null) return error.RuleStillPresent;

    // Removing what is not there must be detectable by exit status.
    const again = try run(alloc, home.path, &.{ moat_path, "allow", "-r", "zig", "~/.cache/zig" });
    if (again.term.success()) return error.ExpectedNonZeroExit;
}

fn testLinkAndDetect(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    const dir = try std.fmt.allocPrint(alloc, "{s}/project", .{home.path});
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};

    _ = try run(alloc, home.path, &.{ moat_path, "link", dir, "zig" });
    const result = try run(alloc, home.path, &.{ moat_path, "detect", dir });
    try expectContains(result.stderr, "via link");
    try expectContains(result.stderr, "zig");
}

fn testUnlink(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    const dir = try std.fmt.allocPrint(alloc, "{s}/project", .{home.path});
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};

    _ = try run(alloc, home.path, &.{ moat_path, "link", dir, "go" });
    _ = try run(alloc, home.path, &.{ moat_path, "link", "-r", dir });
    const result = try run(alloc, home.path, &.{ moat_path, "detect", dir });
    try expectContains(result.stderr, "no shells detected");
}

fn testLinkRelative(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    const result = try run(alloc, home.path, &.{ moat_path, "link", ".", "zig" });
    if (!result.term.success()) return error.NonZeroExit;
    try expectContains(result.stderr, "linked");
}

fn testDetectRules(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    const dir = try std.fmt.allocPrint(alloc, "{s}/detect-proj", .{home.path});
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};

    const marker = try std.fmt.allocPrint(alloc, "{s}/build.zig.zon", .{dir});
    try writeFile(marker, "");

    const cfg_dir = try std.fmt.allocPrint(alloc, "{s}/.config/moat", .{home.path});
    std.Io.Dir.cwd().createDirPath(io, cfg_dir) catch {};
    const cfg_path = try std.fmt.allocPrint(alloc, "{s}/config.zon", .{cfg_dir});
    try writeFile(cfg_path,
        \\.{
        \\    .jailbreak = .{},
        \\    .links = .{},
        \\    .detect = .{.{ .markers = .{"build.zig.zon"}, .shells = .{"zig"} }},
        \\}
    );

    const result = try run(alloc, home.path, &.{ moat_path, "detect", dir });
    try expectContains(result.stderr, "detect rule");
    try expectContains(result.stderr, "zig");
}

// run() deliberately supplies a bogus flake and a PATH without nix, so check
// must report issues and exit non-zero: it is a validation command.
fn testCheck(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    const result = try run(alloc, home.path, &.{ moat_path, "check" });
    try expectContains(result.stderr, "config:");
    try expectContains(result.stderr, "issue(s) found");
    if (result.term.success()) return error.ExpectedNonZeroExit;
}

fn testCheckRejectsBadAllow(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    const cfg_dir = try std.fmt.allocPrint(alloc, "{s}/.config/moat", .{home.path});
    std.Io.Dir.cwd().createDirPath(io, cfg_dir) catch {};
    try writeFile(try std.fmt.allocPrint(alloc, "{s}/config.zon", .{cfg_dir}),
        \\.{
        \\    .allow = .{.{ .bin = "git", .paths = .{"~/../.."} }},
        \\}
    );
    const result = try run(alloc, home.path, &.{ moat_path, "check" });
    try expectContains(result.stderr, "allow: git");
    if (result.term.success()) return error.ExpectedNonZeroExit;
}

fn testVerboseFlag(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    const dir = try std.fmt.allocPrint(alloc, "{s}/vproj", .{home.path});
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};

    const r1 = try run(alloc, home.path, &.{ moat_path, "-v", "detect", dir });
    if (!r1.term.success()) return error.NonZeroExit;

    const r2 = try run(alloc, home.path, &.{ moat_path, "detect", "-v", dir });
    if (!r2.term.success()) return error.NonZeroExit;
}
