const std = @import("std");
const domain = @import("domain");
const pipeline = @import("pipeline");

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
