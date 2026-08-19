const std = @import("std");
const progress_console = @import("progress_console");

test "renderer shows phase child task bar and completion summary" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    var renderer = progress_console.Renderer.init(std.testing.io, &output.writer, false);
    renderer.begin(.hashing, 20);
    renderer.advance(.hashing, 7, 20);
    renderer.complete(.{ .files_enumerated = 22, .recoverable_errors = 1 });

    const text = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, text, "Hashing 7/20") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[#######") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Complete: 22 files") != null);
}

test "renderer always produces progress even when stderr is redirected" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    var renderer = progress_console.Renderer.init(std.testing.io, &output.writer, false);
    renderer.begin(.enumerating, null);
    renderer.advance(.enumerating, 2, 0);
    renderer.complete(.{});

    try std.testing.expect(output.writer.end != 0);
}

