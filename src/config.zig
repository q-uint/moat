const std = @import("std");

pub const Config = struct {
    jailbreak: []const []const u8 = &.{},
    allow: []const AllowRule = &.{},
    links: []const Link = &.{},
    detect: []const DetectRule = &.{},

    // Enforced per-binary when a wrapped binary sandboxes itself; unioned into
    // the session profile under `moat shell`, where nesting cannot widen.
    pub const AllowRule = struct {
        bin: []const u8,
        paths: []const []const u8,
        write: bool = false,
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

pub fn configPath(alloc: std.mem.Allocator, home: []const u8) ![]const u8 {
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

pub fn readOverride(alloc: std.mem.Allocator, io: std.Io, dir_path: []const u8) !?[]const []const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return null;
    defer dir.close(io);
    var buf: [4096]u8 = undefined;
    // An unreadable .moat-shell is reported; only an absent one is "no override".
    const content = dir.readFile(io, ".moat-shell", &buf) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            std.debug.print("moat: cannot read {s}/.moat-shell: {s}\n", .{ dir_path, @errorName(err) });
            return err;
        },
    };
    var shells: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len > 0) try shells.append(alloc, try alloc.dupe(u8, trimmed));
    }
    if (shells.items.len == 0) return null;
    return shells.items;
}

pub const ResolveResult = struct {
    shells: []const []const u8,
    source: enum { override, link, detect },
};

pub fn resolve(alloc: std.mem.Allocator, io: std.Io, loaded: *const Loaded, dir_path: []const u8) !?ResolveResult {
    if (try readOverride(alloc, io, dir_path)) |s| return .{ .shells = s, .source = .override };
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
        try std.zon.stringify.serialize(cfg, .{}, &w.interface);
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

pub fn addAllow(alloc: std.mem.Allocator, io: std.Io, home: []const u8, bin: []const u8, path: []const u8, write: bool) !void {
    const loaded = try load(alloc, io, home);
    var rules: std.ArrayList(Config.AllowRule) = .empty;
    var merged = false;
    for (loaded.config.allow) |r| {
        if (std.mem.eql(u8, r.bin, bin) and r.write == write) {
            var paths: std.ArrayList([]const u8) = .empty;
            try paths.appendSlice(alloc, r.paths);
            for (r.paths) |p| {
                if (std.mem.eql(u8, p, path)) return; // already granted
            }
            try paths.append(alloc, path);
            try rules.append(alloc, .{ .bin = bin, .paths = paths.items, .write = write });
            merged = true;
        } else try rules.append(alloc, r);
    }
    if (!merged) try rules.append(alloc, .{ .bin = bin, .paths = &.{path}, .write = write });

    var out = loaded.config;
    out.allow = rules.items;
    try saveConfig(alloc, io, loaded.path, out);
}
