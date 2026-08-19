const std = @import("std");
const domain = @import("domain");
const pipeline = @import("pipeline");
const ports = @import("ports");

const ConcurrentReader = struct {
    active: u8 = 0,
    maximum_active: u8 = 0,
    mutex: std.Io.Mutex = .init,

    fn fingerprint(_: *anyopaque, _: []const u8, _: u64, _: []u8) anyerror!domain.Fingerprint {
        return .{ .first = digest(1), .last = digest(1) };
    }

    fn fullHash(context: *anyopaque, _: []const u8, _: u64, _: []u8) anyerror!domain.ContentHash {
        const self: *ConcurrentReader = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(std.testing.io);
        self.active += 1;
        self.maximum_active = @max(self.maximum_active, self.active);
        self.mutex.unlock(std.testing.io);
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(25), .awake);
        self.mutex.lockUncancelable(std.testing.io);
        self.active -= 1;
        self.mutex.unlock(std.testing.io);
        return digest(9);
    }

    fn port(self: *ConcurrentReader) ports.FileReader {
        return .{ .context = @ptrCast(self), .fingerprint = fingerprint, .full_hash = fullHash };
    }
};

const ProgressProbe = struct {
    mutex: std.Io.Mutex = .init,
    sampling_total: u64 = 0,
    hashing_total: u64 = 0,
    hashing_completed: u64 = 0,

    fn onBegin(context: *anyopaque, phase: ports.ProgressPhase, total: ?u64) void {
        const self: *ProgressProbe = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        switch (phase) {
            .sampling => self.sampling_total = total orelse 0,
            .hashing => self.hashing_total = total orelse 0,
            else => {},
        }
    }

    fn onAdvance(context: *anyopaque, phase: ports.ProgressPhase, completed: u64, _: u64) void {
        const self: *ProgressProbe = @ptrCast(@alignCast(context));
        if (phase != .hashing) return;
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.hashing_completed = completed;
    }

    fn onComplete(_: *anyopaque, _: domain.Metrics) void {}

    fn observer(self: *ProgressProbe) ports.ProgressObserver {
        return .{ .context = @ptrCast(self), .begin = onBegin, .advance = onAdvance, .complete = onComplete };
    }
};

const FixedVolumeWalker = struct {
    fn walk(_: *anyopaque, _: []const u8, visitor: ports.FileVisitor) anyerror!void {
        for ([_][]const u8{ "one.bin", "two.bin", "three.bin" }) |path| {
            const owned_path = try std.testing.allocator.dupe(u8, path);
            errdefer std.testing.allocator.free(owned_path);
            try visitor.on_file(visitor.context, .{
                .absolute_path = owned_path,
                .comparison_name = owned_path,
                .size = 100,
                .modified_ns = 0,
                .volume_key = .{ .raw = 1 },
                .drive_class = .fixed,
            });
        }
    }

    fn port(self: *FixedVolumeWalker) ports.DirectoryWalker {
        return .{ .context = @ptrCast(self), .walk = walk };
    }
};

fn record(path: []const u8, name: []const u8, size: u64) domain.FileRecord {
    return .{
        .absolute_path = path,
        .comparison_name = name,
        .size = size,
        .modified_ns = 0,
        .volume_key = .{ .raw = 1 },
    };
}

fn digest(byte: u8) domain.ContentHash {
    return .{ .bytes = [_]u8{byte} ** 32 };
}

fn hashed(path: []const u8, name: []const u8, size: u64, digest_byte: u8) pipeline.HashedRecord {
    return .{
        .record = record(path, name, size),
        .digest = digest(digest_byte),
    };
}

test "size bucketing keeps only files that share an exact size" {
    const records = [_]domain.FileRecord{
        record("C:/scan/one.bin", "one.bin", 10),
        record("C:/scan/two.bin", "two.bin", 10),
        record("C:/scan/only.bin", "only.bin", 11),
    };

    var buckets = try pipeline.bucketBySize(std.testing.allocator, &records);
    defer buckets.deinit();

    try std.testing.expectEqual(@as(usize, 1), buckets.candidateBucketCount());
    try std.testing.expectEqual(@as(usize, 2), buckets.candidateFileCount());
}

test "same normalized name and size with unequal digest is a collision" {
    var grouping = try pipeline.buildGroups(std.testing.allocator, &[_]pipeline.HashedRecord{
        hashed("C:/one/report.bin", "report.bin", 4, 1),
        hashed("C:/two/report.bin", "report.bin", 4, 2),
    });
    defer grouping.deinit();

    try std.testing.expectEqual(@as(usize, 0), grouping.duplicates.len);
    try std.testing.expectEqual(@as(usize, 1), grouping.name_collisions.len);
    try std.testing.expectEqual(@as(usize, 2), grouping.name_collisions[0].members.len);
}

test "equal complete digests form one duplicate group despite different names" {
    var grouping = try pipeline.buildGroups(std.testing.allocator, &[_]pipeline.HashedRecord{
        hashed("C:/one/a.bin", "a.bin", 4, 9),
        hashed("C:/two/b.bin", "b.bin", 4, 9),
    });
    defer grouping.deinit();

    try std.testing.expectEqual(@as(usize, 1), grouping.duplicates.len);
    try std.testing.expectEqual(@as(usize, 2), grouping.duplicates[0].members.len);
}

test "sample matching requires both the first and last sample digest" {
    const full_match = domain.Fingerprint{ .first = digest(3), .last = digest(4) };
    const different_end = domain.Fingerprint{ .first = digest(3), .last = digest(5) };

    try std.testing.expect(pipeline.sampleMatches(full_match, full_match));
    try std.testing.expect(!pipeline.sampleMatches(full_match, different_end));
}

test "full hashing uses two readers for fixed-volume candidates when capped at two" {
    var walker = FixedVolumeWalker{};
    var reader = ConcurrentReader{};
    var result = try pipeline.scan(
        std.testing.allocator,
        std.testing.io,
        .{ .roots = &.{"fixture"}, .workers = .{ .explicit = 2 } },
        walker.port(),
        reader.port(),
        null,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 2), reader.maximum_active);
}

test "scan reports determinate sampling and hashing progress" {
    var walker = FixedVolumeWalker{};
    var reader = ConcurrentReader{};
    var progress = ProgressProbe{};
    var result = try pipeline.scan(
        std.testing.allocator,
        std.testing.io,
        .{ .roots = &.{"fixture"}, .workers = .{ .explicit = 1 } },
        walker.port(),
        reader.port(),
        progress.observer(),
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), progress.sampling_total);
    try std.testing.expectEqual(@as(u64, 3), progress.hashing_total);
    try std.testing.expectEqual(@as(u64, 3), progress.hashing_completed);
}
