from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

sys.modules.setdefault("numexpr", None)
sys.modules.setdefault("bottleneck", None)
from ortools.sat.python import cp_model


REQUIRED_PREDS = {
    "ARRIVE_SECURE": set(),
    "DISEMBARK": {"ARRIVE_SECURE"},
    "BAG_UNLOAD": {"ARRIVE_SECURE"},
    "FUEL": {"DISEMBARK", "CARGO_UNLOAD"},
    "CABIN_CLEAN": {"DISEMBARK"},
    "WATER_LAV": {"DISEMBARK"},
    "CATERING": {"DISEMBARK"},
    "BAG_LOAD": {"BAG_UNLOAD"},
    "INTL_DOCS": {"CABIN_CLEAN", "CATERING", "FUEL", "WATER_LAV"},
    "BOARDING": {"CABIN_CLEAN", "CATERING", "FUEL", "WATER_LAV", "INTL_DOCS"},
    "PUSHBACK": {"BOARDING", "BAG_LOAD"},
    "CARGO_UNLOAD": set(),
    "CARGO_LOAD": {"CARGO_UNLOAD"},
    "DEP_RELEASE": {"CARGO_LOAD", "FUEL"},
}

REQUIRED_TEAM = {
    "ARRIVE_SECURE": "ramp_team",
    "DISEMBARK": "ramp_team",
    "BAG_UNLOAD": "baggage_team",
    "FUEL": "fuel_team",
    "CABIN_CLEAN": "cabin_clean_team",
    "WATER_LAV": "water_waste_team",
    "CATERING": "catering_team",
    "BAG_LOAD": "baggage_team",
    "INTL_DOCS": "ramp_team",
    "BOARDING": "ramp_team",
    "PUSHBACK": "pushback_team",
    "CARGO_UNLOAD": "baggage_team",
    "CARGO_LOAD": "baggage_team",
    "DEP_RELEASE": "pushback_team",
}


@dataclass(frozen=True)
class Task:
    index: int
    flight: int
    position: int
    kind: str
    team_kind: str
    duration: int
    release: int
    deadline: int
    gate: int
    candidates: tuple[int, ...]


def load_json(path: Path) -> dict:
    text = path.read_text(encoding="utf-8-sig")
    if "\n%" in text:
        text = text.split("\n%", 1)[0]
    return json.loads(text)


def build_tasks(data: dict, incumbent: dict) -> tuple[list[Task], dict[tuple[int, int], int]]:
    gate_index = {gate: i for i, gate in enumerate(data["GateID"])}
    fixed_gate = [gate_index[gate] for gate in incumbent["gate"]]
    tasks = []
    by_flight_position = {}
    for f, n_tasks in enumerate(data["flight_n_tasks"]):
        for t in range(n_tasks):
            record = data["flight_tasks"][f][t]
            duration = record["duration"]
            team_kind = REQUIRED_TEAM[record["kind"]]
            candidates = tuple(
                l
                for l in range(len(data["LaborID"]))
                if data["labor_kind"][l] == team_kind
                and max(data["flight_arr"][f], data["labor_shift_start"][l])
                + duration
                <= min(data["flight_dep"][f], data["labor_shift_end"][l])
            )
            if not candidates:
                raise ValueError(f"task {(f, t)} has no compatible labor")
            i = len(tasks)
            by_flight_position[(f, t)] = i
            tasks.append(
                Task(
                    index=i,
                    flight=f,
                    position=t,
                    kind=record["kind"],
                    team_kind=team_kind,
                    duration=duration,
                    release=data["flight_arr"][f],
                    deadline=data["flight_dep"][f],
                    gate=fixed_gate[f],
                    candidates=candidates,
                )
            )
    return tasks, by_flight_position


