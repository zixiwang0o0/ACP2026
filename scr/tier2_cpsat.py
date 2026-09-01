from __future__ import annotations

import argparse, json
from pathlib import Path
from ortools.sat.python import cp_model
from scr.tier3_cpsat import REQUIRED_PREDS, REQUIRED_TEAM, load_json


def solve(data: dict, seed: dict, seconds: float, workers: int) -> dict:
    model = cp_model.CpModel()
    labor_count = len(data["LaborID"])
    tasks, at = [], {}
    starts, ends, assigned = [], [], []
    labor_tasks = [[] for _ in range(labor_count)]

    for f, count in enumerate(data["flight_n_tasks"]):
        for t in range(count):
            spec = data["flight_tasks"][f][t]
            i = len(tasks); at[f, t] = i
            duration = spec["duration"]
            choices = [l for l in range(labor_count)
                       if data["labor_kind"][l] == REQUIRED_TEAM[spec["kind"]]
                       and max(data["flight_arr"][f], data["labor_shift_start"][l]) + duration
                       <= min(data["flight_dep"][f], data["labor_shift_end"][l])]
            s = model.new_int_var(data["flight_arr"][f], data["flight_dep"][f] - duration, f"s{i}")
            e = model.new_int_var(data["flight_arr"][f] + duration, data["flight_dep"][f], f"e{i}")
            model.add(e == s + duration)
            xs = {}
            for l in choices:
                x = model.new_bool_var(f"x{i}_{l}"); xs[l] = x
                model.add(s >= data["labor_shift_start"][l]).only_enforce_if(x)
                model.add(e <= data["labor_shift_end"][l]).only_enforce_if(x)
                labor_tasks[l].append(i)
            model.add_exactly_one(xs.values())
            tasks.append((f, t, spec["kind"], duration, choices))
            starts.append(s); ends.append(e); assigned.append(xs)

    for f, count in enumerate(data["flight_n_tasks"]):
        by_kind = {tasks[at[f, t]][2]: at[f, t] for t in range(count)}
        for t in range(count):
            j = at[f, t]
            for kind in REQUIRED_PREDS[tasks[j][2]]:
                if kind in by_kind: model.add(ends[by_kind[kind]] <= starts[j])

    for l, indices in enumerate(labor_tasks):
        intervals = [model.new_optional_interval_var(starts[i], tasks[i][3], ends[i],
                     assigned[i][l], f"iv{i}_{l}") for i in indices]
        if intervals: model.add_no_overlap(intervals)

    used = []
    for l, indices in enumerate(labor_tasks):
        u = model.new_bool_var(f"used{l}"); used.append(u)
        if indices: model.add_max_equality(u, [assigned[i][l] for i in indices])
        else: model.add(u == 0)
    solver = cp_model.CpSolver()
    solver.parameters.max_time_in_seconds = seconds
    solver.parameters.num_search_workers = workers
    status = solver.solve(model)
    print(solver.status_name(status), solver.wall_time)
    if status not in (cp_model.FEASIBLE, cp_model.OPTIMAL): raise RuntimeError(solver.status_name(status))

    max_tasks = data["max_tasks"]
    sr = [[0] * max_tasks for _ in data["FlightID"]]
    lr = [[data["LaborID"][0]] * max_tasks for _ in data["FlightID"]]
    for i, (f, t, _, _, choices) in enumerate(tasks):
        sr[f][t] = solver.value(starts[i])
        l = next(l for l in choices if solver.boolean_value(assigned[i][l]))
        lr[f][t] = data["LaborID"][l]
    cost = sum(data["labor_cost"][l] for l in range(labor_count) if solver.boolean_value(used[l]))
    return {"gate": seed["gate"], "task_start": sr, "task_labor": lr, "cost": cost}


if __name__ == "__main__":
    p = argparse.ArgumentParser(); p.add_argument("data", type=Path)
    p.add_argument("seed", type=Path); p.add_argument("output", type=Path)
    p.add_argument("--seconds", type=float, default=300); p.add_argument("--workers", type=int, default=8)
    a = p.parse_args(); result = solve(load_json(a.data), load_json(a.seed), a.seconds, a.workers)
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
