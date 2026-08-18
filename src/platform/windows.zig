const std = @import("std");
const builtin = @import("builtin");
const domain = @import("domain");
const ports = @import("ports");

const Handle = usize;
const invalid_handle = std.math.maxInt(Handle);
const generic_read: u32 = 0x80000000;
const file_share_read: u32 = 0x00000001;
const file_share_write: u32 = 0x00000002;
const file_share_delete: u32 = 0x00000004;
const open_existing: u32 = 3;
const file_attribute_normal: u32 = 0x00000080;
const file_flag_sequential_scan: u32 = 0x08000000;
const file_flag_open_reparse_point: u32 = 0x00200000;
const file_begin: u32 = 0;
const sample_size: u64 = 64 * 1024;
const find_ex_info_basic: u32 = 1;
const find_ex_search_name_match: u32 = 0;
const find_first_ex_large_fetch: u32 = 0x00000002;
const error_no_more_files: u32 = 18;

pub const file_attribute_directory: u32 = 0x00000010;
pub const file_attribute_reparse_point: u32 = 0x00000400;

pub const EntryKind = enum {
    file,
    directory,
    skip_reparse_point,
};

pub fn mapAttributes(attributes: u32) EntryKind {
    if ((attributes & file_attribute_reparse_point) != 0) return .skip_reparse_point;
    if ((attributes & file_attribute_directory) != 0) return .directory;
    return .file;
}

const FileTime = extern struct {
    low: u32,
    high: u32,
};

const Win32FindDataW = extern struct {
    attributes: u32,
    creation_time: FileTime,
    last_access_time: FileTime,
    last_write_time: FileTime,
    file_size_high: u32,
    file_size_low: u32,
    reserved0: u32,
    reserved1: u32,
    file_name: [260]u16,
    alternate_file_name: [14]u16,
};

extern "kernel32" fn FindFirstFileExW(
    file_name: [*:0]const u16,
    info_level: u32,
    find_data: *Win32FindDataW,
    search_op: u32,
    search_filter: ?*anyopaque,
    additional_flags: u32,
) callconv(.winapi) Handle;
extern "kernel32" fn FindNextFileW(handle: Handle, find_data: *Win32FindDataW) callconv(.winapi) i32;
extern "kernel32" fn FindClose(handle: Handle) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

extern "kernel32" fn CreateFileW(
    file_name: [*:0]const u16,
    desired_access: u32,
    share_mode: u32,
    security_attributes: ?*anyopaque,
    creation_disposition: u32,
    flags_and_attributes: u32,
    template_file: Handle,
) callconv(.winapi) Handle;
extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(
    handle: Handle,
    buffer: ?*anyopaque,
    bytes_to_read: u32,
    bytes_read: *u32,
    overlapped: ?*anyopaque,
) callconv(.winapi) i32;
extern "kernel32" fn SetFilePointerEx(
    handle: Handle,
    distance: i64,
    new_position: ?*i64,
    move_method: u32,
) callconv(.winapi) i32;

