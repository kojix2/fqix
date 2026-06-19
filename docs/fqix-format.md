# FQIX File Format

fqix currently reads and writes two on-disk formats:

- version 1.1: sparse anchor index
- version 2.2: exact MPHF index

## Versioning

The version field is `major.minor`, split into two little-endian `u16` values right after the magic. The two axes are orthogonal:

- **major** is the index kind: `1` = sparse, `2` = exact. It matches the fifth byte of the magic.
- **minor** is a revision within that kind, bumped when its layout changes (`1.0`, `1.1`, … for sparse; `2.0`, `2.1`, … for exact).

A reader dispatches on `major`, then handles known `minor` revisions; an unknown `major`, or a `minor` newer than it understands, is rejected with a rebuild message. This split lets each kind evolve independently instead of consuming a shared sequential number. The two `u16` fields are byte-compatible with the earlier single `u32` version (`2` reads as `2.0`, `1` as `1.0`).

Both formats are little-endian. Integers are unsigned unless noted otherwise. Strings are stored as raw bytes without a trailing NUL.

## Version 1: sparse index

Sparse mode writes version 1 indexes.

### Layout

```text
header
source path bytes
checkpoint metadata table
sparse name anchor table
checkpoint windows
```

### Header

The v1.1 header is 88 bytes. v1.0 used the same fields through `record_count`
and had an 80-byte header; readers treat v1.0 as `order_mode = lex`.

| Offset | Size | Type | Field | Meaning |
| ---: | ---: | --- | --- | --- |
| 0 | 8 | bytes | magic | `FQIX\x01\0\0\0` |
| 8 | 2 | u16 | version_major | Index kind, `1` = sparse |
| 10 | 2 | u16 | version_minor | Sparse revision, `1` |
| 12 | 2 | u16 | flags | Reserved, must be `0` |
| 14 | 2 | u16 | padding | Reserved, must be `0` |
| 16 | 8 | u64 | source_size | Source `.fastq.gz` size in bytes |
| 24 | 8 | i64 | source_mtime | Source mtime as Unix seconds |
| 32 | 8 | u64 | checkpoint_span | Requested checkpoint span |
| 40 | 4 | u32 | name_interval | Sparse anchor interval |
| 44 | 4 | u32 | source_path_len | Byte length of source path |
| 48 | 8 | u64 | ncheckpoints | Number of checkpoint entries |
| 56 | 8 | u64 | nnames | Number of sparse anchors |
| 64 | 8 | u64 | windows_offset | File offset of checkpoint windows |
| 72 | 8 | u64 | record_count | Number of FASTQ records |
| 80 | 1 | u8 | order_mode | `1` = lex, `2` = natural |
| 81 | 7 | bytes | reserved | Reserved, must be `0` |

### Sparse name anchor

Each anchor is variable length:

```text
name_length: u16
name bytes
uncompressed_offset: u64
checkpoint_id: u64
delta: u64
```

Sparse indexes are compact, but lookup is correct only when the FASTQ is sorted by the stored read-name order.

`natural` order splits names into ASCII digit and non-digit runs. Non-digit runs
compare bytewise. Digit runs compare by numeric value without integer
conversion: strip leading zeros, compare significant digit length, compare
significant digits bytewise, then break equal numeric values by shorter raw
digit-run length.

## Version 2: exact index

Exact mode writes version 2 indexes.

### Layout

```text
header
source path bytes
mphf blob
slot table
overflow table
checkpoint metadata table
checkpoint windows
```

### Header

The v2.2 header is 128 bytes.

