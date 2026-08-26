% =============================================================================
% ACP Summer School 2026: Melbourne Airport Ground Operations
% MiniZinc CP starter (SKELETON -- fill in the C1..C12 constraint blocks).
%
% Run it with an instance JSON as the data file. Use the two flags below to
% suppress MiniZinc's solution separators so the output is a single clean JSON:
%     minizinc --soln-sep "" --search-complete-msg "" airport_sched.mzn data/hackathon_03.json > sol_03.json
% For the larger instances use OR-Tools CP-SAT with intermediate solutions:
%     minizinc --solver cp-sat -i --time-limit 300000 airport_sched.mzn data/hackathon_03.json
% MiniZinc reads the instance JSON directly: its top-level keys map to the parameters below.
%
% Output JSON contract (consumed by the grader):
%   { "gate":       ["<GateID>", ...],                        (FlightID)
%     "task_start": [[int, ...], ...],                        (FlightID x max_tasks)
%     "task_labor": [["<LaborID>", ...], ...],                (FlightID x max_tasks)
%     "cost":       int }
% This skeleton already declares the decision variables, prints the exact
% contract. You job is to ADD C1..C12 and minimise the true team cost.
% =============================================================================

include "globals.mzn";

% ---- Model-level enums (fixed across all instances) ----
enum Carrier   = { domestic, international };
enum Size      = { narrow, wide };
enum OpType    = { passenger, freighter };
enum StandSize = { small, large };

enum TeamType  = { ramp_team, baggage_team, fuel_team, catering_team,
                   cabin_clean_team, water_waste_team, pushback_team };

enum TaskType  = { ARRIVE_SECURE, DISEMBARK, BAG_UNLOAD, FUEL, CABIN_CLEAN,
                   WATER_LAV,     CATERING,  BAG_LOAD,   INTL_DOCS,
                   BOARDING,      PUSHBACK,
                   CARGO_UNLOAD,  CARGO_LOAD, DEP_RELEASE };

% Task precedence graph (fixed): a task may only start once all its preds finished.
array[TaskType] of set of TaskType: required_preds = [
  ARRIVE_SECURE: {},
  DISEMBARK:     {ARRIVE_SECURE},
  BAG_UNLOAD:    {ARRIVE_SECURE},
  FUEL:          {DISEMBARK, CARGO_UNLOAD},
  CABIN_CLEAN:   {DISEMBARK},
  WATER_LAV:     {DISEMBARK},
  CATERING:      {DISEMBARK},
  BAG_LOAD:      {BAG_UNLOAD},
  INTL_DOCS:     {CABIN_CLEAN, CATERING, FUEL, WATER_LAV},
  BOARDING:      {CABIN_CLEAN, CATERING, FUEL, WATER_LAV, INTL_DOCS},
  PUSHBACK:      {BOARDING, BAG_LOAD},
  CARGO_UNLOAD:  {},
  CARGO_LOAD:    {CARGO_UNLOAD},
  DEP_RELEASE:   {CARGO_LOAD, FUEL}
];

% The single team kind each task requires (fixed across all instances).
array[TaskType] of TeamType: required_team = [
  ARRIVE_SECURE: ramp_team,        DISEMBARK:  ramp_team,
  BAG_UNLOAD:    baggage_team,     FUEL:       fuel_team,
  CABIN_CLEAN:   cabin_clean_team, WATER_LAV:  water_waste_team,
  CATERING:      catering_team,    BAG_LOAD:   baggage_team,
  INTL_DOCS:     ramp_team,        BOARDING:   ramp_team,
  PUSHBACK:      pushback_team,
  CARGO_UNLOAD:  baggage_team,     CARGO_LOAD: baggage_team,
  DEP_RELEASE:   pushback_team
];

% ---- Per-instance data (loaded from the instance JSON) ----
enum FlightID;
enum GateID;
enum LaborID;

int: horizon;
int: max_tasks;
set of int: TASK_IDX = 1..max_tasks;

% ---- Per-flight data ----
array[FlightID] of int: flight_arr; 
array[FlightID] of int: flight_dep; 
array[FlightID] of Carrier: flight_carrier;
array[FlightID] of Size: flight_size;
array[FlightID] of OpType: flight_op_type;
array[FlightID] of int: flight_n_tasks;
array[FlightID, TASK_IDX] of record(
  TaskType: kind,
  int: duration,
): flight_tasks;

% ---- Per-gate data ----
array[GateID] of StandSize: gate_stand_size;
array[GateID] of Carrier: gate_usage;
array[GateID] of OpType: gate_op_type;
array[GateID] of int: gate_open;
array[GateID] of int: gate_close;

% ---- Per-labor (team) data ----
array[LaborID] of TeamType: labor_kind;
array[LaborID] of int: labor_cost;
array[LaborID] of int: labor_shift_start;
array[LaborID] of int: labor_shift_end;

