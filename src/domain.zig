const std = @import("std");

pub const DriveClass = enum {
    fixed,
    removable,
    remote,
    unknown,
};

pub const Backend = enum {
    auto,
    portable,
    win32,
};

pub const VolumeKey = struct {
    raw: u64,

    pub fn eql(self: VolumeKey, other: VolumeKey) bool {
        return self.raw == other.raw;
    }
};

pub const ContentHash = struct {
    bytes: [32]u8,

    pub fn eql(self: ContentHash, other: ContentHash) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

pub const Fingerprint = struct {
    first: ContentHash,
    last: ContentHash,
};

pub const FileRecord = struct {
    absolute_path: []const u8,
    comparison_name: []const u8,
    size: u64,
    modified_ns: i128,
    volume_key: VolumeKey,
    drive_class: DriveClass = .unknown,
};

pub const ScanErrorKind = enum {
    access_denied,
    sharing_violation,
    file_changed,
    path_malformed,
    read_failed,
    root_not_found,
    skipped_reparse_point,
    unsupported_backend,
};

pub const ScanError = struct {
    kind: ScanErrorKind,
    path: []const u8,
    platform_code: ?u32 = null,
};

pub const Metrics = struct {
    files_enumerated: u64 = 0,
    bytes_enumerated: u64 = 0,
    size_candidates: u64 = 0,
    sample_candidates: u64 = 0,
    full_hashes: u64 = 0,
    bytes_read: u64 = 0,
    skipped_entries: u64 = 0,
    recoverable_errors: u64 = 0,
    elapsed_ns: u64 = 0,
};

pub const WorkerLimit = union(enum) {
    auto,
    explicit: u16,
};

pub const VolumeReaderPlan = struct {
    key: VolumeKey,
    drive_class: DriveClass,
    pending_jobs: u64,
    readers: u8,
};

pub const ScanRequest = struct {
    roots: []const []const u8,
    output_path: ?[]const u8 = null,
    workers: WorkerLimit = .auto,
    backend: Backend = .auto,
};

pub fn autoReaders(class: DriveClass) u8 {
    return if (class == .fixed) 2 else 1;
}
