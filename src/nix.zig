const std = @import("std");
const builtin = @import("builtin");
const c = @import("nix_c");

// Nix's C API is not a stable API yet, so this module is the only place that
// touches it: everything else in moat talks to the small surface below.

// The version these bindings were written against. The C API carries no ABI
// promise, so a mismatch is worth saying out loud rather than debugging later.
pub const tested_version = "2.34";

// Hand declared: see nix_c.h.
const RealisedString = opaque {};
extern fn nix_get_attr_byname(context: ?*c.nix_c_context, value: ?*c.nix_value, state: ?*c.EvalState, name: [*:0]const u8) ?*c.nix_value;
extern fn nix_get_string(context: ?*c.nix_c_context, value: ?*c.nix_value, callback: c.nix_get_string_callback, user_data: ?*anyopaque) c.nix_err;
extern fn nix_value_decref(context: ?*c.nix_c_context, value: ?*c.nix_value) c.nix_err;
extern fn nix_string_realise(context: ?*c.nix_c_context, state: ?*c.EvalState, value: ?*c.nix_value, is_ifd: bool) ?*RealisedString;
extern fn nix_realised_string_get_buffer_start(realised: ?*RealisedString) [*c]const u8;
extern fn nix_realised_string_get_buffer_size(realised: ?*RealisedString) usize;
extern fn nix_realised_string_free(realised: ?*RealisedString) void;

// Compares major.minor only: patch releases have not moved this API.
pub fn versionMatches(built_for: []const u8, running: []const u8) bool {
    var a = std.mem.splitScalar(u8, built_for, '.');
    var b = std.mem.splitScalar(u8, running, '.');
    const a_major = a.next() orelse return false;
    const b_major = b.next() orelse return false;
    if (!std.mem.eql(u8, a_major, b_major)) return false;
    const a_minor = a.next() orelse return true;
    const b_minor = b.next() orelse return false;
    return std.mem.eql(u8, a_minor, b_minor);
}

pub fn runningVersion() []const u8 {
    const v = c.nix_version_get();
    if (v == null) return "";
    return std.mem.span(v);
}

// The flake attribute set is per system, and moat is macOS only, so this is the
// only shape it can take.
pub const system = @tagName(builtin.target.cpu.arch) ++ "-darwin";

test "versionMatches" {
    try std.testing.expect(versionMatches("2.34", "2.34.8"));
    try std.testing.expect(versionMatches("2.34", "2.34"));
    try std.testing.expect(!versionMatches("2.34", "2.35.2"));
    try std.testing.expect(!versionMatches("2.34", "3.0.1"));
    try std.testing.expect(!versionMatches("2.34", ""));
}

pub const Error = error{
    NixInit,
    NixStore,
    NixEval,
    NixFlakeRef,
    NixFlakeLock,
    NixAttrMissing,
    NixRealise,
};

// Receives a string from a nix_get_string_callback.
const Collector = struct {
    alloc: std.mem.Allocator,
    value: ?[]const u8 = null,

    fn take(start: [*c]const u8, n: c_uint, user_data: ?*anyopaque) callconv(.c) void {
        const self: *Collector = @ptrCast(@alignCast(user_data orelse return));
        if (start == null) return;
        self.value = self.alloc.dupe(u8, start[0..n]) catch null;
    }
};

fn ignore(_: [*c]const u8, _: c_uint, _: ?*anyopaque) callconv(.c) void {}

