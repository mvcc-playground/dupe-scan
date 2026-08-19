const std = @import("std");
const domain = @import("domain");
const pipeline = @import("pipeline");

pub const TextReporter = struct {
    writer: *std.Io.Writer,
    hyperlinks: bool,

    pub fn init(writer: *std.Io.Writer, hyperlinks: bool) TextReporter {
        return .{ .writer = writer, .hyperlinks = hyperlinks };
    }

    pub fn writeResult(self: *TextReporter, result: *const pipeline.ScanResult) !void {
        try self.writer.writeAll("dupe-scan\n=========\n\n");
        try self.writer.print("Duplicatas ({d})\n", .{result.grouping.duplicates.len});
        for (result.grouping.duplicates, 0..) |group, index| {
            try self.writer.print("\n[{d}] digest ", .{index + 1});
            try writeHex(self.writer, group.digest.bytes[0..]);
            try self.writer.writeByte('\n');
            for (group.members) |member| {
                try self.writer.print("  FILE   {s} (", .{basename(member.record.absolute_path)});
                try writeSize(self.writer, member.record.size);
                try self.writer.writeAll(")\n         ");
                try self.writePath(member.record.absolute_path);
                try self.writer.writeByte('\n');
            }
            try self.writeFolders(group.members);
        }
        try self.writer.print("\nColisoes de nome ({d})\n", .{result.grouping.name_collisions.len});
        for (result.grouping.name_collisions) |group| {
            try self.writer.print("\n- {s} (", .{group.comparison_name});
            try writeSize(self.writer, group.size);
            try self.writer.writeAll(")\n");
            for (group.members) |member| {
                try self.writer.print("  FILE   {s} (", .{basename(member.record.absolute_path)});
                try writeSize(self.writer, member.record.size);
                try self.writer.writeAll(")\n         ");
                try self.writePath(member.record.absolute_path);
                try self.writer.writeByte('\n');
            }
            try self.writeFolders(group.members);
        }
        try self.writer.print("\nErros recuperaveis ({d})\n", .{result.errors.len});
        for (result.errors) |scan_error| {
            try self.writer.print("  - {s}: ", .{@tagName(scan_error.kind)});
            try self.writePath(scan_error.path);
            try self.writer.writeByte('\n');
        }
        const seconds = @as(f64, @floatFromInt(result.metrics.elapsed_ns)) / 1_000_000_000.0;
        const files_per_second = if (seconds > 0) @as(f64, @floatFromInt(result.metrics.files_enumerated)) / seconds else 0;
        const mib_per_second = if (seconds > 0) (@as(f64, @floatFromInt(result.metrics.bytes_read)) / (1024.0 * 1024.0)) / seconds else 0;
        try self.writer.print("\nResumo\n------\nArquivos: {d}\nBytes enumerados: ", .{result.metrics.files_enumerated});
        try writeSize(self.writer, result.metrics.bytes_enumerated);
        try self.writer.print("\nCandidatos: {d}\nHashes completos: {d}\nBytes lidos: ", .{ result.metrics.sample_candidates, result.metrics.full_hashes });
        try writeSize(self.writer, result.metrics.bytes_read);
        try self.writer.writeAll("\nEspaco recuperavel: ");
        try writeSize(self.writer, pipeline.reclaimableBytes(result.grouping));
        try self.writer.print("\nTempo: {d:.2} s\nArquivos/s: {d:.1}\nMiB/s: {d:.1}\nErros: {d}\n", .{ seconds, files_per_second, mib_per_second, result.metrics.recoverable_errors });
    }

    fn writePath(self: *TextReporter, path: []const u8) !void {
        if (!self.hyperlinks) return self.writer.writeAll(path);
        try self.writer.writeAll("\x1b]8;;file:///");
        for (path) |byte| try self.writer.writeByte(if (byte == '\\') '/' else byte);
        try self.writer.writeAll("\x1b\\");
        try self.writer.writeAll(path);
        try self.writer.writeAll("\x1b]8;;\x1b\\");
    }

    fn writeFolders(self: *TextReporter, members: []const pipeline.HashedRecord) !void {
        try self.writer.writeAll("  FOLDER\n");
        for (members, 0..) |member, index| {
            const folder = parentPath(member.record.absolute_path);
            var repeated = false;
            for (members[0..index]) |previous| {
                if (std.mem.eql(u8, folder, parentPath(previous.record.absolute_path))) {
                    repeated = true;
                    break;
                }
            }
            if (!repeated) {
                try self.writer.writeAll("         ");
                try self.writePath(folder);
                try self.writer.writeByte('\n');
            }
        }
    }
};

fn basename(path: []const u8) []const u8 {
    var index = path.len;
    while (index != 0) : (index -= 1) {
        if (path[index - 1] == '\\' or path[index - 1] == '/') return path[index..];
    }
    return path;
}

fn parentPath(path: []const u8) []const u8 {
    var index = path.len;
    while (index != 0) : (index -= 1) {
        if (path[index - 1] == '\\' or path[index - 1] == '/') return path[0 .. index - 1];
    }
    return ".";
}

fn writeSize(writer: *std.Io.Writer, size: u64) !void {
    const value = @as(f64, @floatFromInt(size));
    if (size >= 1 << 40) return writer.print("{d:.2} TiB", .{value / (1 << 40)});
    if (size >= 1 << 30) return writer.print("{d:.2} GiB", .{value / (1 << 30)});
    if (size >= 1 << 20) return writer.print("{d:.2} MiB", .{value / (1 << 20)});
    if (size >= 1 << 10) return writer.print("{d:.2} KiB", .{value / (1 << 10)});
    return writer.print("{d} bytes", .{size});
}

fn writeHex(writer: *std.Io.Writer, bytes: []const u8) !void {
    const alphabet = "0123456789abcdef";
    for (bytes) |byte| {
        try writer.writeByte(alphabet[byte >> 4]);
        try writer.writeByte(alphabet[byte & 0x0f]);
    }
}