% ---- Per-gate travel data ----
array[GateID, GateID] of int: travel;

% Fixed constants.
int: min_gate_gap    = 30;      % C5: minimum inter-turn gap on a shared gate
int: max_work_streak = 90;      % C12: work streak after which a rest is required
int: rest_duration   = 15;      % C12: minimum rest gap

% ---- A test on whether a task index is active for a flight or not ----
function bool: active(FlightID: f, int: t) = t <= flight_n_tasks[f];

% ---- Decision variables ----
array[FlightID] of var GateID: gate;
array[FlightID, TASK_IDX] of var 0..horizon: task_start;
array[FlightID, TASK_IDX] of var LaborID: task_labor;

% ---- Constraints ----  (add yours here; see hackathon.pdf for the full text)
% Tier 1 (gate feasibility, C1-C5).
%
% Precompute the gates that satisfy all static requirements for each flight:
%   C1 the whole flight stay fits inside the gate's opening window;
%   C2 a wide-body flight uses a large stand (narrow-body fits either size);
%   C3 the gate's operation type matches the flight's operation type;
%   C4 the gate's domestic/international usage matches the flight's carrier.
array[FlightID] of set of GateID: compatible_gates = [
  { g | g in GateID where
      gate_open[g] <= flight_arr[f] /\
      flight_dep[f] <= gate_close[g] /\
      (flight_size[f] = narrow \/ gate_stand_size[g] = large) /\
      gate_op_type[g] = flight_op_type[f] /\
      gate_usage[g] = flight_carrier[f]
  }
  | f in FlightID
];

% C1-C4: every flight chooses exactly one gate from its compatible set.
% `gate[f]` is a single enum decision variable, so membership also enforces
% the "exactly one gate per flight" requirement.
constraint forall(f in FlightID)(
  gate[f] in compatible_gates[f]
);

% C5: a pair of flights conflicts when neither chronological order leaves the
% required 30-minute inter-turn gap. A conflicting pair cannot share a gate.
constraint forall(f1, f2 in FlightID where
  f1 < f2 /\
  flight_dep[f1] + min_gate_gap > flight_arr[f2] /\
  flight_dep[f2] + min_gate_gap > flight_arr[f1]
)(
  gate[f1] != gate[f2]
);

% Tier 2 (crew scheduling, C6-C10).
%
% A labor team is compatible with a task when it has the required specialty and
% its shift has a non-empty interval in which the whole task can be performed.
% The shift-overlap test is redundant with C7/C10, but removes impossible LaborID
% values before search.
array[FlightID, TASK_IDX] of set of LaborID: compatible_labor =
  array2d(FlightID, TASK_IDX, [
    if active(f, t) then
      { l | l in LaborID where
          labor_kind[l] = required_team[flight_tasks[f, t].kind] /\
          max(flight_arr[f], labor_shift_start[l]) + flight_tasks[f, t].duration
            <= min(flight_dep[f], labor_shift_end[l])
      }
    else
      { min(LaborID) }
    endif
    | f in FlightID, t in TASK_IDX
  ]);

% C6: every real task is assigned to exactly one team of the required kind.
% `task_labor[f,t]` is one enum variable, so membership also supplies the
% exactly-one part of the requirement.
constraint forall(f in FlightID, t in TASK_IDX where active(f, t))(
  task_labor[f, t] in compatible_labor[f, t]
);

% C7: every real task starts after arrival and finishes before departure.
constraint forall(f in FlightID, t in TASK_IDX where active(f, t))(
  task_start[f, t] >= flight_arr[f] /\
  task_start[f, t] + flight_tasks[f, t].duration <= flight_dep[f]
);

% C8: enforce every precedence arc whose predecessor is present in this
% flight's task list. Task types absent from a flight create no arc.
constraint forall(f in FlightID, pred_t, succ_t in TASK_IDX where
  active(f, pred_t) /\ active(f, succ_t) /\
  flight_tasks[f, pred_t].kind in required_preds[flight_tasks[f, succ_t].kind]
)(
  task_start[f, pred_t] + flight_tasks[f, pred_t].duration
    <= task_start[f, succ_t]
);

% C9: tasks assigned to the same LaborID may not overlap. Only pairs whose
% flight windows overlap, whose required team types match, and which share at
% least one compatible LaborID can possibly conflict. These static filters are
% important on the large instances and keep the flattened model compact.
constraint forall(f1, f2 in FlightID, t1, t2 in TASK_IDX where
  active(f1, t1) /\ active(f2, t2) /\
  (f1 < f2 \/ (f1 = f2 /\ t1 < t2)) /\
  flight_arr[f1] < flight_dep[f2] /\
  flight_arr[f2] < flight_dep[f1] /\
  required_team[flight_tasks[f1, t1].kind] =
    required_team[flight_tasks[f2, t2].kind] /\
  compatible_labor[f1, t1] intersect compatible_labor[f2, t2] != {}
)(
  task_labor[f1, t1] = task_labor[f2, t2] ->
    (task_start[f1, t1] + flight_tasks[f1, t1].duration <= task_start[f2, t2] \/
     task_start[f2, t2] + flight_tasks[f2, t2].duration <= task_start[f1, t1])
);

