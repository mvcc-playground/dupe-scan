# Safe CLI Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add terminal progress without risking scanned files, JSONL consumers, or existing report files.

**Architecture:** An optional observer carries pipeline phase totals to a mutex-protected stderr renderer. The report writer remains separate and is opened exclusively.

**Tech Stack:** Zig 0.16.0 and the Zig standard library.

**Spec:** `docs/superpowers/specs/2026-08-19-safe-progress-design.md`

## Global Constraints

- Scanned inputs remain read-only.
- JSONL stays exclusively on stdout or the report file; progress stays on stderr.
- An existing `--output` path must return `error.PathAlreadyExists`, untouched.
- Progress write failures must never affect scan results.

---

### Task 1: Safe output and CLI mode

**Files:** Modify `src/domain.zig`, `src/main.zig`, and `tests/cli_test.zig`.

**Interfaces:** `domain.ProgressMode = enum { auto, always, never }`; `main.parseProgressMode([]const u8) !domain.ProgressMode`; `main.createExclusiveReport(std.Io, []const u8) !std.Io.File`.

- [ ] **Step 1: Write the failing tests**

```zig
test "progress parser accepts modes and rejects an invalid value" {
    try std.testing.expectEqual(domain.ProgressMode.always, try main.parseProgressMode("always"));
    try std.testing.expectError(error.InvalidProgressMode, main.parseProgressMode("loud"));
}

test "existing output is never truncated" {
    var temporary = std.testing.tmpDir(.{}); defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "report.jsonl", .data = "preserve me" });
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/report.jsonl", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.PathAlreadyExists, main.createExclusiveReport(std.testing.io, path));
}
```

- [ ] **Step 2: Verify RED**

Run: `zig build test --summary all`

Expected: the symbols are missing.

- [ ] **Step 3: Implement the minimal behavior**

```zig
pub fn parseProgressMode(value: []const u8) !domain.ProgressMode {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "always")) return .always;
    if (std.mem.eql(u8, value, "never")) return .never;
    return error.InvalidProgressMode;
}
pub fn createExclusiveReport(io: std.Io, path: []const u8) !std.Io.File {
    return std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
}
```

Parse one `--progress` option, reject a duplicate, and replace the current report creation call with `createExclusiveReport`.

- [ ] **Step 4: Verify GREEN**

Run: `zig build test --summary all`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```powershell
git add src/domain.zig src/main.zig tests/cli_test.zig
git commit -m "fix: protect report output and parse progress mode"
```

### Task 2: Pipeline observer

**Files:** Modify `src/ports.zig`, `src/pipeline.zig`, and `tests/pipeline_test.zig`.

**Interfaces:** `ports.ProgressPhase = enum { enumerating, sampling, hashing, grouping, complete }`; `ports.ProgressObserver`; `pipeline.scan(..., observer: ?ports.ProgressObserver) !ScanResult`.

- [ ] **Step 1: Write the failing observer test**

```zig
test "scan publishes progress totals for each determined stage" {
    var walker = FixedVolumeWalker{};
    var reader = ConcurrentReader{};
    var probe = ProgressProbe{};
    var result = try pipeline.scan(std.testing.allocator, std.testing.io,
        .{ .roots = &.{"fixture"}, .workers = .{ .explicit = 1 } },
        walker.port(), reader.port(), probe.observer());
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 3), probe.totalFor(.sampling));
    try std.testing.expectEqual(@as(u64, 3), probe.totalFor(.hashing));
    try std.testing.expectEqual(@as(u64, 3), probe.completedFor(.hashing));
}
```

- [ ] **Step 2: Verify RED**

Run: `zig build test --summary all`

Expected: observer contract and `scan` argument are missing.

- [ ] **Step 3: Implement observer publication**

```zig
pub const ProgressObserver = struct {
    context: *anyopaque,
    begin: *const fn (*anyopaque, ProgressPhase, ?u64) void,
    advance: *const fn (*anyopaque, ProgressPhase, u64, u64) void,
    complete: *const fn (*anyopaque, domain.Metrics) void,
};
```

Begin enumeration before walking; report records discovered. Begin sampling with `size_candidates`; report every attempt. Begin hashing with `full_hashes`; count every worker result. Begin grouping before groups are built and call `complete` after metrics are finalized. All observer calls are optional and cannot return an error.

- [ ] **Step 4: Verify GREEN**

Run: `zig build test --summary all`

Expected: observer behavior and all existing tests pass.

- [ ] **Step 5: Commit**

```powershell
git add src/ports.zig src/pipeline.zig tests/pipeline_test.zig
git commit -m "feat: expose pipeline progress stages"
```

### Task 3: Stderr renderer

**Files:** Create `src/progress_console.zig`, `tests/progress_test.zig`; modify `build.zig`, `src/main.zig`, and `tests/test_root.zig`.

**Interfaces:** `progress_console.Renderer.init(io, writer, mode, is_tty)` and `Renderer.observer()`.

- [ ] **Step 1: Write the failing renderer test**

```zig
test "renderer shows phase child task and a determinate bar" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = progress_console.Renderer.init(std.testing.io, &output.writer, .always, false);
    renderer.begin(.hashing, 20);
    renderer.advance(.hashing, 7, 20);
    renderer.complete(.{ .files_enumerated = 22, .recoverable_errors = 1 });
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffer[0..output.writer.end], "Hashing 7/20") != null);
}
```

- [ ] **Step 2: Verify RED**

Run: `zig build test --summary all`

Expected: `progress_console.Renderer` is missing.

- [ ] **Step 3: Implement and wire stderr rendering**

Use a `std.Io.Mutex`, fixed 20-cell `#`/`-` bar, and `std.fmt.bufPrint`. Render `Enumerating`, `Sampling done/total`, `Hashing done/total`, `Grouping`, and `Complete`. Interactive output redraws using `\r`; `always` uses lines. Catch formatting, write, and flush errors. Main enables the renderer only for `always` or for `auto` when `std.Io.File.stderr().isTty(io) catch false`.

- [ ] **Step 4: Verify GREEN**

Run: `zig build test --summary all; zig build -Doptimize=ReleaseSafe`

Expected: tests pass and ReleaseSafe build succeeds.

- [ ] **Step 5: Commit**

```powershell
git add build.zig src/progress_console.zig src/main.zig tests/progress_test.zig tests/test_root.zig
git commit -m "feat: add safe terminal scan progress"
```

## Plan self-review

- Task 1 implements the safe output path and the CLI selector.
- Task 2 provides the stage/subtask totals from the real scanning pipeline.
- Task 3 renders only to stderr, serializes concurrent updates, and makes observability non-fatal.
- Interface names and parameters are consistent across tasks; no placeholders remain.
