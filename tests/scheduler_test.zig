const std = @import("std");
const domain = @import("domain");
const scheduler = @import("scheduler");

test "scheduler reserves a removable reader before a fixed-drive second reader" {
    var plan = try scheduler.plan(std.testing.allocator, &.{
        .{ .key = .{ .raw = 1 }, .class = .fixed, .pending = 50 },
        .{ .key = .{ .raw = 2 }, .class = .removable, .pending = 2 },
    }, .{ .explicit = 3 });
    defer plan.deinit();

    try std.testing.expectEqual(@as(u8, 2), plan.readerCountFor(.{ .raw = 1 }));
    try std.testing.expectEqual(@as(u8, 1), plan.readerCountFor(.{ .raw = 2 }));
    try std.testing.expectEqual(@as(u8, 3), plan.totalReaders());
}

test "scheduler never exceeds an explicit worker ceiling" {
    var plan = try scheduler.plan(std.testing.allocator, &.{
        .{ .key = .{ .raw = 1 }, .class = .fixed, .pending = 1 },
        .{ .key = .{ .raw = 2 }, .class = .remote, .pending = 1 },
        .{ .key = .{ .raw = 3 }, .class = .unknown, .pending = 1 },
    }, .{ .explicit = 2 });
    defer plan.deinit();

    try std.testing.expectEqual(@as(u8, 2), plan.totalReaders());
    try std.testing.expectEqual(@as(u8, 1), plan.readerCountFor(.{ .raw = 1 }));
    try std.testing.expectEqual(@as(u8, 1), plan.readerCountFor(.{ .raw = 2 }));
    try std.testing.expectEqual(@as(u8, 0), plan.readerCountFor(.{ .raw = 3 }));
}