% C10: a task assigned to a team must be wholly contained in that team's shift.
constraint forall(f in FlightID, t in TASK_IDX where active(f, t))(
  task_start[f, t] >= labor_shift_start[task_labor[f, t]] /\
  task_start[f, t] + flight_tasks[f, t].duration
    <= labor_shift_end[task_labor[f, t]]
);

% Teams with identical kind, shift and cost are interchangeable. Require their
% first appearances to follow LaborID order to remove factorial assignment
% symmetries while preserving every distinct schedule and objective value.
constraint forall(rep in LaborID where
  rep = min({ l | l in LaborID where
    labor_kind[l] = labor_kind[rep] /\
    labor_cost[l] = labor_cost[rep] /\
    labor_shift_start[l] = labor_shift_start[rep] /\
    labor_shift_end[l] = labor_shift_end[rep]
  })
)(
  value_precede_chain(
    [l | l in LaborID where
      labor_kind[l] = labor_kind[rep] /\
      labor_cost[l] = labor_cost[rep] /\
      labor_shift_start[l] = labor_shift_start[rep] /\
      labor_shift_end[l] = labor_shift_end[rep]
    ],
    [task_labor[f, t] | f in FlightID, t in TASK_IDX where active(f, t)]
  )
);

% Tier 3 (routing + rest, C11-C12): TODO
%   C11 two consecutive tasks of one team at gates g1,g2 need travel[g1,g2] minutes between them;
%   C12 a team needs a >= 15-min rest once its work has spanned > 90 minutes.

% Redundant constraint: pin padding tasks so their output is fixed. (do not modify)
constraint forall(f in FlightID, t in TASK_IDX where not active(f, t))(
  task_start[f, t] = 0 /\ task_labor[f, t] = min(LaborID)
);

% ---- Tier 2 objective: cost of the distinct teams used by real tasks ----
array[LaborID] of var bool: used;
var int: cost;

% Exact usage equivalence, restricted to tasks for which a LaborID is a static
% candidate. The filter avoids materialising impossible task/labor pairs.
constraint assert(
  forall(l in LaborID)(labor_cost[l] > 0),
  "Tier 2 requires strictly positive labor costs"
);
constraint forall(l in LaborID)(
  used[l] <-> exists(f in FlightID, t in TASK_IDX where
    active(f, t) /\ l in compatible_labor[f, t]
  )(
    task_labor[f, t] = l
  )
);
constraint cost = sum(l in LaborID)(labor_cost[l] * bool2int(used[l]));

% Establish a concrete time line before choosing teams. Earliest feasible start
% values expose the interval graph to the subsequent first-fail labor search.
solve :: seq_search([
  int_search(
    [task_start[f, t] | f in FlightID, t in TASK_IDX where active(f, t)],
    smallest,
    indomain_min,
    complete
  ),
  int_search(
    [task_labor[f, t] | f in FlightID, t in TASK_IDX where active(f, t)],
    first_fail,
    indomain_min,
    complete
  ),
  int_search([gate[f] | f in FlightID], first_fail, indomain_min, complete)
]) minimize cost;

% ---- Output (do not modify) ----
function string: row_gate() =
  "[" ++ concat([ (if f = min(FlightID) then "" else ", " endif) ++
                  "\"" ++ show(fix(gate[f])) ++ "\"" | f in FlightID ]) ++ "]";
function string: row2d_int(array[FlightID, TASK_IDX] of var int: a) =
  "[" ++ concat([ (if f = min(FlightID) then "" else ", " endif) ++ "[" ++
                  concat([ (if t = 1 then "" else ", " endif) ++ show(fix(a[f, t])) | t in TASK_IDX ]) ++ "]"
                  | f in FlightID ]) ++ "]";
function string: row_task_labor() =
  "[" ++ concat([ (if f = min(FlightID) then "" else ", " endif) ++ "[" ++
                  concat([(if t = 1 then "" else ", " endif) ++ "\"" ++ show(fix(task_labor[f, t])) ++ "\""
                         | t in TASK_IDX]) ++ "]"
                  | f in FlightID ]) ++ "]";

output [
    "{\n",
    "  \"gate\":       ", row_gate(), ",\n",
    "  \"task_start\": ", row2d_int(task_start), ",\n",
    "  \"task_labor\": ", row_task_labor(), ",\n",
    "  \"cost\":       ", show(fix(cost)), "\n",
    "}\n"
];
