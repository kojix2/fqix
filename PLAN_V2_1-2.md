# fqix Exact Index Compaction Plan: v2.1 → v2.2

Two-stage compaction of the exact index. Stage 1 (`v2.1`) is a pure-Crystal
format change with no new dependencies. Stage 2 (`v2.2`) replaces the lookup
core with a minimal perfect hash. Both keep the `--mode exact` user contract
unchanged.

```sh
fqix index --mode exact reads.fastq.gz
fqix get reads.fastq.gz read_id
```

Exact mode must still support arbitrary FASTQ record order, duplicate read
names, `--all`, `--first`, `--count`, `--unique`, `--list`, and stale/mismatch
protection.

This is pre-1.0. v2.0 exact indexes are not kept backward compatible; existing
v2.0 indexes are rebuilt.

## Why: the exact index is currently as large as the data

Measured on realistic FASTQ (binned-quality, ~3.5× short-read compression; see
`experiments/`), building real v2.0 exact indexes and accounting every section:

| dataset (150 bp short read) | v2.0 index | as % of `.fastq.gz` |
| --- | ---: | ---: |
| illumina (38 B names) | 17.9 MB | **91 %** |
| sra (17 B names) | 13.6 MB | **74 %** |

The v2.0 exact index is roughly the size of the compressed FASTQ it indexes, and
with higher compression or longer names it exceeds the data file. Expressed per
record (compression-independent): v2.0 short-read ≈ 68–89 B/read.

The cost is structural, not incidental. Per record v2.0 stores a 64-bit hash, a
name-table reference, `record_number`, `record_offset`, `record_size`, `flags`
(48 B), plus the read name itself in a separate string table. Correctness already
comes from re-reading and verifying the FASTQ header after seeking; the stored
name and the wide hash are only candidate filters.

For long reads the picture is different: the index is already ~2 % of the file
and is dominated by the shared zran checkpoint windows (32 KiB per checkpoint).
Below ~5.5 kb reads the lookup table dominates the index; above it the window
floor dominates. **This plan targets the short-read regime.** Shrinking the
long-read index is a separate axis (checkpoint spacing / window compression) and
is out of scope here.

## Design principle: verification is the source of truth

Both stages keep the v2.0 invariant that the extracted FASTQ header is verified
after seeking. Because verification is authoritative, the in-index name
representation only has to *select candidates*, not *prove identity*. That lets
the per-record name cost fall toward an information-theoretic floor:

- A wide fingerprint is unnecessary; a fingerprint only needs enough bits to keep
  wasted candidate reads rare (Stage 1).
- The name set can be addressed by a minimal perfect hash at ~3 bits/key, with no
  stored fingerprint at all (Stage 2).

Conceptually, the irreducible content of an order-independent exact index is *how
disordered the file is* — where each named record landed. Everything else
(fingerprints, redundant name bytes) is compressible away. v2.1 and v2.2 remove
the compressible parts in two steps.

## Per-record size targets

| layout | bytes/record (short read) | vs v2.0 |
| --- | ---: | ---: |
| v2.0 exact (today) | ~86 (48 + name) | 1× |
| **v2.1** compact fingerprint table | **20** | ~4.3× smaller |
| **v2.2** minimal perfect hash | **~13.4 + MPHF blob (~0.4/key) + overflow** | ~6× smaller |
| (research) implicit offsets, Plan C | ~4–5 | ~17× smaller |

These per-record figures are validated against real indexes in `experiments/`
(reconstruction matches measured size to the byte). For 150 bp short reads the
total exact index — entry table plus the shared zran windows — is ~89 B/read at
v2.0 and ~23 B/read at v2.1. Stage 1 takes the short-read exact index from ~91 %
of the `.gz` to ~23 %; Stage 2 to ~14 %.

---

# Stage 1 — v2.1: compact fingerprint table (no new dependencies)

Same structural family as v2.0 (a hash-sorted table searched by binary search,
verified against the FASTQ), with three changes: drop the name string table,
right-size the fingerprint to 64 bits, and drop `record_number` (recovered from
`record_offset` order). Pure Crystal; no external code.

## Format scope

- sparse v1.0 / v1.1 read support: unchanged.
- sparse writes: still v1.1.
- exact writes: become v2.1.
- exact v2.0 read/write support: **removed**.
- version dispatch (see below) must reject v2.0 and unknown minors distinctly.

