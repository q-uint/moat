const std = @import("std");
const sandbox = @import("sandbox.zig");

pub const Request = struct {
    bin: []const u8,
    root: []const u8,
    env_home: ?[]const u8 = null,
    grants: []const sandbox.Grant = &.{},
    jailbreaks: []const []const u8 = &.{},
};

// `never` skips the prompt; `always` re-prompts even for a stored approval.
pub const Mode = enum { config, never, always };

pub fn modeFromEnv(value: ?[]const u8) Mode {
    const v = value orelse return .config;
    if (std.mem.eql(u8, v, "never")) return .never;
    if (std.mem.eql(u8, v, "always")) return .always;
    return .config;
}

pub fn required(list: []const []const u8, bin: []const u8, mode: Mode) bool {
    switch (mode) {
        .never => return false,
        .always => return true,
        .config => {},
    }
    for (list) |n| {
        if (std.mem.eql(u8, n, "*") or std.mem.eql(u8, n, bin)) return true;
    }
    return false;
}

// Order-independent, so reordering the config keeps an approval valid; summed
// rather than xored so a duplicated grant cannot cancel itself out.
pub fn key(req: Request) u64 {
    var set: u64 = 0;
    for (req.grants) |g| {
        var gh = std.hash.Wyhash.init(0);
        gh.update(g.path);
        gh.update(&.{ @intFromBool(g.write), @intFromBool(g.exec) });
        set +%= gh.final();
    }
    for (req.jailbreaks) |j| {
        var jh = std.hash.Wyhash.init(1);
        jh.update(j);
        set +%= jh.final();
    }
    // Seed doubles as a format version: bump it to invalidate stored approvals.
    var h = std.hash.Wyhash.init(2);
    h.update(req.bin);
    h.update(req.root);
    h.update(req.env_home orelse "");
    h.update(std.mem.asBytes(&set));
    return h.final();
}

fn addLine(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(text);
    try buf.appendSlice(alloc, text);
}

pub fn render(alloc: std.mem.Allocator, req: Request) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try addLine(alloc, &buf, "moat: about to run {s} in {s}\n", .{ req.bin, req.root });
    try addLine(alloc, &buf, "  {s: <16} {s}\n", .{ "read/write/exec", req.root });
    if (req.env_home) |h| try addLine(alloc, &buf, "  {s: <16} {s}\n", .{ "HOME", h });
    for (req.grants) |g| {
        const mode: []const u8 = if (g.write and g.exec)
            "read/write/exec"
        else if (g.write)
            "read/write"
        else if (g.exec)
            "read/exec"
        else
            "read";
        try addLine(alloc, &buf, "  {s: <16} {s}\n", .{ mode, g.path });
    }
    for (req.jailbreaks) |j| {
        try addLine(alloc, &buf, "  {s: <16} {s}  UNSANDBOXED\n", .{ "jailbreak", j });
    }
    try addLine(alloc, &buf, "  {s: <16} {s}\n", .{ "network", "allowed" });
    try buf.appendSlice(alloc, "nothing else outside those paths is readable\n");
    return buf.toOwnedSlice(alloc);
}

// Hardcoded under $HOME, as config.configPath is. Both should start honouring
// XDG_CONFIG_HOME / XDG_STATE_HOME at the same time, or neither.
pub fn approvalsPath(alloc: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/.local/state/moat/approvals", .{home});
}

fn formatKey(buf: *[16]u8, k: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>16}", .{k}) catch unreachable;
}

pub fn containsKey(content: []const u8, k: u64) bool {
    var buf: [16]u8 = undefined;
    const want = formatKey(&buf, k);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const field = if (std.mem.indexOfScalar(u8, line, '\t')) |tab| line[0..tab] else line;
        if (std.mem.eql(u8, field, want)) return true;
    }
    return false;
}

pub const Entry = struct { bin: []const u8, root: []const u8 };

// Malformed lines are skipped rather than reported: the file is moat's own
// state, and a partial one should still list what it can.
pub fn parseEntries(alloc: std.mem.Allocator, content: []const u8) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |l| {
        var fields = std.mem.splitScalar(u8, l, '\t');
        _ = fields.next() orelse continue;
        const bin = fields.next() orelse continue;
        const root = fields.next() orelse continue;
        if (bin.len == 0 or root.len == 0) continue;
        try out.append(alloc, .{ .bin = bin, .root = root });
    }
    return out.toOwnedSlice(alloc);
}

pub const Filtered = struct { content: []const u8, removed: usize };

