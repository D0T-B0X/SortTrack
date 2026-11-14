#!/usr/bin/env python3
"""Run the SortTrack test binary with a given size and append the result to results.csv.

Usage:
    python run_test.py 1000000
    python run_test.py 1000000 --exe build/SortTrack_test --results results.csv
"""

import argparse
import csv
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

KERNEL_KEYS = ["hist", "scan", "bin0", "bin1", "bin2", "bin3"]
COLUMNS = [
    "timestamp",
    "test_type",
    "test_size",
    "onesweep_ms",
    "rocprim_ms",
    "cpu_ms",
    "speedup",          # cpu_ms / onesweep_ms
    "vs_rocprim",       # onesweep_ms / rocprim_ms  (>1 means onesweep is slower)
    *[f"{k}_ms" for k in KERNEL_KEYS],
    "status",
]

PATTERNS = {
    "test_type": re.compile(r"Test Type:\s*(.+)"),
    "test_size": re.compile(r"Test Size:\s*(\d+)"),
    "onesweep_ms": re.compile(r"Onesweep time:\s*([\d.eE+-]+)\s*ms"),
    "cpu_ms": re.compile(r"CPU time:\s*([\d.eE+-]+)\s*ms"),
}
# Not required, so binaries that don't print a rocPRIM line still log.
# Matches "ROCM time: 1.2ms" and "Rocprim time: 1.2ms" (the scratch-space line has no "time:").
OPTIONAL_PATTERNS = {
    "rocprim_ms": re.compile(r"(?:rocm|rocprim)\s+time:\s*([\d.eE+-]+)\s*ms", re.IGNORECASE),
}
# Lines printed by RadixSort::sort, e.g. "Kernel bin2: 41.2ms"
KERNEL_PATTERN = re.compile(r"Kernel\s+(hist|scan|bin\d+):\s*([\d.eE+-]+)\s*ms")


def parse_output(text: str) -> dict:
    row = {}
    for key, pattern in PATTERNS.items():
        match = pattern.search(text)
        if match is None:
            raise ValueError(f"could not find '{key}' in test output")
        row[key] = match.group(1).strip()
    for key, pattern in OPTIONAL_PATTERNS.items():
        match = pattern.search(text)
        if match is not None:
            row[key] = match.group(1).strip()
    for name, value in KERNEL_PATTERN.findall(text):
        if name in KERNEL_KEYS:
            row[f"{name}_ms"] = value
    return row


def ensure_schema(results_path: Path) -> None:
    """If results.csv has an older header, rewrite it with the current columns."""
    if not results_path.exists() or results_path.stat().st_size == 0:
        return
    with results_path.open(newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames == COLUMNS:
            return
        rows = list(reader)
    with results_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=COLUMNS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)  # columns missing from old rows are left empty


def append_row(results_path: Path, row: dict) -> None:
    ensure_schema(results_path)
    # Create the file with a header if it doesn't exist (or is empty)
    needs_header = not results_path.exists() or results_path.stat().st_size == 0
    with results_path.open("a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=COLUMNS)
        if needs_header:
            writer.writeheader()
        writer.writerow(row)


def main() -> int:
    ap = argparse.ArgumentParser(description="Run the SortTrack test and log the result.")
    ap.add_argument("size", type=int, help="number of keys to sort")
    ap.add_argument("--exe", type=Path, default=ROOT / "build" / "SortTrack_test",
                    help="path to the test binary (default: <project root>/build/SortTrack_test)")
    ap.add_argument("--results", type=Path, default=ROOT / "results.csv",
                    help="results file (default: <project root>/results.csv)")
    ap.add_argument("--timeout", type=int, default=600, help="seconds before giving up")
    args = ap.parse_args()

    exe = args.exe.resolve()
    if not exe.exists():
        print(f"error: test binary not found at {exe} (build it first)", file=sys.stderr)
        return 1

    row = {col: "" for col in COLUMNS}
    row["timestamp"] = datetime.now().isoformat(timespec="seconds")
    row["test_size"] = args.size

    # Run from the binary's own folder in case it opens files relative to it
    try:
        proc = subprocess.run(
            [str(exe), str(args.size)],
            cwd=exe.parent,
            capture_output=True,
            text=True,
            timeout=args.timeout,
        )
    except subprocess.TimeoutExpired:
        row["status"] = "timeout"
        append_row(args.results, row)
        print(f"timed out after {args.timeout}s (logged)", file=sys.stderr)
        return 1

    if proc.returncode != 0:
        # The test exits with -1 on a wrong sort or a missing file; keep a record of the failure
        row["status"] = "fail"
        append_row(args.results, row)
        print(proc.stdout, end="")
        print(proc.stderr, end="", file=sys.stderr)
        print(f"test failed with exit code {proc.returncode} (logged)", file=sys.stderr)
        return 1

    try:
        parsed = parse_output(proc.stdout)
    except ValueError as e:
        row["status"] = "parse_error"
        append_row(args.results, row)
        print(proc.stdout, end="")
        print(f"error: {e} (logged)", file=sys.stderr)
        return 1

    row.update(parsed)
    row["speedup"] = f"{float(row['cpu_ms']) / float(row['onesweep_ms']):.3f}"
    if row["rocprim_ms"]:
        row["vs_rocprim"] = f"{float(row['onesweep_ms']) / float(row['rocprim_ms']):.3f}"
    row["status"] = "ok"
    append_row(args.results, row)

    print(proc.stdout, end="")
    print(f"logged to {args.results}")
    return 0


if __name__ == "__main__":
    sys.exit(main())