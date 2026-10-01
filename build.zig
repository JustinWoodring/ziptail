const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const app_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vaxis", .module = vaxis.module("vaxis") }},
    });
    const executable = b.addExecutable(.{
        .name = "ziptail",
        .root_module = app_module,
        .use_llvm = true,
    });
    b.installArtifact(executable);

    const run_step = b.step("run", "Run ziptail");
    const run = b.addRunArtifact(executable);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    run_step.dependOn(&run.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/dialog.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run CLI parsing tests");
    const deck_test_module = b.createModule(.{
        .root_source_file = b.path("src/deck.zig"),
        .target = target,
        .optimize = optimize,
    });
    const deck_tests = b.addTest(.{ .root_module = deck_test_module });
    const run_deck_tests = b.addRunArtifact(deck_tests);
    test_step.dependOn(&run_deck_tests.step);
    test_step.dependOn(&run_tests.step);
}
