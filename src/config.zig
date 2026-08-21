const std = @import("std");

fn expandInto(buf: []u8, home: []const u8, p: []const u8) []const u8 {
    const rest: []const u8 = if (std.mem.eql(u8, p, "~"))
        ""
    else if (std.mem.startsWith(u8, p, "~/"))
        p[1..]
    else
        return p;
    if (home.len + rest.len > buf.len) return p;
    @memcpy(buf[0..home.len], home);
    @memcpy(buf[home.len..][0..rest.len], rest);
    return buf[0 .. home.len + rest.len];
}

// `~/x` and the shell-expanded `/Users/you/x` name the same rule.
fn samePath(home: []const u8, a: []const u8, b: []const u8) bool {
    var ba: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var bb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return std.mem.eql(u8, expandInto(&ba, home, a), expandInto(&bb, home, b));
}

// True when `a` already grants everything `b` grants for `path`, making b's
// entry for it redundant.
pub fn covers(home: []const u8, a: Config.AllowRule, b: Config.AllowRule, path: []const u8) bool {
    if (!a.matchesBin(b.bin)) return false;
    if (b.write and !a.write) return false;
    if (b.exec and !a.exec) return false;
    if (a.dirs.len != 0) {
        if (b.dirs.len == 0) return false;
        for (b.dirs) |d| {
            if (!a.matchesDir(d)) return false;
        }
    }
    for (a.paths) |p| {
        if (samePath(home, p, path)) return true;
    }
    return false;
}

test "covers" {
    const home = "/Users/test";
    const R = Config.AllowRule;
    const global = R{ .bin = "zig", .paths = &.{"~/.cache/zig"} };
    const scoped = R{ .bin = "zig", .paths = &.{"~/.cache/zig"}, .dirs = &.{"/Users/test/work"} };

    // Same flags, wider scope: the scoped rule is dead.
    try std.testing.expect(covers(home, global, scoped, "~/.cache/zig"));
    try std.testing.expect(!covers(home, scoped, global, "~/.cache/zig"));

    // The shell-expanded form is the same path.
    try std.testing.expect(covers(home, global, scoped, "/Users/test/.cache/zig"));

    // A narrower grant cannot cover a wider one.
    const scoped_w = R{ .bin = "zig", .paths = &.{"~/.cache/zig"}, .write = true, .dirs = &.{"/Users/test/work"} };
    try std.testing.expect(!covers(home, global, scoped_w, "~/.cache/zig"));
    const global_w = R{ .bin = "zig", .paths = &.{"~/.cache/zig"}, .write = true };
    try std.testing.expect(covers(home, global_w, scoped_w, "~/.cache/zig"));

    // exec is independent of write.
    const scoped_x = R{ .bin = "zig", .paths = &.{"~/.cache/zig"}, .exec = true, .dirs = &.{"/Users/test/work"} };
    try std.testing.expect(!covers(home, global_w, scoped_x, "~/.cache/zig"));

    // `*` covers a named binary, not the reverse.
    const star = R{ .bin = "*", .paths = &.{"~/.cache/zig"} };
    try std.testing.expect(covers(home, star, scoped, "~/.cache/zig"));
    try std.testing.expect(!covers(home, scoped, star, "~/.cache/zig"));

    // A different path is not covered.
    try std.testing.expect(!covers(home, global, scoped, "~/.cargo"));
}

pub const Config = struct {
    jailbreak: []const []const u8 = &.{},
    allow: []const AllowRule = &.{},
    links: []const Link = &.{},
    detect: []const DetectRule = &.{},
    // Unioned into every session, after the named or detected shells so those
    // win on PATH.
    default: []const []const u8 = &.{},
    // Binaries that show their access and ask before starting; "*" for every one.
    confirm: []const []const u8 = &.{},

    // Enforced per-binary when a wrapped binary sandboxes itself; unioned into
    // the session profile under `moat shell`, where nesting cannot widen.
    pub const AllowRule = struct {
        bin: []const u8,
        paths: []const []const u8,
        write: bool = false,
        exec: bool = false,
        // Empty means every project; otherwise only these roots (and subdirs).
        dirs: []const []const u8 = &.{},

        pub fn matchesBin(self: AllowRule, bin: []const u8) bool {
            return std.mem.eql(u8, self.bin, "*") or std.mem.eql(u8, self.bin, bin);
        }

        pub fn matchesDir(self: AllowRule, root: []const u8) bool {
            if (self.dirs.len == 0) return true;
            for (self.dirs) |d| {
                if (std.mem.startsWith(u8, root, d) and
                    (root.len == d.len or root[d.len] == '/')) return true;
            }
            return false;
        }
    };

    pub const Link = struct {
        dir: []const u8,
        shells: []const []const u8,
    };

    pub const DetectRule = struct {
        markers: []const []const u8,
        shells: []const []const u8,
    };
};

