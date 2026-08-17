# Duplicate Scanner Design

## Goal

Build a Windows-first, cross-platform CLI that finds byte-identical files even when their names differ. It must be read-only: it never deletes, moves, renames, executes, or modifies scanned files.

## User-facing contract

```text
dupe-scan <root>... [--output <path>] [--workers auto|N]
```

- Roots are scanned recursively.
- JSON Lines is emitted to stdout by default. `--output` writes the same report to a user-provided new or existing report path.
- The report contains duplicate groups, same-name-and-size files whose full hashes differ, recoverable errors, timing metrics, and scan configuration.
- No action command exists in this release.

## Architecture

The core is portable and uses ports/adapters. Domain and pipeline code receive file metadata, candidate groups, file bytes, and report sinks through narrow interfaces. Platform adapters provide the filesystem traversal and volume classification.

```text
CLI
  -> scan pipeline
      -> metadata walker port
      -> size buckets
      -> sample fingerprint workers
      -> full BLAKE3 hash workers
      -> duplicate and collision grouping
      -> JSONL reporter port
```

### Domain

- `FileRecord`: absolute path, normalized comparison name, logical size, modified time, volume key, and safe file identity fields.
- `Candidate`: a `FileRecord` that shares its size with at least one other file.
- `Fingerprint`: the size plus fixed first/last sample hashes. It narrows full-hash work but never decides duplication by itself.
- `ContentHash`: the complete BLAKE3 digest.
- `DuplicateGroup`: at least two records with the same complete digest.
- `NameCollisionGroup`: at least two records with the same comparison name and size but different complete digests. This explicitly surfaces corrupted or revised copies rather than calling them duplicates.

### Ports

- `DirectoryWalker`: emits metadata records and recoverable traversal errors.
- `FileReader`: reads a file in bounded reusable buffers for sampling and full hashing.
- `Hasher`: hashes byte streams and samples.
- `Reporter`: writes JSONL records and a final summary.
- `VolumeClassifier`: reports whether a root is local fixed, removable, network, or unknown.

### Adapters

- Windows walker: `FindFirstFileExW` / `FindNextFileW` with UTF-16 paths and `FIND_FIRST_EX_LARGE_FETCH`; it uses returned metadata rather than opening every file merely to learn its size.
- Windows volume adapter: classifies root drives with Win32 volume APIs, allowing conservative defaults for removable and network media.
- Portable walker: standard Zig filesystem traversal for non-Windows systems.
- Hash adapter: Zig BLAKE3 in the initial release. It stays behind the `Hasher` port so an FFI implementation can be benchmarked and substituted later without touching orchestration.
- JSONL adapter: buffered stdout or an explicitly requested report file.

## Pipeline and performance policy

1. Enumerate metadata iteratively, without following reparse points, symlinks, or junctions.
2. Bucket records by exact logical file size. Singleton size buckets stop here.
3. Compute first/last 64 KiB fingerprints for every remaining candidate. Candidates must match both fingerprints before full hashing.
4. Compute a complete BLAKE3 digest for each remaining candidate.
5. Group identical full digests as duplicates. Group same normalized name plus size with different full digests as name collisions.

Hash workers read one file sequentially at a time with reusable buffers. Worker counts are bounded, not tied directly to CPU cores:

- removable or network roots: one heavy reader;
- local fixed roots: two heavy readers by default;
- `--workers N`: an explicit global upper bound;
- `--workers auto`: uses the policy above and never nests worker pools.

The first version intentionally does not use raw IOCP. This workload is expected to be storage-bound, and bounded sequential reads are simpler and safer. A later Windows benchmark may justify a `FileReader` adapter based on thread-pool I/O or raw IOCP.

## Safety rules

- Read-only scan of user files. The process never calls file deletion, move, rename, process-launch, or archive-extraction APIs.
- Reparse points, symlinks, and junctions are reported as skipped by default.
- Long Windows paths are handled as UTF-16 with extended-path support when needed.
- `AccessDenied`, sharing violations, disappearing files, malformed paths, and read failures are reported as structured errors; they do not abort the whole scan.
- The scanner does not silently infer that files with equal names or sizes are duplicates. Full hashes are required.
- Report writing is opt-in as a file; stdout is the default.

## Testing

- Unit tests cover size bucketing, sample gating, full-hash grouping, same-name/different-hash collision reporting, long-path normalization, skipped reparse-point policy, and JSONL output.
- Integration tests construct a temporary tree containing identical files with different names, same-name files with different bytes, unique files, inaccessible/missing-path simulation boundaries, and nested directories.
- Windows-specific tests validate UTF-16 conversion and the Windows adapter's metadata mapping without scanning user data.

## Validation and benchmarks

- Build and test with Zig 0.16.0 in `ReleaseSafe` during correctness work and `ReleaseFast` for benchmarks.
- Benchmark mixed datasets: many small files, few large files, deep trees, multiple roots, and a removable-volume fixture when available.
- Record wall-clock time, files per second, bytes per second, selected worker count, candidate reduction after each pipeline stage, and approximate peak memory.
- Compare one, two, and four workers on the same physical disk before changing defaults.

## Non-goals for this release

- Deletion, move, rename, deduplication by hard links, or any automated cleanup.
- Archive extraction or scanning inside archives.
- Background service, GUI, database, cloud upload, or persistent indexing.
- Raw IOCP implementation before benchmarks show it outperforms the bounded synchronous reader.
