# fqix

`fqix` is an experimental FASTQ read-name index for ordinary `.fastq.gz`
files.

It is intended for name-sorted FASTQ files. It does not require re-compressing
with bgzip.

The index combines zran-style gzip restart checkpoints with a sparse read-name
index. Lookup uses the sparse read-name index to find a nearby read, then
resumes gzip inflation from the nearest checkpoint and scans forward until the
requested read is found.

## Documentation

- [Usage](usage/)
- [License](license/)
- [API documentation](api/)

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
