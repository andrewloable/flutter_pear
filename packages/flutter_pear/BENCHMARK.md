# E5.1 — Platform-channel throughput benchmark + bulk-transport decision record

Harness: `packages/flutter_pear_example/integration_test/bulk_transport_benchmark_test.dart`. Run with:

```bash
cd packages/flutter_pear_example
flutter test integration_test/bulk_transport_benchmark_test.dart -d <device>
```

Measures round-trip throughput for 1KB/64KB/1MB/16MB payloads over the two candidate bulk-transport paths, both riding the same `BasicMessageChannel`:

- **in-channel** — `debug.echo` (E5.1, debug-only): base64-encode the payload into a JSON RPC request, get it echoed straight back. No JS-side work beyond the RPC envelope itself.
- **file-path** — `bulk.writeFile` (E4.4): base64-encode the payload into a JSON RPC request, the worklet writes it to its own private storage and returns a path; Dart reads the file straight back with `dart:io`.

## Results

Two runs, Android emulator (arm64-v8a, API level per the project's `flutter_pear_example` default), debug build:

| Size | in-channel (run 1) | file-path (run 1) | in-channel (run 2) | file-path (run 2) |
|---|---|---|---|---|
| 1KB | 0.02 MB/s (48ms) | 0.05 MB/s (21ms) | 0.34 MB/s (2ms) | 0.14 MB/s (6ms) |
| 64KB | 8.62 MB/s (7ms) | 3.39 MB/s (18ms) | 3.82 MB/s (16ms) | 3.04 MB/s (20ms) |
| 1MB | 13.84 MB/s (72ms) | 28.45 MB/s (35ms) | 11.31 MB/s (88ms) | 21.96 MB/s (45ms) |
| 16MB | 5.94 MB/s (2693ms) | 15.48 MB/s (1033ms) | 6.05 MB/s (2644ms) | 15.30 MB/s (1045ms) |

## Reading the numbers

- **1KB**: noise-dominated (single-digit-to-double-digit millisecond range, first-call JIT/GC warm-up swamps the actual transport cost) — not meaningful at this size either way.
- **64KB**: roughly comparable, in-channel edges ahead or ties — small enough that JSON/base64 overhead and file I/O syscall overhead are close.
- **1MB**: file-path pulls ahead ~2x (22–28 MB/s vs 11–14 MB/s) and stays consistent across both runs.
- **16MB**: file-path is ~2.5x faster (15.3–15.5 MB/s vs ~6 MB/s) — and the *absolute* gap matters for UX: a single 16MB transfer takes ~1.0s via file-path vs ~2.65s in-channel, reproducibly.

The pattern is consistent across both runs: the bigger the payload, the more file-path wins, which is exactly the shape you'd expect (file I/O throughput scales better than repeatedly re-encoding/re-decoding an ever-larger base64 JSON string through the RPC envelope) and exactly the payload range Hyperdrive (E5.5) actually needs — real files, not 1KB control messages.

## Decision

**LOCKED default confirmed: file-path.** The numbers do not argue otherwise — they actively support the already-locked default (codex #4). No in-channel chunked-streaming primitive is justified by this evidence; `PearFrameType.raw` stays reserved (see `schema.dart`).

**PearDrive (E5.5)** should default file transfers through the `bulk.writeFile`-style seam (or an equivalent Hyperdrive-specific path/stream primitive built the same way), matching `PearMethod.bulkWriteFile`'s existing pattern: the whole payload still travels as one JSON request today (no in-channel chunking machinery), but the *destination* is a file the caller reads directly, avoiding the repeated JSON/base64 inflation on every future access that an in-response-payload design would incur.

## What's deferred

This benchmark ran on **emulator only** — per this project's standing "automated tests first, hardware last" decision, the physical-device leg (this ticket's STEPS item 2: "Run on one physical device + one emulator") is deferred and tracked centrally in `flutter_pear-doi` alongside E1.5/E5.2/E5.3's hardware legs. The emulator numbers above are real, reproducible evidence, not synthetic — a physical device is expected to show the same qualitative shape (file I/O beating repeated JSON/base64 inflation at scale) with different absolute numbers; if the physical-device pass ever contradicts this decision, revisit it there rather than assuming this record is final.
