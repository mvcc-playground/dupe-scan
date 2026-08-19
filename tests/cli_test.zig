const std = @import("std");
const domain = @import("domain");
const main = @import("main");

test "argument parser rejects a mutation flag" {
    try std.testing.expectError(
        error.UnknownArgument,
        main.parseArgs(std.testing.allocator, &.{ "C:\\scan", "--delete" }),
    );
}

test "progress parser accepts known modes and rejects an invalid value" {
    try std.testing.expectEqual(domain.ProgressMode.always, try main.parseProgressMode("always"));
    try std.testing.expectEqual(domain.ProgressMode.never, try main.parseProgressMode("never"));
    try std.testing.expectError(error.InvalidProgressMode, main.parseProgressMode("loud"));
}

test "argument parser rejects a duplicate progress option" {
    try std.testing.expectError(
        error.DuplicateOption,
        main.parseArgs(std.testing.allocator, &.{ "C:\\scan", "--progress", "always", "--progress", "never" }),
    );
}

test "existing report destination is never truncated" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "report.jsonl", .data = "preserve me" });

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/report.jsonl", .{temporary.sub_path});
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.PathAlreadyExists, main.createExclusiveReport(std.testing.io, path));
    const contents = try temporary.dir.readFileAlloc(std.testing.io, "report.jsonl", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("preserve me", contents);
}

test "CLI execution writes duplicate JSONL to its supplied writer" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "left");
    try temporary.dir.createDirPath(std.testing.io, "right");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "left/first.bin", .data = "same" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "right/second.bin", .data = "same" });

    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(root);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try main.runWithWriter(
        std.testing.allocator,
        std.testing.io,
        &.{ root, "--backend", "auto" },
        &output.writer,
    );

    const text = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, text, "\"event\":\"duplicate_group\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"backend\":\"win32\"") != null);
}