// A null root drops every entry.
pub fn withoutRoot(alloc: std.mem.Allocator, content: []const u8, root: ?[]const u8) !Filtered {
    var kept: std.ArrayList(u8) = .empty;
    var removed: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        const drop = if (root) |r| blk: {
            var fields = std.mem.splitScalar(u8, l, '\t');
            _ = fields.next();
            _ = fields.next();
            const line_root = fields.next() orelse break :blk false;
            break :blk std.mem.eql(u8, line_root, r);
        } else true;
        if (drop) {
            removed += 1;
            continue;
        }
        try kept.appendSlice(alloc, l);
        try kept.append(alloc, '\n');
    }
    return .{ .content = try kept.toOwnedSlice(alloc), .removed = removed };
}

pub fn writeApprovals(io: std.Io, path: []const u8, content: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        std.Io.Dir.cwd().createDirPath(io, path[0..sep]) catch {};
    }
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(content);
    try w.flush();
}

pub fn readApprovals(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var buf: [64 * 1024]u8 = undefined;
    const content = std.Io.Dir.cwd().readFile(io, path, &buf) catch return "";
    return alloc.dupe(u8, content);
}

fn isApproved(io: std.Io, path: []const u8, k: u64) bool {
    var buf: [64 * 1024]u8 = undefined;
    const content = std.Io.Dir.cwd().readFile(io, path, &buf) catch return false;
    return containsKey(content, k);
}

// Best effort: a session that runs anyway is better than one that refuses
// because the state dir is unwritable.
fn record(alloc: std.mem.Allocator, io: std.Io, path: []const u8, k: u64, req: Request) void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        std.Io.Dir.cwd().createDirPath(io, path[0..sep]) catch return;
    }
    var kbuf: [16]u8 = undefined;
    const line = std.fmt.allocPrint(alloc, "{s}\t{s}\t{s}\n", .{ formatKey(&kbuf, k), req.bin, req.root }) catch return;
    const existing = blk: {
        var buf: [64 * 1024]u8 = undefined;
        const content = std.Io.Dir.cwd().readFile(io, path, &buf) catch break :blk "";
        break :blk alloc.dupe(u8, content) catch return;
    };
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer file.close(io);
    var wbuf: [4096]u8 = undefined;
    var w = file.writer(io, &wbuf);
    w.interface.writeAll(existing) catch return;
    w.interface.writeAll(line) catch return;
    w.flush() catch return;
}

// stdin may be the tool's own input, so the answer comes from the terminal.
fn ask(io: std.Io, summary: []const u8) !bool {
    var tty = try std.Io.Dir.cwd().openFile(io, "/dev/tty", .{ .mode = .read_write });
    defer tty.close(io);

    var wbuf: [4096]u8 = undefined;
    var w = tty.writer(io, &wbuf);
    try w.interface.writeAll(summary);
    try w.interface.writeAll("continue? [y/N] ");
    try w.flush();

    var rbuf: [64]u8 = undefined;
    var r = tty.reader(io, &rbuf);
    const line = r.interface.takeDelimiterExclusive('\n') catch return false;
    const answer = std.mem.trim(u8, line, &std.ascii.whitespace);
    return std.mem.eql(u8, answer, "y") or std.mem.eql(u8, answer, "Y") or
        std.mem.eql(u8, answer, "yes");
}

// Prompts unless this exact access set was approved before for this root.
// Called before the profile is applied, so $HOME is still readable.
pub fn ensure(alloc: std.mem.Allocator, io: std.Io, req: Request, home: []const u8, mode: Mode) !void {
    if (mode == .never) return;
    const k = key(req);
    const path = try approvalsPath(alloc, home);
    if (mode != .always and isApproved(io, path, k)) return;

    const summary = try render(alloc, req);
    const ok = ask(io, summary) catch {
        std.debug.print("{s}moat: no terminal to confirm on; set MOAT_CONFIRM=never to skip this prompt\n", .{summary});
        return error.ConfirmDenied;
    };
    if (!ok) return error.ConfirmDenied;
    // An `always` run is an explicit review, not a new decision, so it leaves
    // the stored set alone.
    if (mode != .always) record(alloc, io, path, k, req);
}

test "required" {
    try std.testing.expect(required(&.{"claude"}, "claude", .config));
    try std.testing.expect(!required(&.{"claude"}, "zig", .config));
    try std.testing.expect(required(&.{"*"}, "anything", .config));
    try std.testing.expect(!required(&.{}, "claude", .config));

    // The env override wins in both directions.
    try std.testing.expect(!required(&.{"claude"}, "claude", .never));
    try std.testing.expect(required(&.{}, "zig", .always));
}

test "modeFromEnv" {
    try std.testing.expectEqual(Mode.config, modeFromEnv(null));
    try std.testing.expectEqual(Mode.never, modeFromEnv("never"));
    try std.testing.expectEqual(Mode.always, modeFromEnv("always"));
    // An unrecognised value must not read as "never".
    try std.testing.expectEqual(Mode.config, modeFromEnv("1"));
}

