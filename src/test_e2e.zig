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
        .{ "link and detect", testLinkAndDetect },
        .{ "unlink", testUnlink },
        .{ "link relative path", testLinkRelative },
        .{ "detect .moat-shell override", testDetectOverride },
        .{ "detect rules (build.zig.zon)", testDetectRules },
        .{ "check", testCheck },
        .{ "check rejects bad allow", testCheckRejectsBadAllow },
        .{ "verbose flag positions", testVerboseFlag },
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

// Usage errors must be detectable by exit status, not just by their message.
fn testUsageErrorsExitNonZero(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    const cases: []const []const []const u8 = &.{
        &.{moat_path},
        &.{ moat_path, "shell" },
        &.{ moat_path, "link" },
        &.{ moat_path, "unlink" },
        &.{ moat_path, "allow" },
        &.{ moat_path, "allow", "git" },
    };
    for (cases) |argv| {
        const result = try run(alloc, home.path, argv);
        if (result.term.success()) {
            std.debug.print("    expected non-zero exit for: {s}\n", .{argv[argv.len - 1]});
            return error.ExpectedNonZeroExit;
        }
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
    _ = try run(alloc, home.path, &.{ moat_path, "unlink", dir });
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

fn testDetectOverride(alloc: std.mem.Allocator) !void {
    const home = try TestHome.init(alloc);
    defer home.deinit();
    const dir = try std.fmt.allocPrint(alloc, "{s}/override-proj", .{home.path});
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};

    const shell_file = try std.fmt.allocPrint(alloc, "{s}/.moat-shell", .{dir});
    try writeFile(shell_file, "node\n");

    const result = try run(alloc, home.path, &.{ moat_path, "detect", dir });
    try expectContains(result.stderr, ".moat-shell");
    try expectContains(result.stderr, "node");
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