## On-disk format

Exact magic, version pair `2.1`:

```text
magic         = FQIX\x02\0\0\0
version_major = 2
version_minor = 1
```

### Layout

```text
header
source path bytes
compact entry table
checkpoint metadata table
checkpoint windows
```

There is no read-name string table.

### Header

Clean v2.1 header with honest field names (no reinterpretation of v2.0
name-table fields). Fixed size **112 bytes**: 104 bytes of fields plus an 8-byte
reserved tail, so existing offset math and validators keep a single
`HEADER_SIZE` constant.

```text
magic: u8[8]
version_major: u16
version_minor: u16
flags: u16                  reserved, must be 0
padding: u16                reserved, must be 0
source_size: u64
source_mtime: i64
checkpoint_span: u64
fingerprint_algorithm: u8
name_mode: u8
input_names_sorted: u8      diagnostic only (exact mode is order-independent)
header_padding: u8          reserved, must be 0
fingerprint_seed: u64
record_count: u64
checkpoint_count: u64
entry_count: u64
source_path_len: u32
entries_offset: u64
checkpoints_offset: u64
windows_offset: u64
reserved_tail: u8[8]        reserved, must be 0
```

Validation:

- reserved fields are zero
- offsets are monotonic and within file size: `HEADER_SIZE ≤ entries_offset ≤
  checkpoints_offset ≤ windows_offset ≤ file_size`
- `source_path_len ≤ entries_offset − HEADER_SIZE`
- compact entry table size equals `entry_count * 20`
- checkpoint metadata table size equals `checkpoint_count * 21`
- checkpoint windows fit at `windows_offset`

There is no `name_table_size` / `name_table_offset` field.

### Compact entry (20 bytes)

| Offset | Size | Type | Field |
| ---: | ---: | --- | --- |
| 0 | 8 | u64 | fingerprint |
| 8 | 8 | u64 | record_offset |
| 16 | 4 | u32 | record_size |

Entries are sorted by `(fingerprint, record_offset)`.

- `record_offset` is the **uncompressed-stream** byte offset of the record (the
  same space the zran checkpoints map). It is strictly monotonic with FASTQ input
  order, so it replaces `record_number` for stable ordering and for returning
  duplicates in input order.
- `record_size` is `u32`. Indexing rejects an individual FASTQ record larger than
  `UInt32::MAX` with a clear error.
- No per-entry `flags`. Forward-incompatible per-entry data, if ever needed, is a
  minor bump.

A 64-bit fingerprint is more than enough: with verification downstream, its only
job is to keep candidate reads rare. At 10⁹ records the expected number of
64-bit collisions is < 0.1, and any collision only causes an extra verified read,
never a wrong result.

## Fingerprint

Stable 64-bit hash of the normalized read name plus the stored seed.

Requirements:

- deterministic across platforms, endianness, and Crystal versions
- no dependency on process-randomized hashes
- fast enough for one pass over every FASTQ record
- a deterministic test-only collision mode (equivalent to `HashAlgorithm::TestZero`)
  so collision handling can be exercised

The existing stable FNV-1a-64 (`src/fqix/index.cr`) already satisfies this and is
reused directly. No 128-bit hash is needed in Stage 1.

## Lookup semantics

1. Normalize the query with the index `name_mode`.
2. Compute the 64-bit fingerprint.
3. Binary-search the entry table for the fingerprint range.
4. For each candidate, resume gzip inflation at the nearest checkpoint and extract
   exactly `record_size` bytes at `record_offset`.
5. Normalize the extracted header and compare to the query.
6. Return only verified matches. The fingerprint range is already
   `record_offset`-sorted, so matches come back in input order.

### `--count`, missing names, batch lookups

Stated explicitly because it changes from v2.0. v2.0 could answer `--count` and
many negative lookups from the name table without touching the FASTQ. v2.1
cannot prove a candidate is a true match without reading the header:

- `--count` = number of **verified** header matches
- not-found = no verified match in the fingerprint range
- `--list` / batch may read one record per fingerprint candidate

With a 64-bit fingerprint, honest missing names usually have an empty range
(0 reads) and honest present names read only real matches. Correctness holds even
when collisions are forced in tests.