test "key ignores grant order" {
    const a = Request{ .bin = "claude", .root = "/w", .grants = &.{
        .{ .path = "/a" },
        .{ .path = "/b", .write = true },
    } };
    const b = Request{ .bin = "claude", .root = "/w", .grants = &.{
        .{ .path = "/b", .write = true },
        .{ .path = "/a" },
    } };
    try std.testing.expectEqual(key(a), key(b));
}

test "key changes when access widens" {
    const base = Request{ .bin = "claude", .root = "/w", .grants = &.{.{ .path = "/a" }} };
    const write = Request{ .bin = "claude", .root = "/w", .grants = &.{.{ .path = "/a", .write = true }} };
    const exec = Request{ .bin = "claude", .root = "/w", .grants = &.{.{ .path = "/a", .exec = true }} };
    const extra = Request{ .bin = "claude", .root = "/w", .grants = &.{ .{ .path = "/a" }, .{ .path = "/b" } } };
    const jailed = Request{ .bin = "claude", .root = "/w", .grants = &.{.{ .path = "/a" }}, .jailbreaks = &.{"/bin/git"} };
    const other_root = Request{ .bin = "claude", .root = "/other", .grants = &.{.{ .path = "/a" }} };
    const other_home = Request{ .bin = "claude", .root = "/w", .env_home = "/w/.moat/home", .grants = &.{.{ .path = "/a" }} };

    const k = key(base);
    try std.testing.expect(k != key(write));
    try std.testing.expect(k != key(exec));
    try std.testing.expect(k != key(extra));
    try std.testing.expect(k != key(jailed));
    try std.testing.expect(k != key(other_root));
    try std.testing.expect(k != key(other_home));

    // A duplicated grant must not cancel itself out.
    const dup = Request{ .bin = "claude", .root = "/w", .grants = &.{ .{ .path = "/a" }, .{ .path = "/a" } } };
    try std.testing.expect(k != key(dup));
}

test "render lists every access level" {
    const alloc = std.testing.allocator;
    const out = try render(alloc, .{
        .bin = "claude",
        .root = "/Users/t/proj",
        .env_home = "/Users/t/proj/.moat/home",
        .grants = &.{
            .{ .path = "/Users/t/.claude/CLAUDE.md" },
            .{ .path = "/Users/t/.cache/zig", .write = true, .exec = true },
        },
        .jailbreaks = &.{"/nix/store/x/bin/git"},
    });
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "about to run claude in /Users/t/proj") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "HOME             /Users/t/proj/.moat/home") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "read             /Users/t/.claude/CLAUDE.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "read/write/exec  /Users/t/.cache/zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "UNSANDBOXED") != null);
}

test "parseEntries skips malformed lines" {
    const alloc = std.testing.allocator;
    const out = try parseEntries(alloc, "aaa\tclaude\t/w\nnot a record\nbbb\tzig\t/x\n\n");
    defer alloc.free(out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("claude", out[0].bin);
    try std.testing.expectEqualStrings("/x", out[1].root);
}

test "withoutRoot drops matching entries only" {
    const alloc = std.testing.allocator;
    const content = "aaa\tclaude\t/w\nbbb\tzig\t/x\nccc\tnpm\t/w\n";

    const one = try withoutRoot(alloc, content, "/w");
    defer alloc.free(one.content);
    try std.testing.expectEqual(@as(usize, 2), one.removed);
    try std.testing.expectEqualStrings("bbb\tzig\t/x\n", one.content);

    // A root that is merely a prefix is a different project.
    const none = try withoutRoot(alloc, content, "/w2");
    defer alloc.free(none.content);
    try std.testing.expectEqual(@as(usize, 0), none.removed);

    const all = try withoutRoot(alloc, content, null);
    defer alloc.free(all.content);
    try std.testing.expectEqual(@as(usize, 3), all.removed);
    try std.testing.expectEqualStrings("", all.content);
}

test "containsKey matches whole field only" {
    const content = "00000000deadbeef\tclaude\t/w\n0000000000000001\tzig\t/x\n";
    try std.testing.expect(containsKey(content, 0xdeadbeef));
    try std.testing.expect(containsKey(content, 1));
    try std.testing.expect(!containsKey(content, 0xdeadbeee));
    try std.testing.expect(!containsKey("", 1));
}

test "approvalsPath" {
    const alloc = std.testing.allocator;
    const p = try approvalsPath(alloc, "/Users/t");
    defer alloc.free(p);
    try std.testing.expectEqualStrings("/Users/t/.local/state/moat/approvals", p);
}
