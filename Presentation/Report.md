## PPT

I need a slide for the final presentation. Structure below:

### title card

including team name: Avalon Airpot Team

member: Keming Han, Yecheng Lao, Zixi Wang

### slide 1: the picture of our best outcome

![alt text](outcome.png)

### slide 2:

solvers and tools: MiniZinc Chuffled and Google OR-Tools CP-SAT
runtime limit = 300s

### slide 3: the techniques we used

workflow: 

1. use MiniZinc Chuffled to solve out the **tier2** solutions for all data.
2. Warm start to get a solution: we get the tier3 solution based on the solution of tier2.
   1. fix all the `gate` got from the existing tier2 solution
   2. recreate vars of `task_start` and `task_labor` 
   3. use tier2 value as CP-SAT hint: 
      1. try the solution got before
      2. if failed, release 10% of the var `task_start` and `task_labor`, and resolve. The released rate can be self-defined by the user. We have tried 10% to 30%.

3. optimisation(LNS): as if we get a solution, we can fix 90% of the solution and on this base, searching for a better solution with the added `constraint: cost < current_cost;`
   1. **question**: if the released percentage is too low, then we cannot find a new solution; if too much, then the runtime may still exceed the runtime limit.

<!-- ## format requirement

generate this slide with beamer, dark blue style. For other format that doesn't covered, use the default academic format. -->