## Internal model

Replace the v2.0 exact `Entry` with the compact entry. No transitional dual
model, since v2.0 support is removed.

```crystal
struct Entry            # exact v2.1
  getter fingerprint : UInt64
  getter record_offset : UInt64
  getter record_size : UInt32
end
```

Remove `Index#name_table` and the v2.0 name-table reader/writer/validator.
Sparse anchors keep their own names and are unaffected.

## Version dispatch (correctness)

With `EXACT_MINOR` bumped to `1`, the reader must branch explicitly rather than
rely on the `minor > EXACT_MINOR` "future" check, because a v2.0 file (`minor 0`)
would otherwise pass that check and be misparsed by the v2.1 reader:

```text
major == 2:
  minor == 1            -> read v2.1 compact
  minor == 0            -> Error: v2.0 exact no longer supported; rebuild
  minor  > 1            -> Error: unsupported future format; rebuild
```

## `fqix show`

- `show` metadata reports `version 2.1` and exact counts as before.
- `show --entries` cannot print names or record numbers from the compact index.
  It prints `fingerprint`, `record_offset`, `record_size`. It must not inflate the
  FASTQ to decorate output.

## Implementation steps

1. Define the v2.1 header and 20-byte compact entry constants.
2. Replace exact entry construction: parse normalized name, compute 64-bit
   fingerprint, store offset and checked `u32` size, sort by
   `(fingerprint, record_offset)`.
3. Replace the exact writer with the v2.1 writer (no name table).
4. Replace the exact reader with the v2.1 reader and validators; add the explicit
   version-dispatch branches.
5. Remove v2.0 name-table reader/writer/validator and `Index#name_table`.
6. Update exact lookup to verify every candidate by extracting the FASTQ header.
7. Update `fqix show --entries` for compact entries.
8. Update README, `docs/how-it-works.md`, `docs/fqix-format.md`.

## Tests

Format:

- exact writes version `2.1`; no name table; entry table is `20 * record_count`
- entries sorted by `(fingerprint, record_offset)`
- invalid section offsets rejected; reserved fields nonzero rejected
- v2.0 exact index rejected with a rebuild message (distinct from future-minor)
- sparse v1.0 / v1.1 still readable

Lookup:

- unsorted FASTQ works; shuffled reads retrievable after write+read
- duplicate names returned in input order
- `--count`, `--first`, `--all`, `--unique` keep verified-match semantics
- forced fingerprint collisions never return wrong records
- missing query under a forced collision returns not found
- stale/swapped FASTQ caught by header verification
- oversized record rejected at indexing

Size:

- compact exact smaller than the old `48 + name` design on synthetic many-read FASTQ
- entry table byte size is exactly `20 * record_count`

## Completion criteria

- `fqix index --mode exact` writes v2.1 (20 B/record, no name table)
- exact lookup correct under forced collisions
- v2.0 exact indexes produce a clear rebuild error
- sparse behavior and format unchanged
- `make test` passes

---

# Stage 2 — v2.2: minimal perfect hash (MPHF)

Stage 2 keeps everything Stage 1 established (FASTQ verification, zran machinery,
duplicate handling, `show` behavior, version dispatch) and replaces only the
lookup core: instead of a fingerprint-sorted table, address records through a
minimal perfect hash. Target ~13.4 B/record for the slot table, plus the MPHF
blob (~0.4 B/key at γ≈2) and overflow metadata for the rare multi-record slots.

There is **no external dependency**. The MPHF is implemented in pure Crystal as a
clean-room port of the BBHash *algorithm* (the algorithm is not copyrightable;
no BBHash source is copied, so fqix stays MIT). This also lets fqix own the
on-disk MPHF serialization instead of adopting a foreign binary format.

## MPHF implementation (pure Crystal, BBHash algorithm)

BBHash (Rizk, Limasset, Chikhi — SEA 2017) is chosen because it is the simplest
MPHF to implement correctly: leveled bit arrays plus a rank structure, ~3 bits/key
at γ≈2, scalable to billion-key sets. (RecSplit ~1.8 bits and PTHash are smaller
but far more complex to port — recursive splitting / bijection search / Golomb-
Rice — and are not worth it for a from-scratch implementation.)

