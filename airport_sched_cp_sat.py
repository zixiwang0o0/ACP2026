"""Native OR-Tools CP-SAT model for airport scheduling (C1-C12)."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from ortools.sat.python import cp_model


PREDS = {
    "DISEMBARK": {"ARRIVE_SECURE"}, "BAG_UNLOAD": {"ARRIVE_SECURE"},
    "FUEL": {"DISEMBARK", "CARGO_UNLOAD"}, "CABIN_CLEAN": {"DISEMBARK"},
    "WATER_LAV": {"DISEMBARK"}, "CATERING": {"DISEMBARK"},
    "BAG_LOAD": {"BAG_UNLOAD"},
    "INTL_DOCS": {"CABIN_CLEAN", "CATERING", "FUEL", "WATER_LAV"},
    "BOARDING": {"CABIN_CLEAN", "CATERING", "FUEL", "WATER_LAV", "INTL_DOCS"},
    "PUSHBACK": {"BOARDING", "BAG_LOAD"}, "CARGO_LOAD": {"CARGO_UNLOAD"},
    "DEP_RELEASE": {"CARGO_LOAD", "FUEL"},
}
TEAM = {
    "ARRIVE_SECURE": "ramp_team", "DISEMBARK": "ramp_team",
    "BAG_UNLOAD": "baggage_team", "FUEL": "fuel_team",
    "CABIN_CLEAN": "cabin_clean_team", "WATER_LAV": "water_waste_team",
    "CATERING": "catering_team", "BAG_LOAD": "baggage_team",
    "INTL_DOCS": "ramp_team", "BOARDING": "ramp_team",
    "PUSHBACK": "pushback_team", "CARGO_UNLOAD": "baggage_team",
    "CARGO_LOAD": "baggage_team", "DEP_RELEASE": "pushback_team",
}


def solve(data: dict, time_limit: float, workers: int) -> dict | None:
    m = cp_model.CpModel()
    flights, gates, labors = data["FlightID"], data["GateID"], data["LaborID"]
    F, G, L, horizon = len(flights), len(gates), len(labors), data["horizon"]

    # C1-C4: static gate domains.
    gate_ok = []
    for f in range(F):
        allowed = []
        for g in range(G):
            size_ok = data["flight_size"][f] == "narrow" or data["gate_stand_size"][g] == "large"
            if (data["gate_open"][g] <= data["flight_arr"][f]
                    and data["flight_dep"][f] <= data["gate_close"][g]
                    and size_ok
                    and data["gate_op_type"][g] == data["flight_op_type"][f]
                    and data["gate_usage"][g] == data["flight_carrier"][f]):
                allowed.append(g)
        if not allowed:
            return None
        gate_ok.append(allowed)
    gate = [m.new_int_var_from_domain(cp_model.Domain.from_values(gate_ok[f]), f"gate_{f}") for f in range(F)]

    # C5: statically conflicting flights cannot share a gate.
    for f1 in range(F):
        for f2 in range(f1 + 1, F):
            if (data["flight_dep"][f1] + 30 > data["flight_arr"][f2]
                    and data["flight_dep"][f2] + 30 > data["flight_arr"][f1]):
                m.add(gate[f1] != gate[f2])

    tasks = []
    by_flight = [[] for _ in range(F)]
    for f in range(F):
        for t in range(data["flight_n_tasks"][f]):
            spec = data["flight_tasks"][f][t]
            i = len(tasks)
            tasks.append((f, t, spec["kind"], spec["duration"]))
            by_flight[f].append(i)
    N = len(tasks)
    start, end, compatible, assign = [], [], [], {}

    # C6, C7, C10: compatible labor domains and task windows.
    for i, (f, t, kind, duration) in enumerate(tasks):
        s = m.new_int_var(data["flight_arr"][f], data["flight_dep"][f] - duration, f"start_{i}")
        e = m.new_int_var(data["flight_arr"][f] + duration, data["flight_dep"][f], f"end_{i}")
        m.add(e == s + duration)
        start.append(s); end.append(e)
        choices = []
        for l in range(L):
            if (data["labor_kind"][l] == TEAM[kind]
                    and max(data["flight_arr"][f], data["labor_shift_start"][l]) + duration
                    <= min(data["flight_dep"][f], data["labor_shift_end"][l])):
                choices.append(l)
                x = m.new_bool_var(f"x_{i}_{l}")
                assign[i, l] = x
                m.add(s >= data["labor_shift_start"][l]).only_enforce_if(x)
                m.add(e <= data["labor_shift_end"][l]).only_enforce_if(x)
        if not choices:
            return None
        compatible.append(choices)
        m.add_exactly_one(assign[i, l] for l in choices)

    # C8: precedence within each flight.
    for f in range(F):
        for i in by_flight[f]:
            for j in by_flight[f]:
                if tasks[i][2] in PREDS.get(tasks[j][2], set()):
                    m.add(end[i] <= start[j])

    # Gate-pair travel variables are shared by all task arcs for that flight pair.
    travel_flat = [v for row in data["travel"] for v in row]
    travel_var = {}
    for f1 in range(F):
        for f2 in range(F):
            index = m.new_int_var(0, G * G - 1, f"travel_index_{f1}_{f2}")
            value = m.new_int_var(min(travel_flat), max(travel_flat), f"travel_{f1}_{f2}")
            m.add(index == gate[f1] * G + gate[f2])
            m.add_element(index, travel_flat, value)
            travel_var[f1, f2] = value

    # C9-C12: one circuit per labor. Self-loops mean "task not assigned".
    streak = [m.new_int_var(0, horizon, f"streak_{i}") for i in range(N)]
    used = []
    for l in range(L):
        candidates = [i for i in range(N) if (i, l) in assign]
        use = m.new_bool_var(f"used_{l}")
        used.append(use)
        if not candidates:
            m.add(use == 0)
            continue
        m.add_max_equality(use, [assign[i, l] for i in candidates])
        node = {task: k + 1 for k, task in enumerate(candidates)}
        arcs = []
        empty = m.new_bool_var(f"empty_{l}")
        m.add(empty + use == 1)
        arcs.append((0, 0, empty))
        for i in candidates:
            x = assign[i, l]
            not_x = m.new_bool_var(f"not_x_{i}_{l}")
            m.add(not_x + x == 1)
            arcs.append((node[i], node[i], not_x))
            first = m.new_bool_var(f"first_{i}_{l}")
            last = m.new_bool_var(f"last_{i}_{l}")
            arcs.extend(((0, node[i], first), (node[i], 0, last)))
            m.add(streak[i] == start[i]).only_enforce_if(first)
            m.add(start[i] <= streak[i] + 90).only_enforce_if(x)
        for i in candidates:
            fi = tasks[i][0]
            latest_i_end = data["flight_dep"][fi]
            for j in candidates:
                if i == j:
                    continue
                fj = tasks[j][0]
                # Skip arcs that cannot respect even zero travel.
                if data["flight_arr"][fi] + tasks[i][3] > data["flight_dep"][fj] - tasks[j][3]:
                    continue
                arc = m.new_bool_var(f"arc_{i}_{j}_{l}")
                arcs.append((node[i], node[j], arc))
                tv = travel_var[fi, fj]
                m.add(start[j] >= end[i] + tv).only_enforce_if(arc)
                rested = m.new_bool_var(f"rest_{i}_{j}_{l}")
                m.add_implication(rested, arc)
                m.add(start[j] >= end[i] + tv + 15).only_enforce_if(rested)
                m.add(start[j] <= end[i] + tv + 14).only_enforce_if([arc, rested.not_()])
                m.add(streak[j] == start[j]).only_enforce_if(rested)
                m.add(streak[j] == streak[i]).only_enforce_if([arc, rested.not_()])
        m.add_circuit(arcs)

    cost = sum(data["labor_cost"][l] * used[l] for l in range(L))
    m.minimize(cost)
    solver = cp_model.CpSolver()
    solver.parameters.max_time_in_seconds = time_limit
    solver.parameters.num_search_workers = workers
    solver.parameters.log_search_progress = True
    status = solver.solve(m)
    if status not in (cp_model.FEASIBLE, cp_model.OPTIMAL):
        return None

    out_gate = [gates[solver.value(gate[f])] for f in range(F)]
    out_start, out_labor = [], []
    for f in range(F):
        sr, lr = [], []
        for i in by_flight[f]:
            sr.append(solver.value(start[i]))
            chosen = next(l for l in compatible[i] if solver.boolean_value(assign[i, l]))
            lr.append(labors[chosen])
        while len(sr) < data["max_tasks"]:
            sr.append(0); lr.append(labors[0])
        out_start.append(sr); out_labor.append(lr)
    return {"gate": out_gate, "task_start": out_start, "task_labor": out_labor,
            "cost": int(solver.objective_value)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("instance", type=Path)
    parser.add_argument("-o", "--output", type=Path, required=True)
    parser.add_argument("--time-limit", type=float, default=60)
    parser.add_argument("--workers", type=int, default=8)
    args = parser.parse_args()
    result = solve(json.loads(args.instance.read_text(encoding="utf-8-sig")),
                   args.time_limit, args.workers)
    if result is None:
        raise SystemExit("No solution found within the limit")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(f"cost={result['cost']} output={args.output.resolve()}")


if __name__ == "__main__":
    main()
