const std = @import("std");
const domain = @import("domain");
const pipeline = @import("pipeline");
const portable = @import("portable");
const report_jsonl = @import("report_jsonl");

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

    switch (parsed.request.backend) {
        .win32 => return error.UnsupportedBackend,
        .auto, .portable => {
            var adapter = portable.Adapter.init(allocator, io);
            var result = try pipeline.scan(
                allocator,
                parsed.request,
                adapter.directoryWalker(),
                adapter.fileReader(),
            );
            defer result.deinit();

            var reporter = report_jsonl.JsonlReporter.init(writer);
            try reporter.writeResult(.portable, &result);
        },
    }
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
