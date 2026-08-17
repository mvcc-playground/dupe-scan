const std = @import("std");
const domain = @import("domain");

pub const SizeBucket = struct {
    size: u64,
    indexes: []usize,
};

pub const SizeBuckets = struct {
    allocator: std.mem.Allocator,
    buckets: []SizeBucket = &.{},

    pub fn deinit(self: *SizeBuckets) void {
        for (self.buckets) |bucket| self.allocator.free(bucket.indexes);
        if (self.buckets.len != 0) self.allocator.free(self.buckets);
        self.buckets = &.{};
    }

    pub fn candidateBucketCount(self: SizeBuckets) usize {
        return self.buckets.len;
    }

    pub fn candidateFileCount(self: SizeBuckets) usize {
        var total: usize = 0;
        for (self.buckets) |bucket| total += bucket.indexes.len;
        return total;
    }
};

pub const HashedRecord = struct {
    record: domain.FileRecord,
    digest: domain.ContentHash,
};

pub const DuplicateGroup = struct {
    digest: domain.ContentHash,
    members: []HashedRecord,
};

pub const NameCollisionGroup = struct {
    comparison_name: []const u8,
    size: u64,
    members: []HashedRecord,
};

pub const Grouping = struct {
    allocator: std.mem.Allocator,
    duplicates: []DuplicateGroup = &.{},
    name_collisions: []NameCollisionGroup = &.{},

    pub fn deinit(self: *Grouping) void {
        for (self.duplicates) |group| self.allocator.free(group.members);
        for (self.name_collisions) |group| self.allocator.free(group.members);
        if (self.duplicates.len != 0) self.allocator.free(self.duplicates);
        if (self.name_collisions.len != 0) self.allocator.free(self.name_collisions);
        self.duplicates = &.{};
        self.name_collisions = &.{};
    }
};

pub fn bucketBySize(allocator: std.mem.Allocator, records: []const domain.FileRecord) !SizeBuckets {
    if (records.len < 2) return .{ .allocator = allocator };

    const sorted_indexes = try allocator.alloc(usize, records.len);
    defer allocator.free(sorted_indexes);
    for (sorted_indexes, 0..) |*slot, index| slot.* = index;
    std.mem.sortUnstable(usize, sorted_indexes, records, sizeIndexLessThan);

    var bucket_count: usize = 0;
    var start: usize = 0;
    while (start < sorted_indexes.len) {
        var end = start + 1;
        while (end < sorted_indexes.len and records[sorted_indexes[end]].size == records[sorted_indexes[start]].size) : (end += 1) {}
        if (end - start >= 2) bucket_count += 1;
        start = end;
    }
    if (bucket_count == 0) return .{ .allocator = allocator };

    const buckets = try allocator.alloc(SizeBucket, bucket_count);
    var bucket_index: usize = 0;
    start = 0;
    while (start < sorted_indexes.len) {
        var end = start + 1;
        while (end < sorted_indexes.len and records[sorted_indexes[end]].size == records[sorted_indexes[start]].size) : (end += 1) {}
        if (end - start >= 2) {
            const member_indexes = try allocator.alloc(usize, end - start);
            errdefer allocator.free(member_indexes);
            for (sorted_indexes[start..end], 0..) |member, destination| member_indexes[destination] = member;
            buckets[bucket_index] = .{
                .size = records[sorted_indexes[start]].size,
                .indexes = member_indexes,
            };
            bucket_index += 1;
        }
        start = end;
    }

    return .{ .allocator = allocator, .buckets = buckets };
}

pub fn sampleMatches(left: domain.Fingerprint, right: domain.Fingerprint) bool {
    return left.first.eql(right.first) and left.last.eql(right.last);
}

pub fn buildGroups(allocator: std.mem.Allocator, hashed: []const HashedRecord) !Grouping {
    if (hashed.len < 2) return .{ .allocator = allocator };

    const digest_order = try sortedIndexes(allocator, hashed, digestIndexLessThan);
    defer allocator.free(digest_order);
    const duplicate_group_count = countDigestGroups(hashed, digest_order);
    const duplicates = try allocateDuplicateGroups(allocator, hashed, digest_order, duplicate_group_count);
    errdefer freeDuplicateGroups(allocator, duplicates);

    const name_order = try sortedIndexes(allocator, hashed, nameIndexLessThan);
    defer allocator.free(name_order);
    const collision_group_count = countCollisionGroups(hashed, name_order);
    const name_collisions = try allocateCollisionGroups(allocator, hashed, name_order, collision_group_count);

    return .{
        .allocator = allocator,
        .duplicates = duplicates,
        .name_collisions = name_collisions,
    };
}

fn sortedIndexes(
    allocator: std.mem.Allocator,
    hashed: []const HashedRecord,
    comptime less_than: fn ([]const HashedRecord, usize, usize) bool,
) ![]usize {
    const indexes = try allocator.alloc(usize, hashed.len);
    for (indexes, 0..) |*slot, index| slot.* = index;
    std.mem.sortUnstable(usize, indexes, hashed, less_than);
    return indexes;
}

