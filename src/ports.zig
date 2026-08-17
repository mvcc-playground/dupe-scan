const domain = @import("domain");

pub const FileVisitor = struct {
    context: *anyopaque,
    on_file: *const fn (context: *anyopaque, record: domain.FileRecord) anyerror!void,
    on_error: *const fn (context: *anyopaque, scan_error: domain.ScanError) anyerror!void,
};

pub const DirectoryWalker = struct {
    context: *anyopaque,
    walk: *const fn (context: *anyopaque, root: []const u8, visitor: FileVisitor) anyerror!void,
};

pub const FileReader = struct {
    context: *anyopaque,
    fingerprint: *const fn (context: *anyopaque, path: []const u8, size: u64, buffer: []u8) anyerror!domain.Fingerprint,
    full_hash: *const fn (context: *anyopaque, path: []const u8, expected_size: u64, buffer: []u8) anyerror!domain.ContentHash,
};

pub const VolumeClassifier = struct {
    context: *anyopaque,
    classify: *const fn (context: *anyopaque, root: []const u8) anyerror!domain.DriveClass,
};

pub const Reporter = struct {
    context: *anyopaque,
    event: *const fn (context: *anyopaque, name: []const u8) anyerror!void,
    finish: *const fn (context: *anyopaque, metrics: domain.Metrics) anyerror!void,
};
