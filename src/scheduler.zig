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

const max_explicit_readers: u8 = 32;

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
    allocateAdditionalReaders(queues, allocations, &remaining);

    return .{ .allocator = allocator, .allocations = allocations };
}

fn readerCeiling(queues: []const VolumeQueue, ceiling: domain.WorkerLimit) u8 {
    return switch (ceiling) {
        .explicit => |count| @intCast(@min(count, max_explicit_readers)),
        .auto => autoReaderCeiling(queues),
    };
}

fn autoReaderCeiling(queues: []const VolumeQueue) u8 {
    var active_volumes: u8 = 0;
    for (queues) |queue| {
        if (queue.pending != 0) active_volumes += 1;
    }
    if (active_volumes == 0) return 0;

    // File hashing is I/O-bound on most Windows volumes, so start above the
    // logical CPU count, but keep a hard cap. Each reader owns a 256 KiB stack
    // buffer; the cap therefore bounds memory even when RAM is under pressure.
    const cpu_count = std.Thread.getCpuCount() catch 4;
    const suggested: usize = @max(@as(usize, 4), cpu_count * 2);
    return @intCast(@min(suggested, max_explicit_readers));
}

fn allocateFirstReaders(queues: []const VolumeQueue, allocations: []ReaderAllocation, remaining: *u8) void {
    for (queues, allocations) |queue, *allocation| {
        if (remaining.* == 0) return;
        if (queue.pending == 0) continue;
        allocation.readers = 1;
        remaining.* -= 1;
    }
}

fn allocateAdditionalReaders(queues: []const VolumeQueue, allocations: []ReaderAllocation, remaining: *u8) void {
    // Add readers round-robin so an explicit worker limit is useful even when
    // all candidates are on one volume. Removable/remote volumes stay at one
    // reader to avoid seek and network contention.
    while (remaining.* != 0) {
        var allocated = false;
        for (queues, allocations) |queue, *allocation| {
            if (remaining.* == 0) break;
            if (queue.class != .fixed or allocation.readers == 0 or queue.pending <= allocation.readers) continue;
            allocation.readers += 1;
            remaining.* -= 1;
            allocated = true;
        }
        if (!allocated) break;
    }
}
