import pandas as pd
import numpy as np
from pathlib import Path

TEST_CASE_SIZE = 1_000_000_000

OUT_DIR = Path(__file__).resolve().parent.parent / "Tests"

def gen_test(n) -> np.ndarray:
    arr = np.arange(n, dtype=np.uint32)

    np.random.default_rng().shuffle(arr)
    return arr

def main():
    tests = gen_test(TEST_CASE_SIZE)

    df = pd.DataFrame({len(tests): tests})
    df.to_csv(OUT_DIR / 'tests.csv', index=False)

if __name__ == "__main__":
    main()