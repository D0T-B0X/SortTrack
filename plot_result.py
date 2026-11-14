#!/usr/bin/env python3
"""Plot Onesweep vs rocPRIM vs std::sort execution time from results.csv.

Usage:
    python plot_results.py
    python plot_results.py --agg min --since 2026-11-14T06:00:00 --show

Needs matplotlib:  pip install matplotlib
"""

import argparse
import csv
import statistics
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent

SERIES = [
    ("onesweep_ms", "Onesweep", "o"),
    ("rocprim_ms", "rocPRIM (AMD)", "s"),
    ("cpu_ms", "C++ std::sort()", "^"),
]
AGGREGATORS = {
    "median": statistics.median,
    "min": min,
    "mean": statistics.mean,
    "last": lambda values: values[-1],
}


def to_float(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def load(results_path: Path, since: str):
    """Return {series_key: {size: [values in file order]}} for successful rows."""
    data = {key: defaultdict(list) for key, _, _ in SERIES}
    with results_path.open(newline="") as f:
        for row in csv.DictReader(f):
            if row.get("status") != "ok":
                continue
            if since and row.get("timestamp", "") < since:
                continue
            size = to_float(row.get("test_size"))
            if size is None:
                continue
            for key, _, _ in SERIES:
                value = to_float(row.get(key))
                if value is not None:
                    data[key][int(size)].append(value)
    return data


def main() -> int:
    ap = argparse.ArgumentParser(description="Plot execution times from results.csv.")
    ap.add_argument("--results", type=Path, default=ROOT / "results.csv")
    ap.add_argument("--out", type=Path, default=ROOT / "results_plot.png")
    ap.add_argument("--agg", choices=AGGREGATORS, default="median",
                    help="how to combine several runs of the same size (default: median)")
    ap.add_argument("--since", default="",
                    help="ignore rows older than this ISO timestamp, e.g. 2026-11-14T06:00:00")
    ap.add_argument("--show", action="store_true", help="open a window instead of only saving")
    args = ap.parse_args()

    if not args.results.exists():
        print(f"error: {args.results} not found", file=sys.stderr)
        return 1

    try:
        import matplotlib
        if not args.show:
            matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("error: matplotlib is not installed (pip install matplotlib)", file=sys.stderr)
        return 1

    data = load(args.results, args.since)
    agg = AGGREGATORS[args.agg]

    fig, ax = plt.subplots(figsize=(9, 5.5))
    plotted = 0
    for key, label, marker in SERIES:
        points = sorted((size, agg(values)) for size, values in data[key].items())
        if not points:
            print(f"note: no data for '{label}', skipping", file=sys.stderr)
            continue
        xs, ys = zip(*points)
        ax.plot(xs, ys, marker=marker, linewidth=1.8, markersize=6, label=label)
        plotted += 1

    if plotted == 0:
        print("error: no usable rows in results.csv", file=sys.stderr)
        return 1

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("Number of keys")
    ax.set_ylabel("Time (ms, log scale)")
    ax.set_title(f"Execution time by input size ({args.agg} of runs)")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend()
    fig.tight_layout()

    fig.savefig(args.out, dpi=150)
    print(f"saved {args.out}")
    if args.show:
        plt.show()
    return 0


if __name__ == "__main__":
    sys.exit(main())