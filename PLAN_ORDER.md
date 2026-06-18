# fqix Order Mode Plan

## Goal

Make the read-name ordering used by **sparse** indexes a first-class, persisted
property instead of a compile-time hook.

Today the comparator lives in [`src/fqix/order.cr`](src/fqix/order.cr) as a fixed
`Order.compare(a, b) = a <=> b` (bytewise lexicographic). Changing the order
means editing that file and rebuilding `fqix`. That is fine as a library
extension point but unacceptable for a CLI tool:

- the order cannot be chosen per file at index time;
- an existing `.fqix` file does not record how it was ordered;
- two builds of `fqix` can silently disagree about order.

This plan introduces explicit, named order modes that are selected at index
time and **stored in the sparse index**, so lookup always reproduces the build
order.

## Core invariant (the safety net)

Sparse lookup is correct only when build and lookup use the *same* comparator,
and only when the FASTQ body is monotonic under it. Both are already enforced at
build time: [`SparseNameTableBuilder`](src/fqix/index.cr) rejects a file that is
not monotonic under `Order.compare`.

Generalized to configurable order modes, this gives a strong guarantee:

> **If a sparse index builds successfully under order mode `O`, then lookups
> under `O` are correct.** An order under which the file is not monotonic fails
> the build with a clear message; it never produces silent wrong results.

A subtlety that matters once keys become lossy (PR2): a *poor but monotonic*
order can still be accepted. The file may be monotonic under several orders, and
a coarse one (long equal-key runs) is still correct — it only costs lookup
performance, not correctness. Precisely: a build that succeeds under `O` is
lookup-correct under `O`; it does not claim `O` is the *best* order.

Consequences:

- fqix does **not** need to trust the user's order declaration — the full-file
  monotonicity check validates it.
- The order must be a **total, deterministic function of the read name**
  (`order = f(name)`), computable at lookup time for an arbitrary query.
  - Orders based on something *not* in the read name (original sequencer
    position, external metadata, sample grouping with unsorted interiors) cannot
    be reproduced from a query and are out of scope for sparse → use `exact`.

## Scope: sparse only

Order is meaningful only for sparse lookup. Exact lookup hashes the name and is
order-independent.

- `--name-order` is a **sparse-only** option. Passing it with `--mode exact` prints a
  warning and is ignored (same pattern as the existing `--name-interval`
  warning in [`src/fqix/cli.cr`](src/fqix/cli.cr)).
- Exact indexes do not store an order mode. The existing `input_names_sorted`
  flag stays a bytewise diagnostic, computed with a **fixed** lexicographic
  comparison — never the configurable comparator (see below).

## Data model

Two orthogonal axes. Identity is always checked by the full read name; ordering
is by a (possibly lossy) key:

- **key extraction**: how a comparison key is derived from the name.
  - PR1: `Whole` (the normalized name itself).
  - Later: `Regex(pattern)` / field selection (lossy key; ties allowed).
- **key comparison**: how two keys are ordered.
  - PR1: `Lexicographic`, `Natural`.

The sparse scan already confirms a hit by comparing the full name in
[`RecordScanner`](src/fqix/reader.cr); making the key explicit means the binary
search and scan position by *key*, while a match is confirmed by *full name*.
This naturally supports weak orders (distinct names sharing a key): the
equal-key run is scanned and the exact name is matched within it.

On disk, the persisted discriminator is a single `order_mode : u8` (plus, in a
later revision, an inert `key_spec` for the regex/field family). PR1 only needs
`Lexicographic` and `Natural`.

```crystal
enum OrderMode : UInt8
  Lexicographic = 1
  Natural       = 2
  # Reserved for later revisions: RegexLexicographic, RegexNatural, presets…
end
```

`Order.compare` becomes a dispatch on the index's `order_mode` rather than a
single fixed body. Build and lookup of a **sparse** index both read the
comparator from the same persisted `order_mode` value.

To avoid an implementation hazard, keep a separate fixed
`Order.lexicographic_compare` (always bytewise, never dispatched):

- sparse builder + lookup use the dispatched comparator for `order_mode`;
- the exact builder's `input_names_sorted` diagnostic uses
  `lexicographic_compare` only, so making the sparse comparator configurable can
  never accidentally change the exact diagnostic.