The MPHF is built over the set of distinct **64-bit key hashes** of normalized
names (`key = fnv1a64(name, seed)`); BBHash operates on `uint64` keys.

Construction (γ controls space/speed, default ~2.0):

```text
S = distinct keys, level = 0
while S not empty and level < MAXLEVEL:
  m = ceil(γ * |S|)
  A[level]  = bitvector(m)          # final placement bits
  collide   = bitvector(m)          # transient
  # pass 1: mark positions that receive >= 2 keys
  for k in S: p = h(k, level) % m; if A[level][p] { collide[p] = 1 } else { A[level][p] = 1 }
  # pass 2: a key is placed iff its position is not a collision
  for k in S: p = h(k, level) % m; if collide[p] { A[level][p] = 0 }
  S = { k in S : collide[ h(k,level) % m ] }   # collided keys fall to next level
  level += 1
# fallback: any keys left at MAXLEVEL go in a small explicit map
```

Query:

```text
for level in 0..:
  p = h(key, level) % m[level]
  if A[level][p] == 1: return base[level] + rank_within(level, p)
# else: look up the fallback map
```

`base[level]` is the total set-bit count of all earlier levels; `rank_within` is
the popcount of `A[level]` below `p`. Total set bits across all levels = N, so the
result is a bijection onto `[0, N)` (minimal and perfect).

Components to implement and get right:

- **Deterministic level hash** `h(key, level)`: a pure mixing function (e.g.
  splitmix64) seeded per level from the stored `fingerprint_seed`. Must be
  platform- and endian-independent and reproducible across Crystal versions.
- **Rank structure**: cumulative popcount per ~512-bit block plus per-word
  `Int#popcount` for O(1) `rank_within`.
- **γ** default 2.0 (~3 bits/key); expose as a build-time constant.
- **MAXLEVEL fallback** map for the residual keys.
- **Serialization** = the v2.2 `mphf blob`: concatenated `A[level]` bitvectors,
  each level's `m` and `base`, the rank index, and the fallback map. fqix owns
  this format; round-trip and cross-platform determinism are tested.

## Structure

```text
header (v2.2)
source path bytes
mphf blob                 pure-Crystal MPHF (BBHash algorithm), ~3 bits/key
slot table                one record (or overflow ref) per MPHF slot
overflow table            extra records for slots with >1 record
checkpoint metadata table
checkpoint windows
```

### Slot table entry (~13 bytes)

| Size | Type | Field |
| ---: | --- | --- |
| 8 | u64 | record_offset |
| 4 | u32 | record_size |
| 1 | u8 | guard — low 8 bits of a second independent hash of **this record's** name |

The guard is **per record**, not per slot. This is the key correctness point
(see below): a slot may hold records for more than one name, so a single
slot-level guard would reject a colliding member.

Multiplicity is handled out of line: a slot whose key has more than one record
(true duplicate names, or distinct names that share a 64-bit key) stores an
overflow reference (offset + count into the overflow table) instead of an inline
record. Each overflow entry carries its own `record_offset`, `record_size`, and
per-record `guard`. A reserved bit in the slot distinguishes inline vs overflow.

## Correctness: why a 64-bit key collision is not a false negative

In a fingerprint table every record has its own entry, so a key collision merely
adds candidates. Under an MPHF the key *is* the identity, so two distinct names
sharing a 64-bit key would collapse to one slot. Naively storing one record there
would make the other name unfindable — a false negative.

Resolution: a slot maps to **all records whose name-key equals that slot's key**,
not to a single record. Lookup verifies each against the query header and returns
the matches. This unifies three cases under one mechanism:

- one unique name → one record in the slot (the common case)
- a genuinely duplicated read name → several records in the slot, returned in
  `record_offset` order
- two distinct names colliding in 64 bits → both records in the slot; verification
  returns only the queried name's records

So Stage 2 is correct for any input, and duplicate handling and pre-hash collision
handling are the same code path.

## Negative-lookup guard (per record, never rejects a member)

An MPHF maps *any* input to some slot, so a missing query lands on a real slot and
would cost one wasted FASTQ read. The 1-byte `guard` is an independent hash used
to skip reads — but it must be applied **per candidate record**, not as a single
slot-level membership test, or it would cause a false negative:

