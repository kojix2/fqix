# fqix v2 Refactor Plan: Hash-Based Index (No Read-Name Order Assumption)

## Goal

Make fqix work correctly even when read names in the FASTQ are **not** sorted
(alphabetically, lexicographically, or by coordinate). The new design depends on
**no assumption about record order** in the FASTQ body. Instead, the index
records the location of every read at build time and stores the lookup table
ordered by **read-name hash**.

```
FASTQ body order : treated only as "appearance order in the original file"
fqix index order : ordered by read-name hash
lookup           : read name -> hash -> candidate range -> exact name compare -> seek to record
```

Acceptance: for a FASTQ such as

```
@read_C ...
@read_A ...
@read_B ...
```

`fqix get read_A sample.fastq.gz` must correctly return `read_A`.

## Decisions (confirmed)

- **First implementation scope:** make the existing gzip/zran path
  order-independent. Reuse the zran machinery; record every record and add a
  hash index. Plain FASTQ / BGZF backends are deferred to a later phase.
- **Format compatibility:** bump to `VERSION = 2` and drop v1. Reading a v1
  index returns an "unsupported; please rebuild" error.
- **Default name mode:** `first-token` (matches the current
  `Fastq.name_from_header` behavior).

## Environment note

`crystal` is available via mise
(`~/.local/share/mise/installs/crystal/latest/bin/crystal`). The earlier
`crystal: not found` from `make test` was a PATH issue; in this environment
`make` and `make test` (including the zran C reference object) can run, so each
phase can be built and tested.

## Why this is the right mapping onto the current code

The current fqix is built entirely around seekable gzip (zran). Its lookup uses
`Order.compare` to drive three things at once: the build-time sort check, the
sparse-anchor binary search, and the forward scan during lookup. That is exactly
the read-name-sorted assumption we are removing.

| Aspect | v1 (current) | v2 (target) |
|---|---|---|
| Entries | Sparse (one every N records) | **Every record** |
| Sort key | Read-name order (input must be sorted) | **(name_hash, record_number)** |
| Lookup | Name-order binary search + forward scan | **Hash-range binary search + exact name compare + direct seek** |
| Order assumption | Required (raises if unsorted) | **None** |
| Post-seek check | None | **Re-normalize header and verify** |

For the gzip backend, `record_offset` (an uncompressed-stream logical offset) maps
to a checkpoint via the existing `Index.checkpoint_for`, yielding a `delta` that
`Zran.extract_to` uses to read exactly one record. No changes to the zran API are
required.

## On-disk format (v2)

### Header (extends the current one)

- `magic`            : `"FQIX\u{2}\0\0\0"` (version byte = 2)
- `version`          : `u32` = 2
- `flags` / padding
- `source_size`      : `u64`
- `source_mtime`     : `i64`
- `checkpoint_span`  : `u64`
- `hash_algorithm`   : `u8`  (selects the 64-bit hash)
- `hash_seed`        : `u64`
- `name_mode`        : `u8`  (`full` / `first-token` / `illumina-pair`)
- `record_count`     : `u64` (every record is an entry now)
- `ncheckpoints`     : `u64`
- `source_path_len`  : `u32`
- table/section offsets (entries, name table, windows)
- `input_names_sorted` : recorded for diagnostics only; **never used for lookup**

Reading any non-2 version returns: `unsupported fqix version N; please rebuild the index`.

### Entry (fixed length, sorted by `(name_hash, record_number)`)

```
struct Entry {
  name_hash      : u64
  name_offset    : u64   # into the name string table
  name_length    : u32
  record_number  : u64
  record_offset  : u64   # uncompressed-stream logical offset
  record_size    : u64
  flags          : u32
}
```

`checkpoint_id` / `delta` are **not stored**; they are computed at lookup from
`record_offset` (single source of truth) via the existing `checkpoint_for`.

### Name string table

Concatenated normalized name bytes; entries reference slices via
`(name_offset, name_length)`. Fixed-length entries keep binary search by hash
simple.

## Implementation phases

### Phase 0 — Add the failing test (locks the acceptance condition)

- In [spec/index_spec.cr](spec/index_spec.cr), add a test: an **unsorted** gzip
  FASTQ (`@read_C` / `@read_A` / `@read_B`) where each `get` returns the correct
  record. It fails first; it is the completion criterion.

### Phase 1 — v2 internal data model

- [src/fqix/index_format.cr](src/fqix/index_format.cr): set `VERSION = 2`, change
  the MAGIC version byte to `\u{2}`. Add `hash_algorithm` (u8), `hash_seed` (u64),
  `name_mode` (u8), and `record_count` to the header. Reject v1 via the existing
  version-mismatch path.
