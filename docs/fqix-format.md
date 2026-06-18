# FQIX File Format

This document describes the current `.fqix` on-disk format, version 2.

The format is little-endian. Integers are unsigned unless noted otherwise.
Strings are stored as raw UTF-8 bytes without a trailing NUL.

## Layout

```text
header
source path bytes
entry table
name string table
checkpoint metadata table
checkpoint windows
```

## Header

The header is 112 bytes.

| Offset | Size | Type | Field | Meaning |
| ---: | ---: | --- | --- | --- |
| 0 | 8 | bytes | magic | `FQIX\x02\0\0\0` |
| 8 | 4 | u32 | version | Currently `2` |
| 12 | 2 | u16 | flags | Reserved, must be `0` |
| 14 | 2 | u16 | padding | Reserved, must be `0` |
| 16 | 8 | u64 | source_size | Source `.fastq.gz` size in bytes |
| 24 | 8 | i64 | source_mtime | Source mtime as Unix seconds |
| 32 | 8 | u64 | checkpoint_span | Requested checkpoint span |
| 40 | 1 | u8 | hash_algorithm | `1` = FNV-1a 64-bit |
| 41 | 1 | u8 | name_mode | `1` = first token |
| 42 | 1 | u8 | input_names_sorted | Diagnostic flag |
| 43 | 1 | u8 | padding | Reserved, must be `0` |
| 44 | 8 | u64 | hash_seed | Hash seed |
| 52 | 8 | u64 | record_count | Number of FASTQ records |
| 60 | 8 | u64 | ncheckpoints | Number of checkpoint entries |
| 68 | 8 | u64 | nentries | Number of record entries |
| 76 | 4 | u32 | source_path_len | Byte length of the source path |
| 80 | 8 | u64 | name_table_size | Byte length of the name string table |
| 88 | 8 | u64 | entries_offset | File offset of the entry table |
| 96 | 8 | u64 | name_table_offset | File offset of the name string table |
| 104 | 8 | u64 | windows_offset | File offset of checkpoint windows |

Readers reject non-v2 indexes with `unsupported fqix version N; please rebuild
the index`.

## Entry Table

Each entry is 48 bytes and entries are sorted by `(name_hash, record_number)`.

| Offset | Size | Type | Field | Meaning |
| ---: | ---: | --- | --- | --- |
| 0 | 8 | u64 | name_hash | Hash of the normalized read name |
| 8 | 8 | u64 | name_offset | Offset into the name string table |
| 16 | 4 | u32 | name_length | Name byte length |
| 20 | 8 | u64 | record_number | FASTQ appearance order |
| 28 | 8 | u64 | record_offset | Uncompressed FASTQ record start |
| 36 | 8 | u64 | record_size | FASTQ record byte size |
| 44 | 4 | u32 | flags | Reserved |

Lookup binary-searches the hash range and verifies candidate names with an exact
name-table byte comparison. The hash is only an accelerator; collisions are safe.

## Name String Table

The name string table stores concatenated normalized read names. Entries refer
to slices by `(name_offset, name_length)`.

## Checkpoint Metadata

Each checkpoint metadata entry is 21 bytes.

| Offset | Size | Type | Field | Meaning |
| ---: | ---: | --- | --- | --- |
| 0 | 8 | u64 | out_offset | Uncompressed offset at the checkpoint |
| 8 | 8 | u64 | in_offset | Compressed file offset |
| 16 | 1 | u8 | bits | Number of primed bits for raw inflate |
| 17 | 4 | u32 | have | Dictionary byte count |

The corresponding 32 KiB dictionary window is stored later in the checkpoint
window area.

## Checkpoint Windows

At `windows_offset`, checkpoint windows are stored back-to-back. Each checkpoint
has one 32768-byte window, so the window for checkpoint `i` starts at:

```text
windows_offset + i * 32768
```

The window data is the zlib dictionary needed to resume raw inflate from that
checkpoint.

## Compatibility Notes

- Version 1 indexes are not read; rebuild them with the current `fqix`.
- The format is tied to ordinary gzip streams and zran-style restart points, not
  BGZF blocks.
