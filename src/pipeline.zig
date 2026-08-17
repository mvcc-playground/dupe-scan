const std = @import("std");
const domain = @import("domain");
const ports = @import("ports");

const sample_size: u64 = 64 * 1024;
const worker_buffer_size = 256 * 1024;

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

pub const ScanResult = struct {
    allocator: std.mem.Allocator,
    records: []domain.FileRecord,
    errors: []domain.ScanError,
    grouping: Grouping,
    metrics: domain.Metrics,

    pub fn deinit(self: *ScanResult) void {
        self.grouping.deinit();
        for (self.records) |record| self.allocator.free(record.absolute_path);
        for (self.errors) |scan_error| self.allocator.free(scan_error.path);
        if (self.records.len != 0) self.allocator.free(self.records);
        if (self.errors.len != 0) self.allocator.free(self.errors);
        self.records = &.{};
        self.errors = &.{};
    }
};

pub fn scan(
    allocator: std.mem.Allocator,
    request: domain.ScanRequest,
    walker: ports.DirectoryWalker,
    reader: ports.FileReader,
) !ScanResult {
    var collector = RecordCollector.init(allocator);
    errdefer collector.deinit();

    const visitor = ports.FileVisitor{
        .context = @ptrCast(&collector),
        .on_file = RecordCollector.onFile,
        .on_error = RecordCollector.onError,
    };
    for (request.roots) |root| try walker.walk(walker.context, root, visitor);

    var buckets = try bucketBySize(allocator, collector.records.items);
    defer buckets.deinit();
    collector.metrics.size_candidates = @intCast(buckets.candidateFileCount());

    const buffer = try allocator.alloc(u8, worker_buffer_size);
    defer allocator.free(buffer);

    var sampled: std.ArrayListUnmanaged(SampledRecord) = .empty;
    defer sampled.deinit(allocator);
    for (buckets.buckets) |bucket| {
        for (bucket.indexes) |record_index| {
            const record = collector.records.items[record_index];
            const fingerprint = reader.fingerprint(reader.context, record.absolute_path, record.size, buffer) catch |err| {
                try collector.appendReadError(record.absolute_path, err);
                continue;
            };
            try sampled.append(allocator, .{ .record_index = record_index, .fingerprint = fingerprint });
        }
    }

    const full_candidates = try fullHashCandidateIndexes(allocator, collector.records.items, sampled.items);
    defer allocator.free(full_candidates);
    collector.metrics.sample_candidates = @intCast(full_candidates.len);

    var hashed: std.ArrayListUnmanaged(HashedRecord) = .empty;
    defer hashed.deinit(allocator);
    for (full_candidates) |record_index| {
        const record = collector.records.items[record_index];
        collector.metrics.full_hashes += 1;
        const digest = reader.full_hash(reader.context, record.absolute_path, record.size, buffer) catch |err| {
            try collector.appendReadError(record.absolute_path, err);
            continue;
        };
        collector.metrics.bytes_read += record.size;
        try hashed.append(allocator, .{ .record = record, .digest = digest });
    }

    var grouping = try buildGroups(allocator, hashed.items);
    errdefer grouping.deinit();
    const records = try collector.records.toOwnedSlice(allocator);
    errdefer freeRecords(allocator, records);
    const errors = try collector.errors.toOwnedSlice(allocator);
    errdefer freeErrors(allocator, errors);

    return .{
        .allocator = allocator,
        .records = records,
        .errors = errors,
        .grouping = grouping,
        .metrics = collector.metrics,
    };
}

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

const SampledRecord = struct {
    record_index: usize,
    fingerprint: domain.Fingerprint,
};

const RecordCollector = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayListUnmanaged(domain.FileRecord) = .empty,
    errors: std.ArrayListUnmanaged(domain.ScanError) = .empty,
    metrics: domain.Metrics = .{},

    fn init(allocator: std.mem.Allocator) RecordCollector {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *RecordCollector) void {
        freeRecords(self.allocator, self.records.items);
        freeErrors(self.allocator, self.errors.items);
        self.records.deinit(self.allocator);
        self.errors.deinit(self.allocator);
    }

    fn onFile(context: *anyopaque, record: domain.FileRecord) anyerror!void {
        const self: *RecordCollector = @ptrCast(@alignCast(context));
        try self.records.append(self.allocator, record);
        self.metrics.files_enumerated += 1;
        self.metrics.bytes_enumerated += record.size;
    }

    fn onError(context: *anyopaque, scan_error: domain.ScanError) anyerror!void {
        const self: *RecordCollector = @ptrCast(@alignCast(context));
        try self.errors.append(self.allocator, scan_error);
        self.metrics.recoverable_errors += 1;
        if (scan_error.kind == .skipped_reparse_point) self.metrics.skipped_entries += 1;
    }

    fn appendReadError(self: *RecordCollector, path: []const u8, source: anyerror) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const kind: domain.ScanErrorKind = if (source == error.FileChanged) .file_changed else .read_failed;
        try RecordCollector.onError(@ptrCast(self), .{ .kind = kind, .path = owned_path });
    }
};

