const std = @import("std");
const domain = @import("domain");
const ports = @import("ports");
const scheduler = @import("scheduler");

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
    worker_plan: []domain.VolumeReaderPlan,

    pub fn deinit(self: *ScanResult) void {
        self.grouping.deinit();
        for (self.records) |record| self.allocator.free(record.absolute_path);
        for (self.errors) |scan_error| self.allocator.free(scan_error.path);
        if (self.records.len != 0) self.allocator.free(self.records);
        if (self.errors.len != 0) self.allocator.free(self.errors);
        if (self.worker_plan.len != 0) self.allocator.free(self.worker_plan);
        self.records = &.{};
        self.errors = &.{};
        self.worker_plan = &.{};
    }
};

pub fn scan(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: domain.ScanRequest,
    walker: ports.DirectoryWalker,
    reader: ports.FileReader,
    progress: ?ports.ProgressObserver,
) !ScanResult {
    const started = std.Io.Timestamp.now(io, .awake);
    var collector = RecordCollector.init(allocator, progress);
    errdefer collector.deinit();

    beginProgress(progress, .enumerating, null);

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
    beginProgress(progress, .sampling, collector.metrics.size_candidates);
    var samples_completed: u64 = 0;
    for (buckets.buckets) |bucket| {
        for (bucket.indexes) |record_index| {
            const record = collector.records.items[record_index];
            const fingerprint = reader.fingerprint(reader.context, record.absolute_path, record.size, buffer) catch |err| {
                try collector.appendReadError(record.absolute_path, err);
                samples_completed += 1;
                advanceProgress(progress, .sampling, samples_completed, collector.metrics.size_candidates);
                continue;
            };
            try sampled.append(allocator, .{ .record_index = record_index, .fingerprint = fingerprint });
            samples_completed += 1;
            advanceProgress(progress, .sampling, samples_completed, collector.metrics.size_candidates);
        }
    }

    const full_candidates = try fullHashCandidateIndexes(allocator, collector.records.items, sampled.items);
    defer allocator.free(full_candidates);
    collector.metrics.sample_candidates = @intCast(full_candidates.len);

    collector.metrics.full_hashes = @intCast(full_candidates.len);
    beginProgress(progress, .hashing, collector.metrics.full_hashes);
    var batch = try hashCandidates(allocator, io, request.workers, collector.records.items, full_candidates, reader, progress);
    defer batch.deinit(allocator);

    var hashed: std.ArrayListUnmanaged(HashedRecord) = .empty;
    defer hashed.deinit(allocator);
    for (batch.outcomes, 0..) |outcome, position| {
        const record = collector.records.items[full_candidates[position]];
        switch (outcome.?) {
            .digest => |digest| {
                collector.metrics.bytes_read += record.size;
                try hashed.append(allocator, .{ .record = record, .digest = digest });
            },
            .failed => |err| try collector.appendReadError(record.absolute_path, err),
        }
    }

    beginProgress(progress, .grouping, null);
    var grouping = try buildGroups(allocator, hashed.items);
    errdefer grouping.deinit();
    const worker_plan = batch.takeWorkerPlan();
    errdefer if (worker_plan.len != 0) allocator.free(worker_plan);
    const records = try collector.records.toOwnedSlice(allocator);
    errdefer freeRecords(allocator, records);
    const errors = try collector.errors.toOwnedSlice(allocator);
    errdefer freeErrors(allocator, errors);
    const elapsed = started.untilNow(io, .awake).toNanoseconds();
    collector.metrics.elapsed_ns = @intCast(@max(elapsed, 0));
    completeProgress(progress, collector.metrics);

    return .{
        .allocator = allocator,
        .records = records,
        .errors = errors,
        .grouping = grouping,
        .metrics = collector.metrics,
        .worker_plan = worker_plan,
    };
}

