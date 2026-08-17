const std = @import("std");
const windows = @import("windows");

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
