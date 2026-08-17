const std = @import("std");
const main = @import("main");

test "argument parser rejects a mutation flag" {
    try std.testing.expectError(
        error.UnknownArgument,
        main.parseArgs(std.testing.allocator, &.{ "C:\\scan", "--delete" }),
    );
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
        &.{ root, "--backend", "portable" },
        &output.writer,
    );

    const text = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, text, "\"event\":\"duplicate_group\"") != null);
}