fn fullHashCandidateIndexes(
    allocator: std.mem.Allocator,
    records: []const domain.FileRecord,
    sampled: []const SampledRecord,
) ![]usize {
    if (sampled.len < 2) return allocator.alloc(usize, 0);

    const selected = try allocator.alloc(bool, records.len);
    defer allocator.free(selected);
    @memset(selected, false);

    const ordered = try allocator.alloc(usize, sampled.len);
    defer allocator.free(ordered);
    for (ordered, 0..) |*slot, index| slot.* = index;
    std.mem.sortUnstable(usize, ordered, SampleSortContext{ .records = records, .sampled = sampled }, SampleSortContext.lessThan);

    var start: usize = 0;
    while (start < ordered.len) {
        var end = start + 1;
        while (end < ordered.len and sampleMatches(sampled[ordered[start]].fingerprint, sampled[ordered[end]].fingerprint)) : (end += 1) {}
        if (end - start >= 2) {
            for (ordered[start..end]) |sample_index| selected[sampled[sample_index].record_index] = true;
        }
        start = end;
    }

    std.mem.sortUnstable(usize, ordered, SampleNameSortContext{ .records = records, .sampled = sampled }, SampleNameSortContext.lessThan);
    start = 0;
    while (start < ordered.len) {
        var end = start + 1;
        while (end < ordered.len and sameNameAndSize(
            .{ .record = records[sampled[ordered[start]].record_index], .digest = undefined },
            .{ .record = records[sampled[ordered[end]].record_index], .digest = undefined },
        )) : (end += 1) {}
        if (end - start >= 2) {
            for (ordered[start..end]) |sample_index| selected[sampled[sample_index].record_index] = true;
        }
        start = end;
    }

    var count: usize = 0;
    for (selected) |is_selected| {
        if (is_selected) count += 1;
    }
    const indexes = try allocator.alloc(usize, count);
    var written: usize = 0;
    for (selected, 0..) |is_selected, record_index| {
        if (!is_selected) continue;
        indexes[written] = record_index;
        written += 1;
    }
    return indexes;
}

const SampleSortContext = struct {
    records: []const domain.FileRecord,
    sampled: []const SampledRecord,

    fn lessThan(self: SampleSortContext, left_index: usize, right_index: usize) bool {
        const left = self.sampled[left_index];
        const right = self.sampled[right_index];
        const first_order = std.mem.order(u8, &left.fingerprint.first.bytes, &right.fingerprint.first.bytes);
        if (first_order != .eq) return first_order == .lt;
        const last_order = std.mem.order(u8, &left.fingerprint.last.bytes, &right.fingerprint.last.bytes);
        if (last_order != .eq) return last_order == .lt;
        return std.mem.order(u8, self.records[left.record_index].absolute_path, self.records[right.record_index].absolute_path) == .lt;
    }
};

const SampleNameSortContext = struct {
    records: []const domain.FileRecord,
    sampled: []const SampledRecord,

    fn lessThan(self: SampleNameSortContext, left_index: usize, right_index: usize) bool {
        const left = self.records[self.sampled[left_index].record_index];
        const right = self.records[self.sampled[right_index].record_index];
        const name_order = std.mem.order(u8, left.comparison_name, right.comparison_name);
        if (name_order != .eq) return name_order == .lt;
        if (left.size != right.size) return left.size < right.size;
        return std.mem.order(u8, left.absolute_path, right.absolute_path) == .lt;
    }
};

fn freeRecords(allocator: std.mem.Allocator, records: []const domain.FileRecord) void {
    for (records) |record| allocator.free(record.absolute_path);
}

fn freeErrors(allocator: std.mem.Allocator, errors: []const domain.ScanError) void {
    for (errors) |scan_error| allocator.free(scan_error.path);
}