## The `natural` comparator — frozen specification

`natural` is the workhorse for real-world data (see "Real-world fit" below). It
is persisted and lookup correctness depends on byte-for-byte reproducibility, so
its definition is **frozen** and documented. Changing it requires a sparse minor
version bump (see versioning).

Definition (frozen):

1. Split each key into maximal runs of ASCII digits `[0-9]` and maximal runs of
   non-digits.
2. Compare run by run, left to right:
   - non-digit vs non-digit: compare bytewise (unsigned).
   - digit vs digit: compare numerically **without integer conversion** — strip
     leading zeros, compare the length of the significant-digit strings, then,
     for equal length, compare significant digits bytewise. This handles
     arbitrary width with no overflow and no BigInt.
   - digit vs non-digit at the same position: the digit run orders first (fixed,
     documented).
3. Tiebreak for equal numeric value (e.g. `"01"` vs `"1"`): the run with the
   shorter raw length (fewer leading zeros) orders first, so distinct strings
   never compare equal by accident.
4. If all runs are equal, the keys are equal.

Implementation note: numeric comparison is `(strip leading zeros) → (compare
significant length) → (compare significant digits bytewise) → (tiebreak on raw
length)`. No integer/BigInt conversion is needed at any point.

Notes:

- No locale, no sign handling (`-` is a separator, not a minus), no `sort -V`
  dot/tilde special cases.
- Non-consecutive, variable-width numbers are the expected input and are handled
  by the significant-length rule.

## On-disk format

### Sparse 1.1

Order support is an additive change to the sparse (v1) format, so it bumps the
**sparse minor** version to `1.1`. The major/minor scheme from
[`docs/fqix-format.md`](docs/fqix-format.md) already supports this.

- `1.0` indexes have no order field and are read as `order_mode = Lexicographic`
  (the historical behavior).
- `1.1` adds `order_mode` (and reserves room for a future `order_pattern`).
- The reader dispatches on `version.major == 1` then handles minor `0` and `1`.
- Exact (`2.0`) is untouched.

Proposed `1.1` header (extends the 80-byte `1.0` header by appending fields;
`windows_offset` remains an absolute offset, so appending is safe). It is kept
**minimal** — only `order_mode` — rather than reserving a speculative
`order_pattern_len`, because the regex/field family needs a richer key-spec than
a single pattern and will define its own serialization later:

```text
... existing 1.0 header through record_count (offset 72, 8 bytes) = 80 bytes
order_mode : u8    @ 80
reserved   : u8[7] @ 81   (must be 0)
= 88-byte header (u64-aligned)
```

PR1 stores no pattern or key-spec. Reader validation for a `1.1` index:

- reject an unknown `order_mode` value;
- require the reserved bytes to be `0` (do not skip bytes we do not understand).

The regex/field key family is **not** part of `1.1`. When it lands it bumps to
`1.2`, defines its own inert key-spec serialization (stored after the source
path), and its reader must fold the key-spec length into the section-offset
validation:

```text
source_path_len + key_spec_len <= windows_offset - header_size
```

### Reader/writer

- `write_v1` writes `SPARSE_VERSION` as `1.1` and the `order_mode`.
- `read_v1_after_version` branches on `version.minor`: `0` → `Lexicographic`,
  no order bytes; `1` → read `order_mode` and the reserved bytes (which must be
  `0`).
- An unknown minor newer than supported is already rejected with a rebuild
  message.

## CLI

### index

```sh
fqix index reads.fastq.gz                               # sparse, --name-order auto (default)
fqix index --name-order natural reads.fastq.gz          # force natural
fqix index --name-order lex reads.fastq.gz              # force bytewise
fqix index --mode exact --name-order natural reads.fastq.gz   # warns: ignored
```

- `--name-order auto|lex|natural` (default `auto`), long-only. Sparse only; warn
  + ignore for exact.
- `auto` (the default) tries the fixed preset set `{lex, natural}` during the
  single build pass and **persists the first one the file is monotonic under**
  (precedence: `lex`, then `natural`). It never stores `auto`; the index always
  records a concrete mode. If neither is monotonic it fails, suggesting
  `--mode exact`. `auto` does **not** infer custom orders — that is PR2/PR3.
