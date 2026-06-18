# fqix Dual-Mode Index Implementation Plan

## Goal

Rework fqix so it supports two explicit index strategies side by side:

- `sparse`: the v1 sparse anchor index. It is small and fast, but it requires the FASTQ records to be sorted by the fqix read-name order.
- `exact`: the v2 full hash index. It is larger, but it does not assume any order in the FASTQ body.

`auto` mode is intentionally deferred. The immediate goal is to restore a small-index path while keeping the order-independent exact path available for files whose read order is unreliable.

## Design summary

```text
fqix index --mode sparse reads.fastq.gz
  -> writes a v1.0 sparse index
  -> stores zran checkpoints plus sparse read-name anchors
  -> rejects unsorted FASTQ during indexing
  -> lookup resumes near the lower anchor and scans forward through the matching name run

fqix index --mode exact reads.fastq.gz
  -> writes a v2.0 exact index
  -> stores zran checkpoints plus one hash-sorted entry per FASTQ record
  -> accepts arbitrary FASTQ record order
  -> lookup hashes the query, verifies the stored name, then extracts the exact record
```

The default mode is `sparse`. This avoids accidentally creating very large exact indexes for ordinary Illumina-style FASTQ files.

## Why dual mode should come before exact-index compaction

Exact-index compaction is important, but it improves only the large-index strategy. The more urgent architectural issue is that fqix needs a small-index strategy again. Adding explicit `sparse` and `exact` modes creates a clean boundary:

```text
IndexMode::Sparse -> v1.x sparse anchor logic
IndexMode::Exact  -> v2.x full hash logic
```

Once that boundary exists, exact-mode internals can be changed later from the current `hash + name_table + offset` layout to a compact fingerprint layout without disturbing sparse mode.

## On-disk formats

### Sparse mode: v1

Sparse mode uses the v1.x on-disk format:

```text
magic/version: FQIX v1.0
source metadata
checkpoint_span
name_interval
record_count
source path
checkpoint metadata
sparse name anchors
zran windows
```

Each sparse name anchor stores:

```text
name_length: u16
name bytes
uncompressed_offset: u64
checkpoint_id: u64
delta: u64
```

The first read is always an anchor. Every `name_interval`-th read is also an anchor.

### Exact mode: v2

Exact mode uses the v2.x on-disk format:

```text
magic/version: FQIX v2.0
source metadata
checkpoint_span
hash_algorithm
name_mode
input_names_sorted diagnostic flag
hash_seed
record_count
checkpoint count
entry count
source path
entry table
name table
checkpoint metadata
zran windows
```

Each exact entry currently stores:

```text
name_hash: u64
name_offset: u64
name_length: u32
record_number: u64
record_offset: u64
record_size: u64
flags: u32
```

This is still the larger exact representation. A later compact exact mode should remove `name_table` and use a 128-bit fingerprint plus record location.

### Format versioning

The on-disk version field is stored as two little-endian `u16` values:

```text
version_major: u16
version_minor: u16
```

`version_major` is the index kind and matches the magic byte:

```text
1 -> sparse
2 -> exact
```

`version_minor` is a layout revision within that kind. Current formats are `1.0` for sparse and `2.0` for exact. Readers dispatch by major, reject mismatched magic/kind pairs, and reject future minor revisions with a rebuild message.

This remains byte-compatible with the earlier single little-endian `u32` exact version: `2_u32` decodes as `2.0`.

## Internal data model

Add an explicit mode enum:

```crystal
enum IndexMode : UInt8
  Sparse = 1
  Exact  = 2
end
```

The `Index` object holds both sets of structures, but only one side is populated:

```text
sparse index:
  mode = Sparse
  names      = Array(NameEntry)
  entries    = empty
  name_table = empty
  format_version = 1.0

exact index:
  mode = Exact
  names      = empty
  entries    = Array(Entry)
  name_table = Bytes
  format_version = 2.0
```

This keeps the public `Index.read`, `Index.write`, `Index.default_path`, `stale_for?`, and checkpoint APIs stable.

## Build path

### Shared gzip/zran pass

Both modes reuse the same gzip inflation and zran checkpoint generation. The only difference is the consumer attached to the decompressed stream.

```text
Zran.build_to_temp(gz_path, checkpoint_span, consumer)
  -> emits decompressed chunks to the mode-specific builder
  -> writes temporary zran checkpoint metadata
```

### Sparse builder

`SparseNameTableBuilder` performs the original v1 behavior:

1. Parse four-line FASTQ records from the decompressed stream.
2. Extract the normalized read name from the header.
3. Check monotonic order with `Fqix::Order.compare`.
4. Record the first read and every `name_interval`-th read as anchors.
5. After checkpoint metadata is known, map each anchor offset to `(checkpoint_id, delta)`.

