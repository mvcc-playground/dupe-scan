# Native Duplicate Scanner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a strictly read-only Zig 0.16 command-line scanner that finds byte-identical files, with a portable core and a high-throughput Win32 adapter.

**Architecture:** The pipeline narrows a metadata stream through size buckets, two fixed samples, and full BLAKE3 hashes. Walkers, readers, drive classification, and reporting are ports. On Windows, the adapter enumerates with Win32 metadata calls and reads regular candidate files through sequential read handles; a volume-aware scheduler bounds concurrent full reads.

**Tech Stack:** Zig 0.16.0 via mise; Zig standard library BLAKE3; Win32 `FindFirstFileExW`, `FindNextFileW`, `CreateFileW`, `ReadFile`, and `GetDriveTypeW`; no third-party package or FFI.

## Global Constraints

- Use exactly Zig `0.16.0` selected by `mise.toml`.
- The scanner must never delete, move, rename, execute, lock, alter, or write to a scanned input file.
- It may write only an explicitly requested `--output <path>` JSONL report; stdout is the default output.
- Full BLAKE3 digest equality is required before a duplicate group is emitted.
- Skip and report reparse points, symbolic links, and junctions; never recurse through them.
- The Win32 adapter uses `FindFirstFileExW` with `FIND_FIRST_EX_LARGE_FETCH` and `CreateFileW` with `FILE_FLAG_SEQUENTIAL_SCAN`.
- Auto scheduling gives a fixed drive two full-file readers and removable, remote, or unknown drives one; `--workers N` remains a global cap.
- This release has no persistent database, USN Journal, IOCP, FFI, archive extraction, cleanup command, or mutation action.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `mise.toml` | Pins Zig version. |
| `build.zig`, `build.zig.zon` | Defines executable, unit/integration tests, and a safe benchmark run step. |
| `src/domain.zig` | Immutable scan data, errors, metrics, backend and drive enums. |
| `src/ports.zig` | Narrow read-only interfaces for walker, reader, classifier, and reporter. |
| `src/pipeline.zig` | Candidate reduction and verified grouping. |
| `src/scheduler.zig` | Fair, bounded per-volume work allocation. |
| `src/report_jsonl.zig` | One JSON object per event and final summary. |
| `src/platform/portable.zig` | Standard-library fallback traversal and reading. |
| `src/platform/windows.zig` | Win32 UTF-16 traversal, sequential reading, and drive type. |
| `src/platform/select.zig` | Resolves `auto`, `portable`, and `win32` without leaking platform APIs. |
| `src/main.zig` | Parses the read-only CLI and supplies adapters to the pipeline. |
| `src/test_support.zig` | Owns isolated temporary test trees and in-memory reports. |
| `tests/*.zig` | Domain, pipeline, integration, scheduler, and Windows adapter coverage. |
| `docs/benchmark.md` | Reproducible performance protocol and change gates. |

### Task 1: Bootstrap the project and immutable read-only domain

**Files:**
- Create: `mise.toml`, `build.zig`, `build.zig.zon`, `src/root.zig`, `src/domain.zig`, `src/ports.zig`, `tests/domain_test.zig`

**Interfaces:**
- Produces `domain.FileRecord`, `domain.Fingerprint`, `domain.ContentHash`, `domain.DriveClass`, `domain.Backend`, `domain.ScanError`, `domain.Metrics`, and `domain.autoReaders`.
- Produces read-only `ports.DirectoryWalker`, `ports.FileReader`, `ports.VolumeClassifier`, and `ports.Reporter` contracts.

- [ ] **Step 1: Write failing domain tests**

```zig
const std = @import("std");
const domain = @import("domain");

test "content hashes require exact equality" {
    const a = domain.ContentHash{ .bytes = [_]u8{7} ** 32 };
    const b = domain.ContentHash{ .bytes = [_]u8{7} ** 32 };
    const c = domain.ContentHash{ .bytes = [_]u8{8} ** 32 };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "automatic reader count protects removable and remote drives" {
    try std.testing.expectEqual(@as(u8, 2), domain.autoReaders(.fixed));
    try std.testing.expectEqual(@as(u8, 1), domain.autoReaders(.removable));
    try std.testing.expectEqual(@as(u8, 1), domain.autoReaders(.remote));
}
```

