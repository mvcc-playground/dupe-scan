const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const domain_module = b.createModule(.{
        .root_source_file = b.path("src/domain.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ports_module = b.createModule(.{
        .root_source_file = b.path("src/ports.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "domain", .module = domain_module }},
    });

    const pipeline_module = b.createModule(.{
        .root_source_file = b.path("src/pipeline.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain", .module = domain_module },
            .{ .name = "ports", .module = ports_module },
        },
    });

    const portable_module = b.createModule(.{
        .root_source_file = b.path("src/platform/portable.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain", .module = domain_module },
            .{ .name = "ports", .module = ports_module },
        },
    });

    const windows_module = b.createModule(.{
        .root_source_file = b.path("src/platform/windows.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain", .module = domain_module },
            .{ .name = "ports", .module = ports_module },
            .{ .name = "portable", .module = portable_module },
        },
    });

    const report_module = b.createModule(.{
        .root_source_file = b.path("src/report_jsonl.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain", .module = domain_module },
            .{ .name = "pipeline", .module = pipeline_module },
        },
    });

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain", .module = domain_module },
            .{ .name = "pipeline", .module = pipeline_module },
            .{ .name = "portable", .module = portable_module },
            .{ .name = "report_jsonl", .module = report_module },
            .{ .name = "windows", .module = windows_module },
        },
    });

    const executable = b.addExecutable(.{
        .name = "dupe-scan",
        .root_module = main_module,
    });
    b.installArtifact(executable);

    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/test_root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain", .module = domain_module },
            .{ .name = "pipeline", .module = pipeline_module },
            .{ .name = "portable", .module = portable_module },
            .{ .name = "report_jsonl", .module = report_module },
            .{ .name = "main", .module = main_module },
            .{ .name = "windows", .module = windows_module },
        },
    });
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run scanner tests");
    test_step.dependOn(&run_tests.step);
}