- New `struct Entry` as above (fixed length).
- Name modes and a `hash_algorithm`-abstracted 64-bit hash. Default name mode is
  `first-token` (matches current behavior). The hash choice is a performance
  concern only — collision safety is guaranteed by the exact-name compare.

### Phase 2 — Offset-aware FASTQ parser

- [src/fqix/fastq.cr](src/fqix/fastq.cr): `StreamParser` already tracks
  `record_start`. Compute `record_size` from the delta between consecutive record
  starts (the final record's size is settled at `finish`).

### Phase 3 — v2 index writer (record every read)

- [src/fqix/index.cr](src/fqix/index.cr): replace `NameTableBuilder` with an
  `EntryBuilder`:
  - Record **every** record (drop sparse anchors). Assign `record_number`,
    normalize the name, store `record_offset` / `record_size`.
  - **Remove the sort check** at [index.cr:67-79](src/fqix/index.cr#L67-L79).
    Compute the `input_names_sorted` flag for diagnostics only.
- After build: sort entries by `(name_hash, record_number)`, build the name
  table, then write the index. The single zran inflate pass
  (`build_to_temp` + consumer) is unchanged.

### Phase 4 — v2 index reader (lookup without reading the FASTQ body)

- Replace `find_floor_name` ([index.cr:197](src/fqix/index.cr#L197)) with
  `lower_bound` / `upper_bound` over `name_hash`. Within the range, compare
  `name_length` and the name-table bytes; collect matching entries.

### Phase 5 — Record reader (seek and read one record)

- [src/fqix/reader.cr](src/fqix/reader.cr): remove the order-dependent forward-scan
  `BatchRecordScanner`.
- For each match: `checkpoint_for(record_offset)` -> `delta` ->
  `Zran.extract_to(..., max_out = record_size)` to extract one record ->
  re-normalize the header and verify it equals the query (otherwise raise
  `index/input mismatch`).
- `--scan-limit` becomes unnecessary (`record_size` gives an exact bound).

### Phase 6 — CLI

- [src/fqix/cli.cr](src/fqix/cli.cr) `get`: return all matches by default for
  duplicate names. Add `--first`, `--count`, `--all`, `--unique`,
  `--list FILE`, and `--order query|input`. Default output order is
  `record_number` ascending (i.e., original FASTQ order).
- `show` / `check` / `stats`: report hash algorithm, name mode, record count,
  duplicate names, and `input_names_sorted`. Remove `-n/--name-interval` and
  `-s/--scan-limit`.

### Phase 7 — Robustness

- Return all matches for duplicate names; hash-collision safety (test with a
  fixed `hash = 0` build, verifying exact-name compare separates records
  correctly); detect a swapped FASTQ (size/mtime + post-seek header check);
  clear errors on corruption.

### Phase 8 — Deferred (optional)

- plain FASTQ / BGZF backends, external sort, `illumina-pair` mode,
  `pair-check`, multi-query optimization.

## Remove / reuse

- **Remove:** `Order`-driven search ([src/fqix/order.cr](src/fqix/order.cr)),
  `find_floor_name`, the forward-scan `BatchRecordScanner`, the sort requirement,
  and the `name-interval` / `scan-limit` options.
- **Reuse:** all of zran (`build_to_temp` / `read_temp` / `extract_to`),
  `checkpoint_for`, the window store, `StreamParser`, the CLI skeleton, and error
  handling.

## Tests

Run `make` / `make test` (which also builds the zran C reference object) after
each phase.

1. Minimal unsorted FASTQ (`read_C` / `read_A` / `read_B`): each `get` succeeds.
2. Shuffled FASTQ of size N: every name returns the correct record.
3. Duplicate read names: default returns all; `--first` returns one; `--count`
   returns the count.
4. Hash collision: build with a fake `hash = 0`; exact-name compare still returns
   only the correct read.
5. Name normalization across `full` / `first-token` / `illumina-pair`.
6. Index/source mismatch detection (size, mtime, post-read header re-check).
7. (Later) paired-end ordinal check.
8. Compression backends: gzip now; plain / BGZF later.

## Completion criteria

- `get` works when read names in the FASTQ are unsorted.
- No order-dependent search logic remains over the FASTQ body.
- Hash collisions are handled correctly via exact-name compare.
- Duplicate read names are supported.
- `record_number` reconstructs the original order.
- The v2 index format is versioned.

Minimal acceptance:

```
fqix index unsorted.fastq.gz
fqix get read_A unsorted.fastq.gz
fqix get read_B unsorted.fastq.gz
fqix get read_C unsorted.fastq.gz
```

All must succeed.

## Open question (to resolve at Phase 1)

XXH3-64 has no standard Crystal implementation. Either (a) port XXH3, or
(b) adopt an existing stable 64-bit hash behind the `hash_algorithm` abstraction
for now. Collision safety is guaranteed by the exact-name compare, so the hash
choice is purely a performance question.