- [ ] **Step 2: Run the test and confirm the bootstrap is missing**

Run: `mise exec -- zig build test --summary all`

Expected: FAIL because the project and `domain` module do not yet exist.

- [ ] **Step 3: Implement the minimum domain**

```toml
# mise.toml
[tools]
zig = "0.16.0"
```

```zig
// src/domain.zig
const std = @import("std");
pub const DriveClass = enum { fixed, removable, remote, unknown };
pub const Backend = enum { auto, portable, win32 };
pub const ContentHash = struct {
    bytes: [32]u8,
    pub fn eql(self: ContentHash, other: ContentHash) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};
pub fn autoReaders(class: DriveClass) u8 {
    return if (class == .fixed) 2 else 1;
}
```

Add `FileRecord` (absolute path, normalized name, size, timestamp, `VolumeKey`), `Fingerprint` (first/last 32-byte hashes), tagged `ScanError`, and zero-initialized `Metrics`. The port contracts expose only `walk`, `readAtMost`, `readAll`, `classify`, `event`, and `finish` methods; do not define an action/mutation method.

- [ ] **Step 4: Wire the test build and prove it passes**

Run: `mise exec -- zig build test --summary all`

Expected: PASS with both tests; build artefacts remain untracked.

- [ ] **Step 5: Commit the bootstrap**

```powershell
git add mise.toml build.zig build.zig.zon src/root.zig src/domain.zig src/ports.zig tests/domain_test.zig
git commit -m "feat: bootstrap read-only scanner domain"
```

### Task 2: Implement deterministic candidate reduction and verified groups

**Files:**
- Create: `src/pipeline.zig`, `tests/pipeline_test.zig`
- Modify: `src/domain.zig`, `src/root.zig`

**Interfaces:**
- Consumes `domain.FileRecord`, `domain.Fingerprint`, `domain.ContentHash`, `domain.Metrics`, and `ports.FileReader`.
- Produces `pipeline.bucketBySize`, `pipeline.sampleMatches`, `pipeline.buildGroups`, `pipeline.HashedRecord`, and `pipeline.Grouping`.

- [ ] **Step 1: Write failing reduction/grouping tests**

```zig
test "single-size records never reach sample or full hashing" {
    const records = [_]domain.FileRecord{ fixture("a", 10), fixture("b", 10), fixture("c", 11) };
    var buckets = try pipeline.bucketBySize(std.testing.allocator, &records);
    defer buckets.deinit();
    try std.testing.expectEqual(@as(usize, 2), buckets.candidateFileCount());
}

test "same name and size with unequal full digest is a collision" {
    var groups = try pipeline.buildGroups(std.testing.allocator, &[_]pipeline.HashedRecord{
        hashed("one/report.bin", 4, 1), hashed("two/report.bin", 4, 2),
    });
    defer groups.deinit();
    try std.testing.expectEqual(@as(usize, 0), groups.duplicates.len);
    try std.testing.expectEqual(@as(usize, 1), groups.name_collisions.len);
}

test "equal full digest with different names is one duplicate group" {
    var groups = try pipeline.buildGroups(std.testing.allocator, &[_]pipeline.HashedRecord{
        hashed("one/a.bin", 4, 9), hashed("two/b.bin", 4, 9),
    });
    defer groups.deinit();
    try std.testing.expectEqual(@as(usize, 1), groups.duplicates.len);
}
```

- [ ] **Step 2: Run the new tests and confirm failure**

Run: `mise exec -- zig build test --summary all`

Expected: FAIL because `pipeline` and the fixture helpers do not exist.

- [ ] **Step 3: Implement the pure pipeline**