| Offset | Size | Type | Field | Meaning |
| ---: | ---: | --- | --- | --- |
| 0 | 8 | bytes | magic | `FQIX\x02\0\0\0` |
| 8 | 2 | u16 | version_major | Index kind, `2` = exact |
| 10 | 2 | u16 | version_minor | Exact revision, `2` |
| 12 | 2 | u16 | flags | Reserved, must be `0` |
| 14 | 2 | u16 | padding | Reserved, must be `0` |
| 16 | 8 | u64 | source_size | Source `.fastq.gz` size in bytes |
| 24 | 8 | i64 | source_mtime | Source mtime as Unix seconds |
| 32 | 8 | u64 | checkpoint_span | Requested checkpoint span |
| 40 | 1 | u8 | fingerprint_algorithm | `1` = FNV-1a 64-bit |
| 41 | 1 | u8 | name_mode | `1` = first token |
| 42 | 1 | u8 | input_names_sorted | Diagnostic flag |
| 43 | 1 | u8 | padding | Reserved, must be `0` |
| 44 | 8 | u64 | fingerprint_seed | Fingerprint seed |
| 52 | 8 | u64 | record_count | Number of FASTQ records |
| 60 | 8 | u64 | ncheckpoints | Number of checkpoint entries |
| 68 | 8 | u64 | nslots | Number of MPHF slots |
| 76 | 4 | u32 | source_path_len | Byte length of the source path |
| 80 | 8 | u64 | mphf_offset | File offset of the MPHF blob |
| 88 | 8 | u64 | slots_offset | File offset of the slot table |
| 96 | 8 | u64 | overflows_offset | File offset of the overflow table |
| 104 | 8 | u64 | checkpoints_offset | File offset of checkpoint metadata |
| 112 | 8 | u64 | windows_offset | File offset of checkpoint windows |
| 120 | 8 | bytes | reserved_tail | Reserved, must be `0` |

### MPHF blob

The MPHF blob is fqix-owned serialization of a pure-Crystal BBHash-style minimal perfect hash over distinct 64-bit read-name keys. It stores level bit arrays and a small fallback map. It maps a key to a slot id, or returns no slot when a non-member is provably absent.

### Slot table

Each slot is 14 bytes.

| Offset | Size | Type | Field | Meaning |
| ---: | ---: | --- | --- | --- |
| 0 | 8 | u64 | value | Inline record offset, or overflow-table offset |
| 8 | 4 | u32 | count_or_size | Inline record size, or overflow count |
| 12 | 1 | u8 | guard | Inline per-record guard; `0` for overflow slots |
| 13 | 1 | u8 | flags | `0` = inline, `1` = overflow |

### Overflow table

Each overflow entry is 13 bytes.

| Offset | Size | Type | Field | Meaning |
| ---: | ---: | --- | --- | --- |
| 0 | 8 | u64 | record_offset | Uncompressed FASTQ record start |
| 8 | 4 | u32 | record_size | FASTQ record byte size |
| 12 | 1 | u8 | guard | Per-record guard |

Lookup computes the 64-bit key, queries the MPHF, gathers the inline record or overflow run, filters by the per-record guard, extracts surviving candidates, and verifies the extracted FASTQ header. Verification is authoritative, so duplicate names and 64-bit key collisions remain correct.

## Checkpoint metadata

Both formats use the same 21-byte checkpoint metadata entry.

| Offset | Size | Type | Field | Meaning |
| ---: | ---: | --- | --- | --- |
| 0 | 8 | u64 | out_offset | Uncompressed offset at the checkpoint |
| 8 | 8 | u64 | in_offset | Compressed file offset |
| 16 | 1 | u8 | bits | Number of primed bits for raw inflate |
| 17 | 4 | u32 | have | Dictionary byte count |

At `windows_offset`, checkpoint windows are stored back-to-back. Each checkpoint has one 32768-byte window.

## Compatibility notes

- v1.1 sparse indexes are readable and writable; v1.0 sparse indexes are readable as lexicographic order.
- v2.2 exact indexes are readable and writable. v2.1 exact indexes are readable. v2.0 exact indexes are not supported; rebuild them.
- The format is tied to ordinary gzip streams and zran-style restart points, not BGZF blocks.
