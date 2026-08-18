const std = @import("std");
const domain = @import("domain");
const pipeline = @import("pipeline");
const report_jsonl = @import("report_jsonl");

fn record(path: []const u8, name: []const u8) domain.FileRecord {
    return .{
        .absolute_path = path,
        .comparison_name = name,
        .size = 4,
        .modified_ns = 0,
        .volume_key = .{ .raw = 1 },
    };
}

fn digest(byte: u8) domain.ContentHash {
    return .{ .bytes = [_]u8{byte} ** 32 };
}

test "JSONL reporter emits duplicate collision and summary events" {
    var grouping = try pipeline.buildGroups(std.testing.allocator, &[_]pipeline.HashedRecord{
        .{ .record = record("C:/one/same.bin", "same.bin"), .digest = digest(1) },
        .{ .record = record("C:/two/renamed.bin", "renamed.bin"), .digest = digest(1) },
        .{ .record = record("C:/three/report.bin", "report.bin"), .digest = digest(2) },
        .{ .record = record("C:/four/report.bin", "report.bin"), .digest = digest(3) },
    });
    defer grouping.deinit();

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var reporter = report_jsonl.JsonlReporter.init(&output.writer);
    try reporter.writeGroupsAndSummary(.portable, grouping, .{
        .files_enumerated = 4,
        .size_candidates = 4,
        .sample_candidates = 4,
        .full_hashes = 4,
    });

    const text = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema_version\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"event\":\"duplicate_group\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"event\":\"name_collision_group\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"event\":\"scan_summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"worker_plan\"") != null);
}
