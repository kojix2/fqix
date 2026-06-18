# fqix

`fqix` is an experimental FASTQ read-name index for ordinary `.fastq.gz`
files.

It does not require read-name sorted input or re-compressing with bgzip.

The index combines zran-style gzip restart checkpoints with one hash-sorted
entry per FASTQ record. Lookup hashes the query, verifies matching names exactly,
resumes gzip inflation from the nearest checkpoint, and extracts the indexed
record.

## Links

- [GitHub](https://github.com/kojix2/fqix)
- [Releases](https://github.com/kojix2/fqix/releases)

## Documentation

- [Usage](usage.html)
- [How it works](how-it-works.html)
- [FQIX file format](fqix-format.html)
- [API documentation](api/)

## Status

This is a minimal prototype.

Known limitations:

- FASTQ records must use the standard four-line layout; wrapped multiline
  sequence or quality fields are not supported.
- Some gzip files may have sparse deflate block boundaries, so zran checkpoints
  may be farther apart than requested.
- `fqix check` compares the source file size and second-resolution modification
  time. Rewrites that keep the same size within the same second may not be
  reported as stale.
- Parallel lookup is not implemented yet.

## License

fqix is licensed under the MIT License.

The files under `spec/support/` and the implementation in `src/fqix/zran.cr`
are based on Mark Adler's zran from zlib, and are distributed under the zlib
License.