If the FASTQ is not sorted, sparse mode fails immediately with a message pointing the user to exact mode.

### Exact builder

`ExactEntryBuilder` records every FASTQ record:

1. Parse four-line FASTQ records from the decompressed stream.
2. Extract the normalized read name from the header.
3. Store `(name, record_number, record_offset, record_size)` in memory.
4. Compute `input_names_sorted` for diagnostics only.
5. Build the exact entry table sorted by `(name_hash, record_number)`.
6. Build the concatenated name string table.

Exact mode never rejects the file for read-name order.

## Lookup path

### Sparse lookup

Sparse mode preserves the v1 lookup algorithm:

1. Normalize the query name.
2. Binary-search sparse anchors for the last anchor whose name orders before the query.
3. Resume gzip inflation at the anchor checkpoint and delta.
4. Scan forward until the scan moves past the query or `--scan-limit` is reached.
5. Return every record whose normalized name exactly equals the query.

Because sparse mode requires sorted read names, duplicate records for the same name form a contiguous run. `--all`, `--count`, and `--unique` therefore have the same duplicate-aware behavior in sparse and exact mode.

### Exact lookup

Exact mode uses the v2 hash lookup:

1. Normalize the query name.
2. Compute the query hash.
3. Binary-search the exact entry table for the matching hash range.
4. Compare the stored name bytes in the name table.
5. For every exact match, seek to the indexed record offset and extract exactly `record_size` bytes.
6. Re-normalize the extracted FASTQ header and verify it equals the query.

The final header check protects against stale indexes, hash collisions, and accidental FASTQ/index mismatches.

## CLI changes

### Indexing

```sh
fqix index reads.fastq.gz
fqix index --mode sparse reads.fastq.gz
fqix index --mode exact reads.fastq.gz
```

Options:

```text
--mode sparse|exact       default: sparse
--name-interval N         sparse only, default: 1024
--checkpoint-span BYTES   shared zran checkpoint spacing
```

### Lookup

```sh
fqix get reads.fastq.gz read_id
fqix get --scan-limit 16777216 reads.fastq.gz read_id
fqix get --first reads.fastq.gz read_id
fqix get --count reads.fastq.gz read_id
fqix get --list names.txt reads.fastq.gz
```

`--scan-limit` applies to sparse mode. Exact mode ignores it because exact entries store record sizes.

If sparse lookup reaches `--scan-limit` before it can prove the query is absent or complete, the CLI reports scan-limit exhaustion instead of silently treating the query as missing.

### Inspection

```sh
fqix show reads.fastq.gz.fqix
fqix show --anchors reads.fastq.gz.fqix
fqix show --entries reads.fastq.gz.fqix
```

`--anchors` and `--entries` both print raw mode-specific lookup entries:

- sparse index: anchors
- exact index: hash-sorted exact entries

## Tests

### Sparse mode tests

1. Build a sparse v1 index for sorted FASTQ.
2. Confirm it writes and reads as format version 1.0.
3. Confirm lookup works after reading the index from disk.
4. Confirm unsorted FASTQ is rejected with a message suggesting `--mode exact`.
5. Confirm duplicate read names are returned in input order.
6. Confirm `--count`, `--unique`, and scan-limit reporting work in sparse mode.

### Exact mode tests

1. Build exact index for an unsorted FASTQ.
2. Confirm all shuffled reads are retrievable.
3. Confirm exact name comparison inside colliding hash ranges.
4. Confirm duplicate read names are returned in input order.
5. Confirm stale or swapped FASTQ is caught by post-seek header verification.

### CLI tests

1. Default `fqix index` creates sparse indexes.
2. `fqix index --mode exact` creates exact indexes.
3. Duplicate-aware CLI behavior works in both sparse and exact mode.
4. Help output lists `--mode`, `--name-interval`, and `--scan-limit`.

## Future exact compaction plan

After dual mode is stable, exact mode can be compacted.

Current exact entry cost:

```text
48 bytes/read + read name bytes/read
```

Target compact exact entry:

```text
hash_hi: u64
hash_lo: u64
record_offset: u64
record_size: u32
```

With alignment, this should be about 32 bytes/read and can remove the name table entirely. Lookup would read candidate records from FASTQ and compare the actual header after extraction. Wrong results remain impossible because the FASTQ header is still verified; collisions only cause extra candidate reads.

## Completion criteria for this phase

- `fqix index --mode sparse` writes v1.0 sparse indexes.
- `fqix index --mode exact` writes v2.0 exact indexes.
- `fqix index` defaults to sparse.
- v1 sparse indexes are readable.
- v2 exact indexes are readable.
- Sparse mode rejects unsorted FASTQ.
- Sparse and exact modes both support duplicate-aware `--all`, `--count`, and `--unique`.
- Exact mode works on unsorted FASTQ.
- CLI help and README describe both modes clearly.