```zig
pub const HashedRecord = struct {
    record: domain.FileRecord,
    digest: domain.ContentHash,
};
pub fn bucketBySize(allocator: std.mem.Allocator, records: []const domain.FileRecord) !SizeBuckets;
pub fn sampleMatches(a: domain.Fingerprint, b: domain.Fingerprint) bool {
    return std.mem.eql(u8, &a.first, &b.first) and std.mem.eql(u8, &a.last, &b.last);
}
pub fn buildGroups(allocator: std.mem.Allocator, hashed: []const HashedRecord) !Grouping;
```

Index exact sizes with `std.AutoHashMap(u64, std.ArrayListUnmanaged(usize))`, retaining indexes into the original records instead of copying paths. Sort candidates deterministically by `(size, first sample, last sample, path)`. Full-hash only records that match both sample hashes. Retain a duplicate digest group only if it has at least two records; form collisions from all successful full hashes with same normalized name and size but different digest. Update `Metrics` at every stage.

- [ ] **Step 4: Run all tests**

Run: `mise exec -- zig build test --summary all`

Expected: PASS; names and sample matches never prove duplication, only full digest equality does.

- [ ] **Step 5: Commit the pipeline**

```powershell
git add src/domain.zig src/root.zig src/pipeline.zig tests/pipeline_test.zig
git commit -m "feat: add verified duplicate grouping pipeline"
```

### Task 3: Add portable adapters, JSONL, and the safe CLI

**Files:**
- Create: `src/platform/portable.zig`, `src/platform/select.zig`, `src/report_jsonl.zig`, `src/main.zig`, `src/test_support.zig`, `tests/integration_test.zig`
- Modify: `build.zig`

**Interfaces:**
- Produces `portable.AdapterSet`, `report_jsonl.JsonlReporter`, and `main.parseArgs`.
- `main.parseArgs(args: []const []const u8) !domain.ScanRequest` accepts roots, `--output`, `--workers auto|N`, and `--backend auto|portable|win32` only.

- [ ] **Step 1: Write failing integration and parser tests**

```zig
test "portable scan emits duplicate collision and summary JSONL" {
    var tree = try support.TempTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.write("one/alpha.bin", "same bytes");
    try tree.write("two/renamed.bin", "same bytes");
    try tree.write("three/report.bin", "old!");
    try tree.write("four/report.bin", "new!");
    const text = try support.scanPortableToOwnedJsonl(std.testing.allocator, tree.root_path);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "duplicate_group") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "name_collision_group") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "scan_summary") != null);
}
test "parser rejects every mutation flag" {
    try std.testing.expectError(error.UnknownArgument, main.parseArgs(&.{ "dupe-scan", "C:\\\\scan", "--delete" }));
}
```

- [ ] **Step 2: Run integration test and confirm failure**

Run: `mise exec -- zig build test --summary all`

Expected: FAIL because the adapter, reporter, parser, and test tree do not exist.

- [ ] **Step 3: Implement portable scanning and reporting**

```zig
pub const EventKind = enum { scan_started, skipped_entry, recoverable_error, duplicate_group, name_collision_group, scan_summary };
pub fn emitDuplicateGroup(self: *JsonlReporter, group: domain.DuplicateGroup) !void;
pub fn emitCollisionGroup(self: *JsonlReporter, group: domain.NameCollisionGroup) !void;
pub fn finish(self: *JsonlReporter, result: domain.ScanResult) !void;
```

Walk iteratively through the Zig standard library. Read only regular candidate files, stream full hashes with a reused `256 * 1024` byte worker buffer, and create samples from the first/last 64 KiB. A disappearing, changed, denied, or malformed file emits a tagged recoverable error and does not stop unrelated work. Emit a standalone JSON object per line with `schema_version`, `event`, paths, sizes, errors, groups, and final metrics. Use buffered stdout until an explicit output path is requested.

- [ ] **Step 4: Verify portable operation and the CLI boundary**

Run: `mise exec -- zig build test --summary all`

Expected: PASS; temporary input files retain their original bytes.

Run: `mise exec -- zig build run -- --help`

Expected: usage has only roots, `--output`, `--workers`, and `--backend`; it has no cleanup, delete, move, rename, repair, or execute command.

- [ ] **Step 5: Commit portable operation**

