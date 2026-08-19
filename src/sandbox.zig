const std = @import("std");

// Private libsandbox API, linked via .tbd stub in lib/.
const c = struct {
    const params_t = ?*anyopaque;
    extern "sandbox" fn sandbox_create_params() callconv(.c) params_t;
    extern "sandbox" fn sandbox_set_param(params: params_t, key: [*:0]const u8, val: [*:0]const u8) callconv(.c) c_int;
    extern "sandbox" fn sandbox_compile_string(profile: [*:0]const u8, params: params_t, err: *?[*:0]u8) callconv(.c) ?*anyopaque;
    extern "sandbox" fn sandbox_apply(compiled: *anyopaque) callconv(.c) c_int;
    // Comes from libSystem, not libsandbox.1.dylib. Adding it to the .tbd stub
    // makes the linker bind it to a null address that crashes when called.
    extern "c" fn sandbox_check(pid: std.c.pid_t, operation: ?[*:0]const u8, kind: c_int) callconv(.c) c_int;
    extern "sandbox" fn sandbox_free_error(err: [*:0]u8) callconv(.c) void;
};

// Deny-by-default: a rule that is missing here shows up as a tool that breaks
// loudly, not as a hole nobody notices. bsd.sb (via system.sb) supplies the
// dyld, sysctl and mach-lookup plumbing; it grants no data reads under /Users.
const sbpl_header =
    \\(version 1)
    \\(deny default)
    \\(import "bsd.sb")
    \\(define root (param "root"))
    \\(define home (param "home"))
    \\(allow network*)
    \\(allow process-fork)
    \\(allow signal (target same-sandbox))
    \\(allow sysctl-read)
    \\(allow file-read* file-map-executable process-exec (subpath "/nix/store"))
    \\(allow file-read* file-map-executable process-exec
    \\  (subpath "/bin")
    \\  (subpath "/sbin")
    \\  (subpath "/usr/bin")
    \\  (subpath "/usr/lib")
    \\  (subpath "/usr/libexec")
    \\  (subpath "/usr/sbin")
    \\  (subpath "/System"))
    \\(allow file-read*
    \\  (subpath "/etc")
    \\  (subpath "/private/etc")
    \\  (subpath "/usr/share")
    \\  (literal "/dev/null")
    \\  (literal "/dev/zero")
    \\  (literal "/dev/random")
    \\  (literal "/dev/urandom"))
    \\(allow file-write-data (literal "/dev/null") (literal "/dev/dtracehelper"))
    \\(allow file-read* file-write* file-ioctl (regex #"^/dev/tty"))
    \\; file* does not imply process-exec; project-local binaries must run too.
    \\(allow file* process-exec file-map-executable (subpath root))
    \\
;

// Under (deny default) the root allow no longer competes with a home deny, but
// a root at or above $HOME would still hand back all of $HOME, so it is
// rejected rather than silently granted.
fn containsPath(parent: []const u8, child: []const u8) bool {
    const p = if (parent.len > 1 and parent[parent.len - 1] == '/') parent[0 .. parent.len - 1] else parent;
    if (std.mem.eql(u8, p, "/")) return true;
    if (!std.mem.startsWith(u8, child, p)) return false;
    return child.len == p.len or child[p.len] == '/';
}

// /tmp is shared with every other user and process on the machine, so strict
// mode does not grant it. TMPDIR points here instead, inside the root.
pub const tmp_subdir = ".moat/tmp";

// Creates <root>/.moat/tmp and points TMPDIR at it. The .moat dir carries a
// .gitignore of "*", which ignores its contents and itself, so the user's own
// .gitignore is left alone.
pub fn prepareTmpDir(alloc: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map, root: []const u8) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, tmp_subdir });
    std.Io.Dir.cwd().createDirPath(io, path) catch return;

    const ignore = try std.fmt.allocPrint(alloc, "{s}/.moat/.gitignore", .{root});
    if (std.Io.Dir.cwd().access(io, ignore, .{})) |_| {} else |_| {
        if (std.Io.Dir.cwd().createFile(io, ignore, .{})) |f| {
            var buf: [8]u8 = undefined;
            var w = f.writer(io, &buf);
            w.interface.writeAll("*\n") catch {};
            w.flush() catch {};
            f.close(io);
        } else |_| {}
    }
    try environ.put("TMPDIR", path);
}

// Config lists jailbreaks by name; SBPL needs the absolute exec path.
// Grants for one binary, or -- when bin is "*" -- the union of every rule that
// applies to this root. `moat shell` must union, because one profile covers the
// whole session and a nested sandbox can never widen it.
// The sandbox canonicalizes the paths it checks but not the patterns in the
// profile, so a grant naming a symlinked path (/tmp -> /private/tmp) would
// never match. Resolve it here; fall back to the literal path when it does not
// exist yet, which is still correct for an already-canonical path.
pub fn canonicalize(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.realPathFileAbsolute(io, path, &buf)) |n| {
        return try alloc.dupe(u8, buf[0..n]);
    } else |_| {}
    const dir = std.fs.path.dirname(path) orelse return path;
    const base = std.fs.path.basename(path);
    if (std.Io.Dir.realPathFileAbsolute(io, dir, &buf)) |n| {
        return try std.fmt.allocPrint(alloc, "{s}/{s}", .{ buf[0..n], base });
    } else |_| {}
    return path;
}

