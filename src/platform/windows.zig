const std = @import("std");
const builtin = @import("builtin");
const domain = @import("domain");
const ports = @import("ports");
const portable = @import("portable");

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
    portable_adapter: portable.Adapter,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Adapter {
        return .{
            .allocator = allocator,
            .io = io,
            .portable_adapter = portable.Adapter.init(allocator, io),
        };
    }

    pub fn directoryWalker(self: *Adapter) ports.DirectoryWalker {
        return self.portable_adapter.directoryWalker();
    }

    pub fn fileReader(self: *Adapter) ports.FileReader {
        return .{ .context = @ptrCast(self), .fingerprint = fingerprint, .full_hash = fullHash };
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