- Named `--name-order` (not `--order`) to avoid confusion with `get --order
  input|query`, which controls *output* record order, not the index's sort
  order. A short `-O` is avoided because it sits next to `index -o, --output`.
- A specific `--name-order` (not `auto`) verifies monotonicity under exactly that
  order and, on failure, names the offending pair and points at any preset that
  *would* work:
  `FASTQ is not sorted under --name-order lex near "X" < "Y"; try --name-order natural, sort the file, or use --mode exact`.
- When `auto` finds nothing monotonic:
  `FASTQ is not sorted under any built-in --name-order (tried lex, natural); sort the file or use --mode exact`.

### get

```sh
fqix get reads.fastq.gz DRR000001.572
```

- **No order option.** The order mode is read from the index and used for the
  anchor binary search ([`find_floor_name`](src/fqix/index.cr)) and the forward
  scan. This is the whole point of persisting it.

### show

```sh
fqix show reads.fastq.gz.fqix
```

- Prints `order_mode` for sparse indexes so users can see how a file was
  indexed.

## Real-world fit

Observation from real data: FASTQ files are frequently *already sorted*, by
idiosyncratic rules, and their numeric fields are **non-consecutive and
variable-width** (tile / x / y / coordinate / spot numbers), not a dense
counter.

This is the best case for `natural`:

- bytewise `lex` breaks on variable width (`.1000` sorts before `.265`);
- `natural` compares the numeric runs by value, left to right, and matches the
  common "sorted ascending by the name's natural field order" layout — which is
  the default output order of most instruments and sort tools;
- non-consecutive / variable-width numbers actually *disambiguate* `lex` vs
  `numeric` for a field, so order detection (later) is cleaner, not harder.

Example (DDBJ/SRA-style), normalized name is the first token after `@`
(`name_mode = FirstToken`):

```text
@DRR000001.265 3060N:7:1:502:2032 length=36
GTTTTTCCCCATTATTTATACCTCTGATAAAAGTAA
+DRR000001.265 3060N:7:1:502:2032 length=36
IIIIIIIIII<II@IGIHI3B3IA?1322+)--/:%
@DRR000001.572 3060N:7:1:620:2034 length=36
GGTGACAGCAGGATTACGGAAGACANNNNTNNGNNT
+...
@DRR000001.904 3060N:7:1:873:2032 length=36
GGCGGTTGTCAAAATAGGGATTCGATTTGCCGTTAA
```

Normalized keys: `DRR000001.265`, `DRR000001.572`, `DRR000001.904`.

- `natural`: shared prefix `DRR000001.`, then numeric `265 < 572 < 904` →
  monotonic. Stays correct when the spot number grows to `1000`+
  (`.904 < .1000`), where `lex` would fail.
- `lex`: happens to work *only* while every number is the same width.

`whole-name natural` is expected to cover the bulk of such files without any
regex/field key. The cases it does **not** cover (within non-consecutive numeric
data) are:

- sort not left-to-right by field order (e.g. by `y` before `x`);
- descending fields;
- a subset key (sorted by one field, ties arbitrary).

Those are the tail handled by the later field-key work.

## Staging

### PR1 — built-in modes + persistence + auto default (this plan)

- Add `OrderMode { Lexicographic, Natural }`.
- Implement and freeze the `natural` comparator.
- Make `Order.compare` dispatch on `order_mode`.
- Store `order_mode` in sparse indexes; bump sparse to `1.1`; read `1.0` as lex.
- `--name-order auto|lex|natural`, **default `auto`** (sparse only, warn on
  exact); `get` reads order from the index; `show` prints the concrete mode.
- `auto` is cheap over the two fixed presets: `SparseNameTableBuilder` tracks a
  per-candidate "still monotonic" flag (and first-violation pair) during the
  single build pass — anchors are recorded order-independently — and
  `build_sparse` resolves the concrete mode at finish. This is why `auto` is the
  default and not deferred: it makes bare `fqix index reads.fastq.gz` work on
  both lex- and natural-sorted files (e.g. the DRR example) with no flag, which
  the fixed `lex` default did not.
