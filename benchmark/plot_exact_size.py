#!/usr/bin/env python3
"""Plot exact-index size measurements produced by exact_size.cr.

Reads the TSV log and renders two panels:

  1. Stacked bytes-per-record for the v2.3 index (lookup table vs zran windows),
     showing what actually dominates each dataset.
  2. Lookup-table bytes per record for v2.0 / v2.1 / v2.2 side by side, so the
     compaction win is visible independent of how many windows a dataset carries.

Usage:
    python3 benchmark/plot_exact_size.py \
        [--input benchmark/out/exact_size.tsv] \
        [--output benchmark/out/exact_size.png]
"""

import argparse
import csv
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def load_rows(path):
    with open(path, newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    if not rows:
        sys.exit(f"no rows in {path}")
    # Keep only the most recent row per distinct configuration so reruns do not
    # stack up, while keeping genuinely different configs (e.g. name_repeat) apart.
    latest = {}
    for row in rows:
        latest[row.get("fastq_gz_path", row["dataset"])] = row
    return list(latest.values())


def f(row, key):
    value = row.get(key, "")
    return float(value) if value not in ("", None) else 0.0


def label(row):
    repeat = row.get("name_repeat", "1")
    suffix = f"\nrepeat={repeat}" if repeat not in ("", "1") else ""
    return f"{row['dataset']}\nn={row['records']}, {row['read_len']} bp{suffix}"


def plot(rows, output, title):
    labels = [label(r) for r in rows]
    records = [max(float(r["records"]), 1.0) for r in rows]

    # Panel 1: v2.3 bytes-per-record breakdown.
    lookup_bpr = [f(r, "lookup_bytes") / n for r, n in zip(rows, records)]
    window_bpr = [f(r, "window_bytes") / n for r, n in zip(rows, records)]
    other_bpr = [
        max(0.0, f(r, "index_bytes") / n - lb - wb)
        for r, n, lb, wb in zip(rows, records, lookup_bpr, window_bpr)
    ]

    # Panel 2: lookup-table bytes-per-record across format versions.
    v20 = [f(r, "v20_lookup_bytes") / n for r, n in zip(rows, records)]
    v21 = [f(r, "v21_lookup_bytes") / n for r, n in zip(rows, records)]
    v22 = [f(r, "v22_lookup_bytes") / n for r, n in zip(rows, records)]

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5.5))
    x = range(len(rows))

    ax1.bar(x, lookup_bpr, label="lookup table", color="#10b981")
    ax1.bar(x, window_bpr, bottom=lookup_bpr, label="zran windows", color="#ef4444")
    ax1.bar(
        x,
        other_bpr,
        bottom=[a + b for a, b in zip(lookup_bpr, window_bpr)],
        label="header / metadata",
        color="#64748b",
    )
    for i, r in zip(x, rows):
        ax1.text(
            i,
            f(r, "index_bytes") / records[i],
            f" {f(r, 'index_pct_of_gz'):.0f}% of .gz",
            ha="center",
            va="bottom",
            fontsize=9,
            color="#334155",
        )
    ax1.set_title("v2.3 index: bytes per record")
    ax1.set_ylabel("bytes / record")
    ax1.set_xticks(list(x))
    ax1.set_xticklabels(labels, fontsize=9)
    ax1.legend(fontsize=9)
    ax1.margins(y=0.15)

    width = 0.27
    ax2.bar([i - width for i in x], v20, width, label="v2.0 (48 B + name)", color="#94a3b8")
    ax2.bar(list(x), v21, width, label="v2.1 (20 B)", color="#60a5fa")
    ax2.bar([i + width for i in x], v22, width, label="v2.2 (MPHF)", color="#3b82f6")
    for i, r in zip(x, rows):
        ax2.text(
            i + width,
            v22[i],
            f" {f(r, 'v22_vs_v20_pct'):.0f}%",
            ha="center",
            va="bottom",
            fontsize=9,
            color="#334155",
        )
    ax2.set_title("lookup table: bytes per record by format")
    ax2.set_ylabel("bytes / record")
    ax2.set_xticks(list(x))
    ax2.set_xticklabels(labels, fontsize=9)
    ax2.legend(fontsize=9)
    ax2.margins(y=0.15)

    fig.suptitle(title, fontsize=15, fontweight="bold")
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    fig.savefig(output, dpi=130)
    print(f"wrote {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", default="benchmark/out/exact_size.tsv")
    parser.add_argument("--output", default="benchmark/out/exact_size.png")
    parser.add_argument("--title", default="fqix exact v2.3 index size")
    args = parser.parse_args()

    rows = load_rows(args.input)
    plot(rows, args.output, args.title)


if __name__ == "__main__":
    main()
