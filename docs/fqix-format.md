# FQIX File Format

This document describes the current `.fqix` on-disk format, version 1.

The format is little-endian. Integers are unsigned unless noted otherwise.
Strings are stored as raw UTF-8 bytes without a trailing NUL.

## Layout

```text
header
source path bytes
checkpoint metadata table
name anchor table
checkpoint windows
```

The first FASTQ record is always stored as a name anchor.

## Header

The header is 72 bytes.

| Offset | Size | Type | Field | Meaning |
| ---: | ---: | --- | --- | --- |
| 0 | 8 | bytes | magic | `FQIX\x01\0\0\0` |
| 8 | 4 | u32 | version | Currently `1` |
| 12 | 2 | u16 | flags | Reserved, must be `0` |
| 14 | 2 | u16 | padding | Reserved, must be `0` |
| 16 | 8 | u64 | source_size | Source `.fastq.gz` size in bytes |
| 24 | 8 | i64 | source_mtime | Source mtime as Unix seconds |
| 32 | 8 | u64 | checkpoint_span | Requested checkpoint span |
| 40 | 4 | u32 | name_interval | Requested name anchor interval |
| 44 | 4 | u32 | source_path_len | Byte length of the source path |
| 48 | 8 | u64 | ncheckpoints | Number of checkpoint entries |
| 56 | 8 | u64 | nnames | Number of name anchor entries |
| 64 | 8 | u64 | windows_offset | File offset of checkpoint windows |

Readers reject unknown versions and nonzero header flags.

## Source Path

Immediately after the header, `source_path_len` bytes store the source path used
when the index was built. The path is informational; stale-index checks compare
the current source file size and mtime against the header values.

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

## Name Anchor Table

Each name anchor entry is variable length.

| Offset | Size | Type | Field | Meaning |
| ---: | ---: | --- | --- | --- |
| 0 | 2 | u16 | name_len | Read-name byte length |
| 2 | name_len | bytes | name | Read name without the leading `@` |
| 2 + name_len | 8 | u64 | uncompressed_offset | FASTQ record start offset |
| 10 + name_len | 8 | u64 | checkpoint_id | Checkpoint metadata/window index |
| 18 + name_len | 8 | u64 | delta | `uncompressed_offset - checkpoint.out_offset` |

The name table is sparse. It is used to choose a nearby anchor; lookup then
inflates and scans forward until the requested record is found or the scan
limit is reached.

## Checkpoint Windows

At `windows_offset`, checkpoint windows are stored back-to-back. Each checkpoint
has one 32768-byte window, so the window for checkpoint `i` starts at:

```text
windows_offset + i * 32768
```

The window data is the zlib dictionary needed to resume raw inflate from that
checkpoint.

## Compatibility Notes

- Version 1 indexes store windows after the name table and load them lazily.
- Unknown index versions are rejected; rebuild the index with the current `fqix`.
- The format is tied to ordinary gzip streams and zran-style restart points, not
  BGZF blocks.
