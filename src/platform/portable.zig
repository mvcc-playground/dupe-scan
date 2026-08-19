const std = @import("std");
const builtin = @import("builtin");
const domain = @import("domain");
const ports = @import("ports");

const sample_size: u64 = 64 * 1024;

pub const Adapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    exclude_dirs: []const []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Adapter {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn directoryWalker(self: *Adapter) ports.DirectoryWalker {
        return .{ .context = @ptrCast(self), .walk = walk };
    }

    pub fn fileReader(self: *Adapter) ports.FileReader {
        return .{ .context = @ptrCast(self), .fingerprint = fingerprint, .full_hash = fullHash };
    }

    pub fn setExcludeDirs(self: *Adapter, names: []const []const u8) void {
        self.exclude_dirs = names;
    }

    fn walk(context: *anyopaque, root: []const u8, visitor: ports.FileVisitor) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        const absolute_root = std.Io.Dir.cwd().realPathFileAlloc(self.io, root, self.allocator) catch |err| {
            try self.emitError(visitor, mapError(err), root);
            return;
        };
        defer self.allocator.free(absolute_root);

        var root_dir = std.Io.Dir.openDirAbsolute(self.io, absolute_root, .{ .iterate = true }) catch |err| {
            try self.emitError(visitor, mapError(err), absolute_root);
            return;
        };
        defer root_dir.close(self.io);

        var selective_walker = try root_dir.walkSelectively(self.allocator);
        defer selective_walker.deinit();
        while (true) {
            const entry = selective_walker.next(self.io) catch |err| {
                try self.emitError(visitor, mapError(err), absolute_root);
                continue;
            } orelse break;

            switch (entry.kind) {
                .directory => {
                    if (isExcludedName(self.exclude_dirs, entry.basename)) continue;
                    selective_walker.enter(self.io, entry) catch |err| {
                        const child_path = try self.childPath(absolute_root, entry.path);
                        defer self.allocator.free(child_path);
                        try self.emitError(visitor, mapError(err), child_path);
                    };
                },
                .file => self.emitFile(visitor, absolute_root, entry) catch |err| {
                    const child_path = try self.childPath(absolute_root, entry.path);
                    defer self.allocator.free(child_path);
                    try self.emitError(visitor, mapError(err), child_path);
                },
                .sym_link => {
                    const child_path = try self.childPath(absolute_root, entry.path);
                    defer self.allocator.free(child_path);
                    try self.emitError(visitor, .skipped_reparse_point, child_path);
                },
                else => {},
            }
        }
    }

    fn emitFile(self: *Adapter, visitor: ports.FileVisitor, absolute_root: []const u8, entry: std.Io.Dir.Walker.Entry) !void {
        const stat = try entry.dir.statFile(self.io, entry.basename, .{ .follow_symlinks = false });
        if (stat.kind != .file) return;

        const absolute_path = try self.childPath(absolute_root, entry.path);
        errdefer self.allocator.free(absolute_path);
        try visitor.on_file(visitor.context, .{
            .absolute_path = absolute_path,
            .comparison_name = std.fs.path.basename(absolute_path),
            .size = stat.size,
            .modified_ns = @intCast(stat.mtime.nanoseconds),
            .volume_key = .{ .raw = 0 },
        });
    }

    fn childPath(self: *Adapter, root: []const u8, relative: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ root, relative });
    }

    fn emitError(self: *Adapter, visitor: ports.FileVisitor, kind: domain.ScanErrorKind, path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try visitor.on_error(visitor.context, .{ .kind = kind, .path = owned_path });
    }

    fn fingerprint(context: *anyopaque, path: []const u8, size: u64, buffer: []u8) anyerror!domain.Fingerprint {
        const self: *Adapter = @ptrCast(@alignCast(context));
        if (buffer.len < sample_size) return error.BufferTooSmall;
        var file = try openReadOnlyNoFollow(self.io, path);
        defer file.close(self.io);

        const first_length: usize = @intCast(@min(size, sample_size));
        const first = try hashRange(self.io, file, 0, buffer[0..first_length]);
        const last_offset = if (size > sample_size) size - sample_size else 0;
        const last = try hashRange(self.io, file, last_offset, buffer[0..first_length]);
        return .{ .first = first, .last = last };
    }

    fn fullHash(context: *anyopaque, path: []const u8, expected_size: u64, buffer: []u8) anyerror!domain.ContentHash {
        const self: *Adapter = @ptrCast(@alignCast(context));
        var file = try openReadOnlyNoFollow(self.io, path);
        defer file.close(self.io);

        var hasher = std.crypto.hash.Blake3.init(.{});
        var bytes_read: u64 = 0;
        while (true) {
            const amount = try file.readPositional(self.io, &.{buffer}, bytes_read);
            if (amount == 0) break;
            hasher.update(buffer[0..amount]);
            bytes_read += amount;
        }
        if (bytes_read != expected_size) return error.FileChanged;

        var output: [32]u8 = undefined;
        hasher.final(&output);
        return .{ .bytes = output };
    }
};

fn isExcludedName(excludes: []const []const u8, name: []const u8) bool {
    for (excludes) |excluded| if (std.ascii.eqlIgnoreCase(excluded, name)) return true;
    return false;
}

fn hashRange(io: std.Io, file: std.Io.File, offset: u64, buffer: []u8) !domain.ContentHash {
    const amount = try file.readPositionalAll(io, buffer, offset);
    if (amount != buffer.len) return error.FileChanged;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(buffer);
    var output: [32]u8 = undefined;
    hasher.final(&output);
    return .{ .bytes = output };
}

fn openReadOnlyNoFollow(io: std.Io, path: []const u8) !std.Io.File {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only, .follow_symlinks = false });
    if (builtin.os.tag == .windows) {
        // Zig 0.16 opens no-follow Windows handles asynchronously but returns
        // a File marked as synchronous. Keep the file flag aligned with its
        // actual handle mode so the Threaded I/O backend waits for completion.
        file.flags.nonblocking = true;
    }
    return file;
}

fn mapError(source: anyerror) domain.ScanErrorKind {
    return switch (source) {
        error.FileNotFound, error.NotDir => .root_not_found,
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.LockViolation, error.FileBusy => .sharing_violation,
        else => .read_failed,
    };
}
