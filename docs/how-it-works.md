# How It Works

fqix indexes ordinary `.fastq.gz` files without recompressing them. Both modes reuse zran-style gzip restart checkpoints; they differ only in the read-name lookup table.

| | Sparse (v1) | Exact (v2) |
| --- | --- | --- |
| Index size | Small (one anchor per `--name-interval` reads) | Larger (one addressable candidate per read) |
| Read-name order | Must be sorted by the stored `order_mode` | Any order |
| Lookup | Resume at nearest anchor, scan forward | Hash, then jump straight to the record |
| Default | Yes | `--mode exact` |

## Sparse mode

Sparse mode is the v1-compatible strategy.

During indexing, fqix reads the FASTQ once and records:

- gzip restart checkpoints
- the first read-name anchor
- every `--name-interval`-th read-name anchor

Sparse mode checks that read names are sorted by the selected `--name-order`. `lex` is bytewise lexicographic; `natural` compares ASCII digit runs by numeric value without integer conversion. The default `auto` tries `lex` then `natural` in the single indexing pass and stores the first order the file is monotonic under. If no order matches, indexing stops and suggests another order or `--mode exact`.

Lookup binary-searches the anchor table for the nearest lower name, resumes gzip inflation at that anchor, then scans forward. Because matching records sit together in sorted order, the scan collects every record with the target name, stopping once it moves past the name or reaches `--scan-limit`.

## Exact mode

Exact mode is the v2 order-independent strategy.

During indexing, fqix reads the FASTQ once and records each FASTQ record's lookup data:

- normalized read name
- uncompressed record offset
- record byte size

The normalized read names are hashed into distinct 64-bit keys, then fqix builds a pure-Crystal minimal perfect hash over those keys. The MPHF maps a query key to a slot. Each slot stores one record directly or points to an overflow run for duplicate names or rare 64-bit key collisions. A per-record guard byte rejects most missing-name queries before any FASTQ I/O.

Lookup computes the query key, gathers the slot's candidate records, filters them by guard, resumes gzip inflation from the closest checkpoint before each record offset, and extracts the indexed record size. The extracted header is normalized again and checked against the query. Verification is authoritative, so duplicate names and hash collisions cannot produce false matches.

## Tuning

`--checkpoint-span` controls the target spacing between gzip restart checkpoints in uncompressed bytes. Actual spacing depends on deflate block boundaries in the source gzip stream.

`--name-interval` controls sparse-index density. Smaller values make sparse lookup scan less but increase the index size.

`--name-order` controls the sparse read-name comparator and is stored in the index. Lookup reads the stored mode, so `fqix get` has no name-order option.

`--scan-limit` controls how far sparse lookup is allowed to scan after an anchor. Exact mode does not need it because each exact candidate stores the target record size.

## Freshness check

`fqix check` compares the source file size and second-resolution modification time stored in the index. If either value differs, the index is reported as stale.
