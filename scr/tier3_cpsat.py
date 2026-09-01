from __future__ import annotations

import argparse
import heapq
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
    candidate_set: frozenset[int]
    candidate_mask: int


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
                    candidate_set=frozenset(candidates),
                    candidate_mask=sum(1 << l for l in candidates),
                )
            )
    return tasks, by_flight_position


def solve(
    data: dict, incumbent: dict, seconds: float, workers: int,
    optimize: bool, max_successors: int, fix_starts: bool = False,
    start_slack: int = -1, fix_fraction: float = 0.0,
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

        if fix_starts:
            fixed = incumbent["task_start"][task.flight][task.position]
            model.Add(s == fixed)
        elif start_slack >= 0:
            center = incumbent["task_start"][task.flight][task.position]
            model.Add(s >= center - start_slack)
            model.Add(s <= center + start_slack)

    labor_index = {labor_id: i for i, labor_id in enumerate(data["LaborID"])}
    if fix_fraction > 0 and incumbent.get("cost", -1) >= 0:
        release_count = max(1, round(len(tasks) * (1.0 - fix_fraction)))
        ranked = sorted(
            range(len(tasks)),
            key=lambda i: data["labor_cost"][labor_index.get(
                incumbent["task_labor"][tasks[i].flight][tasks[i].position], 0)],
            reverse=True,
        )
        released = set(ranked[:release_count])
        for i, task in enumerate(tasks):
            if i in released:
                continue
            hinted_start = incumbent["task_start"][task.flight][task.position]
            hinted_labor = labor_index.get(
                incumbent["task_labor"][task.flight][task.position], -1)
            if task.release <= hinted_start <= task.deadline - task.duration:
                model.Add(start[i] == hinted_start)
            if hinted_labor in assigned[i]:
                model.Add(assigned[i][hinted_labor] == 1)

    # Flight-profile precedence DAG.
    for f, n_tasks in enumerate(data["flight_n_tasks"]):
        by_kind = {
            tasks[task_at[(f, t)]].kind: tasks[task_at[(f, t)]].index
            for t in range(n_tasks)
        }
        for succ_t in range(n_tasks):
            succ = tasks[task_at[(f, succ_t)]]
            for pred_kind in REQUIRED_PREDS[succ.kind]:
                if pred_kind in by_kind:
                    model.Add(end[by_kind[pred_kind]] <= start[succ.index])

    used = [model.NewBoolVar(f"used_{l}") for l in range(labor_count)]
    for l, indices in enumerate(candidate_tasks):
        if not indices:
            model.Add(used[l] == 0)
            continue
        xs = [assigned[i][l] for i in indices]
        model.AddMaxEquality(used[l], xs)

    # Redundant C9 propagation: optional intervals let CP-SAT's scheduling
    # propagator reason about each crew before routing arcs are selected.
    for l, indices in enumerate(candidate_tasks):
        intervals = [
            model.NewOptionalIntervalVar(
                start[i], tasks[i].duration, end[i], assigned[i][l], f"iv_{i}_{l}"
            )
            for i in indices
        ]
        if intervals:
            model.AddNoOverlap(intervals)

    # Sparse direct-successor graph.  A selected arc is a consecutive pair on
    # one crew time line.  Gates are fixed, so travel is a constant here.
    incoming: list[list[cp_model.IntVar]] = [[] for _ in tasks]
    outgoing: list[list[cp_model.IntVar]] = [[] for _ in tasks]
    first = [model.NewBoolVar(f"first_{i}") for i in range(len(tasks))]
    transitions = []
    arc_count = 0
    tasks_by_team_kind: dict[str, list[int]] = {}
    tasks_by_labor: list[list[int]] = [[] for _ in range(labor_count)]
    for task in tasks:
        tasks_by_team_kind.setdefault(task.team_kind, []).append(task.index)
        for l in task.candidates:
            tasks_by_labor[l].append(task.index)

    # Build candidate pairs from labor buckets ordered by release time.  Each
    # task inspects only a local time neighborhood instead of all pairs in its
    # TeamType bucket. Bounded heaps retain nearest outgoing and incoming arcs.
    selected_pairs = set()
    if max_successors > 0:
        out_heaps = [[] for _ in tasks]
        in_heaps = [[] for _ in tasks]
        seen_pairs = set()
        scan_radius = max(32, 4 * max_successors)

        def consider_pair(i: int, j: int) -> None:
            if i == j or (i, j) in seen_pairs:
                return
            seen_pairs.add((i, j))
            left, right = tasks[i], tasks[j]
            travel = data["travel"][left.gate][right.gate]
            if left.release + left.duration + travel > right.deadline - right.duration:
                return
            common_labor = left.candidate_set & right.candidate_set
            if not any(
                max(right.release,
                    max(left.release, data["labor_shift_start"][l])
                    + left.duration + travel)
                + right.duration <= min(right.deadline, data["labor_shift_end"][l])
                for l in common_labor
            ):
                return
            distance = abs(right.release - left.release - left.duration - travel)
            heapq.heappush(out_heaps[i], (-distance, -right.deadline, -j, j))
            heapq.heappush(in_heaps[j], (-distance, left.release, -i, i))
            if len(out_heaps[i]) > max_successors:
                heapq.heappop(out_heaps[i])
            if len(in_heaps[j]) > max_successors:
                heapq.heappop(in_heaps[j])

        for bucket in tasks_by_labor:
            ordered = sorted(bucket, key=lambda i: (tasks[i].release, tasks[i].deadline, i))
            for p, i in enumerate(ordered):
                for q in range(p + 1, min(len(ordered), p + scan_radius + 1)):
                    j = ordered[q]
                    consider_pair(i, j)
                    consider_pair(j, i)
        for i in range(len(tasks)):
            selected_pairs.update((i, item[3]) for item in out_heaps[i])
            selected_pairs.update((item[3], i) for item in in_heaps[i])
    else:
        for bucket in tasks_by_team_kind.values():
            selected_pairs.update((i, j) for i in bucket for j in bucket if i != j)

    # Always preserve direct incumbent path arcs, so a valid Tier-3 incumbent
    # remains representable inside every sparse LNS neighborhood.
    if incumbent.get("cost", -1) >= 0:
        incumbent_lines: dict[int, list[tuple[int, int]]] = {}
        for task in tasks:
            name = incumbent["task_labor"][task.flight][task.position]
            l = labor_index.get(name, -1)
            s = incumbent["task_start"][task.flight][task.position]
            if l in task.candidate_set and task.release <= s <= task.deadline - task.duration:
                incumbent_lines.setdefault(l, []).append((s, task.index))
        for line in incumbent_lines.values():
            line.sort()
            selected_pairs.update((left[1], right[1]) for left, right in zip(line, line[1:]))

    for i, j in sorted(selected_pairs):
            left, right = tasks[i], tasks[j]
            travel = data["travel"][left.gate][right.gate]
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

    if incumbent.get("cost", -1) >= 0:
        for task in tasks:
            hinted_start = incumbent["task_start"][task.flight][task.position]
            if task.release <= hinted_start <= task.deadline - task.duration:
                model.AddHint(start[task.index], hinted_start)
            hinted_name = incumbent["task_labor"][task.flight][task.position]
            hinted_labor = labor_index.get(hinted_name, -1)
            if hinted_labor in assigned[task.index]:
                model.AddHint(labor[task.index], hinted_labor)
                model.AddHint(assigned[task.index][hinted_labor], 1)

    total_cost = sum(data["labor_cost"][l] * used[l] for l in range(labor_count))
    if optimize:
        model.Minimize(total_cost)

    solver = cp_model.CpSolver()
    if seconds > 0:
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
    parser.add_argument("--fix-starts", action="store_true")
    parser.add_argument("--start-slack", type=int, default=-1)
    parser.add_argument("--fix-fraction", type=float, default=0.0)
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
                args.optimize, level, args.fix_starts, args.start_slack,
                args.fix_fraction,
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