pub const Adapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Adapter {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn directoryWalker(self: *Adapter) ports.DirectoryWalker {
        return .{ .context = @ptrCast(self), .walk = walk };
    }

    pub fn fileReader(self: *Adapter) ports.FileReader {
        return .{ .context = @ptrCast(self), .fingerprint = fingerprint, .full_hash = fullHash };
    }

    fn walk(context: *anyopaque, root: []const u8, visitor: ports.FileVisitor) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        if (builtin.os.tag != .windows) return error.UnsupportedBackend;

        const absolute_root = std.Io.Dir.cwd().realPathFileAlloc(self.io, root, self.allocator) catch |err| {
            try self.emitError(visitor, mapPathError(err), root, null);
            return;
        };
        defer self.allocator.free(absolute_root);

        var pending_directories: std.ArrayListUnmanaged([]u8) = .empty;
        const root_directory = try self.allocator.dupe(u8, absolute_root);
        pending_directories.append(self.allocator, root_directory) catch |err| {
            self.allocator.free(root_directory);
            return err;
        };
        defer {
            for (pending_directories.items) |directory| self.allocator.free(directory);
            pending_directories.deinit(self.allocator);
        }

        while (pending_directories.pop()) |directory| {
            defer self.allocator.free(directory);
            try self.walkDirectory(directory, visitor, &pending_directories);
        }
    }

    fn walkDirectory(
        self: *Adapter,
        directory: []const u8,
        visitor: ports.FileVisitor,
        pending_directories: *std.ArrayListUnmanaged([]u8),
    ) !void {
        const search_path = try self.searchPath(directory);
        defer self.allocator.free(search_path);
        const wide_search_path = try extendedWidePath(self.allocator, search_path);
        defer self.allocator.free(wide_search_path);

        var find_data: Win32FindDataW = undefined;
        const find_handle = FindFirstFileExW(
            wide_search_path.ptr,
            find_ex_info_basic,
            &find_data,
            find_ex_search_name_match,
            null,
            find_first_ex_large_fetch,
        );
        if (find_handle == invalid_handle) {
            const code = GetLastError();
            try self.emitError(visitor, mapWin32Error(code), directory, code);
            return;
        }
        defer _ = FindClose(find_handle);

        while (true) {
            try self.processFindData(directory, &find_data, visitor, pending_directories);
            if (FindNextFileW(find_handle, &find_data) != 0) continue;

            const code = GetLastError();
            if (code == error_no_more_files) break;
            try self.emitError(visitor, mapWin32Error(code), directory, code);
            break;
        }
    }

    fn processFindData(
        self: *Adapter,
        directory: []const u8,
        find_data: *const Win32FindDataW,
        visitor: ports.FileVisitor,
        pending_directories: *std.ArrayListUnmanaged([]u8),
    ) !void {
        const name_wide = zeroTerminatedSlice(&find_data.file_name);
        if (isDotEntry(name_wide)) return;
        const name = std.unicode.utf16LeToUtf8Alloc(self.allocator, name_wide) catch {
            try self.emitError(visitor, .path_malformed, directory, null);
            return;
        };
        defer self.allocator.free(name);

        const absolute_path = try std.fs.path.join(self.allocator, &.{ directory, name });
        switch (mapAttributes(find_data.attributes)) {
            .directory => {
                errdefer self.allocator.free(absolute_path);
                try pending_directories.append(self.allocator, absolute_path);
            },
            .skip_reparse_point => {
                defer self.allocator.free(absolute_path);
                try self.emitError(visitor, .skipped_reparse_point, absolute_path, null);
            },
            .file => {
                errdefer self.allocator.free(absolute_path);
                try visitor.on_file(visitor.context, .{
                    .absolute_path = absolute_path,
                    .comparison_name = std.fs.path.basename(absolute_path),
                    .size = (@as(u64, find_data.file_size_high) << 32) | find_data.file_size_low,
                    .modified_ns = fileTimeToNanoseconds(find_data.last_write_time),
                    .volume_key = volumeKeyForPath(absolute_path),
                });
            },
        }
    }

    fn searchPath(self: *Adapter, directory: []const u8) ![]u8 {
        const suffix: []const u8 = if (directory.len != 0 and (directory[directory.len - 1] == '\\' or directory[directory.len - 1] == '/')) "*" else "\\*";
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ directory, suffix });
    }

    fn emitError(self: *Adapter, visitor: ports.FileVisitor, kind: domain.ScanErrorKind, path: []const u8, platform_code: ?u32) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try visitor.on_error(visitor.context, .{ .kind = kind, .path = owned_path, .platform_code = platform_code });
    }

    fn fingerprint(context: *anyopaque, path: []const u8, size: u64, buffer: []u8) anyerror!domain.Fingerprint {
        const self: *Adapter = @ptrCast(@alignCast(context));
        if (builtin.os.tag != .windows) return error.UnsupportedBackend;
        if (buffer.len < sample_size) return error.BufferTooSmall;

        const handle = try self.openReadOnly(path, 0);
        defer _ = CloseHandle(handle);
        const length: usize = @intCast(@min(size, sample_size));
        try readExactly(handle, 0, buffer[0..length]);
        const first = hashBytes(buffer[0..length]);
        const last_offset = if (size > sample_size) size - sample_size else 0;
        try readExactly(handle, last_offset, buffer[0..length]);
        const last = hashBytes(buffer[0..length]);
        return .{ .first = first, .last = last };
    }

    fn fullHash(context: *anyopaque, path: []const u8, expected_size: u64, buffer: []u8) anyerror!domain.ContentHash {
        const self: *Adapter = @ptrCast(@alignCast(context));
        if (builtin.os.tag != .windows) return error.UnsupportedBackend;
        if (buffer.len == 0 or buffer.len > std.math.maxInt(u32)) return error.BufferTooSmall;

        const handle = try self.openReadOnly(path, file_flag_sequential_scan);
        defer _ = CloseHandle(handle);
        var hasher = std.crypto.hash.Blake3.init(.{});
        var total: u64 = 0;
        while (true) {
            const amount = try readSome(handle, buffer);
            if (amount == 0) break;
            hasher.update(buffer[0..amount]);
            total += amount;
        }
        if (total != expected_size) return error.FileChanged;

        var bytes: [32]u8 = undefined;
        hasher.final(&bytes);
        return .{ .bytes = bytes };
    }

    fn openReadOnly(self: *Adapter, path: []const u8, extra_flags: u32) !Handle {
        const wide_path = try extendedWidePath(self.allocator, path);
        defer self.allocator.free(wide_path);
        const handle = CreateFileW(
            wide_path.ptr,
            generic_read,
            file_share_read | file_share_write | file_share_delete,
            null,
            open_existing,
            file_attribute_normal | file_flag_open_reparse_point | extra_flags,
            0,
        );
        if (handle == invalid_handle) return error.Win32OpenFailed;
        return handle;
    }
};

