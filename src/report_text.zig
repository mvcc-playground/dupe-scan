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
                try self.writer.print("  - {d} bytes | ", .{member.record.size});
                try self.writePath(member.record.absolute_path);
                try self.writer.writeByte('\n');
            }
        }
        try self.writer.print("\nColisoes de nome ({d})\n", .{result.grouping.name_collisions.len});
        for (result.grouping.name_collisions) |group| {
            try self.writer.print("\n- {s} ({d} bytes)\n", .{ group.comparison_name, group.size });
            for (group.members) |member| {
                try self.writer.writeAll("  - ");
                try self.writePath(member.record.absolute_path);
                try self.writer.writeByte('\n');
            }
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
        try self.writer.print("\nResumo\n------\nArquivos: {d}\nBytes enumerados: {d}\nCandidatos: {d}\nHashes completos: {d}\nBytes lidos: {d}\nTempo: {d:.2} s\nArquivos/s: {d:.1}\nMiB/s: {d:.1}\nErros: {d}\n", .{
            result.metrics.files_enumerated,
            result.metrics.bytes_enumerated,
            result.metrics.sample_candidates,
            result.metrics.full_hashes,
            result.metrics.bytes_read,
            seconds,
            files_per_second,
            mib_per_second,
            result.metrics.recoverable_errors,
        });
    }

    fn writePath(self: *TextReporter, path: []const u8) !void {
        if (!self.hyperlinks) return self.writer.writeAll(path);
        try self.writer.writeAll("\x1b]8;;file:///");
        for (path) |byte| try self.writer.writeByte(if (byte == '\\') '/' else byte);
        try self.writer.writeAll("\x1b\\");
        try self.writer.writeAll(path);
        try self.writer.writeAll("\x1b]8;;\x1b\\");
    }
};

fn writeHex(writer: *std.Io.Writer, bytes: []const u8) !void {
    const alphabet = "0123456789abcdef";
    for (bytes) |byte| {
        try writer.writeByte(alphabet[byte >> 4]);
        try writer.writeByte(alphabet[byte & 0x0f]);
    }
}
