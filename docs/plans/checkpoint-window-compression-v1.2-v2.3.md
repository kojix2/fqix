# fqix Checkpoint-Window Compression Plan: exact v2.3 / sparse v1.2

This plan adds **compressed zran checkpoint windows** to both index kinds. It is
the "compressed windows" axis left open in
`exact-index-compaction-v2.1-v2.2.md` (Remaining work, item 4). The current
format and user behavior are documented in:

- `docs/usage.md`
- `docs/how-it-works.md`
- `docs/fqix-format.md`

The user contract does not change:

```sh
fqix index reads.fastq.gz            # sparse, now writes v1.2
fqix index --mode exact reads.fastq.gz   # exact, now writes v2.3
fqix get reads.fastq.gz read_id
```

All current guarantees (arbitrary order in exact, sorted order in sparse,
duplicates, `--all/--first/--count/--unique/--list`, stale protection, forced
collisions) are preserved. Only the on-disk window section and its checkpoint
metadata change.

## Motivation

Both index kinds store one 32 KiB zran restart window per checkpoint, raw and
uncompressed. The window section size is `ncheckpoints * 32768` and is the
dominant term whenever the lookup table is small:

- **sparse** indexes are almost entirely windows (the name table is one anchor
  per `--name-interval` records).
- **exact long-read** indexes are window-dominated.
- **exact short-read** indexes are lookup-table-dominated (`~14 B/record`), so
  window compression helps them only modestly.

The reference `zran.c` (and current fqix) store windows raw. This is not
universal: `indexed_gzip` also stores raw windows, but `gztool` deflate-compresses
each window, which is why its index is ~0.33 % of the gzip file at a 10 MiB span.
We adopt the same idea: deflate each window independently so it stays O(1)
addressable, and decompress one window per lookup.

## Measured window compressibility

`benchmark/window_compression.cr` deflates each stored window independently
(BEST_COMPRESSION) and sums the result. Per-window vs whole-block deflate differ
by only 1–2.5 percentage points, confirming independent per-window compression
keeps random access at near-zero size cost.

| dataset | windows raw | per-window deflate | ratio | whole-block (lower bound) |
| --- | ---: | ---: | ---: | ---: |
| DRR014639_1 (real 76 bp, N-heavy) | 28.7 MB | 5.1 MB | **5.64x** | 16.6 % of raw |
| illumina synthetic 150 bp | 2.7 MB | 0.9 MB | **2.90x** | 32.0 % of raw |
| longread 10 kbp | 1.2 MB | 0.4 MB | **2.91x** | 32.2 % of raw |

Some windows compress to as little as 46 bytes (low-complexity / leading
checkpoints); diverse sequence windows land near 34 % of raw (~11 KB).

### Expected index effect (4 MiB span)

| index | before | windows | after | as % of `.gz` |
| --- | ---: | ---: | ---: | ---: |
| DRR014639_1 sparse v1.1 | 30.7 MB | 30.1→5.1 MB | **~6.0 MB** | 4.5 % → **0.9 %** |
| longread exact v2.2 | 1.39 MB | 1.28→0.44 MB | **~0.56 MB** | 2.6 % → **1.0 %** |
| illumina 1M exact v2.2 | 17.2 MB | 2.82→0.97 MB | **~15.4 MB** | 14.6 % → **13.0 %** |
| DRR014639_1 exact | 227 MB | 30.1→5.1 MB | **~203 MB** | 34.7 % → **29.7 %** |

Honest framing for docs: **big win for sparse and long-read (window-dominated)
indexes; modest win for short-read exact, where the `~14 B/record` lookup table
remains the floor.** Window compression is orthogonal to lookup-table size and to
`--checkpoint-span`.

## Design

### Per-window deflate, independently addressable

Each checkpoint window is stored as a raw DEFLATE stream (Crystal
`Compress::Deflate`, no zlib/gzip header) of its **valid dictionary bytes only**.
The dictionary length is exactly `CheckpointMeta.have`: `make_dict` builds a
`have`-byte dictionary (`have = min(out_seen - member_start, 32768)`) and `zran.cr`
primes inflate with `inflateSetDictionary(window, have)`. So we compress and
restore exactly `have` bytes instead of the padded 32768. Old formats stored a
fixed 32768 stride; new formats store variable-length compressed blobs
concatenated at `windows_offset`.

Window `id` lives at `windows_offset + sum(window_clen[0..id-1])` and is
`window_clen[id]` bytes; it inflates to `have[id]` bytes. The cumulative offsets
are computed once at index-read time from the in-memory checkpoint metadata array,
so `WindowStore#get(id)` stays O(1): seek, read `clen`, inflate to `have`.

