const std = @import("std");
const domain = @import("domain");
const ports = @import("ports");

pub const Renderer = struct {
    io: std.Io,
    writer: *std.Io.Writer,
    enabled: bool,
    interactive: bool,
    mutex: std.Io.Mutex = .init,

    pub fn init(io: std.Io, writer: *std.Io.Writer, is_tty: bool) Renderer {
        return .{
            .io = io,
            .writer = writer,
            .enabled = true,
            .interactive = is_tty,
        };
    }

    pub fn observer(self: *Renderer) ports.ProgressObserver {
        return .{ .context = @ptrCast(self), .begin = onBegin, .advance = onAdvance, .complete = onComplete };
    }

    pub fn begin(self: *Renderer, phase: ports.ProgressPhase, total: ?u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.render(phase, 0, total orelse 0, false);
    }

    pub fn advance(self: *Renderer, phase: ports.ProgressPhase, completed: u64, total: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.render(phase, completed, total, false);
    }

    pub fn complete(self: *Renderer, metrics: domain.Metrics) void {
        if (!self.enabled) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var buffer: [160]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            "Complete: {d} files | {d} errors | {d} skipped",
            .{ metrics.files_enumerated, metrics.recoverable_errors, metrics.skipped_entries },
        ) catch return;
        self.writeLine(text, true);
    }

    fn onBegin(context: *anyopaque, phase: ports.ProgressPhase, total: ?u64) void {
        const self: *Renderer = @ptrCast(@alignCast(context));
        self.begin(phase, total);
    }

    fn onAdvance(context: *anyopaque, phase: ports.ProgressPhase, completed: u64, total: u64) void {
        const self: *Renderer = @ptrCast(@alignCast(context));
        self.advance(phase, completed, total);
    }

    fn onComplete(context: *anyopaque, metrics: domain.Metrics) void {
        const self: *Renderer = @ptrCast(@alignCast(context));
        self.complete(metrics);
    }

    fn render(self: *Renderer, phase: ports.ProgressPhase, completed: u64, total: u64, terminal: bool) void {
        if (!self.enabled) return;
        var buffer: [160]u8 = undefined;
        const text = switch (phase) {
            .enumerating => std.fmt.bufPrint(&buffer, "Enumerating: {d} files discovered", .{completed}) catch return,
            .sampling => self.renderDeterminate(&buffer, "Sampling", completed, total),
            .hashing => self.renderDeterminate(&buffer, "Hashing", completed, total),
            .grouping => std.fmt.bufPrint(&buffer, "Grouping results", .{}) catch return,
            .complete => std.fmt.bufPrint(&buffer, "Complete", .{}) catch return,
        };
        self.writeLine(text, terminal);
    }

    fn renderDeterminate(self: *Renderer, buffer: []u8, label: []const u8, completed: u64, total: u64) []const u8 {
        _ = self;
        var bar: [20]u8 = undefined;
        const filled: usize = if (total == 0) 0 else @intCast(@min(@as(u64, bar.len), completed * bar.len / total));
        @memset(bar[0..filled], '#');
        @memset(bar[filled..], '-');
        return std.fmt.bufPrint(buffer, "{s} {d}/{d} [{s}]", .{ label, completed, total, bar[0..] }) catch "";
    }

    fn writeLine(self: *Renderer, text: []const u8, terminal: bool) void {
        if (self.interactive and !terminal) {
            self.writer.writeAll("\r\x1b[2K") catch return;
            self.writer.writeAll(text) catch return;
        } else {
            self.writer.writeAll(text) catch return;
            self.writer.writeByte('\n') catch return;
        }
        self.writer.flush() catch {};
    }
};