// Appends names not already present, preserving order.
pub fn appendUnique(alloc: std.mem.Allocator, out: *std.ArrayList([]const u8), names: []const []const u8) !void {
    for (names) |n| {
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, n)) break;
        } else try out.append(alloc, n);
    }
}

pub const Loaded = struct {
    config: Config,
    path: []const u8,

    pub fn lookupLink(self: *const Loaded, dir: []const u8) ?[]const []const u8 {
        for (self.config.links) |l| {
            if (std.mem.eql(u8, l.dir, dir)) return l.shells;
        }
        return null;
    }

    pub fn detectShells(self: *const Loaded, alloc: std.mem.Allocator, io: std.Io, dir_path: []const u8) !?[]const []const u8 {
        var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return null;
        defer dir.close(io);

        var shells: std.ArrayList([]const u8) = .empty;
        for (self.config.detect) |rule| {
            var all_present = true;
            for (rule.markers) |marker| {
                dir.access(io, marker, .{}) catch {
                    all_present = false;
                    break;
                };
            }
            if (all_present) try appendUnique(alloc, &shells, rule.shells);
        }
        if (shells.items.len == 0) return null;
        return shells.items;
    }
};

fn configPath(alloc: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/.config/moat/config.zon", .{home});
}

pub fn load(alloc: std.mem.Allocator, io: std.Io, home: []const u8) !Loaded {
    const path = try configPath(alloc, home);
    var read_buf: [64 * 1024]u8 = undefined;
    const raw = std.Io.Dir.cwd().readFile(io, path, &read_buf) catch |err| switch (err) {
        error.FileNotFound => return .{ .config = .{}, .path = path },
        else => return err,
    };
    const source = try alloc.dupeSentinel(u8, raw, 0);
    var diag: std.zon.parse.Diagnostics = .{};
    // Never fall back to an empty config: callers write it back, which would
    // erase every link, detect rule and allow entry in the file.
    const cfg = std.zon.parse.fromSliceAlloc(Config, alloc, source, &diag, .{
        .free_on_error = true,
    }) catch {
        std.debug.print("moat: cannot parse {s}\n", .{path});
        return error.ConfigParse;
    };
    return .{ .config = cfg, .path = path };
}

pub const ResolveResult = struct {
    shells: []const []const u8,
    source: enum { link, detect },
};

pub fn resolve(alloc: std.mem.Allocator, io: std.Io, loaded: *const Loaded, dir_path: []const u8) !?ResolveResult {
    if (loaded.lookupLink(dir_path)) |s| return .{ .shells = s, .source = .link };
    if (try loaded.detectShells(alloc, io, dir_path)) |s| return .{ .shells = s, .source = .detect };
    return null;
}

// Writes to a sibling temp file and renames, so a failure mid-write leaves the
// existing config intact rather than truncated.
pub fn saveConfig(alloc: std.mem.Allocator, io: std.Io, path: []const u8, cfg: Config) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        std.Io.Dir.cwd().createDirPath(io, path[0..sep]) catch {};
    }
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    const file = std.Io.Dir.cwd().createFile(io, tmp_path, .{}) catch |err| {
        std.debug.print("moat: cannot write config: {}\n", .{err});
        return err;
    };
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    {
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var w = file.writer(io, &buf);
        // Fields left at their default are omitted, so a rewritten config does
        // not grow `.write = false` / `.dirs = .{}` on every rule.
        try std.zon.stringify.serialize(cfg, .{ .emit_default_optional_fields = false }, &w.interface);
        try w.flush();
    }
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

