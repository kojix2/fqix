# How It Works

`fqix` builds a sparse read-name index for ordinary `.fastq.gz` files without
recompressing them.

## Indexing

`fqix index` reads the FASTQ file once and records two kinds of positions:

- zran-style gzip restart checkpoints, used to resume inflation near a target
  region
- sparse read-name anchors, used to find a nearby FASTQ record by name

The input must be sorted by read name. This lets lookup scan forward from a
nearby anchor and stop once it has passed the requested name.

## Lookup

`fqix get` finds the nearest stored read-name anchor before the query, resumes
gzip inflation from the closest checkpoint before that anchor, and scans forward
through FASTQ records until the requested read is found.

If a read is not found before the scan limit, lookup fails with `scan limit
reached`. Increasing `--scan-limit` can help when checkpoints or anchors are far
apart.

## Tuning

`--checkpoint-span` controls the target spacing between gzip restart
checkpoints in uncompressed bytes. The actual spacing depends on deflate block
boundaries in the source gzip stream.

`--name-interval` controls how often read-name anchors are stored. Smaller
values make lookup scan less, but increase index size.

`--scan-limit` controls the maximum forward scan during `fqix get`.

## Freshness Check

`fqix check` compares the source file size and second-resolution modification
time stored in the index. If either value differs, the index is reported as
stale.
