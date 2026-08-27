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
array[LaborID] of var bool: used;
var int: cost;

% ---- Constraints ----  (add yours here; see hackathon.pdf for the full text)
% Tier 1: precompute gates satisfying C1-C4 to shrink gate domains.
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
constraint forall(f in FlightID)(gate[f] in compatible_gates[f]);

% C5: only statically conflicting flight pairs need a constraint.
constraint forall(f1, f2 in FlightID where
  f1 < f2 /\
  flight_dep[f1] + min_gate_gap > flight_arr[f2] /\
  flight_dep[f2] + min_gate_gap > flight_arr[f1]
)(
  gate[f1] != gate[f2]
);

% Tier 2 (crew scheduling, C6-C10): TODO
%   C6 the team assigned to a task is of kind required_team[flight_tasks[f,t].kind];
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
constraint forall(f in FlightID, t in TASK_IDX where active(f, t))(
  task_labor[f, t] in compatible_labor[f, t]
);

%   C7 each task runs inside its flight's [flight_arr, flight_dep] window;
constraint forall(f in FlightID, t in TASK_IDX where active(f, t))(
  flight_arr[f] <= task_start[f, t] /\
  task_start[f, t] + flight_tasks[f, t].duration <= flight_dep[f]
);

%   C8 precedence: a task starts only once all its required_preds finished;
constraint forall(f in FlightID, pred, succ in TASK_IDX where
  active(f, pred) /\ active(f, succ) /\
  flight_tasks[f, pred].kind in required_preds[flight_tasks[f, succ].kind]
)(
  task_start[f, pred] + flight_tasks[f, pred].duration <= task_start[f, succ]
);

%   C9 each LaborID is a unit-capacity machine.  The global form avoids the
%   quadratic number of pairwise disjunctions on large instances.
array[LaborID] of int: labor_capacity = [1 | l in LaborID];
constraint cumulatives(
  [task_start[f, t] | f in FlightID, t in TASK_IDX where active(f, t)],
  [flight_tasks[f, t].duration | f in FlightID, t in TASK_IDX where active(f, t)],
  [1 | f in FlightID, t in TASK_IDX where active(f, t)],
  [task_labor[f, t] | f in FlightID, t in TASK_IDX where active(f, t)],
  labor_capacity,
  true
);

%   C10 each team works only inside [labor_shift_start, labor_shift_end].
constraint forall(f in FlightID, t in TASK_IDX where active(f, t))(
  labor_shift_start[task_labor[f, t]] <= task_start[f, t] /\
  task_start[f, t] + flight_tasks[f, t].duration
    <= labor_shift_end[task_labor[f, t]]
);

% Eliminate permutations among teams with identical kind, shift and cost.
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

% ---- Objective: minimise the cost of the DISTINCT teams used: TODO ----
constraint forall(l in LaborID)(
  used[l] <-> exists(f in FlightID, t in TASK_IDX where
    active(f, t) /\ l in compatible_labor[f, t]
  )(
    task_labor[f, t] = l
  )
);
constraint cost = sum(l in LaborID)(
  labor_cost[l] * bool2int(used[l])
);

% Compulsory task intervals give a sound lower bound on teams of each kind.
array[TeamType] of int: min_teams_lb = [
  max(time in 0..horizon)(
    sum(f in FlightID, t in TASK_IDX where
      active(f, t) /\ required_team[flight_tasks[f, t].kind] = k
    )(
      bool2int(
        flight_dep[f] - flight_tasks[f, t].duration < time /\
        time < flight_arr[f] + flight_tasks[f, t].duration
      )
    )
  )
  | k in TeamType
];
constraint forall(k in TeamType)(
  sum(l in LaborID where labor_kind[l] = k)(bool2int(used[l])) >= min_teams_lb[k]
);

