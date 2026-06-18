# fqix

[![CI](https://github.com/kojix2/fqix/actions/workflows/ci.yml/badge.svg)](https://github.com/kojix2/fqix/actions/workflows/ci.yml)
[![build](https://github.com/kojix2/fqix/actions/workflows/build.yml/badge.svg)](https://github.com/kojix2/fqix/actions/workflows/build.yml)
[![Lines of Code](https://img.shields.io/endpoint?url=https%3A%2F%2Ftokei.kojix2.net%2Fbadge%2Fgithub%2Fkojix2%2Ffqix%2Flines)](https://tokei.kojix2.net/github/kojix2/fqix)
![Static Badge](https://img.shields.io/badge/PURE-VIBE_CODING-magenta)

fqix is a small command-line tool for fetching FASTQ records by read name from ordinary `fastq.gz` files.
It builds a `.fqix` index so lookup can resume gzip inflation near the requested read instead of scanning from the beginning.

Note: `fqix` currently expects FASTQ files sorted by read name. It does not work with randomly ordered FASTQ files.

:alembic: Early Prototype

## Installation

Prebuilt binaries are available from [GitHub Releases](https://github.com/kojix2/fqix/releases).

To build from source:

```sh
git clone https://github.com/kojix2/fqix.git
cd fqix
make release=1
```

The binary is written to:

```sh
bin/fqix
```

## Quick Start

Given `reads.fastq.gz`:

1. Build an index

```sh
fqix index reads.fastq.gz
```

This creates:

```text
reads.fastq.gz.fqix
```

2. Fetch by read name

```sh
fqix get reads.fastq.gz read_001
```

You can request multiple reads at once:

```sh
fqix get reads.fastq.gz read_001 read_002 read_003
```

Matching FASTQ records are written to stdout:

```sh
fqix get reads.fastq.gz read_001 read_002 > hits.fastq
```

## Commands

### `fqix index`

Build a `.fqix` index from a `.fastq.gz` file.

```sh
fqix index reads.fastq.gz
```

Specify an output path:

```sh
fqix index -o reads.fqix reads.fastq.gz
```

### `fqix get`

Fetch FASTQ records by read name.

```sh
fqix get reads.fastq.gz read_001
```

Use an explicit index path:

```sh
fqix get -i reads.fqix reads.fastq.gz read_001
```

If any read is missing, a message is written to stderr and the exit code is `2`.

### `fqix show`

Show index metadata.

```sh
fqix show reads.fastq.gz.fqix
```

Print stored read-name anchors:

```sh
fqix show --raw reads.fastq.gz.fqix
```

### `fqix check`

Check whether an index still matches its source `.fastq.gz`.

```sh
fqix check reads.fastq.gz
```

Example output:

```text
ok	reads.fastq.gz.fqix
```

If the source file has changed:

```text
stale	reads.fastq.gz.fqix
```

## Common Options

Tune index density:

```sh
fqix index --checkpoint-span 4194304 --name-interval 1024 reads.fastq.gz
```

- `--checkpoint-span`: target spacing between gzip restart points, in uncompressed bytes.
- `--name-interval`: number of FASTQ records between stored read-name anchors.

Increase the forward scan limit during lookup:

```sh
fqix get --scan-bytes 16777216 reads.fastq.gz read_001
```

If lookup reports `scan limit reached`, increasing `--scan-bytes` may help.

## FASTQ Assumptions

`fqix` currently expects:

- `.fastq.gz` input
- records sorted by read name
- four-line FASTQ records
- no wrapped multiline sequence or quality fields

Example:

```text
@read_001 optional comment
ACGTACGT
+
IIIIIIII
```

The read name is parsed from after `@` up to the first space or tab. In this example, it is `read_001`.

## How It Works

A `.fqix` index stores:

- [zran](https://github.com/madler/zlib/blob/develop/examples/zran.h)-style checkpoints for resuming gzip inflation
- a sparse read-name index

`fqix get` finds a nearby read-name anchor, resumes from the nearest gzip checkpoint, then scans forward to the requested read.

## Limitations

- Multiline FASTQ is not supported.
- `fqix check` compares source file size and second-resolution mtime.
- Parallel lookup is not implemented.

## Development

Run tests:

```sh
make test
```

Tests link Mark Adler's zran example as a reference implementation, so a C compiler is required.

## License

fqix is licensed under the MIT License.

The files under `spec/support/` and the implementation in `src/fqix/zran.cr` are based on Mark Adler's [zran](https://github.com/madler/zlib/tree/develop/examples) from [zlib](https://github.com/madler/zlib), and are distributed under the [zlib License](https://github.com/madler/zlib/blob/develop/LICENSE).
