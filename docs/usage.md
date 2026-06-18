# Usage

## Build

```sh
make
```

The binary is written to `bin/fqix`. For a release build:

```sh
make release=1
```

## Basic workflow

Build an index next to the source FASTQ:

```sh
fqix index reads.fastq.gz
```

This writes `reads.fastq.gz.fqix`. The default index mode is `sparse`.

Use exact mode for unsorted or otherwise order-unreliable FASTQ files:

```sh
fqix index --mode exact reads.fastq.gz
```

Fetch one or more reads by name:

```sh
fqix get reads.fastq.gz read_001 read_002 > hits.fastq
```

If any read is not found, `fqix get` writes a message to stderr and exits with code `2`. Found records are still written to stdout.

## Commands

### `fqix index`

```sh
fqix index [OPTIONS] reads.fastq.gz
```

Options:

- `-o, --output FILE`: write the index to `FILE`.
- `-c, --checkpoint-span BYTES`: target uncompressed spacing between gzip restart checkpoints.
- `-m, --mode sparse|exact`: index strategy; default is `sparse`.
- `-n, --name-interval N`: sparse anchor interval; default is `1024`.
- `--name-order auto|lex|natural`: sparse read-name order; default is `auto`.

Sparse mode writes a v1-compatible small index and rejects unsorted FASTQ. Exact mode writes a v2 full hash index and accepts arbitrary FASTQ order.

By default (`auto`), fqix tries `lex` then `natural` during indexing and stores the first order the file is monotonic under, so a name-sorted FASTQ usually indexes with no flag — including files with variable-width numeric fields such as `DRR000001.904` before `DRR000001.1077`. Pass an explicit `--name-order lex` or `natural` to force one, or `--mode exact` if the file is not name-sorted at all. Exact mode ignores `--name-order`.

### `fqix get`

```sh
fqix get [OPTIONS] reads.fastq.gz read-name...
```

`read-name` is the normalized FASTQ read name, not the full header line. In the default name mode this is the text after the header's first `@` up to the first space or tab; a leading `@` in the query is treated as part of the read name.

Options:

- `-i, --index FILE`: use an explicit `.fqix` index path.
- `-s, --scan-limit BYTES`: sparse-mode forward scan limit; default is `16777216`.
- `--first`: return only the first matching record for each requested name.
- `--count`: print `name<TAB>count` instead of FASTQ records.
- `--all`: return all matching records (the default).
- `--unique`: fail when a requested name has multiple matches.

Duplicate read names are handled the same way in both modes: `--all`, `--count`, and `--unique` see every matching record.
- `--list FILE`: read additional query names from `FILE`, one name per line.
- `--order input|query`: output FASTQ records in original input order or query order.

### `fqix show`

```sh
fqix show reads.fastq.gz.fqix
fqix show --anchors reads.fastq.gz.fqix
fqix show --entries reads.fastq.gz.fqix
```

Without `--entries` or `--anchors`, this prints index metadata. With either raw option, it prints the mode-specific lookup table: sparse anchors for sparse indexes, exact hash entries for exact indexes.

### `fqix check`

```sh
fqix check reads.fastq.gz
```

This compares the index against the source file size and second-resolution mtime.

Example output:

```text
ok	reads.fastq.gz.fqix
stale	reads.fastq.gz.fqix
```

## Input requirements

fqix expects ordinary four-line FASTQ records in a `.fastq.gz` file.

```text
@read_001 optional comment
ACGTACGT
+
IIIIIIII
```

The read name is parsed from after `@` up to the first space or tab. Records are framed as four lines, and wrapped multiline sequence or quality fields are not supported. fqix does not otherwise validate FASTQ semantics such as `+` line contents or sequence/quality length agreement.