pub fn collectGrants(alloc: std.mem.Allocator, io: std.Io, rules: anytype, bin: []const u8, root: []const u8, home: []const u8) ![]const Grant {
    const union_all = std.mem.eql(u8, bin, "*");
    var out: std.ArrayList(Grant) = .empty;
    for (rules) |r| {
        // A non-canonical dir filter would silently never match.
        for (r.dirs) |d| try validatePath(d);
        if (!r.matchesDir(root)) continue;
        if (!union_all and !r.matchesBin(bin)) continue;
        for (r.paths) |p| {
            const expanded = try expandTilde(alloc, home, p);
            try out.append(alloc, .{ .path = try canonicalize(alloc, io, expanded), .write = r.write });
        }
    }
    return out.items;
}

pub fn resolveJailbreak(alloc: std.mem.Allocator, io: std.Io, path_env: []const u8, name: []const u8) !?[]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.fs.path.isAbsolute(name)) {
        const n = std.Io.Dir.realPathFileAbsolute(io, name, &buf) catch return null;
        return try alloc.dupe(u8, buf[0..n]);
    }
    var dirs = std.mem.splitScalar(u8, path_env, ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const cand = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
        std.Io.Dir.cwd().access(io, cand, .{}) catch continue;
        const n = std.Io.Dir.realPathFileAbsolute(io, cand, &buf) catch continue;
        return try alloc.dupe(u8, buf[0..n]);
    }
    return null;
}

pub fn expandTilde(alloc: std.mem.Allocator, home: []const u8, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "~")) return try alloc.dupe(u8, home);
    if (std.mem.startsWith(u8, path, "~/")) {
        return try std.fmt.allocPrint(alloc, "{s}{s}", .{ home, path[1..] });
    }
    return try alloc.dupe(u8, path);
}

pub const Grant = struct {
    path: []const u8,
    write: bool = false,
};

// Every path here is interpolated into the profile as an SBPL string literal.
// A quote or backslash would produce a malformed profile (libsandbox aborts
// rather than erroring), and a ".." component compiles to a rule that silently
// matches nothing, since SBPL does not canonicalize subpath patterns.
pub fn validatePath(p: []const u8) !void {
    if (!std.fs.path.isAbsolute(p)) return error.PathNotAbsolute;
    for (p) |ch| {
        if (ch == '"' or ch == '\\' or ch < 0x20) return error.PathUnsafeChars;
    }
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return error.PathNotCanonical;
    }
}

// Root is granted file* by the header; anything else needs a write grant.
pub fn writableIn(path: []const u8, root: []const u8, grants: []const Grant) bool {
    if (containsPath(root, path)) return true;
    for (grants) |g| {
        if (g.write and containsPath(g.path, path)) return true;
    }
    return false;
}

fn remapNotAbsolute(e: anyerror, as: anyerror) anyerror {
    return if (e == error.PathNotAbsolute) as else e;
}

pub fn validateGrant(g: Grant, home: []const u8) !void {
    try validatePath(g.path);
    // A grant of $HOME or an ancestor would undo the whole profile.
    if (containsPath(g.path, home)) return error.GrantContainsHome;
}

pub const Profile = struct {
    root: []const u8,
    home: []const u8,
    grants: []const Grant = &.{},
    jailbreaks: []const []const u8 = &.{},

    pub fn validate(self: Profile) !void {
        validatePath(self.root) catch |e| return remapNotAbsolute(e, error.RootNotAbsolute);
        validatePath(self.home) catch |e| return remapNotAbsolute(e, error.HomeNotAbsolute);
        if (containsPath(self.root, self.home)) return error.RootContainsHome;
        for (self.grants) |g| try validateGrant(g, self.home);
        // (literal "...") only ever matches an absolute exec path; a bare name
        // silently matches nothing, so refuse it instead of rendering a no-op.
        for (self.jailbreaks) |path| {
            validatePath(path) catch |e| return remapNotAbsolute(e, error.JailbreakNotAbsolute);
        }
    }

    pub fn render(self: Profile, alloc: std.mem.Allocator) ![:0]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(alloc, sbpl_header);
        for (self.grants) |g| {
            const op = if (g.write) "file*" else "file-read*";
            const line = try std.fmt.allocPrint(alloc, "(allow {s} (subpath \"{s}\"))\n", .{ op, g.path });
            defer alloc.free(line);
            try buf.appendSlice(alloc, line);
        }
        for (self.jailbreaks) |path| {
            const line = try std.fmt.allocPrint(alloc, "(allow process-exec (literal \"{s}\")(with no-sandbox))\n", .{path});
            defer alloc.free(line);
            try buf.appendSlice(alloc, line);
        }
        try buf.append(alloc, 0);
        const slice = try buf.toOwnedSlice(alloc);
        return slice[0 .. slice.len - 1 :0];
    }
};

