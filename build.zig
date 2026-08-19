const std = @import("std");

// Private libsandbox API linked via .tbd stub in lib/. The linker resolves
// symbols at build time against the stub, and the actual dylib
// (/usr/lib/libsandbox.1.dylib) is loaded by the dynamic linker at runtime.
fn linkSandbox(mod: *std.Build.Module, b: *std.Build) void {
    mod.addLibraryPath(b.path("lib"));
    mod.linkSystemLibrary("sandbox", .{});
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

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = wrapper_test_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cli_test_mod })).step);

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