**The `have == 0` checkpoint.** Every index begins with an initial checkpoint at
`out_offset == 0` with `have == 0` and an empty window (`zran.cr` writes
`write_checkpoint(output, 0, 0, 0, Bytes.empty)`; extraction for `out_offset == 0`
uses the gzip header directly and never primes a dictionary). For such a window we
store `clen == 0` (no bytes) and the store returns `Bytes.empty` without inflating.
`clen == 0` is therefore valid **iff** `have == 0`.

### Checkpoint metadata change (25 bytes)

`CheckpointMeta` gains a compressed-length field. Both new kinds share it.

| Offset | Size | Type | Field | Meaning |
| ---: | ---: | --- | --- | --- |
| 0 | 8 | u64 | out_offset | Uncompressed offset at the checkpoint |
| 8 | 8 | u64 | in_offset | Compressed file offset |
| 16 | 1 | u8 | bits | Primed bits for raw inflate |
| 17 | 4 | u32 | have | Dictionary byte count (inflated window length) |
| 21 | 4 | u32 | window_clen | Compressed window byte length |

`CHECKPOINT_META_SIZE` becomes 25 for v1.2 / v2.3. The 21-byte entry is retained
for reading v1.0/v1.1 and v2.1/v2.2.

`window_clen` is purely an on-disk concern. The in-memory `CheckpointMeta` struct
(and `CheckpointMeta.from_checkpoint`) is left unchanged; the reader pulls the
per-window `clen` into a side array of window descriptors used only to build the
window store, and the writer computes `clen` locally. Nothing carries a meaningless
`clen` through the build-time `Index`.

### Layout (unchanged except the window section)

```text
# sparse v1.2                # exact v2.3
header                       header
source path bytes            source path bytes
checkpoint metadata (25 B)   mphf blob
sparse name anchor table     slot table
compressed windows           overflow table
                             checkpoint metadata (25 B)
                             compressed windows
```

Headers keep their current size and fields (v1 = 88 B, v2 = 128 B). The
`flags`/`reserved` fields stay `0`; the window encoding is selected by version
`minor`, not by a header flag, matching how the reader already dispatches.

### WindowStore

- `MemoryWindowStore` (build-time, raw windows) is unchanged.
- `FileWindowStore` (raw, stride-32768) is unchanged and still serves
  v1.0/v1.1/v2.1/v2.2 indexes.
- New `CompressedFileWindowStore`: holds `path`, absolute `windows_offset`, and a
  per-window descriptor array `{rel_offset, clen, have}` built by the reader.
  `get(id)` returns `Bytes.empty` when `have == 0`; otherwise it seeks, reads
  `clen` bytes, raw-inflates to exactly `have` bytes (error if the inflated length
  differs), and caches the last decompressed window (same caching contract as
  `FileWindowStore`). It returns a `have`-length buffer, which is all the extract
  path consumes (`inflateSetDictionary(window, have)`); no caller assumes a
  32768-length window.

## Versioning and compatibility

- sparse: `1.1 -> 1.2`. A v1.2 reader handles v1.0 (raw, lex), v1.1 (raw), and
  v1.2 (compressed); it rejects `minor > 2`.
- exact: `2.2 -> 2.3`. A v2.3 reader handles v2.1 (raw), v2.2 (raw), and v2.3
  (compressed); v2.0 still produces a rebuild message; it rejects `minor > 3`.
- Older binaries already reject a newer `minor` with "please rebuild the index",
  so shipping v1.2 / v2.3 is forward-safe.
- `fqix check` semantics (source size + mtime) are unchanged.

## Build path

`IndexFormat.write_v1`/`write_v2` gain a compressed-window path for the new
versions:

1. For each checkpoint, raw-deflate the first `have` bytes of its window; collect
   the compressed blob and its `clen`.
2. Compute `windows_offset` using the 25-byte metadata size.
3. Write header, source path, (exact: mphf/slots/overflows), then the 25-byte
   metadata entries carrying each `window_clen`.
4. Write the compressed blobs back-to-back; assert `io.pos == windows_offset`
   before the first blob, as today.

`clen` is a write-time artifact, so the writer computes a local `clens`/`blobs`
pair rather than mutating the source `CheckpointMeta`. Compression uses zlib via
Crystal's `Compress::Deflate` (already linked through `lib_z`); no new dependency.
Build holds the compressed blobs transiently in addition to the raw windows
already held by `MemoryWindowStore`; for very large indexes a temp-file spill can
be added later (noted, not required for the first pass).

