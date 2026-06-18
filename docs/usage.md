# Usage

Build the binary:

```sh
make
```

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

## Options

```sh
fqix index --checkpoint-span 4194304 --name-interval 1024 reads.fastq.gz
fqix get --scan-limit 16777216 reads.fastq.gz read_001
```

`--checkpoint-span` controls the target distance between gzip restart points in
uncompressed bytes. Actual distances depend on deflate block boundaries.

`--name-interval` controls how many FASTQ records are skipped between sparse
read-name anchors.

`--scan-limit` controls how much data is inflated after a sparse anchor during
lookup.