pub const Nix = struct {
    alloc: std.mem.Allocator,
    ctx: *c.nix_c_context,
    store: *c.Store,
    state: *c.EvalState,
    fetch: *c.nix_fetchers_settings,
    flake: *c.nix_flake_settings,

    pub fn init(alloc: std.mem.Allocator) Error!Nix {
        const ctx = c.nix_c_context_create() orelse return Error.NixInit;
        if (c.nix_libutil_init(ctx) != c.NIX_OK) return Error.NixInit;
        // Flakes are still an experimental feature and the C API does not enable
        // them for us.
        _ = c.nix_setting_set(ctx, "experimental-features", "nix-command flakes");
        if (c.nix_libstore_init(ctx) != c.NIX_OK) return Error.NixInit;
        if (c.nix_libexpr_init(ctx) != c.NIX_OK) return Error.NixInit;

        const store = c.nix_store_open(ctx, null, null) orelse return Error.NixStore;
        const fetch = c.nix_fetchers_settings_new(ctx) orelse return Error.NixInit;
        const flake = c.nix_flake_settings_new(ctx) orelse return Error.NixInit;

        const builder = c.nix_eval_state_builder_new(ctx, store) orelse return Error.NixEval;
        defer c.nix_eval_state_builder_free(builder);
        // nix.conf first, flake settings on top.
        if (c.nix_eval_state_builder_load(ctx, builder) != c.NIX_OK) return Error.NixEval;
        if (c.nix_flake_settings_add_to_eval_state_builder(ctx, flake, builder) != c.NIX_OK) return Error.NixEval;
        const state = c.nix_eval_state_build(ctx, builder) orelse return Error.NixEval;

        return .{ .alloc = alloc, .ctx = ctx, .store = store, .state = state, .fetch = fetch, .flake = flake };
    }

    pub fn deinit(self: *Nix) void {
        c.nix_state_free(self.state);
        c.nix_flake_settings_free(self.flake);
        c.nix_fetchers_settings_free(self.fetch);
        c.nix_store_free(self.store);
        c.nix_c_context_free(self.ctx);
    }

    pub fn lastError(self: *Nix) []const u8 {
        var n: c_uint = 0;
        const msg = c.nix_err_msg(null, self.ctx, &n);
        if (msg == null) return "unknown nix error";
        return msg[0..n];
    }

    // A store path query rather than an evaluation, which is what makes the
    // lock's recorded path usable as the fast path.
    pub fn validPath(self: *Nix, path: []const u8) bool {
        const z = self.alloc.dupeSentinel(u8, path, 0) catch return false;
        defer self.alloc.free(z);
        const parsed = c.nix_store_parse_path(self.ctx, self.store, z) orelse return false;
        defer c.nix_store_path_free(parsed);
        return c.nix_store_is_valid_path(self.ctx, self.store, parsed);
    }

    // Locks the flake, honouring its own flake.lock, and hands back its output
    // attrs. `virtual` keeps the lock in memory so moat never writes a lockfile
    // into someone else's repository.
    fn outputs(self: *Nix, flake_ref: []const u8) Error!*c.nix_value {
        const parse_flags = c.nix_flake_reference_parse_flags_new(self.ctx, self.flake) orelse return Error.NixFlakeRef;
        defer c.nix_flake_reference_parse_flags_free(parse_flags);

        const z = self.alloc.dupeSentinel(u8, flake_ref, 0) catch return Error.NixFlakeRef;
        defer self.alloc.free(z);

        var ref: ?*c.nix_flake_reference = null;
        if (c.nix_flake_reference_and_fragment_from_string(
            self.ctx,
            self.fetch,
            self.flake,
            parse_flags,
            z.ptr,
            z.len,
            &ref,
            ignore,
            null,
        ) != c.NIX_OK) return Error.NixFlakeRef;
        const parsed = ref orelse return Error.NixFlakeRef;
        defer c.nix_flake_reference_free(parsed);

        const lock_flags = c.nix_flake_lock_flags_new(self.ctx, self.flake) orelse return Error.NixFlakeLock;
        defer c.nix_flake_lock_flags_free(lock_flags);
        _ = c.nix_flake_lock_flags_set_mode_virtual(self.ctx, lock_flags);

        const locked = c.nix_flake_lock(self.ctx, self.fetch, self.flake, self.state, lock_flags, parsed) orelse return Error.NixFlakeLock;
        defer c.nix_locked_flake_free(locked);

        return c.nix_locked_flake_get_output_attrs(self.ctx, self.flake, self.state, locked) orelse Error.NixFlakeLock;
    }

    fn attr(self: *Nix, value: *c.nix_value, name: []const u8) ?*c.nix_value {
        const z = self.alloc.dupeSentinel(u8, name, 0) catch return null;
        defer self.alloc.free(z);
        return nix_get_attr_byname(self.ctx, value, self.state, z);
    }

    // packages.<system>.<name>, then legacyPackages, then a bare attribute: the
    // order `nix build .#name` uses.
    fn resolveAttr(self: *Nix, root: *c.nix_value, sys: []const u8, name: []const u8) Error!*c.nix_value {
        for ([_][]const u8{ "packages", "legacyPackages" }) |set| {
            if (self.attr(root, set)) |by_set| {
                if (self.attr(by_set, sys)) |by_system| {
                    if (self.attr(by_system, name)) |found| return found;
                }
            }
        }
        return self.attr(root, name) orelse Error.NixAttrMissing;
    }

    // Evaluates and builds, returning the store path: replaces
    // `nix build <flake>#<attr> --print-out-paths`.
    pub fn build(self: *Nix, flake_ref: []const u8, name: []const u8, sys: []const u8) Error![]const u8 {
        const root = try self.outputs(flake_ref);
        defer _ = nix_value_decref(self.ctx, root);

        const target = try self.resolveAttr(root, sys, name);
        if (c.nix_value_force(self.ctx, self.state, target) != c.NIX_OK) return Error.NixEval;

        const realised = nix_string_realise(self.ctx, self.state, target, false) orelse return Error.NixRealise;
        defer nix_realised_string_free(realised);
        const start = nix_realised_string_get_buffer_start(realised);
        const size = nix_realised_string_get_buffer_size(realised);
        if (start == null or size == 0) return Error.NixRealise;
        return self.alloc.dupe(u8, start[0..size]) catch Error.NixRealise;
    }

    // Evaluation only, no realisation: answers "does this flake resolve, and
    // does it have this attribute" for `moat check`. A null name checks the
    // flake alone.
    pub fn evaluates(self: *Nix, flake_ref: []const u8, name: ?[]const u8, sys: []const u8) bool {
        const root = self.outputs(flake_ref) catch return false;
        defer _ = nix_value_decref(self.ctx, root);
        const target = name orelse return true;
        const found = self.resolveAttr(root, sys, target) catch return false;
        return c.nix_value_force(self.ctx, self.state, found) == c.NIX_OK;
    }

    // The flake C API exposes no rev accessor, so this reads one off the locked
    // flake's own attrs if they carry it, and reports null otherwise. Callers
    // treat a null rev as "this source cannot be pinned by revision".
    pub fn rev(self: *Nix, flake_ref: []const u8) ?[]const u8 {
        const root = self.outputs(flake_ref) catch return null;
        defer _ = nix_value_decref(self.ctx, root);

        const source = self.attr(root, "sourceInfo") orelse root;
        const value = self.attr(source, "rev") orelse return null;
        if (c.nix_value_force(self.ctx, self.state, value) != c.NIX_OK) return null;

        var collector = Collector{ .alloc = self.alloc };
        if (nix_get_string(self.ctx, value, Collector.take, &collector) != c.NIX_OK) return null;
        return collector.value;
    }
};