def solve(
    data: dict, incumbent: dict, seconds: float, workers: int,
    optimize: bool, max_successors: int,
) -> dict:
    tasks, task_at = build_tasks(data, incumbent)
    model = cp_model.CpModel()
    horizon = data["horizon"]
    labor_count = len(data["LaborID"])

    start = []
    end = []
    labor = []
    assigned: list[dict[int, cp_model.IntVar]] = []
    candidate_tasks: list[list[int]] = [[] for _ in range(labor_count)]
    for task in tasks:
        s = model.NewIntVar(task.release, task.deadline - task.duration, f"s_{task.index}")
        e = model.NewIntVar(task.release + task.duration, task.deadline, f"e_{task.index}")
        model.Add(e == s + task.duration)
        domain = cp_model.Domain.FromValues(list(task.candidates))
        lvar = model.NewIntVarFromDomain(domain, f"labor_{task.index}")
        xs = {}
        for l in task.candidates:
            x = model.NewBoolVar(f"x_{task.index}_{l}")
            xs[l] = x
            candidate_tasks[l].append(task.index)
            model.Add(lvar == l).OnlyEnforceIf(x)
            model.Add(s >= data["labor_shift_start"][l]).OnlyEnforceIf(x)
            model.Add(e <= data["labor_shift_end"][l]).OnlyEnforceIf(x)
        model.AddExactlyOne(xs.values())
        start.append(s)
        end.append(e)
        labor.append(lvar)
        assigned.append(xs)

    # Flight-profile precedence DAG.
    for f, n_tasks in enumerate(data["flight_n_tasks"]):
        for pred_t in range(n_tasks):
            pred = tasks[task_at[(f, pred_t)]]
            for succ_t in range(n_tasks):
                succ = tasks[task_at[(f, succ_t)]]
                if pred.kind in REQUIRED_PREDS[succ.kind]:
                    model.Add(end[pred.index] <= start[succ.index])

    used = [model.NewBoolVar(f"used_{l}") for l in range(labor_count)]
    for l, indices in enumerate(candidate_tasks):
        if not indices:
            model.Add(used[l] == 0)
            continue
        xs = [assigned[i][l] for i in indices]
        model.AddMaxEquality(used[l], xs)

    # Sparse direct-successor graph.  A selected arc is a consecutive pair on
    # one crew time line.  Gates are fixed, so travel is a constant here.
    incoming: list[list[cp_model.IntVar]] = [[] for _ in tasks]
    outgoing: list[list[cp_model.IntVar]] = [[] for _ in tasks]
    first = [model.NewBoolVar(f"first_{i}") for i in range(len(tasks))]
    transitions = []
    arc_count = 0
    tasks_by_team_kind: dict[str, list[int]] = {}
    for task in tasks:
        tasks_by_team_kind.setdefault(task.team_kind, []).append(task.index)

    for i, left in enumerate(tasks):
        left_candidates = set(left.candidates)
        possible_successors = []
        # Enumerate only the matching TeamType bucket, not every task pair.
        for j in tasks_by_team_kind[left.team_kind]:
            if i == j:
                continue
            right = tasks[j]
            common_labor = left_candidates.intersection(right.candidates)
            if not common_labor:
                continue
            travel = data["travel"][left.gate][right.gate]
            if left.release + left.duration + travel > right.deadline - right.duration:
                continue
            # Stronger safe pruning: at least one common LaborID must be able
            # to execute this order wholly inside its shift and task windows.
            shift_feasible = False
            for l in common_labor:
                left_start = max(left.release, data["labor_shift_start"][l])
                right_start = max(
                    right.release,
                    left_start + left.duration + travel,
                    data["labor_shift_start"][l],
                )
                if (left_start + left.duration <= data["labor_shift_end"][l]
                        and right_start + right.duration
                        <= min(right.deadline, data["labor_shift_end"][l])):
                    shift_feasible = True
                    break
            if not shift_feasible:
                continue
            distance = max(0, right.release - left.release - left.duration - travel)
            possible_successors.append((distance, right.deadline, j, travel))

        possible_successors.sort()
        if max_successors > 0:
            possible_successors = possible_successors[:max_successors]
        for _, _, j, travel in possible_successors:
            arc = model.NewBoolVar(f"arc_{i}_{j}")
            arc_count += 1
            incoming[j].append(arc)
            outgoing[i].append(arc)
            model.Add(labor[i] == labor[j]).OnlyEnforceIf(arc)
            model.Add(start[j] >= end[i] + travel).OnlyEnforceIf(arc)

            # Exact C12 streak transition on this direct arc.
            rest = model.NewBoolVar(f"rest_{i}_{j}")
            model.Add(start[j] - end[i] - travel >= 15).OnlyEnforceIf([arc, rest])
            model.Add(start[j] - end[i] - travel <= 14).OnlyEnforceIf([arc, rest.Not()])
            transitions.append((arc, i, j, rest))

    for j in range(len(tasks)):
        model.Add(sum(incoming[j]) + first[j] == 1)
        model.Add(sum(outgoing[j]) <= 1)

    streak = [model.NewIntVar(0, horizon, f"streak_{i}") for i in range(len(tasks))]
    for i in range(len(tasks)):
        model.Add(streak[i] == start[i]).OnlyEnforceIf(first[i])
        model.Add(streak[i] <= start[i])
        model.Add(start[i] - streak[i] <= 90)
    for arc, i, j, rest in transitions:
        model.Add(streak[j] == start[j]).OnlyEnforceIf([arc, rest])
        model.Add(streak[j] == streak[i]).OnlyEnforceIf([arc, rest.Not()])

    # Exactly one first task for every used LaborID connects all of that crew's
    # assigned tasks into one path.  A disconnected component would have to be
    # a positive-duration time cycle, which the travel inequalities forbid.
    for l, indices in enumerate(candidate_tasks):
        if not indices:
            continue
        first_on_l = []
        for i in indices:
            both = model.NewBoolVar(f"first_{i}_on_{l}")
            x = assigned[i][l]
            model.Add(both <= first[i])
            model.Add(both <= x)
            model.Add(both >= first[i] + x - 1)
            first_on_l.append(both)
        model.Add(sum(first_on_l) == used[l])

    labor_index = {labor_id: i for i, labor_id in enumerate(data["LaborID"])}
    for task in tasks:
        model.AddHint(start[task.index], incumbent["task_start"][task.flight][task.position])
        hinted_labor = labor_index[incumbent["task_labor"][task.flight][task.position]]
        if hinted_labor in assigned[task.index]:
            model.AddHint(labor[task.index], hinted_labor)
            model.AddHint(assigned[task.index][hinted_labor], 1)

    total_cost = sum(data["labor_cost"][l] * used[l] for l in range(labor_count))
    if optimize:
        model.Minimize(total_cost)

    solver = cp_model.CpSolver()
    solver.parameters.max_time_in_seconds = seconds
    solver.parameters.num_search_workers = workers
    solver.parameters.random_seed = 20260827
    solver.parameters.log_search_progress = False
    status = solver.Solve(model)
    print(
        f"status={solver.StatusName(status)} tasks={len(tasks)} "
        f"arcs={arc_count} conflicts={solver.NumConflicts()} "
        f"branches={solver.NumBranches()} wall={solver.WallTime():.2f}s"
    )
    if status not in (cp_model.FEASIBLE, cp_model.OPTIMAL):
        raise RuntimeError(f"CP-SAT did not find a solution: {solver.StatusName(status)}")

    max_tasks = data["max_tasks"]
    first_labor_id = data["LaborID"][0]
    start_rows = [[0] * max_tasks for _ in data["FlightID"]]
    labor_rows = [[first_labor_id] * max_tasks for _ in data["FlightID"]]
    selected_labor = set()
    for task in tasks:
        value = solver.Value(labor[task.index])
        start_rows[task.flight][task.position] = solver.Value(start[task.index])
        labor_rows[task.flight][task.position] = data["LaborID"][value]
        selected_labor.add(value)

    cost = sum(data["labor_cost"][l] for l in selected_labor)
    return {
        "gate": incumbent["gate"],
        "task_start": start_rows,
        "task_labor": labor_rows,
        "cost": cost,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("data", type=Path)
    parser.add_argument("incumbent", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--seconds", type=float, default=120.0)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--optimize", action="store_true")
    parser.add_argument("--max-successors", type=int, default=16)
    parser.add_argument(
        "--adaptive", action="store_true",
        help="retry infeasible sparse models with 16, 32, then 64 successors",
    )
    args = parser.parse_args()
    data = load_json(args.data)
    incumbent = load_json(args.incumbent)
    levels = [args.max_successors]
    if args.adaptive:
        levels = [k for k in (16, 32, 64) if k >= args.max_successors]
        if not levels:
            levels = [args.max_successors]
    solution = None
    last_error = None
    for level in levels:
        print(f"max_successors={level}")
        try:
            solution = solve(
                data, incumbent, args.seconds, args.workers,
                args.optimize, level,
            )
            break
        except RuntimeError as error:
            last_error = error
            print(f"level={level} failed: {error}")
    if solution is None:
        raise last_error or RuntimeError("adaptive search produced no solution")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(solution, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