// sandbox_apply fails unconditionally once any profile is active, even for an
// identical one. Inside `moat shell` the session profile already confines this
// process and every child, so a wrapped binary must skip re-applying rather
// than die. Restrictions only ever intersect, so this cannot widen anything.
pub fn alreadySandboxed() bool {
    return c.sandbox_check(std.c.getpid(), null, 0) == 1;
}

pub fn apply(profile: Profile, alloc: std.mem.Allocator) !void {
    try profile.validate();
    const sbpl = try profile.render(alloc);
    const params = c.sandbox_create_params() orelse return error.SandboxCreateParams;
    _ = c.sandbox_set_param(params, "root", try alloc.dupeSentinel(u8, profile.root, 0));
    _ = c.sandbox_set_param(params, "home", try alloc.dupeSentinel(u8, profile.home, 0));

    var err_buf: ?[*:0]u8 = null;
    const compiled = c.sandbox_compile_string(sbpl.ptr, params, &err_buf) orelse {
        if (err_buf) |e| {
            std.debug.print("moat: sandbox compile error: {s}\n", .{e});
            c.sandbox_free_error(e);
        }
        return error.SandboxCompile;
    };
    if (c.sandbox_apply(compiled) != 0) {
        return error.SandboxApply;
    }
}

test "profile render" {
    const alloc = std.testing.allocator;
    const p = Profile{ .root = "/tmp/work", .home = "/Users/test" };
    const out = try p.render(alloc);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "(deny default)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(allow file* process-exec file-map-executable (subpath root))") != null);
}

test "containsPath" {
    try std.testing.expect(containsPath("/Users/test", "/Users/test"));
    try std.testing.expect(containsPath("/Users", "/Users/test"));
    try std.testing.expect(containsPath("/", "/Users/test"));
    try std.testing.expect(containsPath("/Users/", "/Users/test"));
    try std.testing.expect(!containsPath("/Users/test/proj", "/Users/test"));
    try std.testing.expect(!containsPath("/Users/testing", "/Users/test"));
    try std.testing.expect(!containsPath("/tmp/work", "/Users/test"));
}

test "grant render and validation" {
    const alloc = std.testing.allocator;
    const p = Profile{ .root = "/Users/test/proj", .home = "/Users/test", .grants = &.{
        .{ .path = "/Users/test/.gitconfig" },
        .{ .path = "/Users/test/.cargo", .write = true },
    } };
    const out = try p.render(alloc);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "(allow file-read* (subpath \"/Users/test/.gitconfig\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(allow file* (subpath \"/Users/test/.cargo\"))") != null);

    try std.testing.expectError(error.PathNotAbsolute, validateGrant(.{ .path = "~/.gitconfig" }, "/Users/test"));
    try std.testing.expectError(error.PathNotCanonical, validateGrant(.{ .path = "/Users/test/proj/../.." }, "/Users/test"));
    try std.testing.expectError(error.PathUnsafeChars, validateGrant(.{ .path = "/tmp/a\")(allow default)(literal \"x" }, "/Users/test"));
    try std.testing.expectError(error.GrantContainsHome, validateGrant(.{ .path = "/Users/test" }, "/Users/test"));
    try std.testing.expectError(error.GrantContainsHome, validateGrant(.{ .path = "/" }, "/Users/test"));
}

test "writableIn" {
    const grants = [_]Grant{ .{ .path = "/tmp/rw", .write = true }, .{ .path = "/tmp/ro" } };
    try std.testing.expect(writableIn("/work/.moat/home", "/work", &grants));
    try std.testing.expect(writableIn("/work", "/work", &grants));
    try std.testing.expect(writableIn("/tmp/rw/home", "/work", &grants));
    try std.testing.expect(!writableIn("/tmp/ro/home", "/work", &grants));
    try std.testing.expect(!writableIn("/elsewhere", "/work", &grants));
}

test "expandTilde" {
    const alloc = std.testing.allocator;
    const a = try expandTilde(alloc, "/Users/test", "~/.gitconfig");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("/Users/test/.gitconfig", a);
    const b = try expandTilde(alloc, "/Users/test", "/etc/hosts");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("/etc/hosts", b);
}

test "validate rejects non-absolute jailbreak" {
    const p = Profile{ .root = "/tmp/work", .home = "/Users/test", .jailbreaks = &.{"git"} };
    try std.testing.expectError(error.JailbreakNotAbsolute, p.validate());
    try (Profile{ .root = "/tmp/work", .home = "/Users/test", .jailbreaks = &.{"/usr/bin/git"} }).validate();
}

test "validate rejects root containing home" {
    try std.testing.expectError(error.RootContainsHome, (Profile{ .root = "/Users/test", .home = "/Users/test" }).validate());
    try std.testing.expectError(error.RootContainsHome, (Profile{ .root = "/Users", .home = "/Users/test" }).validate());
    try std.testing.expectError(error.RootContainsHome, (Profile{ .root = "/", .home = "/Users/test" }).validate());
    try (Profile{ .root = "/Users/test/proj", .home = "/Users/test" }).validate();
    try (Profile{ .root = "/tmp/work", .home = "/Users/test" }).validate();
}