constraint cost < 21489;
constraint task_labor[F000,1] = ramp_team_01;
constraint task_labor[F000,2] = ramp_team_15;
constraint task_labor[F000,3] = baggage_team_01;
constraint task_labor[F000,4] = fuel_team_08;
constraint task_labor[F000,5] = cabin_clean_team_09;
constraint task_labor[F000,6] = water_waste_team_01;
constraint task_labor[F000,8] = baggage_team_33;
constraint task_labor[F000,9] = ramp_team_16;
constraint task_labor[F000,10] = pushback_team_07;
constraint task_labor[F001,1] = ramp_team_02;
constraint task_labor[F001,2] = ramp_team_01;
constraint task_labor[F001,3] = baggage_team_02;
constraint task_labor[F001,4] = fuel_team_09;
constraint task_labor[F001,5] = cabin_clean_team_10;
constraint task_labor[F001,6] = water_waste_team_02;
constraint task_labor[F001,8] = baggage_team_17;
constraint task_labor[F001,9] = ramp_team_17;
constraint task_labor[F001,10] = pushback_team_08;
constraint task_labor[F002,1] = ramp_team_03;
constraint task_labor[F002,2] = ramp_team_03;
constraint task_labor[F002,3] = baggage_team_03;
constraint task_labor[F002,4] = fuel_team_10;
constraint task_labor[F002,5] = cabin_clean_team_11;
constraint task_labor[F002,6] = water_waste_team_03;
constraint task_labor[F002,8] = baggage_team_18;
constraint task_labor[F002,9] = ramp_team_18;
constraint task_labor[F002,10] = pushback_team_09;
constraint task_labor[F003,1] = ramp_team_01;
constraint task_labor[F003,2] = ramp_team_01;
constraint task_labor[F003,3] = baggage_team_01;
constraint task_labor[F003,4] = fuel_team_01;
constraint task_labor[F003,5] = cabin_clean_team_01;
constraint task_labor[F003,6] = water_waste_team_01;
constraint task_labor[F003,8] = baggage_team_04;
constraint task_labor[F003,9] = ramp_team_02;
constraint task_labor[F003,10] = pushback_team_01;
constraint task_labor[F004,1] = ramp_team_02;
constraint task_labor[F004,2] = ramp_team_02;
constraint task_labor[F004,3] = baggage_team_02;
constraint task_labor[F004,4] = fuel_team_02;
constraint task_labor[F004,5] = cabin_clean_team_02;
constraint task_labor[F004,6] = water_waste_team_02;
constraint task_labor[F004,8] = baggage_team_17;
constraint task_labor[F004,9] = ramp_team_17;
constraint task_labor[F004,10] = pushback_team_02;
constraint task_labor[F005,1] = ramp_team_03;
constraint task_labor[F005,2] = ramp_team_03;
constraint task_labor[F005,3] = baggage_team_03;
constraint task_labor[F005,4] = fuel_team_11;
constraint task_labor[F005,5] = cabin_clean_team_03;
constraint task_labor[F005,6] = water_waste_team_03;
constraint task_labor[F005,8] = baggage_team_18;
constraint task_labor[F005,9] = ramp_team_18;
constraint task_labor[F005,10] = pushback_team_03;
constraint task_labor[F006,1] = ramp_team_15;
constraint task_labor[F006,2] = ramp_team_15;
constraint task_labor[F006,3] = baggage_team_33;
constraint task_labor[F006,4] = fuel_team_16;
constraint task_labor[F006,5] = cabin_clean_team_17;
constraint task_labor[F006,6] = water_waste_team_08;
constraint task_labor[F006,8] = baggage_team_33;
constraint task_labor[F006,9] = ramp_team_29;
constraint task_labor[F006,10] = ramp_team_29;
constraint task_labor[F006,11] = pushback_team_14;
constraint task_labor[F007,1] = ramp_team_16;
constraint task_labor[F007,2] = ramp_team_16;
constraint task_labor[F007,3] = baggage_team_19;
constraint task_labor[F007,4] = fuel_team_12;
constraint task_labor[F007,5] = cabin_clean_team_09;
constraint task_labor[F007,6] = water_waste_team_08;
constraint task_labor[F007,8] = baggage_team_17;
constraint task_labor[F007,9] = ramp_team_15;
constraint task_labor[F007,10] = ramp_team_15;
constraint task_labor[F007,11] = pushback_team_07;
constraint task_labor[F008,1] = ramp_team_01;
constraint task_labor[F008,2] = ramp_team_01;
constraint task_labor[F008,3] = baggage_team_01;
constraint task_labor[F008,4] = fuel_team_01;
constraint task_labor[F008,5] = cabin_clean_team_01;
constraint task_labor[F008,6] = water_waste_team_01;
constraint task_labor[F008,8] = baggage_team_01;
constraint task_labor[F008,9] = ramp_team_01;
constraint task_labor[F008,10] = ramp_team_15;
constraint task_labor[F008,11] = pushback_team_01;
constraint task_labor[F009,1] = ramp_team_17;
constraint task_labor[F009,2] = ramp_team_19;
constraint task_labor[F009,3] = baggage_team_18;
constraint task_labor[F009,4] = fuel_team_08;
constraint task_labor[F009,5] = cabin_clean_team_10;
constraint task_labor[F009,6] = water_waste_team_09;
constraint task_labor[F009,8] = baggage_team_18;
constraint task_labor[F009,9] = ramp_team_16;
constraint task_labor[F009,10] = ramp_team_16;
constraint task_labor[F009,11] = pushback_team_07;
constraint task_labor[F010,1] = ramp_team_01;
constraint task_labor[F010,2] = ramp_team_01;
constraint task_labor[F010,3] = baggage_team_04;
constraint task_labor[F010,4] = fuel_team_03;
constraint task_labor[F010,5] = cabin_clean_team_04;
constraint task_labor[F010,6] = water_waste_team_04;
constraint task_labor[F010,8] = baggage_team_20;
constraint task_labor[F010,9] = ramp_team_02;
constraint task_labor[F010,10] = ramp_team_15;
constraint task_labor[F010,11] = pushback_team_07;
constraint task_labor[F011,1] = ramp_team_19;
constraint task_labor[F011,2] = ramp_team_19;
constraint task_labor[F011,3] = baggage_team_19;
constraint task_labor[F011,4] = fuel_team_11;
constraint task_labor[F011,5] = cabin_clean_team_12;
constraint task_labor[F011,6] = water_waste_team_08;
constraint task_labor[F011,8] = baggage_team_20;
constraint task_labor[F011,9] = ramp_team_15;
constraint task_labor[F011,10] = ramp_team_19;
constraint task_labor[F011,11] = pushback_team_07;
constraint task_labor[F012,1] = ramp_team_03;
constraint task_labor[F012,2] = ramp_team_03;
constraint task_labor[F012,3] = baggage_team_02;
constraint task_labor[F012,4] = fuel_team_02;
constraint task_labor[F012,5] = cabin_clean_team_02;
constraint task_labor[F012,6] = water_waste_team_02;
constraint task_labor[F012,8] = baggage_team_02;
constraint task_labor[F012,9] = ramp_team_02;
constraint task_labor[F012,10] = ramp_team_17;
constraint task_labor[F012,11] = pushback_team_02;
constraint task_labor[F013,1] = ramp_team_17;
constraint task_labor[F013,2] = ramp_team_17;
constraint task_labor[F013,3] = baggage_team_17;
constraint task_labor[F013,4] = fuel_team_08;
constraint task_labor[F013,5] = cabin_clean_team_09;
constraint task_labor[F013,6] = water_waste_team_08;
constraint task_labor[F013,8] = baggage_team_17;
constraint task_labor[F013,9] = ramp_team_29;
constraint task_labor[F013,10] = ramp_team_30;
constraint task_labor[F013,11] = pushback_team_14;
constraint task_labor[F014,1] = baggage_team_01;
constraint task_labor[F014,2] = fuel_team_01;
constraint task_labor[F014,3] = baggage_team_01;
constraint task_labor[F014,4] = pushback_team_01;
constraint task_labor[F015,1] = baggage_team_02;
constraint task_labor[F015,2] = fuel_team_02;
constraint task_labor[F015,3] = baggage_team_02;
constraint task_labor[F015,4] = pushback_team_01;
constraint task_labor[F016,1] = baggage_team_34;
constraint task_labor[F016,2] = fuel_team_16;
constraint task_labor[F016,3] = baggage_team_33;
constraint task_labor[F016,4] = pushback_team_14;
constraint task_labor[F017,1] = ramp_team_16;
constraint task_labor[F017,2] = ramp_team_16;
constraint task_labor[F017,3] = baggage_team_17;
constraint task_labor[F017,4] = fuel_team_04;
constraint task_labor[F017,5] = cabin_clean_team_05;
constraint task_labor[F017,6] = water_waste_team_04;
constraint task_labor[F017,8] = baggage_team_21;
constraint task_labor[F017,9] = ramp_team_15;
constraint task_labor[F017,10] = pushback_team_07;
constraint task_labor[F018,1] = ramp_team_01;
constraint task_labor[F018,2] = ramp_team_01;
constraint task_labor[F018,3] = baggage_team_01;
constraint task_labor[F018,4] = fuel_team_01;
constraint task_labor[F018,5] = cabin_clean_team_01;
constraint task_labor[F018,6] = water_waste_team_01;
constraint task_labor[F018,8] = baggage_team_01;
constraint task_labor[F018,9] = ramp_team_01;
constraint task_labor[F018,10] = pushback_team_01;
constraint task_labor[F019,1] = ramp_team_02;
constraint task_labor[F019,2] = ramp_team_02;
constraint task_labor[F019,3] = baggage_team_01;
constraint task_labor[F019,4] = fuel_team_01;
constraint task_labor[F019,5] = cabin_clean_team_01;
constraint task_labor[F019,6] = water_waste_team_01;
constraint task_labor[F019,8] = baggage_team_01;
constraint task_labor[F019,9] = ramp_team_01;
constraint task_labor[F019,10] = pushback_team_01;
constraint task_labor[F020,1] = ramp_team_01;
constraint task_labor[F020,2] = ramp_team_01;
constraint task_labor[F020,3] = baggage_team_03;
constraint task_labor[F020,4] = fuel_team_03;
constraint task_labor[F020,5] = cabin_clean_team_03;
constraint task_labor[F020,6] = water_waste_team_01;
constraint task_labor[F020,8] = baggage_team_03;
constraint task_labor[F020,9] = ramp_team_02;
constraint task_labor[F020,10] = pushback_team_01;
constraint task_labor[F021,1] = ramp_team_15;
constraint task_labor[F021,2] = ramp_team_15;
constraint task_labor[F021,3] = baggage_team_19;
constraint task_labor[F021,4] = fuel_team_09;
constraint task_labor[F021,5] = cabin_clean_team_09;
constraint task_labor[F021,6] = water_waste_team_08;
constraint task_labor[F021,8] = baggage_team_17;
constraint task_labor[F021,9] = ramp_team_17;
constraint task_labor[F021,10] = pushback_team_07;
constraint task_labor[F022,1] = ramp_team_19;
constraint task_labor[F022,2] = ramp_team_19;
constraint task_labor[F022,3] = baggage_team_18;
constraint task_labor[F022,4] = fuel_team_05;
constraint task_labor[F022,5] = cabin_clean_team_06;
constraint task_labor[F022,6] = water_waste_team_01;
constraint task_labor[F022,8] = baggage_team_19;
constraint task_labor[F022,9] = ramp_team_01;
constraint task_labor[F022,10] = pushback_team_08;
constraint task_labor[F023,1] = ramp_team_01;
constraint task_labor[F023,2] = ramp_team_16;
constraint task_labor[F023,3] = baggage_team_22;
constraint task_labor[F023,4] = fuel_team_01;
constraint task_labor[F023,5] = cabin_clean_team_01;
constraint task_labor[F023,6] = water_waste_team_02;
constraint task_labor[F023,8] = baggage_team_22;
constraint task_labor[F023,9] = ramp_team_16;
constraint task_labor[F023,10] = pushback_team_07;
constraint task_labor[F024,1] = ramp_team_31;
constraint task_labor[F024,2] = ramp_team_29;
constraint task_labor[F024,3] = baggage_team_34;
constraint task_labor[F024,4] = fuel_team_17;
constraint task_labor[F024,5] = cabin_clean_team_17;
constraint task_labor[F024,6] = water_waste_team_15;
constraint task_labor[F024,8] = baggage_team_35;
constraint task_labor[F024,9] = ramp_team_31;
constraint task_labor[F024,10] = pushback_team_14;
constraint task_labor[F025,1] = ramp_team_16;
constraint task_labor[F025,2] = ramp_team_16;
constraint task_labor[F025,3] = baggage_team_18;
constraint task_labor[F025,4] = fuel_team_09;
constraint task_labor[F025,5] = cabin_clean_team_18;
constraint task_labor[F025,6] = water_waste_team_09;
constraint task_labor[F025,8] = baggage_team_34;
constraint task_labor[F025,9] = ramp_team_32;
constraint task_labor[F025,10] = pushback_team_14;
constraint task_labor[F026,1] = ramp_team_30;
constraint task_labor[F026,2] = ramp_team_30;
constraint task_labor[F026,3] = baggage_team_34;
constraint task_labor[F026,4] = fuel_team_17;
constraint task_labor[F026,5] = cabin_clean_team_17;
constraint task_labor[F026,6] = water_waste_team_15;
constraint task_labor[F026,8] = baggage_team_34;
constraint task_labor[F026,9] = ramp_team_30;
constraint task_labor[F026,10] = pushback_team_14;
constraint task_labor[F027,1] = ramp_team_02;
constraint task_labor[F027,2] = ramp_team_02;
constraint task_labor[F027,3] = baggage_team_02;
constraint task_labor[F027,4] = fuel_team_02;
constraint task_labor[F027,5] = cabin_clean_team_02;
constraint task_labor[F027,6] = water_waste_team_01;
constraint task_labor[F027,8] = baggage_team_02;
constraint task_labor[F027,9] = ramp_team_03;
constraint task_labor[F027,10] = pushback_team_01;
constraint task_labor[F028,1] = ramp_team_16;
constraint task_labor[F028,2] = ramp_team_16;
constraint task_labor[F028,3] = baggage_team_20;
constraint task_labor[F028,4] = fuel_team_09;
constraint task_labor[F028,5] = cabin_clean_team_09;
constraint task_labor[F028,6] = water_waste_team_08;
constraint task_labor[F028,8] = baggage_team_17;
constraint task_labor[F028,9] = ramp_team_18;
constraint task_labor[F028,10] = pushback_team_08;
constraint task_labor[F029,1] = ramp_team_16;
constraint task_labor[F029,2] = ramp_team_16;
constraint task_labor[F029,3] = baggage_team_23;
constraint task_labor[F029,4] = fuel_team_12;
constraint task_labor[F029,5] = cabin_clean_team_13;
constraint task_labor[F029,6] = water_waste_team_04;
constraint task_labor[F029,8] = baggage_team_20;
constraint task_labor[F029,9] = ramp_team_17;
constraint task_labor[F029,10] = pushback_team_07;
constraint task_labor[F030,1] = ramp_team_15;
constraint task_labor[F030,2] = ramp_team_02;
constraint task_labor[F030,3] = baggage_team_03;
constraint task_labor[F030,4] = fuel_team_04;
constraint task_labor[F030,5] = cabin_clean_team_04;
constraint task_labor[F030,6] = water_waste_team_03;
constraint task_labor[F030,8] = baggage_team_04;
constraint task_labor[F030,9] = ramp_team_01;
constraint task_labor[F030,10] = pushback_team_01;
constraint task_labor[F031,1] = ramp_team_02;
constraint task_labor[F031,2] = ramp_team_02;
constraint task_labor[F031,3] = baggage_team_01;
constraint task_labor[F031,4] = fuel_team_01;
constraint task_labor[F031,5] = cabin_clean_team_01;
constraint task_labor[F031,6] = water_waste_team_01;
constraint task_labor[F031,8] = baggage_team_01;
constraint task_labor[F031,9] = ramp_team_02;
constraint task_labor[F031,10] = pushback_team_01;
constraint task_labor[F032,1] = ramp_team_01;
constraint task_labor[F032,2] = ramp_team_01;
constraint task_labor[F032,3] = baggage_team_01;
constraint task_labor[F032,4] = fuel_team_01;
constraint task_labor[F032,5] = cabin_clean_team_01;
constraint task_labor[F032,6] = water_waste_team_01;
constraint task_labor[F032,8] = baggage_team_01;
constraint task_labor[F032,9] = ramp_team_01;
constraint task_labor[F032,10] = pushback_team_01;
constraint task_labor[F033,1] = ramp_team_01;
constraint task_labor[F033,2] = ramp_team_02;
constraint task_labor[F033,3] = baggage_team_02;
constraint task_labor[F033,4] = fuel_team_01;
constraint task_labor[F033,5] = cabin_clean_team_01;
constraint task_labor[F033,6] = water_waste_team_01;
constraint task_labor[F033,8] = baggage_team_03;
constraint task_labor[F033,9] = ramp_team_01;
constraint task_labor[F033,10] = pushback_team_01;
constraint task_labor[F034,1] = ramp_team_02;
constraint task_labor[F034,2] = ramp_team_02;
constraint task_labor[F034,3] = baggage_team_04;
constraint task_labor[F034,4] = fuel_team_04;
constraint task_labor[F034,5] = cabin_clean_team_01;
constraint task_labor[F034,6] = water_waste_team_01;
constraint task_labor[F034,8] = baggage_team_04;
constraint task_labor[F034,9] = ramp_team_03;
constraint task_labor[F034,10] = pushback_team_01;
constraint task_labor[F035,1] = ramp_team_16;
constraint task_labor[F035,2] = ramp_team_17;
constraint task_labor[F035,3] = baggage_team_19;
constraint task_labor[F035,4] = fuel_team_10;
constraint task_labor[F035,5] = cabin_clean_team_19;
constraint task_labor[F035,6] = water_waste_team_10;
constraint task_labor[F035,8] = baggage_team_35;
constraint task_labor[F035,9] = ramp_team_33;
constraint task_labor[F035,10] = pushback_team_15;
constraint task_labor[F036,1] = ramp_team_16;
constraint task_labor[F036,2] = ramp_team_16;
constraint task_labor[F036,3] = baggage_team_01;
constraint task_labor[F036,4] = fuel_team_01;
constraint task_labor[F036,5] = cabin_clean_team_01;
constraint task_labor[F036,6] = water_waste_team_01;
constraint task_labor[F036,8] = baggage_team_18;
constraint task_labor[F036,9] = ramp_team_18;
constraint task_labor[F036,10] = pushback_team_03;
constraint task_labor[F037,1] = ramp_team_34;
constraint task_labor[F037,2] = ramp_team_31;
constraint task_labor[F037,3] = baggage_team_36;
constraint task_labor[F037,4] = fuel_team_18;
constraint task_labor[F037,5] = cabin_clean_team_18;
constraint task_labor[F037,6] = water_waste_team_16;
constraint task_labor[F037,8] = baggage_team_36;
constraint task_labor[F037,9] = ramp_team_32;
constraint task_labor[F037,10] = pushback_team_15;
constraint task_labor[F038,1] = ramp_team_29;
constraint task_labor[F038,2] = ramp_team_29;
constraint task_labor[F038,3] = baggage_team_21;
constraint task_labor[F038,4] = fuel_team_09;
constraint task_labor[F038,5] = cabin_clean_team_11;
constraint task_labor[F038,6] = water_waste_team_08;
constraint task_labor[F038,8] = baggage_team_20;
constraint task_labor[F038,9] = ramp_team_29;
constraint task_labor[F038,10] = pushback_team_09;
constraint task_labor[F039,1] = ramp_team_02;
constraint task_labor[F039,2] = ramp_team_03;
constraint task_labor[F039,3] = baggage_team_17;
constraint task_labor[F039,4] = fuel_team_01;
constraint task_labor[F039,5] = cabin_clean_team_02;
constraint task_labor[F039,6] = water_waste_team_01;
constraint task_labor[F039,8] = baggage_team_02;
constraint task_labor[F039,9] = ramp_team_02;
constraint task_labor[F039,10] = pushback_team_01;
solve :: seq_search([
  int_search(
    [task_start[f, t] | f in FlightID, t in TASK_IDX where active(f, t)],
    smallest, indomain_min, complete
  ),
  % Once the time line is fixed, try to keep teams unused before assigning
  % individual tasks.  This turns the distinct-team objective into an early
  % branching decision instead of discovering cost only after all assignments.
  bool_search([used[l] | l in LaborID], first_fail, indomain_min, complete),
  int_search(
    [task_labor[f, t] | f in FlightID, t in TASK_IDX where active(f, t)],
    first_fail, indomain_min, complete
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
