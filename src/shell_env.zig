const std = @import("std");

pub const Pair = struct { key: []const u8, value: []const u8 };

// A shell definition cannot know the project root, so it writes $MOAT_ROOT and
// the wrapper substitutes the real one.
pub fn expand(alloc: std.mem.Allocator, value: []const u8, root: []const u8) ![]const u8 {
    const braced = try replaceAll(alloc, value, "${MOAT_ROOT}", root);
    defer alloc.free(braced);
    return replaceAll(alloc, braced, "$MOAT_ROOT", root);
}

fn replaceAll(alloc: std.mem.Allocator, input: []const u8, needle: []const u8, with: []const u8) ![]u8 {
    const size = std.mem.replacementSize(u8, input, needle, with);
    const buf = try alloc.alloc(u8, size);
    _ = std.mem.replace(u8, input, needle, with, buf);
    return buf;
}

// KEY=VALUE per line; blank lines and # comments are skipped, as is a line with
// no '=' or an empty key.
pub fn parse(alloc: std.mem.Allocator, content: []const u8, root: []const u8) ![]Pair {
    var out: std.ArrayList(Pair) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], &std.ascii.whitespace);
        if (key.len == 0) continue;
        try out.append(alloc, .{
            .key = try alloc.dupe(u8, key),
            .value = try expand(alloc, line[eq + 1 ..], root),
        });
    }
    return out.toOwnedSlice(alloc);
}

test "expand" {
    const alloc = std.testing.allocator;
    const a = try expand(alloc, "$MOAT_ROOT/.moat/home", "/w");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("/w/.moat/home", a);

    const b = try expand(alloc, "${MOAT_ROOT}/x:${MOAT_ROOT}/y", "/w");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("/w/x:/w/y", b);

    const c = try expand(alloc, "no vars here", "/w");
    defer alloc.free(c);
    try std.testing.expectEqualStrings("no vars here", c);
}

test "parse" {
    const alloc = std.testing.allocator;
    const content =
        \\# a comment
        \\HOME=$MOAT_ROOT/.moat/home
        \\
        \\CLAUDE_CODE_TMPDIR=$MOAT_ROOT/.moat/tmp
        \\not a pair
        \\=novalue
        \\EMPTY=
    ;
    const pairs = try parse(alloc, content, "/w");
    defer {
        for (pairs) |p| {
            alloc.free(p.key);
            alloc.free(p.value);
        }
        alloc.free(pairs);
    }
    try std.testing.expectEqual(@as(usize, 3), pairs.len);
    try std.testing.expectEqualStrings("HOME", pairs[0].key);
    try std.testing.expectEqualStrings("/w/.moat/home", pairs[0].value);
    try std.testing.expectEqualStrings("CLAUDE_CODE_TMPDIR", pairs[1].key);
    try std.testing.expectEqualStrings("/w/.moat/tmp", pairs[1].value);
    // An explicit empty value is a real setting, not a malformed line.
    try std.testing.expectEqualStrings("EMPTY", pairs[2].key);
    try std.testing.expectEqualStrings("", pairs[2].value);
}
