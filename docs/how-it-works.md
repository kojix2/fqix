# How It Works

`fqix` builds a hash-based read-name index for ordinary `.fastq.gz` files without
recompressing them.

## Indexing

`fqix index` reads the FASTQ file once and records two kinds of positions:

- zran-style gzip restart checkpoints, used to resume inflation near a target
  region
- one entry for every FASTQ record, sorted by read-name hash and record number

Each entry stores the normalized name location, record number, uncompressed
record offset, and record size. The input FASTQ order is preserved through
`record_number`; it is not required to be sorted by read name.

## Lookup

`fqix get` hashes the query name, binary-searches the matching hash range,
checks candidate names with an exact byte comparison, resumes gzip inflation from
the closest checkpoint before the record offset, and extracts the indexed record
size. The extracted header is normalized again and checked against the query.

## Tuning

`--checkpoint-span` controls the target spacing between gzip restart
checkpoints in uncompressed bytes. The actual spacing depends on deflate block
boundaries in the source gzip stream.

## Freshness Check

`fqix check` compares the source file size and second-resolution modification
time stored in the index. If either value differs, the index is reported as
stale.
