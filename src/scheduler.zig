const std = @import("std");
const domain = @import("domain");

pub const VolumeQueue = struct {
    key: domain.VolumeKey,
    class: domain.DriveClass,
    pending: u64,
};

pub const ReaderAllocation = struct {
    key: domain.VolumeKey,
    readers: u8 = 0,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    allocations: []ReaderAllocation = &.{},

    pub fn deinit(self: *Plan) void {
        if (self.allocations.len != 0) self.allocator.free(self.allocations);
        self.allocations = &.{};
    }

    pub fn readerCountFor(self: Plan, key: domain.VolumeKey) u8 {
        for (self.allocations) |allocation| {
            if (allocation.key.eql(key)) return allocation.readers;
        }
        return 0;
    }

    pub fn totalReaders(self: Plan) u8 {
        var total: u8 = 0;
        for (self.allocations) |allocation| total += allocation.readers;
        return total;
    }
};

pub fn plan(
    allocator: std.mem.Allocator,
    queues: []const VolumeQueue,
    ceiling: domain.WorkerLimit,
) !Plan {
    if (queues.len == 0) return .{ .allocator = allocator };

    const allocations = try allocator.alloc(ReaderAllocation, queues.len);
    errdefer allocator.free(allocations);
    for (queues, allocations) |queue, *allocation| allocation.* = .{ .key = queue.key };

    var remaining = readerCeiling(queues, ceiling);
    allocateFirstReaders(queues, allocations, &remaining);
    allocateFixedSecondReaders(queues, allocations, &remaining);

    return .{ .allocator = allocator, .allocations = allocations };
}

fn readerCeiling(queues: []const VolumeQueue, ceiling: domain.WorkerLimit) u8 {
    return switch (ceiling) {
        .explicit => |count| @intCast(@min(count, std.math.maxInt(u8))),
        .auto => blk: {
            var total: u16 = 0;
            for (queues) |queue| {
                if (queue.pending != 0) total += domain.autoReaders(queue.class);
            }
            break :blk @intCast(@min(total, std.math.maxInt(u8)));
        },
    };
}

fn allocateFirstReaders(queues: []const VolumeQueue, allocations: []ReaderAllocation, remaining: *u8) void {
    for (queues, allocations) |queue, *allocation| {
        if (remaining.* == 0) return;
        if (queue.pending == 0) continue;
        allocation.readers = 1;
        remaining.* -= 1;
    }
}

fn allocateFixedSecondReaders(queues: []const VolumeQueue, allocations: []ReaderAllocation, remaining: *u8) void {
    for (queues, allocations) |queue, *allocation| {
        if (remaining.* == 0) return;
        if (queue.class != .fixed or allocation.readers == 0 or queue.pending <= allocation.readers) continue;
        allocation.readers += 1;
        remaining.* -= 1;
    }
}
