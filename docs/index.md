# fqix

`fqix` is an experimental FASTQ read-name index for ordinary `.fastq.gz` files.
It combines zran-style gzip restart checkpoints with a read-name lookup table.

fqix now has two explicit index modes:

- **sparse**: small v1-style anchor index; requires sorted read names.
- **exact**: larger v2-style full hash index; works without any read-name order assumption.

The default is `sparse` to avoid accidentally creating very large exact indexes.
Use `--mode exact` when the FASTQ order has been shuffled, filtered, merged, or is otherwise unreliable.

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

- FASTQ records must use the standard four-line layout; wrapped multiline sequence or quality fields are not supported.
- Sparse mode requires sorted read names.
- Exact mode can produce large indexes because it stores one entry per FASTQ record.
- Some gzip files may have sparse deflate block boundaries, so zran checkpoints may be farther apart than requested.
- `fqix check` compares source file size and second-resolution modification time.
- Parallel lookup is not implemented yet.

## License

fqix is licensed under the MIT License.

The files under `spec/support/` and the implementation in `src/fqix/zran.cr` are based on Mark Adler's zran from zlib, and are distributed under the zlib License.
