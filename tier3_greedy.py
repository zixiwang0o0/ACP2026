"""Fast constructive Tier-3 scheduler for large instances."""
from __future__ import annotations

import argparse
import heapq
import json
import random
from pathlib import Path

from tier3_cpsat import REQUIRED_PREDS, REQUIRED_TEAM, load_json


def construct(data: dict, incumbent: dict, seed: int, debug: bool = False) -> dict | None:
    rng = random.Random(seed)
    gate_pos = {name: i for i, name in enumerate(data["GateID"])}
    try:
        gates = [gate_pos[name] for name in incumbent["gate"]]
    except (KeyError, ValueError):
        return None

    tasks = []
    at = {}
    for f, count in enumerate(data["flight_n_tasks"]):
        for t in range(count):
            rec = data["flight_tasks"][f][t]
            i = len(tasks)
            at[f, t] = i
            tasks.append({"f": f, "t": t, "kind": rec["kind"], "dur": rec["duration"]})

    preds = [[] for _ in tasks]
    succs = [[] for _ in tasks]
    for f, count in enumerate(data["flight_n_tasks"]):
        for pt in range(count):
            p = at[f, pt]
            for st in range(count):
                s = at[f, st]
                if tasks[p]["kind"] in REQUIRED_PREDS[tasks[s]["kind"]]:
                    preds[s].append(p)
                    succs[p].append(s)

    labor_by_kind = {}
    for l, kind in enumerate(data["labor_kind"]):
        labor_by_kind.setdefault(kind, []).append(l)
    candidates = []
    for task in tasks:
        f, duration = task["f"], task["dur"]
        choices = [
            l for l in labor_by_kind[REQUIRED_TEAM[task["kind"]]]
            if max(data["flight_arr"][f], data["labor_shift_start"][l]) + duration
            <= min(data["flight_dep"][f], data["labor_shift_end"][l])
        ]
        if not choices:
            return None
        candidates.append(choices)

    n = len(tasks)
    starts = [-1] * n
    chosen = [-1] * n
    remaining_preds = [len(p) for p in preds]
    ready = []
    for i in range(n):
        if remaining_preds[i] == 0:
            latest = data["flight_dep"][tasks[i]["f"]] - tasks[i]["dur"]
            heapq.heappush(ready, (len(candidates[i]), latest + rng.random() * 10.0, i))
    timelines = [[] for _ in data["LaborID"]]
    used = set()

    def write_partial():
        max_tasks = data["max_tasks"]
        rows_start = [[-1] * max_tasks for _ in data["FlightID"]]
        rows_labor = [[""] * max_tasks for _ in data["FlightID"]]
        for task_id, item in enumerate(tasks):
            value_start = starts[task_id]
            value_labor = chosen[task_id]
            if value_start < 0:
                continue
            rows_start[item["f"]][item["t"]] = value_start
            rows_labor[item["f"]][item["t"]] = data["LaborID"][value_labor]
        Path("tmp/tier3_greedy_partial.json").write_text(
            json.dumps({"gate": incumbent["gate"], "task_start": rows_start,
                        "task_labor": rows_labor, "cost": 0}, indent=2) + "\n",
            encoding="utf-8",
        )

    def valid_timeline(line):
        current_streak = None
        previous = None
        for task_id, task_start in line:
            if previous is None:
                current_streak = task_start
            else:
                prev_id, prev_start = previous
                travel = data["travel"][gates[tasks[prev_id]["f"]]][gates[tasks[task_id]["f"]]]
                prev_end = prev_start + tasks[prev_id]["dur"]
                if task_start < prev_end + travel:
                    return False
                if task_start - prev_end - travel >= 15:
                    current_streak = task_start
            if task_start > current_streak + 90:
                return False
            previous = (task_id, task_start)
        return True

    def options(i: int):
        task = tasks[i]
        f, duration, gate = task["f"], task["dur"], gates[task["f"]]
        precedence_ready = max(
            [data["flight_arr"][f]] + [starts[p] + tasks[p]["dur"] for p in preds[i]]
        )
        result = []
        for l in candidates[i]:
            line = timelines[l]
            for pos in range(len(line) + 1):
                s = max(precedence_ready, data["labor_shift_start"][l])
                if pos > 0:
                    prev_id, prev_start = line[pos - 1]
                    travel_in = data["travel"][gates[tasks[prev_id]["f"]]][gate]
                    s = max(s, prev_start + tasks[prev_id]["dur"] + travel_in)
                if (s + duration > data["flight_dep"][f]
                        or s + duration > data["labor_shift_end"][l]):
                    continue
                if pos < len(line):
                    next_id, next_start = line[pos]
                    travel_out = data["travel"][gate][gates[tasks[next_id]["f"]]]
                    if s + duration + travel_out > next_start:
                        continue
                trial = line[:pos] + [(i, s)] + line[pos:]
                if valid_timeline(trial):
                    score = s + len(line) * 5.0 + rng.random() * 3.0
                    result.append((score, s, l, pos))
        return result

    for _ in range(n):
        if not ready:
            return None
        batch = [heapq.heappop(ready) for _ in range(min(64, len(ready)))]
        ranked = []
        for item in batch:
            i = item[2]
            opts = options(i)
            if not opts:
                ranked = [((), i, opts, item)]
                break
            earliest = min(option[1] for option in opts)
            latest = data["flight_dep"][tasks[i]["f"]] - tasks[i]["dur"]
            ranked.append(((len(opts), latest - earliest, latest), i, opts, item))
        _, best_task, best_opts, chosen_item = min(ranked, key=lambda row: row[0])
        for item in batch:
            if item != chosen_item:
                heapq.heappush(ready, item)
        if not best_opts:
            if debug:
                write_partial()
                task = tasks[best_task]
                print(
                    "blocked",
                    {"task": best_task, "flight": task["f"], "kind": task["kind"],
                     "window": [data["flight_arr"][task["f"]], data["flight_dep"][task["f"]]],
                     "candidate_count": len(candidates[best_task])},
                )
            return None
        _, s, l, position = min(best_opts)
        task = tasks[best_task]
        starts[best_task], chosen[best_task] = s, l
        timelines[l].insert(position, (best_task, s))
        used.add(l)
        for j in succs[best_task]:
            remaining_preds[j] -= 1
            if remaining_preds[j] == 0:
                latest = data["flight_dep"][tasks[j]["f"]] - tasks[j]["dur"]
                heapq.heappush(
                    ready, (len(candidates[j]), latest + rng.random() * 10.0, j)
                )

    max_tasks = data["max_tasks"]
    rows_start = [[0] * max_tasks for _ in data["FlightID"]]
    rows_labor = [[data["LaborID"][0]] * max_tasks for _ in data["FlightID"]]
    for i, task in enumerate(tasks):
        rows_start[task["f"]][task["t"]] = starts[i]
        rows_labor[task["f"]][task["t"]] = data["LaborID"][chosen[i]]
    return {
        "gate": incumbent["gate"], "task_start": rows_start,
        "task_labor": rows_labor,
        "cost": sum(data["labor_cost"][l] for l in used),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("data", type=Path)
    parser.add_argument("incumbent", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--attempts", type=int, default=200)
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()
    data, incumbent = load_json(args.data), load_json(args.incumbent)
    best = None
    for attempt in range(args.attempts):
        result = construct(data, incumbent, 20260827 + attempt, args.debug and attempt == 0)
        if result is not None and (best is None or result["cost"] < best["cost"]):
            best = result
            print(f"attempt={attempt + 1} cost={best['cost']}")
    if best is None:
        raise SystemExit("No greedy Tier-3 solution found")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(best, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
