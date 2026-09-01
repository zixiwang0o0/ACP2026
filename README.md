## Guidance

This file aims to explain you how to use these script to find a solution of the scheduling problem. Following is the workflow:

1. use MiniZinc to find the tier1 solution.
2. use `tier2_cpsat.py` to find the tier2 solution.
3. use `tier3_cpsat.py` to find the tier3 solution.
4. use `tier3_cpsat.py` to optimize the tier3 solution.

The section below contains the command line we used. As for the techniques we used, a good reference is `Presentation\Avalon Airpot Team.pdf`.

### tier1 solution

```

```
### tier2 solution

```

```

### tier3 solution

```
python .\tier3_cpsat.py `
  .\data\hackathon_08.json `
  .\solutions\tier2\sol_06.json `
  .\solutions\tier3\sol_06.json `
  --seconds 300 `
  --workers 8 `
  --max-successors 16 `
  --adaptive
  ```

### optimize tier3 solution

```
python .\tier3_cpsat.py `
  .\data\hackathon_06.json `
  .\solutions\tier3\sol_06.json `
  .\tmp\sol_08_lns70.json `
  --seconds 300 `
  --workers 8 `
  --max-successors 16 `
  --optimize `
  --fix-fraction 0.7
```