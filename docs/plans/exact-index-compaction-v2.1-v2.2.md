# fqix Exact Index Compaction Plan: v2.1 -> v2.2

This is the remaining planning document for exact-index size reduction. Older
dual-mode and sparse-order planning notes have been folded into `docs/`; the
current format and user behavior are documented in:

- `docs/usage.md`
- `docs/how-it-works.md`
- `docs/fqix-format.md`

Exact mode keeps the same user contract throughout this work:

```sh
fqix index --mode exact reads.fastq.gz
fqix get reads.fastq.gz read_id
```

It must support arbitrary FASTQ record order, duplicate read names, `--all`,
`--first`, `--count`, `--unique`, `--list`, stale/mismatch protection, and forced
hash-collision tests.

## Status

Implemented:

- sparse v1.1 order mode (`lex`, `natural`, and index-time `auto`)
- exact v2.1 compact fingerprint reader support
- exact v2.2 MPHF writer/reader
- exact lookup by MPHF slot plus overflow table
- per-record guard filtering before FASTQ I/O
- final FASTQ header verification for every returned exact candidate
- v2.0 exact rejection with a rebuild message

Still in progress:

- measuring exact index size on more real short-read datasets
- tuning MPHF construction memory/time for large inputs
- tightening docs around expected exact-index size by read length and checkpoint
  span
- deciding whether the next reduction should target checkpoint windows,
  implicit offsets, or a disorder-proportional structure

## Why compaction matters

The old v2.0 exact index stored a wide per-record entry plus the full normalized
read name in a name table. For realistic 150 bp short reads this made exact
indexes roughly the size of the compressed FASTQ:

| dataset | v2.0 exact index | as % of `.fastq.gz` |
| --- | ---: | ---: |
| illumina, 38 B names | 17.9 MB | 91 % |
| sra, 17 B names | 13.6 MB | 74 % |

The cost was structural. Per record, v2.0 stored a 64-bit hash, a name-table
reference, `record_number`, `record_offset`, `record_size`, `flags`, and the
read name bytes themselves. Correctness already came from seeking back into the
FASTQ and verifying the extracted header, so the stored names were redundant for
identity.

The exact-index compaction work follows one rule:

> The index only selects candidates; the extracted FASTQ header is the source of
> truth.

That permits much smaller candidate selectors without weakening correctness.
Hash collisions, stale indexes, swapped source files, and duplicate names are all
resolved by verification.

## Size targets

| layout | per-record lookup table target | notes |
| --- | ---: | --- |
| v2.0 exact | `48 B + name bytes` | removed; rebuild required |
| v2.1 compact fingerprint | `20 B` | readable compatibility format |
| v2.2 MPHF | `14 B slot + MPHF blob + overflow` | current write format |
| future implicit offsets | `~4-5 B` | research, not specified |

For short reads, the lookup table dominates the exact index. For long reads, the
32 KiB zran checkpoint windows dominate instead, so further long-read reduction
is more likely to come from checkpoint-span tuning or window compression than
from more lookup-table compaction.

## Stage 1: v2.1 compact fingerprint table

v2.1 removed the name table and reduced each exact record entry to:

| Size | Field |
| ---: | --- |
| 8 | `fingerprint` |
| 8 | `record_offset` |
| 4 | `record_size` |

Entries are sorted by `(fingerprint, record_offset)`. Lookup binary-searches the
fingerprint range, extracts each candidate record, normalizes the extracted FASTQ
header, and returns only verified matches.

Important semantics:

- `record_offset` is in the uncompressed FASTQ stream.
- `record_size` is `u32`; indexing rejects a record larger than `UInt32::MAX`.
- `--count` counts verified header matches.
- missing names are proven by an empty candidate range or by zero verified
  matches.
- forced fingerprint collisions only add extra verified reads; they never return
  wrong records.

v2.1 is no longer the write format, but its reader is kept because it is simple
and avoids forcing rebuilds from the intermediate compact format.

## Stage 2: v2.2 MPHF exact index

v2.2 is the current exact write format. It replaces the sorted fingerprint table
with a pure-Crystal minimal perfect hash over distinct 64-bit normalized-name
keys.

Current structure:

```text
header
source path bytes
mphf blob
slot table
overflow table
checkpoint metadata table
checkpoint windows
```

The slot table has one slot per distinct 64-bit key:

| Size | Field |
| ---: | --- |
| 8 | inline record offset, or overflow-table offset |
| 4 | inline record size, or overflow count |
| 1 | per-record guard for inline records; `0` for overflow slots |
| 1 | flags (`0` inline, `1` overflow) |

Overflow entries are 13 bytes:

| Size | Field |
| ---: | --- |
| 8 | `record_offset` |
| 4 | `record_size` |
| 1 | per-record guard |

The overflow path handles both true duplicate names and rare distinct names that
share the same 64-bit key. Lookup gathers all records for the key, filters by the
per-record guard, extracts surviving candidates, and verifies the FASTQ header.

The guard is intentionally per record, not per slot. If two distinct names share
a 64-bit key, they share an MPHF slot but can have different guards. A single
slot-level guard would create a false negative for one of them; per-record guards
do not.

## MPHF notes

The MPHF is fqix-owned serialization of a BBHash-style algorithm:

- build over distinct 64-bit read-name keys
- deterministic level hashing from the stored fingerprint seed
- leveled bit arrays with rank support
- small fallback map for residual keys
- no external dependency

Querying a missing key may still land on a real slot. The guard byte rejects most
negative lookups before FASTQ I/O; guard false positives are harmless because the
header verification still decides the result.

## Required invariants

- Exact lookup never returns a record unless the extracted FASTQ header
  normalizes to the requested name.
- Duplicate names are returned in input order.
- Forced 64-bit key collisions keep all colliding names findable.
- `--count`, `--first`, `--all`, and `--unique` operate on verified matches.
- v2.0 exact indexes are rejected with a clear rebuild error.
- sparse v1.0/v1.1 behavior is not changed by exact compaction work.

## Remaining work

1. Benchmark v2.2 on larger real datasets and record:
   - bytes per record for MPHF, slots, overflows, checkpoints, and windows
   - build peak memory
   - build throughput
   - positive lookup latency
   - negative lookup latency and guard false-positive rate
2. Tune MPHF construction parameters, especially gamma and fallback thresholds.
3. Add a short exact-size guide to docs that explains when exact mode is dominated
   by the lookup table versus zran windows.
4. Decide the next compaction axis:
   - implicit offsets / rank reconstruction for short reads
   - compressed disorder-proportional permutation
   - larger checkpoint span or compressed windows for long reads

## Completion criteria for the current v2.2 pass

- `fqix index --mode exact` writes v2.2.
- v2.1 exact indexes remain readable.
- v2.0 exact indexes produce a rebuild message.
- correctness holds under duplicates and forced key collisions.
- exact-size measurements are refreshed in `benchmark/` or docs.
- `make test` passes.

## Out of scope

- A full implicit-offset format. The idea is promising but needs a concrete
  offset-reconstruction design and sampling format.
- A unified sparse/exact adaptive index. This likely needs a compressed
  permutation model and should be a separate plan.
- BGZF-specific indexing. fqix targets ordinary gzip streams and zran-style
  restart points.
