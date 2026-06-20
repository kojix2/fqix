# Benchmark harness

A playground for measuring fqix index size, compression, and lookup behaviour.
No real data is committed: real archives are large and licensing-encumbered, so
instead a synthetic generator reproduces the *properties* that make real SRA/DRA
files behave the way they do. Everything under `out/` is generated and gitignored.

## Why synthetic, and why it looks real

Uniform-random FASTQ compresses at ~3x, but real short-read archives compress at
~5-6x — and `index / .gz` ratios scale with that compression ratio, so random
data makes indexes look misleadingly small. `fastq_gen.cr` reproduces the three
structural properties behind real compressibility:

1. the `+` separator repeats the full header (old SRA/DRA dumps);
2. base-call quality is autocorrelated (long runs of similar Phred values);
3. reads are substrings of a shared pool, and a fraction carry `N` runs.

Generation is deterministic for a given spec (seeded RNG), so runs are
reproducible and diffable.

| preset | read len | `+` line | ~compression | mimics |
| --- | ---: | --- | ---: | --- |
| `srr` | 76 | repeated header | ~5x | old short-read SRA/DRA |
| `illumina` | 150 | bare | ~4.3x | modern Illumina |
| `longread` | 10000 | bare | ~4.6x | long-read |

## Generate a FASTQ

```sh
crystal run benchmark/gen.cr -- --preset srr --records 200000
crystal run benchmark/gen.cr -- --preset srr --records 1000000 -o benchmark/out/big.fastq.gz
```

Prints the output path (stdout) and `records / uncompressed / gz / ratio`
(stderr). Knobs: `--preset`, `--records`, `--read-len`, `--accession`, `--seed`,
`--out-dir`, `-o/--output`.

## Measure exact-index size and lookup

`exact_size.cr` builds an exact index and appends one TSV row per run to
`benchmark/out/exact_size.tsv`, splitting the index into its **lookup table**
(`mphf + slots + overflow`) and its **zran windows**. Since v2.3 the windows are
deflate-compressed on disk, so `window_bytes` is the actual compressed section and
`raw_window_bytes` / `window_compress_ratio` show the saving.

```sh
crystal run benchmark/exact_size.cr -- --profile srr --records 200000
crystal run benchmark/exact_size.cr -- --input reads.fastq.gz   # measure a real file
```

Use enough `--records` to span several checkpoints; otherwise the single
`have == 0` first window dominates and per-record numbers are meaningless.
`--checkpoint-span` cannot be smaller than the 32 KiB zran window.

Key knobs: `--profile`, `--records`, `--read-len`, `--name-repeat` (duplicate
names → overflow slots), `--checkpoint-span`, `--input`, `--cleanup`.

### Plot

```sh
python3 benchmark/plot_exact_size.py   # requires matplotlib
```

Writes `benchmark/out/exact_size.png`: left panel = bytes/record split into
lookup table vs windows; right panel = lookup-table bytes/record for v2.0 / v2.1 /
v2.2 side by side.

## Measure raw window compressibility

`window_compression.cr` reports how well each checkpoint window deflates,
independent of the index format (per-window vs whole-block):

```sh
crystal run benchmark/window_compression.cr -- benchmark/out/srr-*.fastq.gz.fqix
```

## Files

- `fastq_gen.cr` — reusable synthetic FASTQ generator (presets + tunable spec)
- `gen.cr` — CLI to materialise a `.fastq.gz`
- `exact_size.cr` — exact-index size and lookup-latency harness (TSV output)
- `window_compression.cr` — per-window deflate ratio probe
- `plot_exact_size.py` — render `exact_size.tsv`
- `out/` — generated FASTQ, indexes, TSV, plots (gitignored)
