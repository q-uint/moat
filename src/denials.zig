const std = @import("std");

pub const Denial = struct {
    proc: []const u8,
    pid: u32,
    op: []const u8,
    path: []const u8,
};

// Parses: [N duplicate report(s) for ]Sandbox: NAME(PID) deny(N) OP PATH
pub fn parseMessage(msg: []const u8) ?Denial {
    const marker = "Sandbox: ";
    const start = std.mem.indexOf(u8, msg, marker) orelse return null;
    var rest = msg[start + marker.len ..];

    const open = std.mem.indexOfScalar(u8, rest, '(') orelse return null;
    const proc = rest[0..open];
    rest = rest[open + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
    const pid = std.fmt.parseInt(u32, rest[0..close], 10) catch return null;
    rest = rest[close + 1 ..];

    const deny = " deny(";
    if (!std.mem.startsWith(u8, rest, deny)) return null;
    rest = rest[deny.len..];
    const deny_close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
    rest = rest[deny_close + 1 ..];
    if (!std.mem.startsWith(u8, rest, " ")) return null;
    rest = rest[1..];

    const sep = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const op = rest[0..sep];
    const path = std.mem.trim(u8, rest[sep + 1 ..], &std.ascii.whitespace);
    if (op.len == 0 or path.len == 0) return null;
    return .{ .proc = proc, .pid = pid, .op = op, .path = path };
}

fn isFileOp(op: []const u8) bool {
    return std.mem.startsWith(u8, op, "file-");
}

fn isWriteOp(op: []const u8) bool {
    return std.mem.startsWith(u8, op, "file-write");
}

// Collapses repeats, keying on (op, path).
pub fn dedupe(alloc: std.mem.Allocator, items: []const Denial) ![]Denial {
    var out: std.ArrayList(Denial) = .empty;
    for (items) |d| {
        for (out.items) |seen| {
            if (std.mem.eql(u8, seen.op, d.op) and std.mem.eql(u8, seen.path, d.path)) break;
        } else try out.append(alloc, d);
    }
    return out.toOwnedSlice(alloc);
}

const LogEntry = struct { eventMessage: []const u8 = "" };

// `last` is a log(1) duration such as "30s" or "5m".
pub fn collect(alloc: std.mem.Allocator, io: std.Io, last: []const u8, min_pid: u32) ![]Denial {
    const arg = try std.fmt.allocPrint(alloc, "--last={s}", .{last});
    const result = std.process.run(alloc, io, .{
        .argv = &.{ "log", "show", arg, "--style", "ndjson", "--predicate", "sender == \"Sandbox\"" },
    }) catch return error.LogUnavailable;
    if (!result.term.success()) return error.LogUnavailable;

    var found: std.ArrayList(Denial) = .empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0 or trimmed[0] != '{') continue;
        // Not deinit'd: the returned Denial borrows these strings. Pass an arena.
        const parsed = std.json.parseFromSlice(LogEntry, alloc, trimmed, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        const d = parseMessage(parsed.value.eventMessage) orelse continue;
        // Drops long-lived system daemons.
        if (d.pid < min_pid) continue;
        try found.append(alloc, d);
    }
    return dedupe(alloc, found.items);
}

pub fn report(items: []const Denial, root: []const u8) void {
    if (items.len == 0) {
        std.debug.print("moat: no denials recorded\n", .{});
        return;
    }
    std.debug.print("moat: {d} path(s) denied by the sandbox\n", .{items.len});
    for (items) |d| {
        std.debug.print("  {s: <14} {s: <22} {s}\n", .{ d.proc, d.op, d.path });
    }
    var grantable: usize = 0;
    var exec_denied = false;
    for (items) |d| {
        if (std.mem.startsWith(u8, d.op, "process-exec")) exec_denied = true;
        if (isGrantable(d, root)) grantable += 1;
    }

    if (grantable > 0) {
        std.debug.print("\nto grant, pick the ones you actually need:\n", .{});
        for (items) |d| {
            if (!isGrantable(d, root)) continue;
            const w: []const u8 = if (isWriteOp(d.op)) " --write" else "";
            std.debug.print("  moat allow {s} {s}{s}\n", .{ d.proc, d.path, w });
        }
    }

    // A grant only ever emits file-read*/file*, neither of which implies
    // process-exec.
    if (exec_denied) {
        std.debug.print(
            \\
            \\process-exec cannot be granted with `moat allow`. The binary has to sit
            \\somewhere the profile already allows exec: under $MOAT_ROOT or /nix/store.
            \\For a tool that execs out of its own cache, point MOAT_ENV_HOME inside the
            \\root, e.g. MOAT_ENV_HOME=$MOAT_ROOT/.moat/home
            \\
        , .{});
    }
}

fn isGrantable(d: Denial, root: []const u8) bool {
    if (!isFileOp(d.op)) return false;
    return !(root.len > 0 and std.mem.startsWith(u8, d.path, root));
}

test "dedupe collapses repeats but keeps distinct ops" {
    const alloc = std.testing.allocator;
    var list: std.ArrayList(Denial) = .empty;
    defer list.deinit(alloc);
    try list.append(alloc, .{ .proc = "a", .pid = 1, .op = "file-read-data", .path = "/x" });
    try list.append(alloc, .{ .proc = "b", .pid = 2, .op = "file-read-data", .path = "/x" });
    try list.append(alloc, .{ .proc = "a", .pid = 1, .op = "file-write-data", .path = "/x" });
    try list.append(alloc, .{ .proc = "a", .pid = 1, .op = "file-read-data", .path = "/y" });

    const out = try dedupe(alloc, list.items);
    defer alloc.free(out);
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("/x", out[0].path);
    try std.testing.expectEqualStrings("file-write-data", out[1].op);
    try std.testing.expectEqualStrings("/y", out[2].path);
}

test "parseMessage" {
    const d = parseMessage("Sandbox: coreutils(19437) deny(1) file-read-data /Users/quint/.ssh").?;
    try std.testing.expectEqualStrings("coreutils", d.proc);
    try std.testing.expectEqual(@as(u32, 19437), d.pid);
    try std.testing.expectEqualStrings("file-read-data", d.op);
    try std.testing.expectEqualStrings("/Users/quint/.ssh", d.path);
}

test "parseMessage strips duplicate-report prefix" {
    const d = parseMessage("3 duplicate reports for Sandbox: zig(42) deny(1) file-write-data /tmp/x").?;
    try std.testing.expectEqualStrings("zig", d.proc);
    try std.testing.expectEqual(@as(u32, 42), d.pid);
    try std.testing.expectEqualStrings("/tmp/x", d.path);

    const one = parseMessage("1 duplicate report for Sandbox: go(7) deny(1) file-read-metadata /Library").?;
    try std.testing.expectEqualStrings("go", one.proc);
}

test "parseMessage non-file operations" {
    const d = parseMessage("Sandbox: ecosystemd(1105) deny(1) mach-lookup com.apple.bird").?;
    try std.testing.expectEqualStrings("mach-lookup", d.op);
    try std.testing.expectEqualStrings("com.apple.bird", d.path);
}

test "parseMessage rejects non-denials" {
    try std.testing.expect(parseMessage("Sandbox: something else entirely") == null);
    try std.testing.expect(parseMessage("") == null);
    try std.testing.expect(parseMessage("Sandbox: bad(notanumber) deny(1) file-read-data /x") == null);
    try std.testing.expect(parseMessage("no sandbox prefix deny(1) file-read-data /x") == null);
}
