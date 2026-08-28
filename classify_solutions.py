from __future__ import annotations

import json, re, shutil
from pathlib import Path
from tier3_cpsat import REQUIRED_PREDS, REQUIRED_TEAM, load_json

ROOT = Path(__file__).parent


def valid_tier(data, sol):
    try:
        gates = [data["GateID"].index(x) for x in sol["gate"]]
        if len(gates) != len(data["FlightID"]): return 0, None
    except (KeyError, ValueError, TypeError): return 0, None
    for f, g in enumerate(gates):
        if not (data["gate_open"][g] <= data["flight_arr"][f]
                and data["flight_dep"][f] <= data["gate_close"][g]
                and (data["flight_size"][f] == "narrow" or data["gate_stand_size"][g] == "large")
                and data["gate_op_type"][g] == data["flight_op_type"][f]
                and data["gate_usage"][g] == data["flight_carrier"][f]): return 0, None
    for a in range(len(gates)):
        for b in range(a + 1, len(gates)):
            if gates[a] == gates[b] and data["flight_dep"][a] + 30 > data["flight_arr"][b] \
                    and data["flight_dep"][b] + 30 > data["flight_arr"][a]: return 0, None
    try:
        starts, labors = sol["task_start"], sol["task_labor"]
        labor_idx = {x: i for i, x in enumerate(data["LaborID"])}
        timeline = [[] for _ in data["LaborID"]]
        for f, count in enumerate(data["flight_n_tasks"]):
            kinds = {data["flight_tasks"][f][t]["kind"]: t for t in range(count)}
            for t in range(count):
                spec = data["flight_tasks"][f][t]; s = starts[f][t]; e = s + spec["duration"]
                l = labor_idx[labors[f][t]]
                if data["labor_kind"][l] != REQUIRED_TEAM[spec["kind"]]: return 1, None
                if s < data["flight_arr"][f] or e > data["flight_dep"][f]: return 1, None
                if s < data["labor_shift_start"][l] or e > data["labor_shift_end"][l]: return 1, None
                for pk in REQUIRED_PREDS[spec["kind"]]:
                    if pk in kinds:
                        pt = kinds[pk]
                        if starts[f][pt] + data["flight_tasks"][f][pt]["duration"] > s: return 1, None
                timeline[l].append((s, e, gates[f]))
    except (KeyError, ValueError, TypeError, IndexError): return 1, None
    for line in timeline:
        line.sort()
        for x, y in zip(line, line[1:]):
            if x[1] > y[0]: return 1, None
    used = [l for l, line in enumerate(timeline) if line]
    cost = sum(data["labor_cost"][l] for l in used)
    for line in timeline:
        streak = None
        for i, item in enumerate(line):
            s, e, g = item
            if i == 0: streak = s
            else:
                ps, pe, pg = line[i - 1]
                travel = data["travel"][pg][g]
                if pe + travel > s: return 2, cost
                if s - pe - travel >= 15: streak = s
            if s - streak > 90: return 2, cost
    return 3, cost


def main():
    instances = {i: load_json(ROOT / "data" / f"hackathon_{i:02}.json") for i in range(1, 13)}
    by_count = {len(d["FlightID"]): i for i, d in instances.items()}
    best = {}
    for base in (ROOT / "sol", ROOT / "tmp"):
        for path in base.rglob("*.json"):
            if not path.stat().st_size: continue
            try: sol = load_json(path)
            except Exception: continue
            match = re.search(r"(?:sol_|hackathon_)(\d{2})", path.name)
            inst = int(match.group(1)) if match else by_count.get(len(sol.get("gate", [])))
            if inst not in instances: continue
            tier, cost = valid_tier(instances[inst], sol)
            if not tier: continue
            if cost is None: cost = sol.get("cost", 10**18)
            key = tier, inst
            if key not in best or cost < best[key][0]: best[key] = (cost, path)
    for (tier, inst), (cost, source) in sorted(best.items()):
        target = ROOT / "solutions" / f"tier{tier}" / f"sol_{inst:02}.json"
        shutil.copy2(source, target)
        print(f"tier{tier} data{inst:02} cost={cost} <- {source.relative_to(ROOT)}")


if __name__ == "__main__": main()