```powershell
git add build.zig src/main.zig src/platform/portable.zig src/platform/select.zig src/report_jsonl.zig src/test_support.zig tests/integration_test.zig
git commit -m "feat: add portable read-only scan command"
```

### Task 4: Add Win32 enumeration, sequential reader, and volume scheduler

**Files:**
- Create: `src/platform/windows.zig`, `src/scheduler.zig`, `tests/scheduler_test.zig`, `tests/windows_adapter_test.zig`
- Modify: `src/domain.zig`, `src/pipeline.zig`, `src/platform/select.zig`

**Interfaces:**
- Produces `windows.walk`, `windows.readSequential`, `windows.classifyRoot`, `windows.mapAttributes`, `windows.toSearchPath`, `scheduler.plan`, and `scheduler.next`.
- `scheduler.plan(allocator, queues: []const scheduler.VolumeQueue, ceiling: domain.WorkerLimit) !scheduler.Plan` returns a fair allocation whose sum never exceeds the configured ceiling.

- [ ] **Step 1: Write failing scheduler and Windows mapping tests**

```zig
test "scheduler reserves a removable reader before a fixed-drive second reader" {
    var plan = try scheduler.plan(std.testing.allocator, &[_]scheduler.VolumeQueue{
        .{ .key = 1, .class = .fixed, .pending = 50 },
        .{ .key = 2, .class = .removable, .pending = 2 },
    }, .{ .explicit = 3 });
    defer plan.deinit();
    try std.testing.expectEqual(@as(u8, 2), plan.readerCountFor(1));
    try std.testing.expectEqual(@as(u8, 1), plan.readerCountFor(2));
}
test "Win32 mapping skips a reparse point before recursion" {
    try std.testing.expectEqual(windows.EntryKind.skip_reparse_point,
        windows.mapAttributes(windows.FILE_ATTRIBUTE_REPARSE_POINT, false));
}
test "Win32 UTF-16 conversion yields a terminated search path" {
    const path = try windows.toSearchPath(std.testing.allocator, "C:\\\\dados\\arquivo.txt");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqual(@as(u16, 0), path[path.len - 1]);
}
```

- [ ] **Step 2: Run the tests and confirm failure**

Run: `mise exec -- zig build test --summary all`

Expected: FAIL because scheduler and Win32 exports do not exist.

- [ ] **Step 3: Implement the native fast path**

```zig
pub extern "kernel32" fn FindFirstFileExW(
    name: [*:0]const u16, info_level: u32, data: *WIN32_FIND_DATAW,
    search_op: u32, filter: ?*anyopaque, flags: u32,
) callconv(.winapi) isize;
pub extern "kernel32" fn CreateFileW(
    name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque,
    disposition: u32, flags: u32, template: ?isize,
) callconv(.winapi) isize;
```

Call `FindFirstFileExW` with `FindExInfoBasic`, `FindExSearchNameMatch`, and `FIND_FIRST_EX_LARGE_FETCH`. Validate/convert absolute paths to UTF-16, add extended `\\\\?\\` form only when necessary, reject `.`/`..`, skip `FILE_ATTRIBUTE_REPARSE_POINT`, and use returned high/low size fields without per-entry opens. Open full-hash candidates with `GENERIC_READ`, `FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE`, `OPEN_EXISTING`, and `FILE_FLAG_SEQUENTIAL_SCAN`; never use a write access mask, lock, `FILE_FLAG_NO_BUFFERING`, IOCP, or USN. Detect changed files by comparing streamed byte count with enumerated size.

Implement `GetDriveTypeW` mapping and a two-pass scheduler: give each nonempty volume one reader while capacity remains, then give fixed volumes a second reader; select jobs round-robin across queues. Compile the Win32 module only under `builtin.os.tag == .windows`; `--backend win32` gives a clear unsupported-backend error elsewhere.

- [ ] **Step 4: Run the platform-safe suite**

Run: `mise exec -- zig build test --summary all`

Expected: PASS on Windows, including scheduler/adapter tests; non-Windows compilation selects portable code and guards the Windows tests.

- [ ] **Step 5: Commit native functionality**

