# Benchmark protocol

The scanner is read-only. Supply a test root explicitly; it never assumes
`Downloads`, a backup disk, or a removable drive. Without `--output`, JSONL is
written only to standard output.

Build the benchmark binary in the mode used for performance comparisons:

```powershell
& 'C:\Users\User\AppData\Local\mise\installs\zig\0.16.0\zig.exe' build bench -Doptimize=ReleaseFast --cache-dir zig-cache --global-cache-dir .zig-global-cache -- .\tests\fixtures --backend auto --workers auto
```

Use a project-owned fixture or a dedicated disposable benchmark directory.
Measure each command at least three times after recording the storage type and
whether the cache is cold or warm:

```powershell
zig build bench -Doptimize=ReleaseFast -- <root> --backend auto --workers 1
zig build bench -Doptimize=ReleaseFast -- <root> --backend auto --workers 2
zig build bench -Doptimize=ReleaseFast -- <root> --backend auto --workers 4
zig build bench -Doptimize=ReleaseFast -- <root> --backend auto --workers auto
```

The suite should include many small files, a few large files, a deep tree,
mixed candidate sizes, multiple volumes when available, denied paths, and
files that disappear during a scan. Record wall time, files/s, bytes/s,
effective readers from `worker_plan`, and peak memory.

Accept an optimization only if it preserves identical duplicate/collision
results, reports recoverable errors instead of aborting unrelated work, makes
no input mutation, and improves the same dataset under the same cache state.
IOCP, USN Journal, raw FFI, and adaptive worker counts are intentionally out
of scope until this protocol demonstrates a need.