/// Incremental variant used by the executable. Enumeration, size indexing and
/// fingerprinting overlap through a bounded std.Io queue. The final hash and
/// grouping stages intentionally retain the batch implementation until their
/// deterministic output contract is replaced by a streaming reducer.
pub fn scanIncremental(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: domain.ScanRequest,
    walker: ports.DirectoryWalker,
    reader: ports.FileReader,
    progress: ?ports.ProgressObserver,
) !ScanResult {
    const started = std.Io.Timestamp.now(io, .awake);
    var collector = RecordCollector.init(allocator, progress);
    errdefer collector.deinit();
    beginProgress(progress, .enumerating, null);

    var queue_buffer: [256]StreamItem = undefined;
    var queue = std.Io.Queue(StreamItem).init(&queue_buffer);
    var group: std.Io.Group = .init;
    var producer = StreamProducer{ .io = io, .queue = &queue, .walker = walker, .request = request };
    group.concurrent(io, StreamProducer.run, .{&producer}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return scan(allocator, io, request, walker, reader, progress),
    };

    var sampled: std.ArrayListUnmanaged(SampledRecord) = .empty;
    defer sampled.deinit(allocator);
    var size_index = std.AutoHashMap(u64, std.ArrayListUnmanaged(usize)).init(allocator);
    defer {
        var values = size_index.valueIterator();
        while (values.next()) |list| list.deinit(allocator);
        size_index.deinit();
    }
    const buffer = try allocator.alloc(u8, worker_buffer_size);
    defer allocator.free(buffer);
    var sample_count: u64 = 0;

    while (queue.getOne(io)) |item| {
        switch (item) {
            .file => |record| {
                try collector.records.append(allocator, record);
                collector.metrics.files_enumerated += 1;
                collector.metrics.bytes_enumerated += record.size;
                advanceProgress(progress, .enumerating, collector.metrics.files_enumerated, 0);
                const entry = try size_index.getOrPut(record.size);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(allocator, collector.records.items.len - 1);
                const indexes = entry.value_ptr.items;
                if (indexes.len >= 2) {
                    const start = if (indexes.len == 2) indexes.len - 2 else indexes.len - 1;
                    for (indexes[start..]) |record_index| {
                        const candidate = collector.records.items[record_index];
                        const fingerprint = reader.fingerprint(reader.context, candidate.absolute_path, candidate.size, buffer) catch |err| {
                            try collector.appendReadError(candidate.absolute_path, err);
                            continue;
                        };
                        try sampled.append(allocator, .{ .record_index = record_index, .fingerprint = fingerprint });
                        sample_count += 1;
                    }
                }
            },
            .scan_error => |scan_error| {
                try collector.errors.append(allocator, scan_error);
                collector.metrics.recoverable_errors += 1;
            },
        }
    } else |err| switch (err) {
        error.Closed => {},
        else => return err,
    }
    try group.await(io);
    collector.metrics.size_candidates = sample_count;
    beginProgress(progress, .sampling, sample_count);
    advanceProgress(progress, .sampling, sample_count, sample_count);

    const full_candidates = try fullHashCandidateIndexes(allocator, collector.records.items, sampled.items);
    defer allocator.free(full_candidates);
    collector.metrics.sample_candidates = @intCast(full_candidates.len);
    collector.metrics.full_hashes = @intCast(full_candidates.len);
    beginProgress(progress, .hashing, collector.metrics.full_hashes);
    var batch = try hashCandidates(allocator, io, request.workers, collector.records.items, full_candidates, reader, progress);
    defer batch.deinit(allocator);
    var hashed: std.ArrayListUnmanaged(HashedRecord) = .empty;
    defer hashed.deinit(allocator);
    for (batch.outcomes, 0..) |outcome, position| {
        const record = collector.records.items[full_candidates[position]];
        switch (outcome.?) {
            .digest => |digest| {
                collector.metrics.bytes_read += record.size;
                try hashed.append(allocator, .{ .record = record, .digest = digest });
            },
            .failed => |err| try collector.appendReadError(record.absolute_path, err),
        }
    }
    beginProgress(progress, .grouping, null);
    var grouping = try buildGroups(allocator, hashed.items);
    errdefer grouping.deinit();
    const worker_plan = batch.takeWorkerPlan();
    errdefer if (worker_plan.len != 0) allocator.free(worker_plan);
    const records = try collector.records.toOwnedSlice(allocator);
    errdefer freeRecords(allocator, records);
    const errors = try collector.errors.toOwnedSlice(allocator);
    errdefer freeErrors(allocator, errors);
    const elapsed = started.untilNow(io, .awake).toNanoseconds();
    collector.metrics.elapsed_ns = @intCast(@max(elapsed, 0));
    completeProgress(progress, collector.metrics);
    return .{ .allocator = allocator, .records = records, .errors = errors, .grouping = grouping, .metrics = collector.metrics, .worker_plan = worker_plan };
}

