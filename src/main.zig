const std = @import("std");
const builtin = @import("builtin");
const domain = @import("domain");
const ports = @import("ports");
const pipeline = @import("pipeline");
const portable = @import("portable");
const report_jsonl = @import("report_jsonl");
const report_text = @import("report_text");
const windows = @import("windows");
const progress_console = @import("progress_console");
const zio = @import("zio");

// ZIO's scheduler diagnostics are useful while developing the runtime, but
// they must not pollute the CLI's progress/JSON output in normal builds.
pub const std_options = std.Options{ .log_level = .info };

const default_excludes = [_][]const u8{ "node_modules", "target", ".git", ".zig-cache", "zig-cache", "zig-out", ".cache", "__pycache__" };

pub const ParsedArgs = struct {
    allocator: std.mem.Allocator,
    request: domain.ScanRequest,

    pub fn deinit(self: *ParsedArgs) void {
        self.allocator.free(self.request.roots);
        if (self.request.exclude_dirs.len != 0) self.allocator.free(self.request.exclude_dirs);
        self.request.roots = &.{};
        self.request.exclude_dirs = &.{};
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !ParsedArgs {
    var roots: std.ArrayListUnmanaged([]const u8) = .empty;
    var excludes: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer roots.deinit(allocator);
    errdefer excludes.deinit(allocator);

    for (default_excludes) |name| try excludes.append(allocator, name);

    var output_path: ?[]const u8 = null;
    var workers: domain.WorkerLimit = .auto;
    var backend: domain.Backend = .auto;
    var format: domain.OutputFormat = .jsonl;
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
        } else if (std.mem.eql(u8, argument, "--format")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            format = try parseFormat(args[index]);
        } else if (std.mem.eql(u8, argument, "--exclude")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            try excludes.append(allocator, args[index]);
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
            .exclude_dirs = try excludes.toOwnedSlice(allocator),
            .output_path = output_path,
            .workers = workers,
            .backend = backend,
            .format = format,
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

    const jsonl = try renderRequest(allocator, io, parsed.request, null, false);
    defer allocator.free(jsonl);
    try writer.writeAll(jsonl);
}

pub fn main(init: std.process.Init) !void {
    var runtime = try zio.Runtime.init(std.heap.smp_allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

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
    const stdout = std.Io.File.stdout();
    const stdout_is_tty = stdout.isTty(io) catch false;
    if (parsed.request.output_path == null and !hasFormatOption(args.items) and stdout_is_tty) parsed.request.format = .text;
    if (parsed.request.output_path) |output_path| {
        var report_file = try createExclusiveReport(io, output_path);
        defer report_file.close(io);
        const jsonl = try renderWithProgress(io, init.gpa, parsed.request, false);
        defer init.gpa.free(jsonl);
        try report_file.writeStreamingAll(io, jsonl);
    } else {
        const jsonl = try renderWithProgress(io, init.gpa, parsed.request, stdout_is_tty);
        defer init.gpa.free(jsonl);
        try std.Io.File.stdout().writeStreamingAll(io, jsonl);
    }
}

pub fn createExclusiveReport(io: std.Io, path: []const u8) !std.Io.File {
    return std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
}

fn renderWithProgress(io: std.Io, allocator: std.mem.Allocator, request: domain.ScanRequest, hyperlinks: bool) ![]u8 {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const is_tty = std.Io.File.stderr().isTty(io) catch false;
    var progress = progress_console.Renderer.init(io, &stderr_writer.interface, is_tty);
    return renderRequest(allocator, io, request, progress.observer(), hyperlinks);
}

fn renderRequest(allocator: std.mem.Allocator, io: std.Io, request: domain.ScanRequest, progress: ?ports.ProgressObserver, hyperlinks: bool) ![]u8 {
    if (request.backend == .win32 and builtin.os.tag != .windows) return error.UnsupportedBackend;
    const use_windows = request.backend == .win32 or
        (request.backend == .auto and builtin.os.tag == .windows);
    var result = if (use_windows) blk: {
        var adapter = windows.Adapter.init(allocator, io);
        adapter.setExcludeDirs(request.exclude_dirs);
        break :blk try pipeline.scanIncremental(allocator, io, request, adapter.directoryWalker(), adapter.fileReader(), progress);
    } else blk: {
        var adapter = portable.Adapter.init(allocator, io);
        adapter.setExcludeDirs(request.exclude_dirs);
        break :blk try pipeline.scanIncremental(allocator, io, request, adapter.directoryWalker(), adapter.fileReader(), progress);
    };
    defer result.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    if (request.format == .text) {
        var reporter = report_text.TextReporter.init(&output.writer, hyperlinks);
        try reporter.writeResult(&result);
    } else {
        var reporter = report_jsonl.JsonlReporter.init(&output.writer);
        try reporter.writeResult(if (use_windows) .win32 else .portable, &result);
    }
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

fn parseFormat(value: []const u8) !domain.OutputFormat {
    if (std.mem.eql(u8, value, "jsonl")) return .jsonl;
    if (std.mem.eql(u8, value, "text")) return .text;
    return error.InvalidFormat;
}

fn hasFormatOption(args: []const []const u8) bool {
    for (args) |argument| if (std.mem.eql(u8, argument, "--format")) return true;
    return false;
}

