# fqix

[![CI](https://github.com/kojix2/fqix/actions/workflows/ci.yml/badge.svg)](https://github.com/kojix2/fqix/actions/workflows/ci.yml)
[![build](https://github.com/kojix2/fqix/actions/workflows/build.yml/badge.svg)](https://github.com/kojix2/fqix/actions/workflows/build.yml)
[![Lines of Code](https://img.shields.io/endpoint?url=https%3A%2F%2Ftokei.kojix2.net%2Fbadge%2Fgithub%2Fkojix2%2Ffqix%2Flines)](https://tokei.kojix2.net/github/kojix2/fqix)
![Static Badge](https://img.shields.io/badge/PURE-VIBE_CODING-magenta)

fqix is a small command-line tool for fetching FASTQ records by read name from ordinary `fastq.gz` files.
It builds a `.fqix` index so lookup can resume gzip inflation near the requested read instead of decompressing from the beginning.

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

## Usage

Build the default index next to a FASTQ file:

```sh
fqix index reads.fastq.gz
```

Fetch one or more reads by name. Matching FASTQ records are written to stdout:

```sh
fqix get reads.fastq.gz read_001 read_002 > hits.fastq
```

Useful variants:

```sh
fqix index -o reads.fqix reads.fastq.gz
fqix get -i reads.fqix reads.fastq.gz read_001
fqix get --first reads.fastq.gz duplicate_name
fqix get --count --list names.txt reads.fastq.gz
fqix show reads.fastq.gz.fqix
fqix show --entries reads.fastq.gz.fqix
fqix check reads.fastq.gz
```

Checkpoint density can be tuned when needed:

```sh
fqix index --checkpoint-span 4194304 reads.fastq.gz
```

Run `fqix --help` or `fqix <command> --help` for the full option list. If any requested read is missing, `fqix get` writes a message to stderr and exits with code `2`.

## FASTQ Assumptions

`fqix` expects ordinary four-line FASTQ records in a `.fastq.gz` file. Read names do not need to be sorted.

```text
@read_001 optional comment
ACGTACGT
+
IIIIIIII
```

Multiline sequence or quality fields are not supported. The read name is the text after the header's first `@` up to the first space or tab. Query names are bare read names; a leading `@` in the query is treated as part of the name.

## How It Works

A `.fqix` index stores:

- [zran](https://github.com/madler/zlib/blob/develop/examples/zran.h)-style checkpoints for resuming gzip inflation
- one hash-sorted entry for every FASTQ record, plus a read-name string table

`fqix get` hashes the query name, checks hash-matching entries with an exact name comparison, resumes from the nearest gzip checkpoint, and extracts the indexed record size.

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
