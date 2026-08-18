const std = @import("std");
const domain = @import("domain");
const windows = @import("windows");

const WalkProbe = struct {
    files: usize = 0,
    volume_key: domain.VolumeKey = .{ .raw = 0 },

    fn onFile(context: *anyopaque, record: domain.FileRecord) anyerror!void {
        const self: *WalkProbe = @ptrCast(@alignCast(context));
        self.files += 1;
        self.volume_key = record.volume_key;
        std.testing.allocator.free(record.absolute_path);
    }

    fn onError(_: *anyopaque, scan_error: domain.ScanError) anyerror!void {
        std.testing.allocator.free(scan_error.path);
        return error.UnexpectedScanError;
    }
};

test "native walker rejects reparse points before entering them" {
    try std.testing.expectEqual(
        windows.EntryKind.skip_reparse_point,
        windows.mapAttributes(windows.file_attribute_reparse_point),
    );
}

test "native Windows walker emits an enumerated file with a volume key" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "enumerated.bin", .data = "metadata only" });

    const relative = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(relative);
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative, std.testing.allocator);
    defer std.testing.allocator.free(absolute);

    var adapter = windows.Adapter.init(std.testing.allocator, std.testing.io);
    var probe = WalkProbe{};
    const visitor = @import("ports").FileVisitor{
        .context = @ptrCast(&probe),
        .on_file = WalkProbe.onFile,
        .on_error = WalkProbe.onError,
    };
    try adapter.directoryWalker().walk(adapter.directoryWalker().context, absolute, visitor);

    try std.testing.expectEqual(@as(usize, 1), probe.files);
    try std.testing.expect(probe.volume_key.raw != 0);
}

test "native Windows reader hashes a temporary file with BLAKE3" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "native.bin", .data = "native reader content" });

    const relative = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/native.bin", .{temporary.sub_path});
    defer std.testing.allocator.free(relative);
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative, std.testing.allocator);
    defer std.testing.allocator.free(absolute);

    var adapter = windows.Adapter.init(std.testing.allocator, std.testing.io);
    var buffer: [64 * 1024]u8 = undefined;
    const actual = try adapter.fileReader().full_hash(adapter.fileReader().context, absolute, "native reader content".len, &buffer);

    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("native reader content");
    var expected: [32]u8 = undefined;
    hasher.final(&expected);
    try std.testing.expect(std.mem.eql(u8, &expected, &actual.bytes));
}
