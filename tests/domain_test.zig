const std = @import("std");
const domain = @import("domain");

test "content hash equality requires every digest byte to match" {
    const first = domain.ContentHash{ .bytes = [_]u8{0x2a} ** 32 };
    const same = domain.ContentHash{ .bytes = [_]u8{0x2a} ** 32 };
    const different = domain.ContentHash{ .bytes = [_]u8{0x2b} ** 32 };

    try std.testing.expect(first.eql(same));
    try std.testing.expect(!first.eql(different));
}

test "automatic full-file reader policy limits slow drive classes" {
    try std.testing.expectEqual(@as(u8, 2), domain.autoReaders(.fixed));
    try std.testing.expectEqual(@as(u8, 1), domain.autoReaders(.removable));
    try std.testing.expectEqual(@as(u8, 1), domain.autoReaders(.remote));
    try std.testing.expectEqual(@as(u8, 1), domain.autoReaders(.unknown));
}
