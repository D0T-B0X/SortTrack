
#!/usr/bin/env python3
"""Benchmark onesweep vs rocPRIM in separate processes and append one row to results.csv.
 
The test binary is run as:   SortTrack_test <o|r> <size>
and must print:              Test size: <n>
                             Time: <ms>
 
Each algorithm runs in its own fresh process, and the two are alternated
(o, r, o, r, ...) so both see the same thermal / power drift.
 
Usage:
    python run_test.py 1000000
    python run_test.py 100000000 --rounds 3
    python run_test.py 1000000 --exe build-release/SortTrack_test --results results.csv
"""
 
import argparse
import csv
import re
import statistics
import subprocess
import sys
from datetime import datetime
from pathlib import Path
 
ROOT = Path(__file__).resolve().parent.parent
 
# binary argument -> (display name, results column)
ALGOS = {
    "o": ("onesweep", "onesweep_ms"),
    "r": ("rocPRIM", "rocprim_ms"),
}
 
# per-kernel columns are kept so older rows survive schema migration; new rows leave them empty
KERNEL_KEYS = ["hist", "scan", "bin0", "bin1", "bin2", "bin3"]
COLUMNS = [
    "timestamp",
    "test_type",
    "test_size",
    "onesweep_ms",
    "rocprim_ms",
    "vs_rocprim",       # onesweep_ms / rocprim_ms  (>1 means onesweep is slower)
    *[f"{k}_ms" for k in KERNEL_KEYS],
    "status",
]
 
SIZE_RE = re.compile(r"Test size:\s*(\d+)", re.IGNORECASE)
# accepts "Time: 2.5" and, if you later print a median, "Median: 2.5"
TIME_RE = re.compile(r"^\s*(?:Time|Median):\s*([\d.eE+-]+)", re.IGNORECASE | re.MULTILINE)
 
 
class RunError(Exception):
    pass
 
 
def run_once(exe: Path, algo: str, size: int, timeout: int):
    """Run one algorithm in a fresh process. Returns (actual_size, ms)."""
    try:
        proc = subprocess.run(
            [str(exe), algo, str(size)],
            cwd=exe.parent,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise RunError("timeout")
 
    if proc.returncode != 0:
        print(proc.stdout, end="")
        print(proc.stderr, end="", file=sys.stderr)
        raise RunError(f"exit_{proc.returncode}")
 
    size_match = SIZE_RE.search(proc.stdout)
    time_match = TIME_RE.search(proc.stdout)
    if size_match is None or time_match is None:
        print(proc.stdout, end="")
        raise RunError("parse_error")
    return int(size_match.group(1)), float(time_match.group(1))
 
 
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
    needs_header = not results_path.exists() or results_path.stat().st_size == 0
    with results_path.open("a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=COLUMNS)
        if needs_header:
            writer.writeheader()
        writer.writerow(row)
 
 
def main() -> int:
    ap = argparse.ArgumentParser(description="Benchmark onesweep vs rocPRIM and log the result.")
    ap.add_argument("size", type=int, help="number of keys to sort")
    ap.add_argument("--rounds", type=int, default=1,
                    help="alternate o/r this many times and log the median of each (default: 1)")
    ap.add_argument("--exe", type=Path, default=ROOT / "build" / "SortTrack_test",
                    help="path to the test binary (default: <project root>/build/SortTrack_test)")
    ap.add_argument("--results", type=Path, default=ROOT / "results.csv",
                    help="results file (default: <project root>/results.csv)")
    ap.add_argument("--timeout", type=int, default=600, help="seconds per process before giving up")
    ap.add_argument("--test-type", default="Random", help="label for the test_type column")
    args = ap.parse_args()
 
    exe = args.exe.resolve()
    if not exe.exists():
        print(f"error: test binary not found at {exe} (build it first)", file=sys.stderr)
        return 1
 
    row = {col: "" for col in COLUMNS}
    row["timestamp"] = datetime.now().isoformat(timespec="seconds")
    row["test_type"] = args.test_type
    row["test_size"] = args.size
 
    times = {algo: [] for algo in ALGOS}
    actual_size = args.size
    failures = []
 
    # alternate the two algorithms so both see the same drift in clocks and temperature
    for round_no in range(1, args.rounds + 1):
        for algo, (name, _) in ALGOS.items():
            try:
                actual_size, ms = run_once(exe, algo, args.size, args.timeout)
            except RunError as e:
                failures.append(f"{name}:{e}")
                break
            times[algo].append(ms)
            print(f"[{round_no}/{args.rounds}] {name}: {ms:.4f} ms")
        if failures:
            break
 
    if actual_size != args.size:
        print(f"note: binary sorted {actual_size} keys (csv had fewer than the {args.size} requested)",
              file=sys.stderr)
    row["test_size"] = actual_size
 
    for algo, (_, column) in ALGOS.items():
        if times[algo]:
            row[column] = f"{statistics.median(times[algo]):.4f}"
    if row["onesweep_ms"] and row["rocprim_ms"]:
        row["vs_rocprim"] = f"{float(row['onesweep_ms']) / float(row['rocprim_ms']):.3f}"
 
    row["status"] = "ok" if not failures else ";".join(failures)
    append_row(args.results, row)
 
    if failures:
        print(f"failed: {row['status']} (logged)", file=sys.stderr)
        return 1
 
    print(f"\nonesweep {row['onesweep_ms']} ms | rocPRIM {row['rocprim_ms']} ms | "
          f"ratio {row['vs_rocprim']}  (logged to {args.results})")
    return 0
 
 
if __name__ == "__main__":
    sys.exit(main())
 