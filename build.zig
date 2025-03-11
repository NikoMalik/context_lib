const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const lib_mod = b.addModule("context_lib", .{
        .root_source_file = b.path("context.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addStaticLibrary(.{
        .name = "context.zig",
        .root_module = lib_mod,
        .link_libc = true,
    });

    b.installArtifact(lib);

    const unit_tests_1 = b.addTest(.{
        .root_source_file = b.path("context.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    unit_tests_1.linkLibrary(lib);

    // tests running

    // ============

    const run_unit_test_1 = b.addRunArtifact(unit_tests_1);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_unit_test_1.step);
}