- `auto` cannot become the *single* default by switching to `natural`: a
  lex-sorted file of opaque IDs (`a10` < `a9` bytewise) is not natural-monotonic,
  so only "try both" is correct.

### PR2 — declarative key extraction (the "custom order" tail)

- A field/regex key spec (e.g. `--key-fields 3n,5n` / `--key-regex PATTERN`)
  combined with `lex|natural` comparison. Bumps sparse to `1.2`.
- Persisted as inert data (the `key_spec`), validated by the build monotonicity
  check; its length is folded into section-offset validation.
- Correctness vs cost: a lossy key (distinct names sharing a key) stays correct
  because the scanner reads the whole equal-key run and confirms by full name —
  but **the longer the equal-key run, the higher the lookup cost and the greater
  the `--scan-limit` risk**. A key that is too coarse is a performance trap, not
  a correctness bug.
- This is the engine the tail needs; build only when real files demand it.

### PR3 — inference over the field-key engine (optional)

- `--name-order auto` extended to *search* the field-key parameter space (field
  permutation × type × direction) via pairwise-monotonicity constraint solving
  over the build pass.
- Feasible and safe for field-structured names (full-file verification + a total
  comparator means existent queries are always found); impossible for non-field
  transforms (reverse / hash / length) → detect and fall back to `exact`.
- Inference is not a separate design: it is the PR2 engine plus a search layer
  that fills in the same persisted spec. Build the engine first.

### Deferred indefinitely — embedded expression languages (kexpr / mruby)

- Only needed for arbitrary, non-field name transforms (a rare long tail).
- For sparse, the order spec must be persisted and re-evaluated at lookup;
  embedding mruby means storing executable code in the index and running
  attacker-influenceable code when reading an index — a reproducibility and
  security burden that an inert declarative spec avoids.
- A small, pure, total expression language (kexpr) is the least-bad escape hatch
  if PR2's declarative spec proves insufficient, but it is not planned.

## Tests

PR1:

1. Build a sparse index with `--name-order natural` on a file like the DRR
   example; confirm `265 < 572 < 904` and that `get` returns each record.
2. A file sorted by variable-width numbers (`.9`, `.10`, `.100`): `natural`
   builds and looks up correctly; `lex` fails the monotonicity check.
3. A bytewise-sorted file builds under `--name-order lex` and fails under
   `natural` only if genuinely non-monotonic.
4. `auto` (the default) picks `natural` for the DRR example and `lex` for a
   bytewise-sorted file; an explicit `--name-order lex` on natural data fails
   and the message suggests `natural`; `auto` on data monotonic under neither
   fails suggesting `--mode exact`.
5. `order_mode` round-trips through write/read and appears in `show`.
6. A `1.0` index (no order field) reads back as `lex`.
7. A `1.1` index with an unknown `order_mode`, or non-zero reserved bytes, is
   rejected.
8. `--name-order` with `--mode exact` warns and is ignored; the exact
   `input_names_sorted` diagnostic stays bytewise regardless of `order_mode`.
9. `get` uses the persisted order with no order option supplied.

## Completion criteria for PR1

- `fqix index --name-order auto|lex|natural` selects and persists the sparse
  order mode; the default is `auto`.
- `auto` tries `{lex, natural}` and persists the first monotonic one (precedence
  lex → natural), so bare `fqix index` works on lex- and natural-sorted files;
  it never stores `auto`, and fails to `--mode exact` when neither is monotonic.
- Sparse `1.1` indexes store `order_mode`; `1.0` indexes still read as `lex`;
  unknown `order_mode` and non-zero reserved bytes are rejected.
- `natural` is implemented to the frozen specification (no BigInt) and
  documented.
- `get` reproduces the build order from the index with no order option.
- `--name-order` is sparse-only and warns under `--mode exact`; the exact
  `input_names_sorted` diagnostic remains a fixed bytewise comparison.
- `show` reports the concrete `order_mode`.
- A specific `--name-order` reports monotonicity failures with an actionable
  message that points at a preset that would work.
- The regex/field key spec (PR2) is explicitly **out of PR1 scope**.
