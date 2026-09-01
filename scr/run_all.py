from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def run(command: list[str]) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=ROOT, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Solve every airport instance.")
    parser.add_argument("--instance", help="Two-digit instance suffix, e.g. 01")
    parser.add_argument("--seconds", type=int, default=300)
    parser.add_argument("--workers", type=int, default=8)
    args = parser.parse_args()

    pattern = f"hackathon_{args.instance}.json" if args.instance else "hackathon_*.json"
    data_files = sorted((ROOT / "data").glob(pattern))
    if not data_files:
        parser.error(f"no data file matches {pattern}")

    for data in data_files:
        suffix = data.stem.rsplit("_", 1)[-1]
        tier1 = ROOT / "solutions" / "tier1" / f"sol_{suffix}.json"
        tier2 = ROOT / "solutions" / "tier2" / f"sol_{suffix}.json"
        tier3 = ROOT / "solutions" / "tier3" / f"sol_{suffix}.json"
        tier1.parent.mkdir(parents=True, exist_ok=True)
        tier2.parent.mkdir(parents=True, exist_ok=True)
        tier3.parent.mkdir(parents=True, exist_ok=True)

        print(f"\n=== Solving instance {suffix} ===", flush=True)
        run([
            "minizinc", "--solver", "gecode",
            "--time-limit", str(args.seconds * 1000),
            "--soln-sep", "", "--search-complete-msg", "",
            "--output-to-file", str(tier1),
            str(ROOT / "scr" / "airport_sched.mzn"), str(data),
        ])
        run([
            sys.executable, str(ROOT / "scr" / "tier2_cpsat.py"),
            str(data), str(tier1), str(tier2),
            "--seconds", str(args.seconds), "--workers", str(args.workers),
        ])
        run([
            sys.executable, str(ROOT / "scr" / "tier3_cpsat.py"),
            str(data), str(tier2), str(tier3),
            "--seconds", str(args.seconds), "--workers", str(args.workers),
            "--max-successors", "16", "--adaptive",
        ])


if __name__ == "__main__":
    main()
