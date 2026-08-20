const std = @import("std");

pub const default_flake = "github:q-uint/moat";

// Every field is duped: the wrapper mutates the environ map, and put() frees the
// storage a borrowed slice would point at.
pub const Env = struct {
    home: ?[]const u8,
    root: ?[]const u8,
    flake: []const u8,
    shell: []const u8,
    path: []const u8,
    jailbreak: ?[]const u8,
    confirm: ?[]const u8,
    env_home: ?[]const u8,
};

fn dupeOpt(alloc: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |v| try alloc.dupe(u8, v) else null;
}

// `lookup` is anything with a get([]const u8) ?[]const u8 method, so tests do
// not have to build a real environ map.
pub fn from(alloc: std.mem.Allocator, lookup: anytype) !Env {
    return .{
        .home = try dupeOpt(alloc, lookup.get("HOME")),
        .root = try dupeOpt(alloc, lookup.get("MOAT_ROOT")),
        .flake = try alloc.dupe(u8, lookup.get("MOAT_FLAKE") orelse default_flake),
        .shell = try alloc.dupe(u8, lookup.get("SHELL") orelse "/bin/bash"),
        .path = try alloc.dupe(u8, lookup.get("PATH") orelse ""),
        .jailbreak = try dupeOpt(alloc, lookup.get("MOAT_JAILBREAK")),
        .confirm = try dupeOpt(alloc, lookup.get("MOAT_CONFIRM")),
        .env_home = try dupeOpt(alloc, lookup.get("MOAT_ENV_HOME")),
    };
}

const FakeEnv = struct {
    entries: []const [2][]const u8,

    fn get(self: FakeEnv, name: []const u8) ?[]const u8 {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e[0], name)) return e[1];
        }
        return null;
    }
};

test "from applies defaults" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const e = try from(arena.allocator(), FakeEnv{ .entries = &.{
        .{ "HOME", "/Users/t" },
    } });
    try std.testing.expectEqualStrings("/Users/t", e.home.?);
    try std.testing.expectEqualStrings(default_flake, e.flake);
    try std.testing.expectEqualStrings("/bin/bash", e.shell);
    try std.testing.expectEqualStrings("", e.path);
    try std.testing.expect(e.root == null);
    try std.testing.expect(e.confirm == null);
}

test "from reads every variable" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const e = try from(arena.allocator(), FakeEnv{ .entries = &.{
        .{ "HOME", "/Users/t" },
        .{ "MOAT_ROOT", "/w" },
        .{ "MOAT_FLAKE", "/local/flake" },
        .{ "SHELL", "/bin/zsh" },
        .{ "PATH", "/nix/store/x/bin" },
        .{ "MOAT_JAILBREAK", "/bin/git" },
        .{ "MOAT_CONFIRM", "always" },
        .{ "MOAT_ENV_HOME", "/w/.moat/home" },
    } });
    try std.testing.expectEqualStrings("/w", e.root.?);
    try std.testing.expectEqualStrings("/local/flake", e.flake);
    try std.testing.expectEqualStrings("/bin/zsh", e.shell);
    try std.testing.expectEqualStrings("/bin/git", e.jailbreak.?);
    try std.testing.expectEqualStrings("always", e.confirm.?);
    try std.testing.expectEqualStrings("/w/.moat/home", e.env_home.?);
}

// The dangling-pointer bug this type exists to prevent: a value read from the
// map must survive a later put() on that same map.
test "values are duped, not borrowed" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var buf = [_]u8{ '/', 'w', 'o', 'r', 'k' };
    const e = try from(arena.allocator(), FakeEnv{ .entries = &.{
        .{ "MOAT_ROOT", &buf },
    } });
    @memset(&buf, 'x');
    try std.testing.expectEqualStrings("/work", e.root.?);
}
