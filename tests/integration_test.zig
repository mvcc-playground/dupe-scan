const std = @import("std");
const domain = @import("domain");
const pipeline = @import("pipeline");
const portable = @import("portable");

test "portable scan finds real duplicate bytes and same-name collisions" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    try temporary.dir.createDirPath(std.testing.io, "one");
    try temporary.dir.createDirPath(std.testing.io, "two");
    try temporary.dir.createDirPath(std.testing.io, "three");
    try temporary.dir.createDirPath(std.testing.io, "four");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "one/alpha.bin", .data = "same bytes" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "two/renamed.bin", .data = "same bytes" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "three/report.bin", .data = "old!" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "four/report.bin", .data = "new!" });

    const relative_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(relative_root);

    var adapter = portable.Adapter.init(std.testing.allocator, std.testing.io);
    var result = try pipeline.scan(
        std.testing.allocator,
        std.testing.io,
        .{ .roots = &.{relative_root}, .workers = .auto, .backend = .portable },
        adapter.directoryWalker(),
        adapter.fileReader(),
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.grouping.duplicates.len);
    try std.testing.expectEqual(@as(usize, 2), result.grouping.duplicates[0].members.len);
    try std.testing.expectEqual(@as(usize, 1), result.grouping.name_collisions.len);
    try std.testing.expectEqual(@as(usize, 2), result.grouping.name_collisions[0].members.len);
    try std.testing.expectEqual(@as(u64, 4), result.metrics.files_enumerated);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "portable scan records a missing root without aborting its other roots" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "present.bin", .data = "content" });

    const present = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(present);

    var adapter = portable.Adapter.init(std.testing.allocator, std.testing.io);
    var result = try pipeline.scan(
        std.testing.allocator,
        std.testing.io,
        .{ .roots = &.{ "does-not-exist-for-dupe-scan", present }, .workers = .auto, .backend = .portable },
        adapter.directoryWalker(),
        adapter.fileReader(),
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.metrics.files_enumerated);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expectEqual(domain.ScanErrorKind.root_not_found, result.errors[0].kind);
}