fn countDigestGroups(hashed: []const HashedRecord, indexes: []const usize) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (start < indexes.len) {
        var end = start + 1;
        while (end < indexes.len and hashed[indexes[start]].digest.eql(hashed[indexes[end]].digest)) : (end += 1) {}
        if (end - start >= 2) count += 1;
        start = end;
    }
    return count;
}

fn allocateDuplicateGroups(
    allocator: std.mem.Allocator,
    hashed: []const HashedRecord,
    indexes: []const usize,
    group_count: usize,
) ![]DuplicateGroup {
    if (group_count == 0) return &.{};

    const groups = try allocator.alloc(DuplicateGroup, group_count);
    var written: usize = 0;
    errdefer {
        freeDuplicateGroups(allocator, groups[0..written]);
        allocator.free(groups);
    }

    var start: usize = 0;
    while (start < indexes.len) {
        var end = start + 1;
        while (end < indexes.len and hashed[indexes[start]].digest.eql(hashed[indexes[end]].digest)) : (end += 1) {}
        if (end - start >= 2) {
            groups[written] = .{
                .digest = hashed[indexes[start]].digest,
                .members = try duplicateMembers(allocator, hashed, indexes[start..end]),
            };
            written += 1;
        }
        start = end;
    }
    return groups;
}

fn countCollisionGroups(hashed: []const HashedRecord, indexes: []const usize) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (start < indexes.len) {
        var end = start + 1;
        while (end < indexes.len and sameNameAndSize(hashed[indexes[start]], hashed[indexes[end]])) : (end += 1) {}
        if (end - start >= 2 and hasDifferentDigest(hashed, indexes[start..end])) count += 1;
        start = end;
    }
    return count;
}

fn allocateCollisionGroups(
    allocator: std.mem.Allocator,
    hashed: []const HashedRecord,
    indexes: []const usize,
    group_count: usize,
) ![]NameCollisionGroup {
    if (group_count == 0) return &.{};

    const groups = try allocator.alloc(NameCollisionGroup, group_count);
    var written: usize = 0;
    errdefer {
        freeCollisionGroups(allocator, groups[0..written]);
        allocator.free(groups);
    }

    var start: usize = 0;
    while (start < indexes.len) {
        var end = start + 1;
        while (end < indexes.len and sameNameAndSize(hashed[indexes[start]], hashed[indexes[end]])) : (end += 1) {}
        if (end - start >= 2 and hasDifferentDigest(hashed, indexes[start..end])) {
            const first = hashed[indexes[start]];
            groups[written] = .{
                .comparison_name = first.record.comparison_name,
                .size = first.record.size,
                .members = try duplicateMembers(allocator, hashed, indexes[start..end]),
            };
            written += 1;
        }
        start = end;
    }
    return groups;
}

fn duplicateMembers(allocator: std.mem.Allocator, hashed: []const HashedRecord, indexes: []const usize) ![]HashedRecord {
    const members = try allocator.alloc(HashedRecord, indexes.len);
    for (indexes, 0..) |index, destination| members[destination] = hashed[index];
    return members;
}

fn freeDuplicateGroups(allocator: std.mem.Allocator, groups: []const DuplicateGroup) void {
    for (groups) |group| allocator.free(group.members);
}

fn freeCollisionGroups(allocator: std.mem.Allocator, groups: []const NameCollisionGroup) void {
    for (groups) |group| allocator.free(group.members);
}

fn sizeIndexLessThan(records: []const domain.FileRecord, left_index: usize, right_index: usize) bool {
    const left = records[left_index];
    const right = records[right_index];
    if (left.size != right.size) return left.size < right.size;
    return std.mem.order(u8, left.absolute_path, right.absolute_path) == .lt;
}

fn digestIndexLessThan(hashed: []const HashedRecord, left_index: usize, right_index: usize) bool {
    const left = hashed[left_index];
    const right = hashed[right_index];
    const digest_order = std.mem.order(u8, &left.digest.bytes, &right.digest.bytes);
    if (digest_order != .eq) return digest_order == .lt;
    return std.mem.order(u8, left.record.absolute_path, right.record.absolute_path) == .lt;
}

fn nameIndexLessThan(hashed: []const HashedRecord, left_index: usize, right_index: usize) bool {
    const left = hashed[left_index];
    const right = hashed[right_index];
    const name_order = std.mem.order(u8, left.record.comparison_name, right.record.comparison_name);
    if (name_order != .eq) return name_order == .lt;
    if (left.record.size != right.record.size) return left.record.size < right.record.size;
    return digestIndexLessThan(hashed, left_index, right_index);
}

fn sameNameAndSize(left: HashedRecord, right: HashedRecord) bool {
    return left.record.size == right.record.size and
        std.mem.eql(u8, left.record.comparison_name, right.record.comparison_name);
}

fn hasDifferentDigest(hashed: []const HashedRecord, indexes: []const usize) bool {
    const first = hashed[indexes[0]].digest;
    for (indexes[1..]) |index| {
        if (!first.eql(hashed[index].digest)) return true;
    }
    return false;
}