const StreamItem = union(enum) { file: domain.FileRecord, scan_error: domain.ScanError };

const StreamProducer = struct {
    io: std.Io,
    queue: *std.Io.Queue(StreamItem),
    walker: ports.DirectoryWalker,
    request: domain.ScanRequest,

    fn run(self: *@This()) std.Io.Cancelable!void {
        const visitor = ports.FileVisitor{ .context = @ptrCast(self), .on_file = onFile, .on_error = onError };
        for (self.request.roots) |root| self.walker.walk(self.walker.context, root, visitor) catch {};
        self.queue.close(self.io);
    }

    fn onFile(context: *anyopaque, record: domain.FileRecord) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.queue.putOne(self.io, .{ .file = record });
    }

    fn onError(context: *anyopaque, scan_error: domain.ScanError) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.queue.putOne(self.io, .{ .scan_error = scan_error });
    }
};

const HashOutcome = union(enum) {
    digest: domain.ContentHash,
    failed: anyerror,
};

const HashBatch = struct {
    outcomes: []?HashOutcome,
    worker_plan: []domain.VolumeReaderPlan = &.{},

    fn deinit(self: *HashBatch, allocator: std.mem.Allocator) void {
        allocator.free(self.outcomes);
        if (self.worker_plan.len != 0) allocator.free(self.worker_plan);
        self.outcomes = &.{};
        self.worker_plan = &.{};
    }

    fn takeWorkerPlan(self: *HashBatch) []domain.VolumeReaderPlan {
        const worker_plan = self.worker_plan;
        self.worker_plan = &.{};
        return worker_plan;
    }
};

const VolumeJobs = struct {
    key: domain.VolumeKey,
    class: domain.DriveClass,
    positions: std.ArrayListUnmanaged(usize) = .empty,
    next_position: usize = 0,
    mutex: std.Io.Mutex = .init,

    fn deinit(self: *VolumeJobs, allocator: std.mem.Allocator) void {
        self.positions.deinit(allocator);
    }
};

const HashState = struct {
    io: std.Io,
    reader: ports.FileReader,
    records: []const domain.FileRecord,
    candidate_indexes: []const usize,
    jobs: []VolumeJobs,
    outcomes: []?HashOutcome,
    progress: ?ports.ProgressObserver,
    completed: u64 = 0,
    progress_mutex: std.Io.Mutex = .init,

    fn takePosition(self: *HashState, volume_index: usize) ?usize {
        const job = &self.jobs[volume_index];
        job.mutex.lockUncancelable(self.io);
        defer job.mutex.unlock(self.io);
        if (job.next_position == job.positions.items.len) return null;
        const position = job.positions.items[job.next_position];
        job.next_position += 1;
        return position;
    }

    fn reportCompleted(self: *HashState) void {
        self.progress_mutex.lockUncancelable(self.io);
        self.completed += 1;
        const completed = self.completed;
        self.progress_mutex.unlock(self.io);
        advanceProgress(self.progress, .hashing, completed, @intCast(self.outcomes.len));
    }
};

const HashWorker = struct {
    state: *HashState,
    volume_index: usize,

    fn run(self: *HashWorker) void {
        var buffer: [worker_buffer_size]u8 = undefined;
        while (self.state.takePosition(self.volume_index)) |position| {
            const record = self.state.records[self.state.candidate_indexes[position]];
            const outcome: HashOutcome = blk: {
                const digest = self.state.reader.full_hash(
                    self.state.reader.context,
                    record.absolute_path,
                    record.size,
                    &buffer,
                ) catch |err| break :blk .{ .failed = err };
                break :blk .{ .digest = digest };
            };
            self.state.outcomes[position] = outcome;
            self.state.reportCompleted();
        }
    }
};

