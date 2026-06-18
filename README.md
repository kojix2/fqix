# fqix

`fqix` is an experimental FASTQ read-name index for ordinary `.fastq.gz` files.

It is intended for name-sorted FASTQ files. It does not require re-compressing
with bgzip.

The index combines two tables in one `.fqix` file:

- zran-style gzip restart checkpoints
- a sparse read-name index

Lookup uses the sparse read-name index to find a nearby read, then resumes gzip
inflation from the nearest checkpoint and scans forward until the requested read
is found.

## Status

This is a minimal prototype.

Known limitations:

- FASTQ must be sorted by read name.
- FASTQ records must use the standard four-line layout; wrapped multiline
  sequence or quality fields are not supported.
- The index is sparse, not exact.
- Some gzip files may have sparse deflate block boundaries, so zran checkpoints
  may be farther apart than requested.
- `fqix check` compares the source file size and second-resolution modification
  time. Rewrites that keep the same size within the same second may not be
  reported as stale.
- Parallel lookup is not implemented yet.
- The low-level zran code uses zlib through Crystal's C bindings.

## Build

Requirements:

- Crystal
- zlib development headers

Tests also link Mark Adler's zran example as a reference implementation, so a C
compiler is required for `make test`.

```sh
make
```

The binary is:

```sh
bin/fqix
```

## Usage

Create an index:

```sh
fqix index reads.fastq.gz
```

This writes:

```sh
reads.fastq.gz.fqix
```

Fetch one or more reads:

```sh
fqix get reads.fastq.gz read_001 read_002
```

Use an explicit index path:

```sh
fqix index -o reads.fqix reads.fastq.gz
fqix get -i reads.fqix reads.fastq.gz read_001
```

Show index metadata:

```sh
fqix show reads.fastq.gz.fqix
```

Check whether the index matches the gzip file size and modification time:

```sh
fqix check reads.fastq.gz
```

Print version:

```sh
fqix --version
```

## Options

```sh
fqix index --checkpoint-span 4194304 --name-interval 1024 reads.fastq.gz
fqix get --scan-bytes 16777216 reads.fastq.gz read_001
```

`--checkpoint-span` controls the target distance between gzip restart points in
uncompressed bytes. Actual distances depend on deflate block boundaries.

`--name-interval` controls how many FASTQ records are skipped between sparse
read-name anchors.

`--scan-bytes` controls how much data is inflated after a sparse anchor during
lookup.

## Design

The `.fqix` file contains:

```text
header
checkpoint table
name table
```

A name entry stores:

```text
read name
uncompressed offset
checkpoint id
delta from checkpoint
```

This keeps the gzip restart index and read-name index as separate tables, while
still linking them directly for fast lookup.

## License

The overall fqix project is licensed under the MIT License.

The zran-related implementation in `src/fqix/zran.cr` is distributed under the
zlib License. It implements zran-derived checkpointing and extraction based on
Mark Adler's zran example from zlib.

The reference zran files under `spec/support/` are Mark Adler's zran example
and remain under the zlib License.
