const std = @import("std");
const domain = @import("domain");
const pipeline = @import("pipeline");

pub const JsonlReporter = struct {
    writer: *std.Io.Writer,

    pub fn init(writer: *std.Io.Writer) JsonlReporter {
        return .{ .writer = writer };
    }

    pub fn writeResult(self: *JsonlReporter, backend: domain.Backend, result: *const pipeline.ScanResult) !void {
        for (result.errors) |scan_error| try self.writeError(scan_error);
        try self.writeGroupsAndSummary(backend, result.grouping, result.metrics);
    }

    pub fn writeGroupsAndSummary(
        self: *JsonlReporter,
        backend: domain.Backend,
        grouping: pipeline.Grouping,
        metrics: domain.Metrics,
    ) !void {
        for (grouping.duplicates) |group| try self.writeDuplicateGroup(group);
        for (grouping.name_collisions) |group| try self.writeCollisionGroup(group);
        try self.writeSummary(backend, metrics);
    }

    fn writeDuplicateGroup(self: *JsonlReporter, group: pipeline.DuplicateGroup) !void {
        try self.writer.writeAll("{\"schema_version\":1,\"event\":\"duplicate_group\",\"digest\":\"");
        try writeHex(self.writer, group.digest.bytes[0..]);
        try self.writer.writeAll("\",\"members\":[");
        try writeMembers(self.writer, group.members);
        try self.writer.writeAll("]}\n");
    }

    fn writeCollisionGroup(self: *JsonlReporter, group: pipeline.NameCollisionGroup) !void {
        try self.writer.writeAll("{\"schema_version\":1,\"event\":\"name_collision_group\",\"name\":\"");
        try writeEscaped(self.writer, group.comparison_name);
        try self.writer.print("\",\"size\":{d},\"members\":[", .{group.size});
        try writeMembers(self.writer, group.members);
        try self.writer.writeAll("]}\n");
    }

    fn writeError(self: *JsonlReporter, scan_error: domain.ScanError) !void {
        try self.writer.writeAll("{\"schema_version\":1,\"event\":\"recoverable_error\",\"kind\":\"");
        try self.writer.writeAll(@tagName(scan_error.kind));
        try self.writer.writeAll("\",\"path\":\"");
        try writeEscaped(self.writer, scan_error.path);
        try self.writer.writeAll("\"}\n");
    }

    fn writeSummary(self: *JsonlReporter, backend: domain.Backend, metrics: domain.Metrics) !void {
        try self.writer.print(
            "{{\"schema_version\":1,\"event\":\"scan_summary\",\"backend\":\"{s}\",\"files_enumerated\":{d},\"bytes_enumerated\":{d},\"size_candidates\":{d},\"sample_candidates\":{d},\"full_hashes\":{d},\"bytes_read\":{d},\"skipped_entries\":{d},\"recoverable_errors\":{d},\"elapsed_ns\":{d}}}\n",
            .{
                @tagName(backend),
                metrics.files_enumerated,
                metrics.bytes_enumerated,
                metrics.size_candidates,
                metrics.sample_candidates,
                metrics.full_hashes,
                metrics.bytes_read,
                metrics.skipped_entries,
                metrics.recoverable_errors,
                metrics.elapsed_ns,
            },
        );
    }
};

fn writeMembers(writer: *std.Io.Writer, members: []const pipeline.HashedRecord) !void {
    for (members, 0..) |member, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":\"");
        try writeEscaped(writer, member.record.absolute_path);
        try writer.print("\",\"size\":{d},\"digest\":\"", .{member.record.size});
        try writeHex(writer, member.digest.bytes[0..]);
        try writer.writeAll("\"}");
    }
}

fn writeHex(writer: *std.Io.Writer, bytes: []const u8) !void {
    const alphabet = "0123456789abcdef";
    for (bytes) |byte| {
        try writer.writeByte(alphabet[byte >> 4]);
        try writer.writeByte(alphabet[byte & 0x0f]);
    }
}

fn writeEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (byte < 0x20) {
                    try writer.print("\\u00{x:0>2}", .{byte});
                } else {
                    try writer.writeByte(byte);
                }
            },
        }
    }
}
