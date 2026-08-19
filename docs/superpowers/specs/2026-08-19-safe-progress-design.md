# Safe CLI Progress Design

## Goal

Keep the duplicate scanner read-only while making a scan understandable in a
terminal. The scanner must expose its current phase, stage totals, completed
work, bytes hashed, recoverable errors, and a final summary without corrupting
the JSONL report consumed by scripts.

## CLI contract

Add `--progress auto|always|never`.

- `auto` is the default. It renders an updating display only when stderr is an
  interactive terminal; redirected stderr receives no status noise.
- `always` renders line-oriented progress even when stderr is redirected,
  useful for logs and debugging.
- `never` disables all progress output.

The normal JSONL report remains exclusively on stdout or the explicitly
requested output file. Progress is exclusively written to stderr.

`--output <path>` will create a new report file only. If the destination
already exists, the command fails before scanning and does not overwrite it.
This prevents an accidental report-path typo from destroying unrelated data.

## Progress model

The pipeline receives an optional progress observer through a narrow,
read-only port. It publishes ordered phases:

1. `enumerating`: indeterminate count with files and metadata bytes found.
2. `filtering`: a completed metadata stage and the number of equal-size
   candidates.
3. `sampling`: `done/total` equal-size candidates.
4. `hashing`: `done/total` full-hash candidates, completed bytes and errors.
5. `grouping`: a short finalization phase.
6. `complete`: elapsed time, duplicates, collisions, skipped entries, and
   recoverable errors.

The console presenter uses a concise status line plus a 20-cell progress bar
for determinate stages. Each update includes a child/subtask label (for
example, `Hashing 7/20`) and makes no claims about an unknown total while
enumerating.

## Safety and concurrency

Progress failures are deliberately non-fatal: losing stderr must not change a
read-only scan result. Full-hash workers only increment synchronized counters;
the presenter serializes terminal writes so concurrent workers cannot corrupt
the display. No progress callback can mutate scanned files.

## Tests

Tests will first establish that an existing output path is rejected without
altering it. They will also exercise phase sequencing, determinate totals,
sample/full-hash completion, and the no-op observer. Integration coverage will
prove that progress is separated from JSONL output. The full test suite and a
ReleaseSafe build will run in the isolated worktree.