// Rebuilds the config with one field replaced, so callers cannot drop the rest.
fn withLinks(cfg: Config, links: []const Config.Link) Config {
    var out = cfg;
    out.links = links;
    return out;
}

pub fn addLink(alloc: std.mem.Allocator, io: std.Io, home: []const u8, dir: []const u8, shells: []const []const u8) !void {
    const loaded = try load(alloc, io, home);
    var links: std.ArrayList(Config.Link) = .empty;
    for (loaded.config.links) |l| {
        if (!std.mem.eql(u8, l.dir, dir)) try links.append(alloc, l);
    }
    try links.append(alloc, .{ .dir = dir, .shells = shells });
    try saveConfig(alloc, io, loaded.path, withLinks(loaded.config, links.items));
}

pub fn removeLink(alloc: std.mem.Allocator, io: std.Io, home: []const u8, dir: []const u8) !void {
    const loaded = try load(alloc, io, home);
    var links: std.ArrayList(Config.Link) = .empty;
    for (loaded.config.links) |l| {
        if (!std.mem.eql(u8, l.dir, dir)) try links.append(alloc, l);
    }
    try saveConfig(alloc, io, loaded.path, withLinks(loaded.config, links.items));
}

// Allows are additive and there is no deny, so a second grant for a path can
// only ever widen it. Rules scoped by `dirs` are a different scope and are left
// alone.
pub fn removeAllow(alloc: std.mem.Allocator, io: std.Io, home: []const u8, bin: []const u8, path: []const u8) !usize {
    const loaded = try load(alloc, io, home);
    var rules: std.ArrayList(Config.AllowRule) = .empty;
    var removed: usize = 0;
    for (loaded.config.allow) |r| {
        const mergeable = r.dirs.len == 0 and std.mem.eql(u8, r.bin, bin);
        var paths: std.ArrayList([]const u8) = .empty;
        for (r.paths) |p| {
            if (mergeable and samePath(home, p, path)) {
                removed += 1;
                continue;
            }
            try paths.append(alloc, p);
        }
        if (paths.items.len == 0) continue;
        try rules.append(alloc, .{ .bin = r.bin, .paths = paths.items, .write = r.write, .exec = r.exec, .dirs = r.dirs });
    }
    if (removed == 0) return 0;

    var out = loaded.config;
    out.allow = rules.items;
    try saveConfig(alloc, io, loaded.path, out);
    return removed;
}

pub const Granted = struct { write: bool, exec: bool, config_path: []const u8 };

pub fn addAllow(alloc: std.mem.Allocator, io: std.Io, home: []const u8, bin: []const u8, path: []const u8, write: bool, exec: bool) !Granted {
    const loaded = try load(alloc, io, home);

    var want_write = write;
    var want_exec = exec;
    for (loaded.config.allow) |r| {
        if (r.dirs.len != 0 or !std.mem.eql(u8, r.bin, bin)) continue;
        for (r.paths) |p| {
            if (!samePath(home, p, path)) continue;
            want_write = want_write or r.write;
            want_exec = want_exec or r.exec;
        }
    }

    var rules: std.ArrayList(Config.AllowRule) = .empty;
    var merged = false;
    for (loaded.config.allow) |r| {
        const mergeable = r.dirs.len == 0 and std.mem.eql(u8, r.bin, bin);
        const target = mergeable and r.write == want_write and r.exec == want_exec;

        var paths: std.ArrayList([]const u8) = .empty;
        for (r.paths) |p| {
            // Dropped here and re-added to the widened rule below.
            if (mergeable and samePath(home, p, path)) continue;
            try paths.append(alloc, p);
        }
        if (target) {
            try paths.append(alloc, path);
            merged = true;
        }
        if (paths.items.len == 0) continue;
        try rules.append(alloc, .{ .bin = r.bin, .paths = paths.items, .write = r.write, .exec = r.exec, .dirs = r.dirs });
    }
    if (!merged) try rules.append(alloc, .{ .bin = bin, .paths = &.{path}, .write = want_write, .exec = want_exec });

    var out = loaded.config;
    out.allow = rules.items;
    try saveConfig(alloc, io, loaded.path, out);
    return .{ .write = want_write, .exec = want_exec, .config_path = loaded.path };
}
