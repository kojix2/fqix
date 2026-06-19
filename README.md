# fqix

[![CI](https://github.com/kojix2/fqix/actions/workflows/ci.yml/badge.svg)](https://github.com/kojix2/fqix/actions/workflows/ci.yml)
[![build](https://github.com/kojix2/fqix/actions/workflows/build.yml/badge.svg)](https://github.com/kojix2/fqix/actions/workflows/build.yml)
[![Lines of Code](https://img.shields.io/endpoint?url=https%3A%2F%2Ftokei.kojix2.net%2Fbadge%2Fgithub%2Fkojix2%2Ffqix%2Flines)](https://tokei.kojix2.net/github/kojix2/fqix)
![Static Badge](https://img.shields.io/badge/PURE-VIBE_CODING-magenta)

fqix is a small command-line tool for fetching FASTQ records by read name from ordinary `fastq.gz` files.
It builds a `.fqix` index so lookup can resume gzip inflation near the requested read instead of decompressing from the beginning.

:alembic: Early Prototype

## Installation

Prebuilt binaries are available from GitHub Releases.

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

By default, fqix builds a **sparse** index. Sparse indexes are small, but they require read names to be sorted by the index's read-name order. The default `--name-order auto` tries bytewise `lex` then `natural` and stores whichever order the file is monotonic under, so most name-sorted FASTQ files index with no flag (including names with variable-width numeric fields). Force one with `--name-order lex` or `natural`.

Use **exact** mode when the FASTQ read order is not reliable:

```sh
fqix index --mode exact reads.fastq.gz
```

Fetch one or more reads by name. Matching FASTQ records are written to stdout:

```sh
fqix get reads.fastq.gz read_001 read_002 > hits.fastq
```

Useful variants:

```sh
fqix index -o reads.fqix reads.fastq.gz
fqix index --mode sparse --name-interval 1024 reads.fastq.gz
fqix index --mode sparse --name-order natural reads.fastq.gz
fqix index --mode exact reads.fastq.gz
fqix get -i reads.fqix reads.fastq.gz read_001
fqix get --scan-limit 16777216 reads.fastq.gz read_001
fqix get --first reads.fastq.gz duplicate_name
fqix get --count --list names.txt reads.fastq.gz
fqix show reads.fastq.gz.fqix
fqix show --anchors reads.fastq.gz.fqix
fqix show --entries reads.fastq.gz.fqix
fqix check reads.fastq.gz
```

Run `fqix --help` or `fqix <command> --help` for the full option list. If any requested read is missing, `fqix get` writes a message to stderr and exits with code `2`.

## Index modes

### Sparse mode

Sparse mode is the v1-compatible small-index strategy.

It stores:

- zran checkpoints for resuming gzip inflation
- sparse read-name anchors, one every `--name-interval` records

Lookup finds the nearest lower anchor, resumes gzip inflation there, and scans forward until the requested read is found or the scan has moved past it.

Sparse mode is compact, but it requires the FASTQ to be sorted by the stored sparse read-name order. `lex` is bytewise lexicographic; `natural` compares ASCII digit runs numerically, so names like `read9`, `read10`, and `read100` can be indexed in their natural order. If the file is not sorted under the selected order, indexing fails and suggests another order or `--mode exact`.

### Exact mode

Exact mode is the v2 order-independent strategy.

It stores:

- zran checkpoints for resuming gzip inflation
- a minimal perfect hash over read-name keys
- slot and overflow tables that point to FASTQ records

Lookup hashes the query into an MPHF slot, filters the slot's record candidates with a small guard byte, resumes gzip inflation from each surviving candidate's checkpoint, extracts the indexed record size, and verifies the extracted FASTQ header.

Exact mode is larger than sparse mode, but it works even when read names are unsorted, shuffled, filtered, or concatenated in arbitrary order.

## FASTQ assumptions

fqix expects ordinary four-line FASTQ records in a `.fastq.gz` file:

```text
@read_001 optional comment
ACGTACGT
+
IIIIIIII
```

Multiline sequence or quality fields are not supported. The read name is the text after the header's first `@` up to the first space or tab. Query names are bare read names; a leading `@` in the query is treated as part of the name.

## Limitations

- Multiline FASTQ is not supported.
- Sparse mode requires read names sorted by the selected `--name-order`.
- Exact mode is larger than sparse mode because it stores one addressable record candidate per FASTQ record.
- `fqix check` compares source file size and second-resolution mtime.
- Parallel lookup is not implemented.

## Development

Run tests:

```sh
make test
```

Tests link Mark Adler's zran example as a reference implementation, so a C compiler is required.

See `PLAN_V3.md` for the dual-mode design and future exact-index compaction plan.

## License

fqix is licensed under the MIT License.

The files under `spec/support/` and the implementation in `src/fqix/zran.cr` are based on Mark Adler's zran example from zlib, and are distributed under the zlib License.