fn hashCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    workers: domain.WorkerLimit,
    records: []const domain.FileRecord,
    candidate_indexes: []const usize,
    reader: ports.FileReader,
    progress: ?ports.ProgressObserver,
) !HashBatch {
    const outcomes = try allocator.alloc(?HashOutcome, candidate_indexes.len);
    errdefer allocator.free(outcomes);
    @memset(outcomes, null);
    if (candidate_indexes.len == 0) return .{ .outcomes = outcomes };

    var jobs = try buildVolumeJobs(allocator, records, candidate_indexes);
    defer deinitVolumeJobs(allocator, &jobs);

    const queues = try allocator.alloc(scheduler.VolumeQueue, jobs.items.len);
    defer allocator.free(queues);
    for (jobs.items, queues) |job, *queue| {
        queue.* = .{ .key = job.key, .class = job.class, .pending = job.positions.items.len };
    }

    var worker_plan = try scheduler.plan(allocator, queues, workers);
    defer worker_plan.deinit();
    const worker_count = worker_plan.totalReaders();
    if (worker_count == 0) return error.InvalidWorkerCount;
    const reported_plan = try allocator.alloc(domain.VolumeReaderPlan, jobs.items.len);
    errdefer allocator.free(reported_plan);
    for (jobs.items, reported_plan) |job, *entry| {
        entry.* = .{
            .key = job.key,
            .drive_class = job.class,
            .pending_jobs = job.positions.items.len,
            .readers = worker_plan.readerCountFor(job.key),
        };
    }

    var state = HashState{
        .io = io,
        .reader = reader,
        .records = records,
        .candidate_indexes = candidate_indexes,
        .jobs = jobs.items,
        .outcomes = outcomes,
        .progress = progress,
    };
    const worker_infos = try allocator.alloc(HashWorker, worker_count);
    defer allocator.free(worker_infos);
    var threads: std.ArrayListUnmanaged(std.Thread) = .empty;
    defer threads.deinit(allocator);
    errdefer for (threads.items) |thread| thread.join();

    var written: usize = 0;
    for (jobs.items, 0..) |job, volume_index| {
        var count = worker_plan.readerCountFor(job.key);
        while (count != 0) : (count -= 1) {
            worker_infos[written] = .{ .state = &state, .volume_index = volume_index };
            const thread = try std.Thread.spawn(.{}, HashWorker.run, .{&worker_infos[written]});
            threads.append(allocator, thread) catch |err| {
                thread.join();
                return err;
            };
            written += 1;
        }
    }
    for (threads.items) |thread| thread.join();

    return .{ .outcomes = outcomes, .worker_plan = reported_plan };
}

fn buildVolumeJobs(
    allocator: std.mem.Allocator,
    records: []const domain.FileRecord,
    candidate_indexes: []const usize,
) !std.ArrayListUnmanaged(VolumeJobs) {
    var jobs: std.ArrayListUnmanaged(VolumeJobs) = .empty;
    errdefer deinitVolumeJobs(allocator, &jobs);

    for (candidate_indexes, 0..) |record_index, position| {
        const record = records[record_index];
        const job_index = try findOrCreateVolumeJob(allocator, &jobs, record);
        try jobs.items[job_index].positions.append(allocator, position);
    }
    return jobs;
}

fn findOrCreateVolumeJob(
    allocator: std.mem.Allocator,
    jobs: *std.ArrayListUnmanaged(VolumeJobs),
    record: domain.FileRecord,
) !usize {
    for (jobs.items, 0..) |job, index| {
        if (job.key.eql(record.volume_key)) return index;
    }
    try jobs.append(allocator, .{ .key = record.volume_key, .class = record.drive_class });
    return jobs.items.len - 1;
}

fn deinitVolumeJobs(allocator: std.mem.Allocator, jobs: *std.ArrayListUnmanaged(VolumeJobs)) void {
    for (jobs.items) |*job| job.deinit(allocator);
    jobs.deinit(allocator);
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
    progress: ?ports.ProgressObserver,

    fn init(allocator: std.mem.Allocator, progress: ?ports.ProgressObserver) RecordCollector {
        return .{ .allocator = allocator, .progress = progress };
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
        advanceProgress(self.progress, .enumerating, self.metrics.files_enumerated, 0);
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

fn beginProgress(progress: ?ports.ProgressObserver, phase: ports.ProgressPhase, total: ?u64) void {
    if (progress) |observer| observer.begin(observer.context, phase, total);
}

fn advanceProgress(progress: ?ports.ProgressObserver, phase: ports.ProgressPhase, completed: u64, total: u64) void {
    if (progress) |observer| observer.advance(observer.context, phase, completed, total);
}

fn completeProgress(progress: ?ports.ProgressObserver, metrics: domain.Metrics) void {
    if (progress) |observer| observer.complete(observer.context, metrics);
}

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
