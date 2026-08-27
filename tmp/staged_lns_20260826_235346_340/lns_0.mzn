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

%   C9 no team is booked on two time-overlapping tasks;
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

% Cost dominance for otherwise interchangeable teams: an expensive copy is
% never needed unless every cheaper copy with the same capability is used.
constraint forall(cheap, expensive in LaborID where
  labor_kind[cheap] = labor_kind[expensive] /\
  labor_shift_start[cheap] = labor_shift_start[expensive] /\
  labor_shift_end[cheap] = labor_shift_end[expensive] /\
  labor_cost[cheap] < labor_cost[expensive]
)(
  used[expensive] -> used[cheap]
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

% Compulsory-part lower bound: if a task's latest start is before its earliest
% end, that interval must consume one team regardless of its chosen start.
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
  sum(l in LaborID where labor_kind[l] = k)(bool2int(used[l]))
    >= min_teams_lb[k]
);
constraint cost < 8312;
constraint gate[F000] = G001;
constraint task_start[F000,1] = 230;
constraint task_labor[F000,1] = ramp_team_01;
constraint task_start[F000,2] = 234;
constraint task_labor[F000,2] = ramp_team_01;
constraint task_start[F000,3] = 234;
constraint task_labor[F000,3] = baggage_team_12;
constraint task_start[F000,4] = 242;
constraint task_labor[F000,4] = fuel_team_07;
constraint task_start[F000,5] = 252;
constraint task_labor[F000,5] = cabin_clean_team_13;
constraint task_start[F000,6] = 242;
constraint task_labor[F000,6] = water_waste_team_01;
constraint task_start[F000,7] = 252;
constraint task_labor[F000,7] = catering_team_13;
constraint task_start[F000,8] = 259;
constraint task_labor[F000,8] = baggage_team_12;
constraint task_start[F000,9] = 285;
constraint task_labor[F000,9] = ramp_team_09;
constraint task_start[F000,10] = 321;
constraint task_labor[F000,10] = pushback_team_08;
constraint gate[F002] = G007;
constraint task_start[F002,1] = 210;
constraint task_labor[F002,1] = ramp_team_01;
constraint task_start[F002,2] = 212;
constraint task_labor[F002,2] = ramp_team_01;
constraint task_start[F002,3] = 212;
constraint task_labor[F002,3] = baggage_team_01;
constraint task_start[F002,4] = 219;
constraint task_labor[F002,4] = fuel_team_07;
constraint task_start[F002,5] = 219;
constraint task_labor[F002,5] = cabin_clean_team_01;
constraint task_start[F002,6] = 219;
constraint task_labor[F002,6] = water_waste_team_01;
constraint task_start[F002,7] = 219;
constraint task_labor[F002,7] = catering_team_01;
constraint task_start[F002,8] = 229;
constraint task_labor[F002,8] = baggage_team_01;
constraint task_start[F002,9] = 233;
constraint task_labor[F002,9] = ramp_team_03;
constraint task_start[F002,10] = 246;
constraint task_labor[F002,10] = pushback_team_01;
constraint gate[F003] = G008;
constraint task_start[F003,1] = 210;
constraint task_labor[F003,1] = ramp_team_02;
constraint task_start[F003,2] = 212;
constraint task_labor[F003,2] = ramp_team_02;
constraint task_start[F003,3] = 212;
constraint task_labor[F003,3] = baggage_team_02;
constraint task_start[F003,4] = 219;
constraint task_labor[F003,4] = fuel_team_08;
constraint task_start[F003,5] = 219;
constraint task_labor[F003,5] = cabin_clean_team_07;
constraint task_start[F003,6] = 219;
constraint task_labor[F003,6] = water_waste_team_04;
constraint task_start[F003,7] = 219;
constraint task_labor[F003,7] = catering_team_07;
constraint task_start[F003,8] = 229;
constraint task_labor[F003,8] = baggage_team_02;
constraint task_start[F003,9] = 233;
constraint task_labor[F003,9] = ramp_team_04;
constraint task_start[F003,10] = 252;
constraint task_labor[F003,10] = pushback_team_08;
constraint gate[F004] = G003;
constraint task_start[F004,1] = 276;
constraint task_labor[F004,1] = ramp_team_09;
constraint task_start[F004,2] = 281;
constraint task_labor[F004,2] = ramp_team_17;
constraint task_start[F004,3] = 281;
constraint task_labor[F004,3] = baggage_team_12;
constraint task_start[F004,4] = 292;
constraint task_labor[F004,4] = fuel_team_07;
constraint task_start[F004,5] = 292;
constraint task_labor[F004,5] = cabin_clean_team_07;
constraint task_start[F004,6] = 292;
constraint task_labor[F004,6] = water_waste_team_04;
constraint task_start[F004,7] = 292;
constraint task_labor[F004,7] = catering_team_07;
constraint task_start[F004,8] = 307;
constraint task_labor[F004,8] = baggage_team_12;
constraint task_start[F004,9] = 332;
constraint task_labor[F004,9] = ramp_team_09;
constraint task_start[F004,10] = 337;
constraint task_labor[F004,10] = ramp_team_09;
constraint task_start[F004,11] = 374;
constraint task_labor[F004,11] = pushback_team_08;
constraint gate[F005] = G004;
constraint task_start[F005,1] = 260;
constraint task_labor[F005,1] = ramp_team_09;
constraint task_start[F005,2] = 265;
constraint task_labor[F005,2] = ramp_team_09;
constraint task_start[F005,3] = 279;
constraint task_labor[F005,3] = baggage_team_13;
constraint task_start[F005,4] = 276;
constraint task_labor[F005,4] = fuel_team_13;
constraint task_start[F005,5] = 276;
constraint task_labor[F005,5] = cabin_clean_team_13;
constraint task_start[F005,6] = 276;
constraint task_labor[F005,6] = water_waste_team_04;
constraint task_start[F005,7] = 276;
constraint task_labor[F005,7] = catering_team_13;
constraint task_start[F005,8] = 302;
constraint task_labor[F005,8] = baggage_team_13;
constraint task_start[F005,9] = 321;
constraint task_labor[F005,9] = ramp_team_09;
constraint task_start[F005,10] = 329;
constraint task_labor[F005,10] = ramp_team_10;
constraint task_start[F005,11] = 363;
constraint task_labor[F005,11] = pushback_team_09;
constraint gate[F006] = G003;
constraint task_start[F006,1] = 96;
constraint task_labor[F006,1] = ramp_team_01;
constraint task_start[F006,2] = 100;
constraint task_labor[F006,2] = ramp_team_01;
constraint task_start[F006,3] = 100;
constraint task_labor[F006,3] = baggage_team_01;
constraint task_start[F006,4] = 111;
constraint task_labor[F006,4] = fuel_team_01;
constraint task_start[F006,5] = 111;
constraint task_labor[F006,5] = cabin_clean_team_01;
constraint task_start[F006,6] = 111;
constraint task_labor[F006,6] = water_waste_team_01;
constraint task_start[F006,7] = 111;
constraint task_labor[F006,7] = catering_team_01;
constraint task_start[F006,8] = 124;
constraint task_labor[F006,8] = baggage_team_01;
constraint task_start[F006,9] = 153;
constraint task_labor[F006,9] = ramp_team_01;
constraint task_start[F006,10] = 159;
constraint task_labor[F006,10] = ramp_team_01;
constraint task_start[F006,11] = 195;
constraint task_labor[F006,11] = pushback_team_01;
constraint gate[F007] = G005;
constraint task_start[F007,1] = 174;
constraint task_labor[F007,1] = ramp_team_02;
constraint task_start[F007,2] = 178;
constraint task_labor[F007,2] = ramp_team_02;
constraint task_start[F007,3] = 178;
constraint task_labor[F007,3] = baggage_team_01;
constraint task_start[F007,4] = 190;
constraint task_labor[F007,4] = fuel_team_02;
constraint task_start[F007,5] = 190;
constraint task_labor[F007,5] = cabin_clean_team_01;
constraint task_start[F007,6] = 190;
constraint task_labor[F007,6] = water_waste_team_01;
constraint task_start[F007,7] = 190;
constraint task_labor[F007,7] = catering_team_01;
constraint task_start[F007,8] = 205;
constraint task_labor[F007,8] = baggage_team_12;
constraint task_start[F007,9] = 238;
constraint task_labor[F007,9] = ramp_team_10;
constraint task_start[F007,10] = 245;
constraint task_labor[F007,10] = ramp_team_10;
constraint task_start[F007,11] = 276;
constraint task_labor[F007,11] = pushback_team_08;
constraint gate[F009] = G000;
constraint task_start[F009,1] = 316;
constraint task_labor[F009,1] = baggage_team_23;
constraint task_start[F009,2] = 336;
constraint task_labor[F009,2] = fuel_team_07;
constraint task_start[F009,3] = 336;
constraint task_labor[F009,3] = baggage_team_12;
constraint task_start[F009,4] = 356;
constraint task_labor[F009,4] = pushback_team_08;
constraint gate[F011] = G001;
constraint task_start[F011,1] = 120;
constraint task_labor[F011,1] = ramp_team_01;
constraint task_start[F011,2] = 122;
constraint task_labor[F011,2] = ramp_team_01;
constraint task_start[F011,3] = 122;
constraint task_labor[F011,3] = baggage_team_02;
constraint task_start[F011,4] = 132;
constraint task_labor[F011,4] = fuel_team_02;
constraint task_start[F011,5] = 132;
constraint task_labor[F011,5] = cabin_clean_team_02;
constraint task_start[F011,6] = 132;
constraint task_labor[F011,6] = water_waste_team_01;
constraint task_start[F011,7] = 132;
constraint task_labor[F011,7] = catering_team_02;
constraint task_start[F011,8] = 134;
constraint task_labor[F011,8] = baggage_team_02;
constraint task_start[F011,9] = 148;
constraint task_labor[F011,9] = ramp_team_02;
constraint task_start[F011,10] = 162;
constraint task_labor[F011,10] = pushback_team_01;
constraint gate[F012] = G002;
constraint task_start[F012,1] = 73;
constraint task_labor[F012,1] = ramp_team_01;
constraint task_start[F012,2] = 75;
constraint task_labor[F012,2] = ramp_team_01;
constraint task_start[F012,3] = 75;
constraint task_labor[F012,3] = baggage_team_02;
constraint task_start[F012,4] = 82;
constraint task_labor[F012,4] = fuel_team_02;
constraint task_start[F012,5] = 82;
constraint task_labor[F012,5] = cabin_clean_team_01;
constraint task_start[F012,6] = 84;
constraint task_labor[F012,6] = water_waste_team_01;
constraint task_start[F012,7] = 82;
constraint task_labor[F012,7] = catering_team_01;
constraint task_start[F012,8] = 92;
constraint task_labor[F012,8] = baggage_team_02;
constraint task_start[F012,9] = 99;
constraint task_labor[F012,9] = ramp_team_03;
constraint task_start[F012,10] = 114;
constraint task_labor[F012,10] = pushback_team_01;
constraint gate[F013] = G008;
constraint task_start[F013,1] = 65;
constraint task_labor[F013,1] = ramp_team_01;
constraint task_start[F013,2] = 67;
constraint task_labor[F013,2] = ramp_team_03;
constraint task_start[F013,3] = 86;
constraint task_labor[F013,3] = baggage_team_03;
constraint task_start[F013,4] = 77;
constraint task_labor[F013,4] = fuel_team_03;
constraint task_start[F013,5] = 77;
constraint task_labor[F013,5] = cabin_clean_team_02;
constraint task_start[F013,6] = 77;
constraint task_labor[F013,6] = water_waste_team_01;
constraint task_start[F013,7] = 77;
constraint task_labor[F013,7] = catering_team_02;
constraint task_start[F013,8] = 97;
constraint task_labor[F013,8] = baggage_team_03;
constraint task_start[F013,9] = 93;
constraint task_labor[F013,9] = ramp_team_04;
constraint task_start[F013,10] = 107;
constraint task_labor[F013,10] = pushback_team_01;
constraint gate[F014] = G009;
constraint task_start[F014,1] = 47;
constraint task_labor[F014,1] = ramp_team_01;
constraint task_start[F014,2] = 50;
constraint task_labor[F014,2] = ramp_team_01;
constraint task_start[F014,3] = 59;
constraint task_labor[F014,3] = baggage_team_03;
constraint task_start[F014,4] = 57;
constraint task_labor[F014,4] = fuel_team_03;
constraint task_start[F014,5] = 57;
constraint task_labor[F014,5] = cabin_clean_team_02;
constraint task_start[F014,6] = 57;
constraint task_labor[F014,6] = water_waste_team_01;
constraint task_start[F014,7] = 57;
constraint task_labor[F014,7] = catering_team_02;
constraint task_start[F014,8] = 75;
constraint task_labor[F014,8] = baggage_team_03;
constraint task_start[F014,9] = 73;
constraint task_labor[F014,9] = ramp_team_02;
constraint task_start[F014,10] = 90;
constraint task_labor[F014,10] = pushback_team_01;
constraint gate[F015] = G009;
constraint task_start[F015,1] = 220;
constraint task_labor[F015,1] = ramp_team_01;
constraint task_start[F015,2] = 222;
constraint task_labor[F015,2] = ramp_team_03;
constraint task_start[F015,3] = 222;
constraint task_labor[F015,3] = baggage_team_03;
constraint task_start[F015,4] = 231;
constraint task_labor[F015,4] = fuel_team_01;
constraint task_start[F015,5] = 233;
constraint task_labor[F015,5] = cabin_clean_team_01;
constraint task_start[F015,6] = 231;
constraint task_labor[F015,6] = water_waste_team_01;
constraint task_start[F015,7] = 232;
constraint task_labor[F015,7] = catering_team_01;
constraint task_start[F015,8] = 237;
constraint task_labor[F015,8] = baggage_team_03;
constraint task_start[F015,9] = 252;
constraint task_labor[F015,9] = ramp_team_17;
constraint task_start[F015,10] = 269;
constraint task_labor[F015,10] = pushback_team_08;
constraint gate[F016] = G001;
constraint task_start[F016,1] = 15;
constraint task_labor[F016,1] = ramp_team_01;
constraint task_start[F016,2] = 17;
constraint task_labor[F016,2] = ramp_team_01;
constraint task_start[F016,3] = 17;
constraint task_labor[F016,3] = baggage_team_01;
constraint task_start[F016,4] = 26;
constraint task_labor[F016,4] = fuel_team_01;
constraint task_start[F016,5] = 26;
constraint task_labor[F016,5] = cabin_clean_team_01;
constraint task_start[F016,6] = 26;
constraint task_labor[F016,6] = water_waste_team_01;
constraint task_start[F016,7] = 26;
constraint task_labor[F016,7] = catering_team_01;
constraint task_start[F016,8] = 31;
constraint task_labor[F016,8] = baggage_team_01;
constraint task_start[F016,9] = 42;
constraint task_labor[F016,9] = ramp_team_02;
constraint task_start[F016,10] = 58;
constraint task_labor[F016,10] = pushback_team_01;
constraint gate[F017] = G010;
constraint task_start[F017,1] = 218;
constraint task_labor[F017,1] = ramp_team_03;
constraint task_start[F017,2] = 220;
constraint task_labor[F017,2] = ramp_team_02;
constraint task_start[F017,3] = 220;
constraint task_labor[F017,3] = baggage_team_13;
constraint task_start[F017,4] = 227;
constraint task_labor[F017,4] = fuel_team_03;
constraint task_start[F017,5] = 227;
constraint task_labor[F017,5] = cabin_clean_team_02;
constraint task_start[F017,6] = 227;
constraint task_labor[F017,6] = water_waste_team_04;
constraint task_start[F017,7] = 227;
constraint task_labor[F017,7] = catering_team_02;
constraint task_start[F017,8] = 242;
constraint task_labor[F017,8] = baggage_team_01;
constraint task_start[F017,9] = 243;
constraint task_labor[F017,9] = ramp_team_09;
constraint task_start[F017,10] = 260;
constraint task_labor[F017,10] = pushback_team_08;
constraint gate[F018] = G011;
constraint task_start[F018,1] = 245;
constraint task_labor[F018,1] = ramp_team_01;
constraint task_start[F018,2] = 248;
constraint task_labor[F018,2] = ramp_team_11;
constraint task_start[F018,3] = 252;
constraint task_labor[F018,3] = baggage_team_23;
constraint task_start[F018,4] = 255;
constraint task_labor[F018,4] = fuel_team_13;
constraint task_start[F018,5] = 259;
constraint task_labor[F018,5] = cabin_clean_team_07;
constraint task_start[F018,6] = 255;
constraint task_labor[F018,6] = water_waste_team_04;
constraint task_start[F018,7] = 256;
constraint task_labor[F018,7] = catering_team_07;
constraint task_start[F018,8] = 265;
constraint task_labor[F018,8] = baggage_team_23;
constraint task_start[F018,9] = 273;
constraint task_labor[F018,9] = ramp_team_11;
constraint task_start[F018,10] = 288;
constraint task_labor[F018,10] = pushback_team_08;
constraint gate[F019] = G011;
constraint task_start[F019,1] = 151;
constraint task_labor[F019,1] = ramp_team_01;
constraint task_start[F019,2] = 153;
constraint task_labor[F019,2] = ramp_team_03;
constraint task_start[F019,3] = 153;
constraint task_labor[F019,3] = baggage_team_01;
constraint task_start[F019,4] = 160;
constraint task_labor[F019,4] = fuel_team_01;
constraint task_start[F019,5] = 160;
constraint task_labor[F019,5] = cabin_clean_team_01;
constraint task_start[F019,6] = 160;
constraint task_labor[F019,6] = water_waste_team_01;
constraint task_start[F019,7] = 160;
constraint task_labor[F019,7] = catering_team_01;
constraint task_start[F019,8] = 169;
constraint task_labor[F019,8] = baggage_team_02;
constraint task_start[F019,9] = 176;
constraint task_labor[F019,9] = ramp_team_03;
constraint task_start[F019,10] = 191;
constraint task_labor[F019,10] = pushback_team_01;
constraint gate[F020] = G007;
constraint task_start[F020,1] = 126;
constraint task_labor[F020,1] = ramp_team_02;
constraint task_start[F020,2] = 128;
constraint task_labor[F020,2] = ramp_team_02;
constraint task_start[F020,3] = 128;
constraint task_labor[F020,3] = baggage_team_03;
constraint task_start[F020,4] = 137;
constraint task_labor[F020,4] = fuel_team_03;
constraint task_start[F020,5] = 137;
constraint task_labor[F020,5] = cabin_clean_team_01;
constraint task_start[F020,6] = 137;
constraint task_labor[F020,6] = water_waste_team_01;
constraint task_start[F020,7] = 137;
constraint task_labor[F020,7] = catering_team_01;
constraint task_start[F020,8] = 142;
constraint task_labor[F020,8] = baggage_team_03;
constraint task_start[F020,9] = 152;
constraint task_labor[F020,9] = ramp_team_04;
constraint task_start[F020,10] = 167;
constraint task_labor[F020,10] = pushback_team_01;
constraint gate[F023] = G007;
constraint task_start[F023,1] = 29;
constraint task_labor[F023,1] = ramp_team_02;
constraint task_start[F023,2] = 32;
constraint task_labor[F023,2] = ramp_team_02;
constraint task_start[F023,3] = 32;
constraint task_labor[F023,3] = baggage_team_03;
constraint task_start[F023,4] = 39;
constraint task_labor[F023,4] = fuel_team_02;
constraint task_start[F023,5] = 39;
constraint task_labor[F023,5] = cabin_clean_team_02;
constraint task_start[F023,6] = 39;
constraint task_labor[F023,6] = water_waste_team_01;
constraint task_start[F023,7] = 39;
constraint task_labor[F023,7] = catering_team_02;
constraint task_start[F023,8] = 49;
constraint task_labor[F023,8] = baggage_team_03;
constraint task_start[F023,9] = 53;
constraint task_labor[F023,9] = ramp_team_04;
constraint task_start[F023,10] = 70;
constraint task_labor[F023,10] = pushback_team_01;
constraint gate[F024] = G010;
constraint task_start[F024,1] = 338;
constraint task_labor[F024,1] = ramp_team_11;
constraint task_start[F024,2] = 340;
constraint task_labor[F024,2] = ramp_team_11;
constraint task_start[F024,3] = 340;
constraint task_labor[F024,3] = baggage_team_13;
constraint task_start[F024,4] = 348;
constraint task_labor[F024,4] = fuel_team_08;
constraint task_start[F024,5] = 348;
constraint task_labor[F024,5] = cabin_clean_team_07;
constraint task_start[F024,6] = 348;
constraint task_labor[F024,6] = water_waste_team_04;
constraint task_start[F024,7] = 348;
constraint task_labor[F024,7] = catering_team_07;
constraint task_start[F024,8] = 354;
constraint task_labor[F024,8] = baggage_team_13;
constraint task_start[F024,9] = 364;
constraint task_labor[F024,9] = ramp_team_10;
constraint task_start[F024,10] = 376;
constraint task_labor[F024,10] = pushback_team_09;
solve :: seq_search([
  int_search(
    [task_start[f, t] | f in FlightID, t in TASK_IDX where active(f, t)],
    smallest, indomain_min, complete
  ),
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
