const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const domain_module = b.createModule(.{
        .root_source_file = b.path("src/domain.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/test_root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "domain", .module = domain_module }},
    });
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run scanner tests");
    test_step.dependOn(&run_tests.step);
}