```text
nameA, nameB distinct but share a 64-bit key  -> same slot (overflow, 2 records)
guard(nameA) != guard(nameB)
query nameB: if we compared guard(nameB) to a single slot guard == guard(nameA),
             it would mismatch -> "not found"  (WRONG: nameB is present)
```

Correct rule: gather the slot's records (1 inline, or N via overflow), keep only
those whose stored per-record guard equals `guard(query)`, then header-verify the
survivors. A true member's record carries its own guard, so it always survives;
a non-member is dropped with probability 255/256 before any I/O. This handles all
cases — unique name, duplicate name (all share the same guard), and distinct-key
collision (each record keeps its own guard) — with no false negatives and no
false positives (verification is still authoritative). Guard width is tunable
(1 byte default; 2 bytes if batch-miss workloads dominate).

## Lookup

1. Normalize the query; compute `key = fnv1a64(name, seed)`.
2. `slot = mphf.lookup(key)`.
3. Gather the slot's record(s) — 1 inline, or N via the overflow table.
4. Keep only candidates whose per-record guard equals `guard(query)` (no I/O);
   if none survive → not found.
5. Extract and header-verify each survivor; return verified matches in
   `record_offset` order.

`--count`, missing, and batch semantics are identical to Stage 1 (verified-match
counting), with negative lookups now usually rejected by the guard before any read.

## Build path

1. Reuse the shared gzip/zran pass and the per-record collection from Stage 1
   (name, record_offset, record_size).
2. Compute the 64-bit key per record; collect distinct keys.
3. Build the BBHash MPHF over the distinct key set.
4. Allocate the slot table by MPHF slot; fill primary record + guard; route extra
   records (duplicate keys) into the overflow table.
5. Serialize MPHF blob + slot table + overflow table.

Construction memory/CPU for the MPHF is the main new cost; BBHash is designed for
this scale (millions of keys/sec, low extra memory). Document peak build memory.

## Format / version

- version pair `2.2`, same exact magic.
- dispatch: `minor == 2 -> v2.2`; `minor == 1 -> v2.1`; `minor == 0 -> rebuild`;
  `minor > 2 -> rebuild`.
- Recommended: keep the v2.1 reader after v2.2 ships, since it costs nothing
  structurally (no dependency) and avoids forcing rebuilds.

## Risks / tradeoffs

- New code to get correct: MPHF construction, rank structure, deterministic level
  hashing, serialization. No external dependency, but more implementation than
  Stage 1.
- MPHF construction memory/time at billion-key scale (γ controls the tradeoff).
- Negative lookups cost one read on a guard false-positive (rare with the guard).
- Larger test surface: MPHF serialization round-trip, cross-platform determinism,
  key-collision grouping, overflow table, guard rejection.

## Tests (additional to Stage 1's, which still apply via verification)

- MPHF serialize/deserialize round-trip is stable and deterministic.
- forced 64-bit key collision between two distinct names: both findable, each
  returns only its own records (no false negative, no false positive).
- duplicate names returned in input order via the overflow path.
- negative lookups rejected by guard without FASTQ I/O (instrument read count).
- guard false-positive path still returns not found after verification.

## Completion criteria

- `fqix index --mode exact` writes v2.2 (~13.4 B/record slot table + MPHF blob + overflow)
- correctness holds under forced key collisions and duplicates
- negative lookups perform no FASTQ read in the common case
- v2.1 still readable; v2.0 produces a rebuild message
- `make test` passes

---

# Out of scope / future research

- **Plan C — implicit offsets** (~4–5 B/record). Store the record's file *rank*
  (≈ log₂N bits) instead of a raw `u64` offset, and reconstruct the byte offset
  from a file-order size prefix-sum (free for fixed-length reads). Needs a
  name→rank permutation plus sampled cumulative offsets. Empirically sized in
  `experiments/`; format and prefix-sum sampling not yet specified.
- **Disorder-proportional index.** A *compressed* permutation (rank deltas /
  Elias-Fano) makes the index shrink toward sparse-index sizes as the file becomes
  more ordered, potentially unifying sparse and exact into one adaptive structure.
- **Long-read index reduction.** Orthogonal to all of the above: the long-read
  exact index is dominated by 32 KiB zran windows. Levers are a larger default
  `checkpoint_span` or compressing the (highly compressible) windows.
</content>