## Lookup path

`Reader` is unchanged above the window store. The only difference is that
`CompressedFileWindowStore#get` inflates one ≤32 KiB window before
`inflateSetDictionary`. This is microseconds against the `span/2` inflate that
already dominates positive lookups (measured ~5 ms/read at 4 MiB on a 685 MB
file), so end-to-end lookup latency should be unchanged within noise. Stage 4
verifies this.

## CLI and reporting

- `fqix index` always writes compressed windows in the new versions; there is no
  opt-out flag in this pass (see Out of scope).
- `fqix show` reports compressed window bytes and the raw/compressed ratio, and a
  `window_compression` field.

## Validation (read time)

- Dispatch metadata-entry size by version (21 vs 25 bytes).
- `have <= WINDOW_SIZE` (unchanged). `window_clen == 0` is valid iff `have == 0`;
  otherwise `window_clen` must be in `1 .. WINDOW_SIZE + slack` (deflate of <= 32768
  bytes, plus a small worst-case expansion margin).
- `sum(window_clen) == file_size - windows_offset` (replaces the old
  `ncheckpoints * 32768` fits-check in `ensure_windows_fit!`).
- On `get`, the inflated length must equal `have`, else raise an index-corruption
  error.

## Invariants

- The decompressed `have`-byte dictionary is byte-identical to the dictionary the
  raw format would have primed, so extraction and header verification are
  unaffected (the unused 32768 - have padding bytes are simply not stored).
- Exact lookup still never returns a record whose extracted header does not
  normalize to the query; duplicates stay in input order; forced key collisions
  stay findable.
- sparse v1.0/v1.1 and exact v2.1/v2.2 indexes keep reading identically.
- `--checkpoint-span`, `--name-interval`, `--name-order`, and `--scan-limit`
  behavior is unchanged; window compression is orthogonal to all of them.

## Stages

There is no pre-existing v1.2 / v2.3 file to read, so the writer and reader land
together and are exercised by round-trip tests (write in memory, read back, assert
window bytes and `get` results match the raw-format index).

1. **Format round-trip + default.** Add the 25-byte metadata entry, the
   compressed-window write path, `CompressedFileWindowStore`, the v1.2 / v2.3 read
   paths, and validation; make v1.2 / v2.3 the default output. Tests:
   - write→read→`get` correctness on sorted, unsorted, duplicate-name, and
     forced-collision inputs;
   - the `have == 0` first checkpoint and an early `have < 32768` checkpoint;
   - decompressed dictionaries are byte-identical to the raw-format build;
   - v1.0/v1.1 and v2.1/v2.2 indexes still read identically; v2.0 still rebuilds.
2. **CLI + show.** Extend `fqix show` with a `window_compression` field and
   compressed window bytes / ratio. No new index flag in this pass.
3. **Docs + experiments.** Update `docs/fqix-format.md`, `docs/how-it-works.md`,
   `docs/usage.md`, and regenerate `benchmark/` numbers (size table + lookup
   latency), keeping the "sparse/long-read big, short-read exact modest" framing.
4. **Validation.** Confirm size reductions match the measured table and that
   positive/negative lookup latency is unchanged within noise on the real DRR
   dataset.

## Completion criteria

- `fqix index` writes v1.2; `fqix index --mode exact` writes v2.3.
- v1.0/v1.1 and v2.1/v2.2 indexes remain readable; v2.0 still asks for a rebuild.
- Decompressed `have`-byte dictionaries are byte-identical to the raw-format build;
  all correctness specs pass under duplicates and forced collisions.
- Measured window-section reduction is reflected in `benchmark/`/docs, with the
  honest "sparse/long-read big, short-read exact modest" framing.
- `make test` passes.

## Out of scope

- A raw-window opt-out flag (`--window-compression none`). Window decompression is
  negligible per lookup, so the first pass always compresses; the flag and a
  second maintained output format can be added later if a real need appears.
- Alternative window codecs (zstd/brotli). Deflate reuses the linked zlib and
  already gives 2–6x; another codec is a separate, dependency-adding decision.
- Dropping or sub-sampling windows for very deep checkpoints (rapidgzip-style).
  Promising but a different structure; not specified here.
- Lookup-table compaction for short-read exact (implicit offsets). Tracked in
  `exact-index-compaction-v2.1-v2.2.md`; window compression does not address it.
- BGZF-specific indexing. fqix targets ordinary gzip streams and zran-style
  restart points; it works on bgzip files but gains nothing from BGZF block
  structure.
