const std = @import("std");
const builtin = @import("builtin");
const domain = @import("domain");
const pipeline = @import("pipeline");
const portable = @import("portable");
const report_jsonl = @import("report_jsonl");
const windows = @import("windows");

pub const ParsedArgs = struct {
    allocator: std.mem.Allocator,
    request: domain.ScanRequest,

    pub fn deinit(self: *ParsedArgs) void {
        self.allocator.free(self.request.roots);
        self.request.roots = &.{};
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !ParsedArgs {
    var roots: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer roots.deinit(allocator);

    var output_path: ?[]const u8 = null;
    var workers: domain.WorkerLimit = .auto;
    var backend: domain.Backend = .auto;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--output")) {
            if (output_path != null) return error.DuplicateOption;
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            output_path = args[index];
        } else if (std.mem.eql(u8, argument, "--workers")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            workers = try parseWorkers(args[index]);
        } else if (std.mem.eql(u8, argument, "--backend")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            backend = try parseBackend(args[index]);
        } else if (std.mem.startsWith(u8, argument, "--")) {
            return error.UnknownArgument;
        } else {
            try roots.append(allocator, argument);
        }
    }
    if (roots.items.len == 0) return error.NoRoots;

    return .{
        .allocator = allocator,
        .request = .{
            .roots = try roots.toOwnedSlice(allocator),
            .output_path = output_path,
            .workers = workers,
            .backend = backend,
        },
    };
}

pub fn runWithWriter(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    writer: *std.Io.Writer,
) !void {
    var parsed = try parseArgs(allocator, args);
    defer parsed.deinit();
    if (parsed.request.output_path != null) return error.OutputPathRequiresFileExecution;

    const jsonl = try renderRequest(allocator, io, parsed.request);
    defer allocator.free(jsonl);
    try writer.writeAll(jsonl);
}

pub fn main(init: std.process.Init) !void {
    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer iterator.deinit();
    _ = iterator.next();

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (args.items) |argument| init.gpa.free(argument);
        args.deinit(init.gpa);
    }
    while (iterator.next()) |argument| {
        const owned = try init.gpa.dupe(u8, argument);
        errdefer init.gpa.free(owned);
        try args.append(init.gpa, owned);
    }

    var parsed = try parseArgs(init.gpa, args.items);
    defer parsed.deinit();
    const jsonl = try renderRequest(init.gpa, init.io, parsed.request);
    defer init.gpa.free(jsonl);
    if (parsed.request.output_path) |output_path| {
        var report_file = try std.Io.Dir.cwd().createFile(init.io, output_path, .{});
        defer report_file.close(init.io);
        try report_file.writeStreamingAll(init.io, jsonl);
    } else {
        try std.Io.File.stdout().writeStreamingAll(init.io, jsonl);
    }
}

fn renderRequest(allocator: std.mem.Allocator, io: std.Io, request: domain.ScanRequest) ![]u8 {
    if (request.backend == .win32 and builtin.os.tag != .windows) return error.UnsupportedBackend;
    const use_windows = request.backend == .win32 or
        (request.backend == .auto and builtin.os.tag == .windows);
    var result = if (use_windows) blk: {
        var adapter = windows.Adapter.init(allocator, io);
        break :blk try pipeline.scan(allocator, io, request, adapter.directoryWalker(), adapter.fileReader());
    } else blk: {
        var adapter = portable.Adapter.init(allocator, io);
        break :blk try pipeline.scan(allocator, io, request, adapter.directoryWalker(), adapter.fileReader());
    };
    defer result.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var reporter = report_jsonl.JsonlReporter.init(&output.writer);
    try reporter.writeResult(if (use_windows) .win32 else .portable, &result);
    return output.toOwnedSlice();
}

fn parseWorkers(value: []const u8) !domain.WorkerLimit {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    const explicit = std.fmt.parseInt(u16, value, 10) catch return error.InvalidWorkerCount;
    if (explicit == 0) return error.InvalidWorkerCount;
    return .{ .explicit = explicit };
}

fn parseBackend(value: []const u8) !domain.Backend {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "portable")) return .portable;
    if (std.mem.eql(u8, value, "win32")) return .win32;
    return error.InvalidBackend;
}