```powershell
git add src/domain.zig src/pipeline.zig src/scheduler.zig src/platform/select.zig src/platform/windows.zig tests/scheduler_test.zig tests/windows_adapter_test.zig
git commit -m "feat: add bounded Win32 scanning path"
```

### Task 5: Add metrics, benchmarks, and release verification

**Files:**
- Create: `docs/benchmark.md`
- Modify: `build.zig`, `src/domain.zig`, `src/pipeline.zig`, `src/report_jsonl.zig`, `tests/integration_test.zig`

**Interfaces:**
- Produces final `scan_summary` JSON containing backend, volume classes, reader allocation, elapsed time, file/byte totals, candidate reductions, duplicate/collision totals, skipped entries, and recoverable errors.

- [ ] **Step 1: Write the failing summary assertion**

```zig
test "summary contains backend worker plan and all candidate counters" {
    const text = try support.scanPortableToOwnedJsonl(std.testing.allocator, fixture_root);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"backend\":\"portable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"size_candidates\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"sample_candidates\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"full_hashes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"worker_plan\"") != null);
}
```

- [ ] **Step 2: Run it and confirm failure**

Run: `mise exec -- zig build test --summary all`

Expected: FAIL because at least one required field is absent.

- [ ] **Step 3: Emit evidence and document future optimization gates**

```zig
pub const Metrics = struct {
    files_enumerated: u64 = 0, bytes_enumerated: u64 = 0,
    size_candidates: u64 = 0, sample_candidates: u64 = 0,
    full_hashes: u64 = 0, bytes_read: u64 = 0,
    skipped_entries: u64 = 0, recoverable_errors: u64 = 0,
    elapsed_ns: u64 = 0,
};
```

Capture monotonic elapsed time around each scan. Emit per-volume `{ key, drive_class, pending_jobs, readers }`. Add a `bench` build step that runs `ReleaseFast` only on roots explicitly supplied at the command line and writes no report without `--output`. In `docs/benchmark.md`, specify small-file, large-file, deep-tree, and multi-volume datasets; exact one/two/four-worker commands; warm/cold cache conditions; and a gate requiring equal result correctness, zero mutations, and measured gain before adding FFI or IOCP.

- [ ] **Step 4: Verify correctness and release build**

Run: `mise exec -- zig build test -Doptimize=ReleaseSafe --summary all`

Expected: PASS for every unit, integration, scheduler, and Win32 adapter test.

Run: `mise exec -- zig build -Doptimize=ReleaseSafe --summary all`

Expected: PASS with no third-party dependency.

- [ ] **Step 5: Benchmark only a project-owned fixture**

Run: `mise exec -- zig build bench -Doptimize=ReleaseFast -- .\tests\fixtures --backend auto --workers auto`

Expected: JSONL summary includes the required evidence and zero mutation action; no Downloads or backup folder is an implicit target.

- [ ] **Step 6: Commit the final observability work**

```powershell
git add build.zig docs/benchmark.md src/domain.zig src/pipeline.zig src/report_jsonl.zig tests/integration_test.zig
git commit -m "docs: define safe duplicate scan benchmarks"
```

## Self-Review

Spec coverage: Tasks 1–3 enforce read-only behavior, full digest proof, portable fallback, structured errors, and JSONL. Task 4 covers UTF-16, reparse skip policy, fast Win32 enumeration, sequential reads, and conservative volume scheduling. Task 5 covers the required measurements and benchmark gates. The global constraints explicitly exclude USN, persistence, IOCP, FFI, and cleanup.

Placeholder scan: The red-flag search found no unfinished markers, delegated error-handling instruction, or unspecified test. Each task gives the exact files, interface, failing test, implementation behavior, test command, and commit.

Type consistency: Task 1 introduces all `domain` and `ports` types. Task 2 introduces `pipeline.HashedRecord` and `Grouping`. Task 4 introduces `scheduler.VolumeQueue` and `Plan`; Task 5 reports those allocations without changing their interface.

## Execution Handoff

Execute Tasks 1–5 inline in order, using test-driven development for each implementation step and validating before every completion claim.