fn zeroTerminatedSlice(values: []const u16) []const u16 {
    for (values, 0..) |value, index| {
        if (value == 0) return values[0..index];
    }
    return values;
}

fn isDotEntry(name: []const u16) bool {
    return (name.len == 1 and name[0] == '.') or
        (name.len == 2 and name[0] == '.' and name[1] == '.');
}

fn fileTimeToNanoseconds(time: FileTime) i128 {
    const ticks = (@as(u64, time.high) << 32) | time.low;
    return @as(i128, ticks) * 100;
}

fn volumeKeyForPath(path: []const u8) domain.VolumeKey {
    if (path.len >= 2 and path[1] == ':') {
        return .{ .raw = @as(u64, std.ascii.toUpper(path[0])) + 1 };
    }
    return .{ .raw = 1 };
}

fn mapWin32Error(code: u32) domain.ScanErrorKind {
    return switch (code) {
        2, 3 => .root_not_found,
        5 => .access_denied,
        32, 33 => .sharing_violation,
        else => .read_failed,
    };
}

fn mapPathError(source: anyerror) domain.ScanErrorKind {
    return switch (source) {
        error.FileNotFound, error.NotDir => .root_not_found,
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.LockViolation, error.FileBusy => .sharing_violation,
        else => .read_failed,
    };
}

fn readExactly(handle: Handle, offset: u64, buffer: []u8) !void {
    if (buffer.len == 0) return;
    if (offset > std.math.maxInt(i64)) return error.OffsetTooLarge;
    if (SetFilePointerEx(handle, @intCast(offset), null, file_begin) == 0) return error.Win32SeekFailed;

    var filled: usize = 0;
    while (filled < buffer.len) {
        const amount = try readSome(handle, buffer[filled..]);
        if (amount == 0) return error.FileChanged;
        filled += amount;
    }
}

fn readSome(handle: Handle, buffer: []u8) !usize {
    if (buffer.len == 0) return 0;
    const requested: u32 = @intCast(@min(buffer.len, std.math.maxInt(u32)));
    var bytes_read: u32 = 0;
    if (ReadFile(handle, @ptrCast(buffer.ptr), requested, &bytes_read, null) == 0) return error.Win32ReadFailed;
    return bytes_read;
}

fn hashBytes(bytes: []const u8) domain.ContentHash {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes);
    var output: [32]u8 = undefined;
    hasher.final(&output);
    return .{ .bytes = output };
}

fn extendedWidePath(allocator: std.mem.Allocator, path: []const u8) ![:0]u16 {
    if (std.mem.startsWith(u8, path, "\\\\?\\")) return std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    if (path.len < 248) return std.unicode.utf8ToUtf16LeAllocZ(allocator, path);

    const extended = if (std.mem.startsWith(u8, path, "\\\\"))
        try std.fmt.allocPrint(allocator, "\\\\?\\UNC\\{s}", .{path[2..]})
    else
        try std.fmt.allocPrint(allocator, "\\\\?\\{s}", .{path});
    defer allocator.free(extended);
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, extended);
}
