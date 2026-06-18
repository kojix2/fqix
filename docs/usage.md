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
- `-n, --name-interval N`: store one read-name anchor every `N` FASTQ records.

The default checkpoint span is `4194304` bytes. Actual checkpoint spacing
depends on deflate block boundaries, so checkpoints may be farther apart than
requested.

### `fqix get`

```sh
fqix get [OPTIONS] reads.fastq.gz read-name...
```

Options:

- `-i, --index FILE`: use an explicit `.fqix` index path.
- `-s, --scan-limit BYTES`: maximum decompressed bytes to scan after the selected anchor.

If lookup reports `scan limit reached`, increase `--scan-limit` or rebuild with
a smaller `--name-interval`.

### `fqix show`

```sh
fqix show reads.fastq.gz.fqix
fqix show --anchors reads.fastq.gz.fqix
```

Without `--anchors`, this prints index metadata. With `--anchors`, it also
prints the sparse read-name anchor table.

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

`fqix` expects ordinary four-line FASTQ records in a `.fastq.gz` file sorted by
read name.

```text
@read_001 optional comment
ACGTACGT
+
IIIIIIII
```

The read name is parsed from after `@` up to the first space or tab. Wrapped
multiline sequence or quality fields are not supported.
