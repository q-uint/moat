const std = @import("std");

// A lock lives next to the config rather than with the approvals: it is part of
// "my setup", the thing you would copy to another machine, not local state.
pub const Lock = struct {
    shells: []const Entry = &.{},

    pub const Entry = struct {
        // The name as typed: a bare shell name, or a qualified flake ref.
        name: []const u8,
        // The immutable ref this resolved to, empty when the source cannot be
        // pinned (a local working tree).
        ref: []const u8 = "",
        rev: []const u8 = "",
        // Content addressed over the whole closure, so it detects any change in
        // what lands on PATH, which the rev alone does not.
        out: []const u8 = "",
    };

    pub fn lookup(self: Lock, name: []const u8) ?Entry {
        for (self.shells) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }
};

// A working tree changes under you, so recording a rev for it would claim a
// pin that does not exist.
pub fn pinnable(flake: []const u8) bool {
    if (std.mem.startsWith(u8, flake, "path:")) return false;
    if (std.mem.startsWith(u8, flake, "git+file:")) return false;
    if (std.mem.startsWith(u8, flake, "/") or std.mem.startsWith(u8, flake, ".")) return false;
    return true;
}

// A name containing '#' carries its own flake, so MOAT_FLAKE does not apply.
pub fn split(name: []const u8) struct { flake: ?[]const u8, attr: []const u8 } {
    if (std.mem.lastIndexOfScalar(u8, name, '#')) |hash| {
        return .{ .flake = name[0..hash], .attr = name[hash + 1 ..] };
    }
    return .{ .flake = null, .attr = name };
}

// github:owner/repo -> github:owner/repo/<rev>. A ref that already carries a rev
// or a query is returned unchanged, since appending would corrupt it.
pub fn withRev(alloc: std.mem.Allocator, flake: []const u8, rev: []const u8) ![]const u8 {
    if (rev.len == 0) return alloc.dupe(u8, flake);
    if (std.mem.indexOfScalar(u8, flake, '?') != null) return alloc.dupe(u8, flake);
    if (std.mem.startsWith(u8, flake, "github:") or std.mem.startsWith(u8, flake, "gitlab:")) {
        // owner/repo, owner/repo/ref: a third segment is already a ref.
        const body = flake[std.mem.indexOfScalar(u8, flake, ':').? + 1 ..];
        var segments: usize = 1;
        for (body) |c| {
            if (c == '/') segments += 1;
        }
        if (segments >= 3) return alloc.dupe(u8, flake);
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ flake, rev });
    }
    return std.fmt.allocPrint(alloc, "{s}?rev={s}", .{ flake, rev });
}

pub fn path(alloc: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/.config/moat/lock.zon", .{home});
}

pub fn load(alloc: std.mem.Allocator, io: std.Io, home: []const u8) !Lock {
    const p = try path(alloc, home);
    var buf: [64 * 1024]u8 = undefined;
    const raw = std.Io.Dir.cwd().readFile(io, p, &buf) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const source = try alloc.dupeSentinel(u8, raw, 0);
    var diag: std.zon.parse.Diagnostics = .{};
    return std.zon.parse.fromSliceAlloc(Lock, alloc, source, &diag, .{ .free_on_error = true }) catch {
        std.debug.print("moat: cannot parse {s}\n", .{p});
        return error.LockParse;
    };
}

pub fn save(alloc: std.mem.Allocator, io: std.Io, home: []const u8, lock: Lock) !void {
    const p = try path(alloc, home);
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |sep| {
        std.Io.Dir.cwd().createDirPath(io, p[0..sep]) catch {};
    }
    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp", .{p});
    const file = try std.Io.Dir.cwd().createFile(io, tmp, .{});
    {
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var w = file.writer(io, &buf);
        try std.zon.stringify.serialize(lock, .{ .emit_default_optional_fields = false }, &w.interface);
        try w.flush();
    }
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), p, io);
}

// Replaces the entry for this name, keeping the rest in order.
pub fn upsert(alloc: std.mem.Allocator, lock: Lock, entry: Lock.Entry) !Lock {
    var out: std.ArrayList(Lock.Entry) = .empty;
    var replaced = false;
    for (lock.shells) |e| {
        if (std.mem.eql(u8, e.name, entry.name)) {
            try out.append(alloc, entry);
            replaced = true;
        } else try out.append(alloc, e);
    }
    if (!replaced) try out.append(alloc, entry);
    return .{ .shells = out.items };
}

test "pinnable" {
    try std.testing.expect(pinnable("github:q-uint/moat"));
    try std.testing.expect(pinnable("github:q-uint/moat/abc123"));
    try std.testing.expect(!pinnable("git+file:///Users/q/moat"));
    try std.testing.expect(!pinnable("path:/Users/q/moat"));
    try std.testing.expect(!pinnable("/Users/q/moat"));
    try std.testing.expect(!pinnable("./moat"));
}

test "split" {
    const bare = split("zig");
    try std.testing.expect(bare.flake == null);
    try std.testing.expectEqualStrings("zig", bare.attr);

    const qualified = split("github:someone/shells#zig-gpu");
    try std.testing.expectEqualStrings("github:someone/shells", qualified.flake.?);
    try std.testing.expectEqualStrings("zig-gpu", qualified.attr);
}

test "withRev" {
    const alloc = std.testing.allocator;
    const a = try withRev(alloc, "github:q-uint/moat", "abc123");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("github:q-uint/moat/abc123", a);

    // Already pinned: appending a second ref would corrupt it.
    const b = try withRev(alloc, "github:q-uint/moat/def456", "abc123");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("github:q-uint/moat/def456", b);

    const c = try withRev(alloc, "git+ssh://git@host/repo", "abc123");
    defer alloc.free(c);
    try std.testing.expectEqualStrings("git+ssh://git@host/repo?rev=abc123", c);

    // A ref carrying a query is left alone rather than guessed at.
    const d = try withRev(alloc, "git+ssh://git@host/repo?ref=main", "abc123");
    defer alloc.free(d);
    try std.testing.expectEqualStrings("git+ssh://git@host/repo?ref=main", d);

    const e = try withRev(alloc, "github:q-uint/moat", "");
    defer alloc.free(e);
    try std.testing.expectEqualStrings("github:q-uint/moat", e);
}

test "upsert replaces in place" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var lock = Lock{ .shells = &.{
        .{ .name = "zig", .rev = "old", .out = "/nix/store/a" },
        .{ .name = "rust", .rev = "r1" },
    } };
    lock = try upsert(a, lock, .{ .name = "zig", .rev = "new", .out = "/nix/store/b" });
    try std.testing.expectEqual(@as(usize, 2), lock.shells.len);
    try std.testing.expectEqualStrings("zig", lock.shells[0].name);
    try std.testing.expectEqualStrings("new", lock.shells[0].rev);
    try std.testing.expectEqualStrings("r1", lock.shells[1].rev);

    lock = try upsert(a, lock, .{ .name = "go", .rev = "g1" });
    try std.testing.expectEqual(@as(usize, 3), lock.shells.len);
    try std.testing.expectEqualStrings("go", lock.shells[2].name);
    try std.testing.expect(lock.lookup("go") != null);
    try std.testing.expect(lock.lookup("missing") == null);
}
