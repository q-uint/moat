const std = @import("std");

// Private libsandbox API linked via .tbd stub in lib/. The linker resolves
// symbols at build time against the stub, and the actual dylib
// (/usr/lib/libsandbox.1.dylib) is loaded by the dynamic linker at runtime.
fn linkSandbox(mod: *std.Build.Module, b: *std.Build) void {
    mod.addLibraryPath(b.path("lib"));
    mod.linkSystemLibrary("sandbox", .{});
}

// Only the top of the chain: nix-flake-c's pkg-config Requires pulls in expr,
// fetchers, store and util. Listing them as well makes each appear twice in the
// link line, and dyld refuses to load a binary with duplicate dylib entries.
const nix_lib = "nix-flake-c";

// src/nix_c.zig is generated from nix's headers and committed, so a build needs
// neither the headers nor translate-c: only the libraries to link against. Run
// `zig build bindings` after a nix upgrade, and update nix.tested_version.
fn addBindingsStep(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const step = b.step("bindings", "Regenerate src/nix_c.zig from nix's C headers");
    var code: u8 = 0;
    const cflags = b.runAllowFail(
        &.{ "pkg-config", "--cflags-only-I", "nix-flake-c", "nix-expr-c", "nix-store-c", "nix-util-c", "nix-fetchers-c" },
        &code,
        .ignore,
    ) catch {
        // Without the headers the step cannot run, but the normal build still can.
        return;
    };

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/nix_c.h"),
        .target = target,
        .optimize = optimize,
    });
    var it = std.mem.tokenizeAny(u8, cflags, " \n\r");
    while (it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-I")) translate.addIncludePath(.{ .cwd_relative = flag[2..] });
    }

    const update = b.addUpdateSourceFiles();
    update.addCopyFileToSource(translate.getOutput(), "src/nix_c.zig");
    step.dependOn(&update.step);
}

// Only the CLI evaluates and builds flakes. The wrapper runs inside the sandbox
// on every command and stays free of the nix C++ closure.
fn linkNix(mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.linkSystemLibrary(nix_lib, .{ .use_pkg_config = .force });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wrapper_mod = b.createModule(.{
        .root_source_file = b.path("src/wrapper.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSandbox(wrapper_mod, b);

    const wrapper = b.addExecutable(.{
        .name = "moat-wrapper",
        .root_module = wrapper_mod,
    });
    b.installArtifact(wrapper);

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSandbox(cli_mod, b);
    linkNix(cli_mod);
    cli_mod.addAnonymousImport("nix_c", .{ .root_source_file = b.path("src/nix_c.zig") });
    addBindingsStep(b, target, optimize);

    const cli = b.addExecutable(.{
        .name = "moat",
        .root_module = cli_mod,
    });
    b.installArtifact(cli);

    const wrapper_test_mod = b.createModule(.{
        .root_source_file = b.path("src/wrapper.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSandbox(wrapper_test_mod, b);

    const cli_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSandbox(cli_test_mod, b);

    // Tests only run from a module's root file, so every test-carrying file
    // needs an entry here: leaving one out means its tests silently never run.
    const unit_tests = [_]struct { file: []const u8, sandbox: bool = false }{
        .{ .file = "src/sandbox.zig", .sandbox = true },
        .{ .file = "src/confirm.zig", .sandbox = true },
        .{ .file = "src/config.zig" },
        .{ .file = "src/denials.zig" },
        .{ .file = "src/shell_env.zig" },
        .{ .file = "src/env.zig" },
        .{ .file = "src/lock.zig" },
    };

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = wrapper_test_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cli_test_mod })).step);
    for (unit_tests) |unit| {
        const mod = b.createModule(.{
            .root_source_file = b.path(unit.file),
            .target = target,
            .optimize = optimize,
        });
        if (unit.sandbox) linkSandbox(mod, b);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }

    const sandbox_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_sandbox.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sandbox_test_exe = b.addExecutable(.{
        .name = "test-sandbox",
        .root_module = sandbox_test_mod,
    });
    const sandbox_test_run = b.addRunArtifact(sandbox_test_exe);
    sandbox_test_run.addArtifactArg(cli);
    const sandbox_test_step = b.step("e2e-sandbox", "Run sandbox enforcement tests (requires nix)");
    sandbox_test_step.dependOn(&sandbox_test_run.step);

    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("src/test_e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    const e2e_exe = b.addExecutable(.{
        .name = "test-e2e",
        .root_module = e2e_mod,
    });
    const e2e_run = b.addRunArtifact(e2e_exe);
    e2e_run.addArtifactArg(cli);
    const e2e_step = b.step("e2e", "Run end-to-end tests");
    e2e_step.dependOn(&e2e_run.step);
}
