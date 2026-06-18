# Usage

## Build

```sh
make
```

The binary is written to `bin/fqix`. For a release build:

```sh
make release=1
```

## Basic Workflow

Build an index next to the source FASTQ:

```sh
fqix index reads.fastq.gz
```

This writes `reads.fastq.gz.fqix`.

Fetch one or more reads by name:

```sh
fqix get reads.fastq.gz read_001 read_002 > hits.fastq
```

If any read is not found, `fqix get` writes a message to stderr and exits with
code `2`. Found records are still written to stdout.

## Commands

### `fqix index`

```sh
fqix index [OPTIONS] reads.fastq.gz
```

Options:

- `-o, --output FILE`: write the index to `FILE`.
- `-c, --checkpoint-span BYTES`: target uncompressed spacing between gzip restart checkpoints.

The default checkpoint span is `4194304` bytes. Actual checkpoint spacing
depends on deflate block boundaries, so checkpoints may be farther apart than
requested.

### `fqix get`

```sh
fqix get [OPTIONS] reads.fastq.gz read-name...
```

`read-name` is the normalized FASTQ read name, not the full header line. In the
default mode this is the text after the header's first `@` up to the first
space or tab; a leading `@` in the query is treated as part of the read name.

Options:

- `-i, --index FILE`: use an explicit `.fqix` index path.
- `--first`: return only the first matching record for each requested name.
- `--count`: print `name<TAB>count` instead of FASTQ records.
- `--all`: return all matching records; this is the default.
- `--unique`: fail when a requested name has multiple matches.
- `--list FILE`: read additional query names from `FILE`, one name per line.
- `--order input|query`: output FASTQ records in original input order or query order.

### `fqix show`

```sh
fqix show reads.fastq.gz.fqix
fqix show --entries reads.fastq.gz.fqix
```

Without `--entries`, this prints index metadata. With `--entries`, it prints the
hash-sorted entry table.

### `fqix check`

```sh
fqix check reads.fastq.gz
```

This compares the index against the source file size and second-resolution
mtime.

Example output:

```text
ok	reads.fastq.gz.fqix
stale	reads.fastq.gz.fqix
```

## Input Requirements

`fqix` expects ordinary four-line FASTQ records in a `.fastq.gz` file. Read
names do not need to be sorted.

```text
@read_001 optional comment
ACGTACGT
+
IIIIIIII
```

The read name is parsed from after `@` up to the first space or tab. Wrapped
multiline sequence or quality fields are not supported.
