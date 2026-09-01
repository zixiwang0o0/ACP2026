## Guidance

Run all commands below from the repository root. The workflow is:

1. Use MiniZinc to obtain a valid gate-assignment seed.
2. Use `scr/tier2_cpsat.py` to solve C1-C10.
3. Use `scr/tier3_cpsat.py` with the Tier 2 solution as a warm start to solve C1-C12.
4. Use the same Tier 3 script with LNS to reduce labor cost.

The techniques are summarized in `Presentation/Avalon Airpot Team.pdf`.

## Run everything with Docker

Build the image, then solve all instances. Results are written to `solutions`.

```powershell
docker build -t airport-solver .
docker run --rm -v "${PWD}/solutions:/app/solutions" airport-solver
```

You can also use docker to run these code. Locate the Docker section.

### Requirements

```powershell
python -m pip install ortools
minizinc --version
```

## Command Line

### Tier 1 solution

The current MiniZinc model has Tier 3 disabled and also enforces C6-C10, so its
output is at least a valid Tier 1 seed and may already satisfy Tier 2.

```powershell
minizinc `
  --solver gecode `
  --time-limit 300000 `
  --soln-sep " " `
  --search-complete-msg " " `
  --output-to-file .\solutions\tier1\sol_01.json `
  .\scr\airport_sched.mzn `
  .\data\hackathon_01.json
```

### Tier 2 solution

The second input is the Tier 1 seed. Its gate assignment is fixed while CP-SAT
solves the task times and labor assignment.

```powershell
python .\scr\tier2_cpsat.py `
  .\data\hackathon_01.json `
  .\solutions\tier1\sol_01.json `
  .\solutions\tier2\sol_01.json `
  --seconds 300 `
  --workers 8
```

### Tier 3 solution

Tier 2 task times and labor assignments are supplied as CP-SAT hints. Gates
remain fixed. `--adaptive` expands sparse successor neighborhoods 16 -> 32 -> 64.

```powershell
python .\scr\tier3_cpsat.py `
  .\data\hackathon_01.json `
  .\solutions\tier2\sol_01.json `
  .\solutions\tier3\sol_01.json `
  --seconds 300 `
  --workers 8 `
  --max-successors 16 `
  --adaptive
```

### Optimize an existing Tier 3 solution with LNS

`--fix-fraction 0.7` fixes 70% of incumbent tasks and releases 30% of tasks
using high-cost labor. Write to `tmp` first so the incumbent is preserved.

```powershell
New-Item -ItemType Directory -Force .\tmp | Out-Null

python .\scr\tier3_cpsat.py `
  .\data\hackathon_01.json `
  .\solutions\tier3\sol_01.json `
  .\tmp\sol_01_lns70.json `
  --seconds 300 `
  --workers 8 `
  --max-successors 16 `
  --optimize `
  --fix-fraction 0.7
```

Only replace `solutions/tier3/sol_01.json` after confirming that the candidate
has a lower `cost`. Change every two-digit instance suffix consistently when
running another data file.
