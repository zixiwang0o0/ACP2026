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
constraint cost < 24303;
constraint gate[F002] = G004;
constraint task_start[F002,1] = 360;
constraint task_labor[F002,1] = ramp_team_03;
constraint task_start[F002,2] = 364;
constraint task_labor[F002,2] = ramp_team_03;
constraint task_start[F002,3] = 364;
constraint task_labor[F002,3] = baggage_team_03;
constraint task_start[F002,4] = 372;
constraint task_labor[F002,4] = fuel_team_11;
constraint task_start[F002,5] = 372;
constraint task_labor[F002,5] = cabin_clean_team_03;
constraint task_start[F002,6] = 372;
constraint task_labor[F002,6] = water_waste_team_03;
constraint task_start[F002,7] = 372;
constraint task_labor[F002,7] = catering_team_03;
constraint task_start[F002,8] = 384;
constraint task_labor[F002,8] = baggage_team_19;
constraint task_start[F002,9] = 410;
constraint task_labor[F002,9] = ramp_team_22;
constraint task_start[F002,10] = 446;
constraint task_labor[F002,10] = pushback_team_10;
constraint gate[F004] = G015;
constraint task_start[F004,1] = 340;
constraint task_labor[F004,1] = ramp_team_02;
constraint task_start[F004,2] = 342;
constraint task_labor[F004,2] = ramp_team_02;
constraint task_start[F004,3] = 342;
constraint task_labor[F004,3] = baggage_team_02;
constraint task_start[F004,4] = 349;
constraint task_labor[F004,4] = fuel_team_02;
constraint task_start[F004,5] = 349;
constraint task_labor[F004,5] = cabin_clean_team_02;
constraint task_start[F004,6] = 349;
constraint task_labor[F004,6] = water_waste_team_02;
constraint task_start[F004,7] = 349;
constraint task_labor[F004,7] = catering_team_02;
constraint task_start[F004,8] = 359;
constraint task_labor[F004,8] = baggage_team_05;
constraint task_start[F004,9] = 363;
constraint task_labor[F004,9] = ramp_team_05;
constraint task_start[F004,10] = 376;
constraint task_labor[F004,10] = pushback_team_02;
constraint gate[F005] = G016;
constraint task_start[F005,1] = 340;
constraint task_labor[F005,1] = ramp_team_03;
constraint task_start[F005,2] = 342;
constraint task_labor[F005,2] = ramp_team_03;
constraint task_start[F005,3] = 342;
constraint task_labor[F005,3] = baggage_team_03;
constraint task_start[F005,4] = 349;
constraint task_labor[F005,4] = fuel_team_03;
constraint task_start[F005,5] = 349;
constraint task_labor[F005,5] = cabin_clean_team_03;
constraint task_start[F005,6] = 349;
constraint task_labor[F005,6] = water_waste_team_03;
constraint task_start[F005,7] = 349;
constraint task_labor[F005,7] = catering_team_03;
constraint task_start[F005,8] = 359;
constraint task_labor[F005,8] = baggage_team_06;
constraint task_start[F005,9] = 363;
constraint task_labor[F005,9] = ramp_team_06;
constraint task_start[F005,10] = 376;
constraint task_labor[F005,10] = pushback_team_03;
constraint gate[F006] = G005;
constraint task_start[F006,1] = 12;
constraint task_labor[F006,1] = ramp_team_01;
constraint task_start[F006,2] = 15;
constraint task_labor[F006,2] = ramp_team_01;
constraint task_start[F006,3] = 15;
constraint task_labor[F006,3] = baggage_team_01;
constraint task_start[F006,4] = 25;
constraint task_labor[F006,4] = fuel_team_01;
constraint task_start[F006,5] = 25;
constraint task_labor[F006,5] = cabin_clean_team_01;
constraint task_start[F006,6] = 25;
constraint task_labor[F006,6] = water_waste_team_01;
constraint task_start[F006,7] = 25;
constraint task_labor[F006,7] = catering_team_01;
constraint task_start[F006,8] = 39;
constraint task_labor[F006,8] = baggage_team_01;
constraint task_start[F006,9] = 75;
constraint task_labor[F006,9] = ramp_team_01;
constraint task_start[F006,10] = 81;
constraint task_labor[F006,10] = ramp_team_01;
constraint task_start[F006,11] = 114;
constraint task_labor[F006,11] = pushback_team_01;
constraint gate[F007] = G005;
constraint task_start[F007,1] = 591;
constraint task_labor[F007,1] = ramp_team_31;
constraint task_start[F007,2] = 595;
constraint task_labor[F007,2] = ramp_team_31;
constraint task_start[F007,3] = 595;
constraint task_labor[F007,3] = baggage_team_43;
constraint task_start[F007,4] = 607;
constraint task_labor[F007,4] = fuel_team_15;
constraint task_start[F007,5] = 607;
constraint task_labor[F007,5] = cabin_clean_team_15;
constraint task_start[F007,6] = 607;
constraint task_labor[F007,6] = water_waste_team_11;
constraint task_start[F007,7] = 607;
constraint task_labor[F007,7] = catering_team_15;
constraint task_start[F007,8] = 622;
constraint task_labor[F007,8] = baggage_team_30;
constraint task_start[F007,9] = 655;
constraint task_labor[F007,9] = ramp_team_31;
constraint task_start[F007,10] = 662;
constraint task_labor[F007,10] = ramp_team_31;
constraint task_start[F007,11] = 693;
constraint task_labor[F007,11] = pushback_team_15;
constraint gate[F008] = G006;
constraint task_start[F008,1] = 0;
constraint task_labor[F008,1] = ramp_team_01;
constraint task_start[F008,2] = 5;
constraint task_labor[F008,2] = ramp_team_02;
constraint task_start[F008,3] = 5;
constraint task_labor[F008,3] = baggage_team_02;
constraint task_start[F008,4] = 13;
constraint task_labor[F008,4] = fuel_team_02;
constraint task_start[F008,5] = 13;
constraint task_labor[F008,5] = cabin_clean_team_02;
constraint task_start[F008,6] = 13;
constraint task_labor[F008,6] = water_waste_team_02;
constraint task_start[F008,7] = 13;
constraint task_labor[F008,7] = catering_team_02;
constraint task_start[F008,8] = 29;
constraint task_labor[F008,8] = baggage_team_02;
constraint task_start[F008,9] = 62;
constraint task_labor[F008,9] = ramp_team_01;
constraint task_start[F008,10] = 67;
constraint task_labor[F008,10] = ramp_team_02;
constraint task_start[F008,11] = 98;
constraint task_labor[F008,11] = pushback_team_01;
constraint gate[F009] = G006;
constraint task_start[F009,1] = 530;
constraint task_labor[F009,1] = ramp_team_20;
constraint task_start[F009,2] = 534;
constraint task_labor[F009,2] = ramp_team_32;
constraint task_start[F009,3] = 534;
constraint task_labor[F009,3] = baggage_team_17;
constraint task_start[F009,4] = 546;
constraint task_labor[F009,4] = fuel_team_09;
constraint task_start[F009,5] = 546;
constraint task_labor[F009,5] = cabin_clean_team_09;
constraint task_start[F009,6] = 546;
constraint task_labor[F009,6] = water_waste_team_07;
constraint task_start[F009,7] = 546;
constraint task_labor[F009,7] = catering_team_09;
constraint task_start[F009,8] = 561;
constraint task_labor[F009,8] = baggage_team_17;
constraint task_start[F009,9] = 594;
constraint task_labor[F009,9] = ramp_team_33;
constraint task_start[F009,10] = 601;
constraint task_labor[F009,10] = ramp_team_33;
constraint task_start[F009,11] = 632;
constraint task_labor[F009,11] = pushback_team_15;
constraint gate[F010] = G006;
constraint task_start[F010,1] = 154;
constraint task_labor[F010,1] = ramp_team_01;
constraint task_start[F010,2] = 157;
constraint task_labor[F010,2] = ramp_team_01;
constraint task_start[F010,3] = 157;
constraint task_labor[F010,3] = baggage_team_01;
constraint task_start[F010,4] = 169;
constraint task_labor[F010,4] = fuel_team_01;
constraint task_start[F010,5] = 169;
constraint task_labor[F010,5] = cabin_clean_team_01;
constraint task_start[F010,6] = 169;
constraint task_labor[F010,6] = water_waste_team_01;
constraint task_start[F010,7] = 169;
constraint task_labor[F010,7] = catering_team_01;
constraint task_start[F010,8] = 180;
constraint task_labor[F010,8] = baggage_team_01;
constraint task_start[F010,9] = 217;
constraint task_labor[F010,9] = ramp_team_01;
constraint task_start[F010,10] = 223;
constraint task_labor[F010,10] = ramp_team_01;
constraint task_start[F010,11] = 257;
constraint task_labor[F010,11] = pushback_team_01;
constraint gate[F012] = G008;
constraint task_start[F012,1] = 30;
constraint task_labor[F012,1] = ramp_team_01;
constraint task_start[F012,2] = 34;
constraint task_labor[F012,2] = ramp_team_01;
constraint task_start[F012,3] = 34;
constraint task_labor[F012,3] = baggage_team_03;
constraint task_start[F012,4] = 46;
constraint task_labor[F012,4] = fuel_team_03;
constraint task_start[F012,5] = 46;
constraint task_labor[F012,5] = cabin_clean_team_02;
constraint task_start[F012,6] = 46;
constraint task_labor[F012,6] = water_waste_team_01;
constraint task_start[F012,7] = 46;
constraint task_labor[F012,7] = catering_team_02;
constraint task_start[F012,8] = 59;
constraint task_labor[F012,8] = baggage_team_02;
constraint task_start[F012,9] = 88;
constraint task_labor[F012,9] = ramp_team_03;
constraint task_start[F012,10] = 94;
constraint task_labor[F012,10] = ramp_team_03;
constraint task_start[F012,11] = 126;
constraint task_labor[F012,11] = pushback_team_01;
constraint gate[F013] = G009;
constraint task_start[F013,1] = 2;
constraint task_labor[F013,1] = ramp_team_02;
constraint task_start[F013,2] = 5;
constraint task_labor[F013,2] = ramp_team_03;
constraint task_start[F013,3] = 5;
constraint task_labor[F013,3] = baggage_team_03;
constraint task_start[F013,4] = 17;
constraint task_labor[F013,4] = fuel_team_04;
constraint task_start[F013,5] = 17;
constraint task_labor[F013,5] = cabin_clean_team_03;
constraint task_start[F013,6] = 17;
constraint task_labor[F013,6] = water_waste_team_03;
constraint task_start[F013,7] = 17;
constraint task_labor[F013,7] = catering_team_03;
constraint task_start[F013,8] = 28;
constraint task_labor[F013,8] = baggage_team_04;
constraint task_start[F013,9] = 65;
constraint task_labor[F013,9] = ramp_team_03;
constraint task_start[F013,10] = 71;
constraint task_labor[F013,10] = ramp_team_04;
constraint task_start[F013,11] = 105;
constraint task_labor[F013,11] = pushback_team_02;
constraint gate[F014] = G010;
constraint task_start[F014,1] = 50;
constraint task_labor[F014,1] = ramp_team_01;
constraint task_start[F014,2] = 54;
constraint task_labor[F014,2] = ramp_team_01;
constraint task_start[F014,3] = 54;
constraint task_labor[F014,3] = baggage_team_05;
constraint task_start[F014,4] = 62;
constraint task_labor[F014,4] = fuel_team_02;
constraint task_start[F014,5] = 62;
constraint task_labor[F014,5] = cabin_clean_team_01;
constraint task_start[F014,6] = 62;
constraint task_labor[F014,6] = water_waste_team_01;
constraint task_start[F014,7] = 62;
constraint task_labor[F014,7] = catering_team_01;
constraint task_start[F014,8] = 82;
constraint task_labor[F014,8] = baggage_team_03;
constraint task_start[F014,9] = 106;
constraint task_labor[F014,9] = ramp_team_04;
constraint task_start[F014,10] = 111;
constraint task_labor[F014,10] = ramp_team_04;
constraint task_start[F014,11] = 146;
constraint task_labor[F014,11] = pushback_team_01;
constraint gate[F015] = G011;
constraint task_start[F015,1] = 9;
constraint task_labor[F015,1] = ramp_team_04;
constraint task_start[F015,2] = 14;
constraint task_labor[F015,2] = ramp_team_02;
constraint task_start[F015,3] = 14;
constraint task_labor[F015,3] = baggage_team_05;
constraint task_start[F015,4] = 25;
constraint task_labor[F015,4] = fuel_team_05;
constraint task_start[F015,5] = 25;
constraint task_labor[F015,5] = cabin_clean_team_04;
constraint task_start[F015,6] = 25;
constraint task_labor[F015,6] = water_waste_team_04;
constraint task_start[F015,7] = 25;
constraint task_labor[F015,7] = catering_team_04;
constraint task_start[F015,8] = 38;
constraint task_labor[F015,8] = baggage_team_06;
constraint task_start[F015,9] = 66;
constraint task_labor[F015,9] = ramp_team_05;
constraint task_start[F015,10] = 72;
constraint task_labor[F015,10] = ramp_team_05;
constraint task_start[F015,11] = 104;
constraint task_labor[F015,11] = pushback_team_03;
constraint gate[F016] = G005;
constraint task_start[F016,1] = 268;
constraint task_labor[F016,1] = ramp_team_01;
constraint task_start[F016,2] = 271;
constraint task_labor[F016,2] = ramp_team_01;
constraint task_start[F016,3] = 271;
constraint task_labor[F016,3] = baggage_team_01;
constraint task_start[F016,4] = 279;
constraint task_labor[F016,4] = fuel_team_01;
constraint task_start[F016,5] = 279;
constraint task_labor[F016,5] = cabin_clean_team_01;
constraint task_start[F016,6] = 279;
constraint task_labor[F016,6] = water_waste_team_01;
constraint task_start[F016,7] = 279;
constraint task_labor[F016,7] = catering_team_01;
constraint task_start[F016,8] = 284;
constraint task_labor[F016,8] = baggage_team_01;
constraint task_start[F016,9] = 298;
constraint task_labor[F016,9] = ramp_team_07;
constraint task_start[F016,10] = 301;
constraint task_labor[F016,10] = ramp_team_08;
constraint task_start[F016,11] = 315;
constraint task_labor[F016,11] = pushback_team_01;
constraint gate[F017] = G012;
constraint task_start[F017,1] = 93;
constraint task_labor[F017,1] = ramp_team_07;
constraint task_start[F017,2] = 96;
constraint task_labor[F017,2] = ramp_team_06;
constraint task_start[F017,3] = 96;
constraint task_labor[F017,3] = baggage_team_02;
constraint task_start[F017,4] = 104;
constraint task_labor[F017,4] = fuel_team_03;
constraint task_start[F017,5] = 104;
constraint task_labor[F017,5] = cabin_clean_team_02;
constraint task_start[F017,6] = 104;
constraint task_labor[F017,6] = water_waste_team_01;
constraint task_start[F017,7] = 104;
constraint task_labor[F017,7] = catering_team_02;
constraint task_start[F017,8] = 121;
constraint task_labor[F017,8] = baggage_team_02;
constraint task_start[F017,9] = 148;
constraint task_labor[F017,9] = ramp_team_03;
constraint task_start[F017,10] = 155;
constraint task_labor[F017,10] = ramp_team_03;
constraint task_start[F017,11] = 189;
constraint task_labor[F017,11] = pushback_team_01;
constraint gate[F019] = G001;
constraint task_start[F019,1] = 460;
constraint task_labor[F019,1] = baggage_team_18;
constraint task_start[F019,2] = 480;
constraint task_labor[F019,2] = fuel_team_09;
constraint task_start[F019,3] = 480;
constraint task_labor[F019,3] = baggage_team_18;
constraint task_start[F019,4] = 500;
constraint task_labor[F019,4] = pushback_team_09;
constraint gate[F020] = G013;
constraint task_start[F020,1] = 500;
constraint task_labor[F020,1] = baggage_team_17;
constraint task_start[F020,2] = 520;
constraint task_labor[F020,2] = fuel_team_09;
constraint task_start[F020,3] = 520;
constraint task_labor[F020,3] = baggage_team_18;
constraint task_start[F020,4] = 540;
constraint task_labor[F020,4] = pushback_team_08;
constraint gate[F022] = G000;
constraint task_start[F022,1] = 109;
constraint task_labor[F022,1] = baggage_team_04;
constraint task_start[F022,2] = 129;
constraint task_labor[F022,2] = fuel_team_02;
constraint task_start[F022,3] = 129;
constraint task_labor[F022,3] = baggage_team_01;
constraint task_start[F022,4] = 149;
constraint task_labor[F022,4] = pushback_team_02;
constraint gate[F023] = G002;
constraint task_start[F023,1] = 655;
constraint task_labor[F023,1] = ramp_team_32;
constraint task_start[F023,2] = 657;
constraint task_labor[F023,2] = ramp_team_32;
constraint task_start[F023,3] = 657;
constraint task_labor[F023,3] = baggage_team_30;
constraint task_start[F023,4] = 666;
constraint task_labor[F023,4] = fuel_team_15;
constraint task_start[F023,5] = 666;
constraint task_labor[F023,5] = cabin_clean_team_15;
constraint task_start[F023,6] = 666;
constraint task_labor[F023,6] = water_waste_team_11;
constraint task_start[F023,7] = 666;
constraint task_labor[F023,7] = catering_team_15;
constraint task_start[F023,8] = 673;
constraint task_labor[F023,8] = baggage_team_30;
constraint task_start[F023,9] = 681;
constraint task_labor[F023,9] = ramp_team_32;
constraint task_start[F023,10] = 697;
constraint task_labor[F023,10] = pushback_team_16;
constraint gate[F024] = G017;
constraint task_start[F024,1] = 471;
constraint task_labor[F024,1] = ramp_team_20;
constraint task_start[F024,2] = 474;
constraint task_labor[F024,2] = ramp_team_20;
constraint task_start[F024,3] = 474;
constraint task_labor[F024,3] = baggage_team_19;
constraint task_start[F024,4] = 481;
constraint task_labor[F024,4] = fuel_team_10;
constraint task_start[F024,5] = 481;
constraint task_labor[F024,5] = cabin_clean_team_09;
constraint task_start[F024,6] = 481;
constraint task_labor[F024,6] = water_waste_team_07;
constraint task_start[F024,7] = 481;
constraint task_labor[F024,7] = catering_team_09;
constraint task_start[F024,8] = 485;
constraint task_labor[F024,8] = baggage_team_19;
constraint task_start[F024,9] = 498;
constraint task_labor[F024,9] = ramp_team_20;
constraint task_start[F024,10] = 512;
constraint task_labor[F024,10] = pushback_team_08;
constraint gate[F025] = G002;
constraint task_start[F025,1] = 561;
constraint task_labor[F025,1] = ramp_team_20;
constraint task_start[F025,2] = 563;
constraint task_labor[F025,2] = ramp_team_20;
constraint task_start[F025,3] = 563;
constraint task_labor[F025,3] = baggage_team_18;
constraint task_start[F025,4] = 570;
constraint task_labor[F025,4] = fuel_team_10;
constraint task_start[F025,5] = 570;
constraint task_labor[F025,5] = cabin_clean_team_09;
constraint task_start[F025,6] = 570;
constraint task_labor[F025,6] = water_waste_team_07;
constraint task_start[F025,7] = 570;
constraint task_labor[F025,7] = catering_team_10;
constraint task_start[F025,8] = 578;
constraint task_labor[F025,8] = baggage_team_18;
constraint task_start[F025,9] = 587;
constraint task_labor[F025,9] = ramp_team_32;
constraint task_start[F025,10] = 604;
constraint task_labor[F025,10] = pushback_team_15;
constraint gate[F027] = G003;
constraint task_start[F027,1] = 606;
constraint task_labor[F027,1] = ramp_team_32;
constraint task_start[F027,2] = 608;
constraint task_labor[F027,2] = ramp_team_31;
constraint task_start[F027,3] = 608;
constraint task_labor[F027,3] = baggage_team_30;
constraint task_start[F027,4] = 619;
constraint task_labor[F027,4] = fuel_team_16;
constraint task_start[F027,5] = 619;
constraint task_labor[F027,5] = cabin_clean_team_16;
constraint task_start[F027,6] = 619;
constraint task_labor[F027,6] = water_waste_team_12;
constraint task_start[F027,7] = 619;
constraint task_labor[F027,7] = catering_team_16;
constraint task_start[F027,8] = 620;
constraint task_labor[F027,8] = baggage_team_31;
constraint task_start[F027,9] = 635;
constraint task_labor[F027,9] = ramp_team_31;
constraint task_start[F027,10] = 648;
constraint task_labor[F027,10] = pushback_team_15;
constraint gate[F028] = G015;
constraint task_start[F028,1] = 540;
constraint task_labor[F028,1] = ramp_team_20;
constraint task_start[F028,2] = 543;
constraint task_labor[F028,2] = ramp_team_20;
constraint task_start[F028,3] = 543;
constraint task_labor[F028,3] = baggage_team_18;
constraint task_start[F028,4] = 553;
constraint task_labor[F028,4] = fuel_team_10;
constraint task_start[F028,5] = 553;
constraint task_labor[F028,5] = cabin_clean_team_10;
constraint task_start[F028,6] = 553;
constraint task_labor[F028,6] = water_waste_team_08;
constraint task_start[F028,7] = 553;
constraint task_labor[F028,7] = catering_team_10;
constraint task_start[F028,8] = 560;
constraint task_labor[F028,8] = baggage_team_19;
constraint task_start[F028,9] = 569;
constraint task_labor[F028,9] = ramp_team_21;
constraint task_start[F028,10] = 583;
constraint task_labor[F028,10] = pushback_team_08;
constraint gate[F029] = G002;
constraint task_start[F029,1] = 207;
constraint task_labor[F029,1] = ramp_team_09;
constraint task_start[F029,2] = 209;
constraint task_labor[F029,2] = ramp_team_10;
constraint task_start[F029,3] = 209;
constraint task_labor[F029,3] = baggage_team_01;
constraint task_start[F029,4] = 216;
constraint task_labor[F029,4] = fuel_team_02;
constraint task_start[F029,5] = 216;
constraint task_labor[F029,5] = cabin_clean_team_01;
constraint task_start[F029,6] = 216;
constraint task_labor[F029,6] = water_waste_team_01;
constraint task_start[F029,7] = 216;
constraint task_labor[F029,7] = catering_team_01;
constraint task_start[F029,8] = 222;
constraint task_labor[F029,8] = baggage_team_01;
constraint task_start[F029,9] = 231;
constraint task_labor[F029,9] = ramp_team_02;
constraint task_start[F029,10] = 243;
constraint task_labor[F029,10] = pushback_team_01;
constraint gate[F030] = G003;
constraint task_start[F030,1] = 132;
constraint task_labor[F030,1] = ramp_team_02;
constraint task_start[F030,2] = 135;
constraint task_labor[F030,2] = ramp_team_05;
constraint task_start[F030,3] = 135;
constraint task_labor[F030,3] = baggage_team_03;
constraint task_start[F030,4] = 146;
constraint task_labor[F030,4] = fuel_team_01;
constraint task_start[F030,5] = 146;
constraint task_labor[F030,5] = cabin_clean_team_01;
constraint task_start[F030,6] = 146;
constraint task_labor[F030,6] = water_waste_team_01;
constraint task_start[F030,7] = 146;
constraint task_labor[F030,7] = catering_team_01;
constraint task_start[F030,8] = 146;
constraint task_labor[F030,8] = baggage_team_02;
constraint task_start[F030,9] = 162;
constraint task_labor[F030,9] = ramp_team_04;
constraint task_start[F030,10] = 174;
constraint task_labor[F030,10] = pushback_team_02;
constraint gate[F033] = G015;
constraint task_start[F033,1] = 63;
constraint task_labor[F033,1] = ramp_team_02;
constraint task_start[F033,2] = 65;
constraint task_labor[F033,2] = ramp_team_08;
constraint task_start[F033,3] = 65;
constraint task_labor[F033,3] = baggage_team_03;
constraint task_start[F033,4] = 72;
constraint task_labor[F033,4] = fuel_team_04;
constraint task_start[F033,5] = 72;
constraint task_labor[F033,5] = cabin_clean_team_02;
constraint task_start[F033,6] = 72;
constraint task_labor[F033,6] = water_waste_team_02;
constraint task_start[F033,7] = 72;
constraint task_labor[F033,7] = catering_team_02;
constraint task_start[F033,8] = 82;
constraint task_labor[F033,8] = baggage_team_05;
constraint task_start[F033,9] = 88;
constraint task_labor[F033,9] = ramp_team_11;
constraint task_start[F033,10] = 105;
constraint task_labor[F033,10] = pushback_team_04;
constraint gate[F034] = G003;
constraint task_start[F034,1] = 494;
constraint task_labor[F034,1] = ramp_team_20;
constraint task_start[F034,2] = 496;
constraint task_labor[F034,2] = ramp_team_21;
constraint task_start[F034,3] = 496;
constraint task_labor[F034,3] = baggage_team_20;
constraint task_start[F034,4] = 507;
constraint task_labor[F034,4] = fuel_team_10;
constraint task_start[F034,5] = 507;
constraint task_labor[F034,5] = cabin_clean_team_09;
constraint task_start[F034,6] = 507;
constraint task_labor[F034,6] = water_waste_team_07;
constraint task_start[F034,7] = 507;
constraint task_labor[F034,7] = catering_team_09;
constraint task_start[F034,8] = 512;
constraint task_labor[F034,8] = baggage_team_19;
constraint task_start[F034,9] = 524;
constraint task_labor[F034,9] = ramp_team_21;
constraint task_start[F034,10] = 540;
constraint task_labor[F034,10] = pushback_team_09;
constraint gate[F035] = G004;
constraint task_start[F035,1] = 578;
constraint task_labor[F035,1] = ramp_team_20;
constraint task_start[F035,2] = 580;
constraint task_labor[F035,2] = ramp_team_20;
constraint task_start[F035,3] = 580;
constraint task_labor[F035,3] = baggage_team_19;
constraint task_start[F035,4] = 591;
constraint task_labor[F035,4] = fuel_team_15;
constraint task_start[F035,5] = 591;
constraint task_labor[F035,5] = cabin_clean_team_15;
constraint task_start[F035,6] = 591;
constraint task_labor[F035,6] = water_waste_team_11;
constraint task_start[F035,7] = 591;
constraint task_labor[F035,7] = catering_team_15;
constraint task_start[F035,8] = 592;
constraint task_labor[F035,8] = baggage_team_30;
constraint task_start[F035,9] = 605;
constraint task_labor[F035,9] = ramp_team_34;
constraint task_start[F035,10] = 622;
constraint task_labor[F035,10] = pushback_team_15;
constraint gate[F036] = G015;
constraint task_start[F036,1] = 146;
constraint task_labor[F036,1] = ramp_team_01;
constraint task_start[F036,2] = 149;
constraint task_labor[F036,2] = ramp_team_04;
constraint task_start[F036,3] = 149;
constraint task_labor[F036,3] = baggage_team_03;
constraint task_start[F036,4] = 158;
constraint task_labor[F036,4] = fuel_team_02;
constraint task_start[F036,5] = 158;
constraint task_labor[F036,5] = cabin_clean_team_02;
constraint task_start[F036,6] = 158;
constraint task_labor[F036,6] = water_waste_team_01;
constraint task_start[F036,7] = 158;
constraint task_labor[F036,7] = catering_team_02;
constraint task_start[F036,8] = 165;
constraint task_labor[F036,8] = baggage_team_02;
constraint task_start[F036,9] = 174;
constraint task_labor[F036,9] = ramp_team_01;
constraint task_start[F036,10] = 189;
constraint task_labor[F036,10] = pushback_team_02;
constraint gate[F037] = G003;
constraint task_start[F037,1] = 35;
constraint task_labor[F037,1] = ramp_team_03;
constraint task_start[F037,2] = 38;
constraint task_labor[F037,2] = ramp_team_03;
constraint task_start[F037,3] = 38;
constraint task_labor[F037,3] = baggage_team_05;
constraint task_start[F037,4] = 47;
constraint task_labor[F037,4] = fuel_team_06;
constraint task_start[F037,5] = 47;
constraint task_labor[F037,5] = cabin_clean_team_03;
constraint task_start[F037,6] = 47;
constraint task_labor[F037,6] = water_waste_team_02;
constraint task_start[F037,7] = 47;
constraint task_labor[F037,7] = catering_team_03;
constraint task_start[F037,8] = 51;
constraint task_labor[F037,8] = baggage_team_07;
constraint task_start[F037,9] = 62;
constraint task_labor[F037,9] = ramp_team_06;
constraint task_start[F037,10] = 76;
constraint task_labor[F037,10] = pushback_team_01;
constraint gate[F040] = G018;
constraint task_start[F040,1] = 454;
constraint task_labor[F040,1] = ramp_team_20;
constraint task_start[F040,2] = 456;
constraint task_labor[F040,2] = ramp_team_20;
constraint task_start[F040,3] = 456;
constraint task_labor[F040,3] = baggage_team_19;
constraint task_start[F040,4] = 463;
constraint task_labor[F040,4] = fuel_team_10;
constraint task_start[F040,5] = 463;
constraint task_labor[F040,5] = cabin_clean_team_09;
constraint task_start[F040,6] = 463;
constraint task_labor[F040,6] = water_waste_team_07;
constraint task_start[F040,7] = 463;
constraint task_labor[F040,7] = catering_team_09;
constraint task_start[F040,8] = 471;
constraint task_labor[F040,8] = baggage_team_20;
constraint task_start[F040,9] = 480;
constraint task_labor[F040,9] = ramp_team_21;
constraint task_start[F040,10] = 492;
constraint task_labor[F040,10] = pushback_team_08;
constraint gate[F041] = G017;
constraint task_start[F041,1] = 323;
constraint task_labor[F041,1] = ramp_team_01;
constraint task_start[F041,2] = 325;
constraint task_labor[F041,2] = ramp_team_01;
constraint task_start[F041,3] = 325;
constraint task_labor[F041,3] = baggage_team_01;
constraint task_start[F041,4] = 332;
constraint task_labor[F041,4] = fuel_team_01;
constraint task_start[F041,5] = 332;
constraint task_labor[F041,5] = cabin_clean_team_01;
constraint task_start[F041,6] = 332;
constraint task_labor[F041,6] = water_waste_team_01;
constraint task_start[F041,7] = 332;
constraint task_labor[F041,7] = catering_team_01;
constraint task_start[F041,8] = 338;
constraint task_labor[F041,8] = baggage_team_05;
constraint task_start[F041,9] = 348;
constraint task_labor[F041,9] = ramp_team_04;
constraint task_start[F041,10] = 362;
constraint task_labor[F041,10] = pushback_team_01;
constraint gate[F042] = G017;
constraint task_start[F042,1] = 51;
constraint task_labor[F042,1] = ramp_team_02;
constraint task_start[F042,2] = 53;
constraint task_labor[F042,2] = ramp_team_02;
constraint task_start[F042,3] = 53;
constraint task_labor[F042,3] = baggage_team_08;
constraint task_start[F042,4] = 62;
constraint task_labor[F042,4] = fuel_team_06;
constraint task_start[F042,5] = 62;
constraint task_labor[F042,5] = cabin_clean_team_03;
constraint task_start[F042,6] = 62;
constraint task_labor[F042,6] = water_waste_team_02;
constraint task_start[F042,7] = 62;
constraint task_labor[F042,7] = catering_team_03;
constraint task_start[F042,8] = 65;
constraint task_labor[F042,8] = baggage_team_04;
constraint task_start[F042,9] = 79;
constraint task_labor[F042,9] = ramp_team_08;
constraint task_start[F042,10] = 95;
constraint task_labor[F042,10] = pushback_team_02;
constraint gate[F043] = G018;
constraint task_start[F043,1] = 321;
constraint task_labor[F043,1] = ramp_team_02;
constraint task_start[F043,2] = 324;
constraint task_labor[F043,2] = ramp_team_02;
constraint task_start[F043,3] = 324;
constraint task_labor[F043,3] = baggage_team_02;
constraint task_start[F043,4] = 335;
constraint task_labor[F043,4] = fuel_team_04;
constraint task_start[F043,5] = 335;
constraint task_labor[F043,5] = cabin_clean_team_02;
constraint task_start[F043,6] = 335;
constraint task_labor[F043,6] = water_waste_team_02;
constraint task_start[F043,7] = 335;
constraint task_labor[F043,7] = catering_team_04;
constraint task_start[F043,8] = 341;
constraint task_labor[F043,8] = baggage_team_06;
constraint task_start[F043,9] = 350;
constraint task_labor[F043,9] = ramp_team_07;
constraint task_start[F043,10] = 364;
constraint task_labor[F043,10] = pushback_team_02;
constraint gate[F044] = G019;
constraint task_start[F044,1] = 477;
constraint task_labor[F044,1] = ramp_team_21;
constraint task_start[F044,2] = 480;
constraint task_labor[F044,2] = ramp_team_22;
constraint task_start[F044,3] = 480;
constraint task_labor[F044,3] = baggage_team_21;
constraint task_start[F044,4] = 488;
constraint task_labor[F044,4] = fuel_team_11;
constraint task_start[F044,5] = 488;
constraint task_labor[F044,5] = cabin_clean_team_10;
constraint task_start[F044,6] = 488;
constraint task_labor[F044,6] = water_waste_team_07;
constraint task_start[F044,7] = 488;
constraint task_labor[F044,7] = catering_team_10;
constraint task_start[F044,8] = 491;
constraint task_labor[F044,8] = baggage_team_21;
constraint task_start[F044,9] = 503;
constraint task_labor[F044,9] = ramp_team_31;
constraint task_start[F044,10] = 516;
constraint task_labor[F044,10] = pushback_team_09;
constraint gate[F046] = G020;
constraint task_start[F046,1] = 472;
constraint task_labor[F046,1] = ramp_team_21;
constraint task_start[F046,2] = 475;
constraint task_labor[F046,2] = ramp_team_31;
constraint task_start[F046,3] = 475;
constraint task_labor[F046,3] = baggage_team_22;
constraint task_start[F046,4] = 482;
constraint task_labor[F046,4] = fuel_team_12;
constraint task_start[F046,5] = 482;
constraint task_labor[F046,5] = cabin_clean_team_11;
constraint task_start[F046,6] = 482;
constraint task_labor[F046,6] = water_waste_team_08;
constraint task_start[F046,7] = 482;
constraint task_labor[F046,7] = catering_team_11;
constraint task_start[F046,8] = 489;
constraint task_labor[F046,8] = baggage_team_22;
constraint task_start[F046,9] = 496;
constraint task_labor[F046,9] = ramp_team_32;
constraint task_start[F046,10] = 512;
constraint task_labor[F046,10] = pushback_team_10;
constraint gate[F047] = G014;
constraint task_start[F047,1] = 576;
constraint task_labor[F047,1] = ramp_team_22;
constraint task_start[F047,2] = 579;
constraint task_labor[F047,2] = ramp_team_22;
constraint task_start[F047,3] = 579;
constraint task_labor[F047,3] = baggage_team_31;
constraint task_start[F047,4] = 589;
constraint task_labor[F047,4] = fuel_team_16;
constraint task_start[F047,5] = 589;
constraint task_labor[F047,5] = cabin_clean_team_16;
constraint task_start[F047,6] = 589;
constraint task_labor[F047,6] = water_waste_team_07;
constraint task_start[F047,7] = 589;
constraint task_labor[F047,7] = catering_team_16;
constraint task_start[F047,8] = 596;
constraint task_labor[F047,8] = baggage_team_31;
constraint task_start[F047,9] = 605;
constraint task_labor[F047,9] = ramp_team_35;
constraint task_start[F047,10] = 620;
constraint task_labor[F047,10] = pushback_team_16;
constraint gate[F048] = G015;
constraint task_start[F048,1] = 637;
constraint task_labor[F048,1] = ramp_team_32;
constraint task_start[F048,2] = 639;
constraint task_labor[F048,2] = ramp_team_32;
constraint task_start[F048,3] = 639;
constraint task_labor[F048,3] = baggage_team_31;
constraint task_start[F048,4] = 646;
constraint task_labor[F048,4] = fuel_team_16;
constraint task_start[F048,5] = 646;
constraint task_labor[F048,5] = cabin_clean_team_15;
constraint task_start[F048,6] = 646;
constraint task_labor[F048,6] = water_waste_team_11;
constraint task_start[F048,7] = 646;
constraint task_labor[F048,7] = catering_team_15;
constraint task_start[F048,8] = 654;
constraint task_labor[F048,8] = baggage_team_31;
constraint task_start[F048,9] = 662;
constraint task_labor[F048,9] = ramp_team_33;
constraint task_start[F048,10] = 678;
constraint task_labor[F048,10] = pushback_team_15;
constraint gate[F049] = G018;
constraint task_start[F049,1] = 104;
constraint task_labor[F049,1] = ramp_team_05;
constraint task_start[F049,2] = 107;
constraint task_labor[F049,2] = ramp_team_05;
constraint task_start[F049,3] = 107;
constraint task_labor[F049,3] = baggage_team_07;
constraint task_start[F049,4] = 118;
constraint task_labor[F049,4] = fuel_team_04;
constraint task_start[F049,5] = 118;
constraint task_labor[F049,5] = cabin_clean_team_03;
constraint task_start[F049,6] = 118;
constraint task_labor[F049,6] = water_waste_team_02;
constraint task_start[F049,7] = 118;
constraint task_labor[F049,7] = catering_team_01;
constraint task_start[F049,8] = 120;
constraint task_labor[F049,8] = baggage_team_05;
constraint task_start[F049,9] = 132;
constraint task_labor[F049,9] = ramp_team_06;
constraint task_start[F049,10] = 144;
constraint task_labor[F049,10] = pushback_team_02;
constraint gate[F050] = G021;
constraint task_start[F050,1] = 473;
constraint task_labor[F050,1] = ramp_team_22;
constraint task_start[F050,2] = 475;
constraint task_labor[F050,2] = ramp_team_32;
constraint task_start[F050,3] = 475;
constraint task_labor[F050,3] = baggage_team_23;
constraint task_start[F050,4] = 484;
constraint task_labor[F050,4] = fuel_team_13;
constraint task_start[F050,5] = 484;
constraint task_labor[F050,5] = cabin_clean_team_12;
constraint task_start[F050,6] = 484;
constraint task_labor[F050,6] = water_waste_team_09;
constraint task_start[F050,7] = 484;
constraint task_labor[F050,7] = catering_team_12;
constraint task_start[F050,8] = 490;
constraint task_labor[F050,8] = baggage_team_23;
constraint task_start[F050,9] = 501;
constraint task_labor[F050,9] = ramp_team_33;
constraint task_start[F050,10] = 516;
constraint task_labor[F050,10] = pushback_team_11;
constraint gate[F051] = G003;
constraint task_start[F051,1] = 217;
constraint task_labor[F051,1] = ramp_team_02;
constraint task_start[F051,2] = 220;
constraint task_labor[F051,2] = ramp_team_02;
constraint task_start[F051,3] = 220;
constraint task_labor[F051,3] = baggage_team_02;
constraint task_start[F051,4] = 227;
constraint task_labor[F051,4] = fuel_team_01;
constraint task_start[F051,5] = 227;
constraint task_labor[F051,5] = cabin_clean_team_02;
constraint task_start[F051,6] = 227;
constraint task_labor[F051,6] = water_waste_team_01;
constraint task_start[F051,7] = 227;
constraint task_labor[F051,7] = catering_team_02;
constraint task_start[F051,8] = 235;
constraint task_labor[F051,8] = baggage_team_01;
constraint task_start[F051,9] = 243;
constraint task_labor[F051,9] = ramp_team_02;
constraint task_start[F051,10] = 259;
constraint task_labor[F051,10] = pushback_team_02;
constraint gate[F052] = G016;
constraint task_start[F052,1] = 548;
constraint task_labor[F052,1] = ramp_team_21;
constraint task_start[F052,2] = 551;
constraint task_labor[F052,2] = ramp_team_21;
constraint task_start[F052,3] = 551;
constraint task_labor[F052,3] = baggage_team_20;
constraint task_start[F052,4] = 560;
constraint task_labor[F052,4] = fuel_team_11;
constraint task_start[F052,5] = 560;
constraint task_labor[F052,5] = cabin_clean_team_11;
constraint task_start[F052,6] = 560;
constraint task_labor[F052,6] = water_waste_team_08;
constraint task_start[F052,7] = 560;
constraint task_labor[F052,7] = catering_team_11;
constraint task_start[F052,8] = 563;
constraint task_labor[F052,8] = baggage_team_20;
constraint task_start[F052,9] = 575;
constraint task_labor[F052,9] = ramp_team_33;
constraint task_start[F052,10] = 592;
constraint task_labor[F052,10] = pushback_team_15;
constraint gate[F053] = G019;
constraint task_start[F053,1] = 133;
constraint task_labor[F053,1] = ramp_team_05;
constraint task_start[F053,2] = 135;
constraint task_labor[F053,2] = ramp_team_07;
constraint task_start[F053,3] = 135;
constraint task_labor[F053,3] = baggage_team_04;
constraint task_start[F053,4] = 143;
constraint task_labor[F053,4] = fuel_team_02;
constraint task_start[F053,5] = 143;
constraint task_labor[F053,5] = cabin_clean_team_03;
constraint task_start[F053,6] = 143;
constraint task_labor[F053,6] = water_waste_team_02;
constraint task_start[F053,7] = 143;
constraint task_labor[F053,7] = catering_team_02;
constraint task_start[F053,8] = 146;
constraint task_labor[F053,8] = baggage_team_04;
constraint task_start[F053,9] = 159;
constraint task_labor[F053,9] = ramp_team_05;
constraint task_start[F053,10] = 174;
constraint task_labor[F053,10] = pushback_team_03;
constraint gate[F054] = G019;
constraint task_start[F054,1] = 266;
constraint task_labor[F054,1] = ramp_team_01;
constraint task_start[F054,2] = 268;
constraint task_labor[F054,2] = ramp_team_02;
constraint task_start[F054,3] = 268;
constraint task_labor[F054,3] = baggage_team_02;
constraint task_start[F054,4] = 277;
constraint task_labor[F054,4] = fuel_team_02;
constraint task_start[F054,5] = 277;
constraint task_labor[F054,5] = cabin_clean_team_02;
constraint task_start[F054,6] = 277;
constraint task_labor[F054,6] = water_waste_team_02;
constraint task_start[F054,7] = 277;
constraint task_labor[F054,7] = catering_team_02;
constraint task_start[F054,8] = 282;
constraint task_labor[F054,8] = baggage_team_02;
constraint task_start[F054,9] = 293;
constraint task_labor[F054,9] = ramp_team_01;
constraint task_start[F054,10] = 309;
constraint task_labor[F054,10] = pushback_team_02;
constraint gate[F055] = G020;
constraint task_start[F055,1] = 87;
constraint task_labor[F055,1] = ramp_team_10;
constraint task_start[F055,2] = 89;
constraint task_labor[F055,2] = ramp_team_10;
constraint task_start[F055,3] = 89;
constraint task_labor[F055,3] = baggage_team_08;
constraint task_start[F055,4] = 96;
constraint task_labor[F055,4] = fuel_team_07;
constraint task_start[F055,5] = 96;
constraint task_labor[F055,5] = cabin_clean_team_05;
constraint task_start[F055,6] = 96;
constraint task_labor[F055,6] = water_waste_team_03;
constraint task_start[F055,7] = 96;
constraint task_labor[F055,7] = catering_team_06;
constraint task_start[F055,8] = 106;
constraint task_labor[F055,8] = baggage_team_08;
constraint task_start[F055,9] = 113;
constraint task_labor[F055,9] = ramp_team_07;
constraint task_start[F055,10] = 126;
constraint task_labor[F055,10] = pushback_team_03;
constraint gate[F056] = G004;
constraint task_start[F056,1] = 186;
constraint task_labor[F056,1] = ramp_team_02;
constraint task_start[F056,2] = 189;
constraint task_labor[F056,2] = ramp_team_01;
constraint task_start[F056,3] = 189;
constraint task_labor[F056,3] = baggage_team_02;
constraint task_start[F056,4] = 196;
constraint task_labor[F056,4] = fuel_team_02;
constraint task_start[F056,5] = 196;
constraint task_labor[F056,5] = cabin_clean_team_01;
constraint task_start[F056,6] = 196;
constraint task_labor[F056,6] = water_waste_team_01;
constraint task_start[F056,7] = 196;
constraint task_labor[F056,7] = catering_team_01;
constraint task_start[F056,8] = 202;
constraint task_labor[F056,8] = baggage_team_02;
constraint task_start[F056,9] = 212;
constraint task_labor[F056,9] = ramp_team_03;
constraint task_start[F056,10] = 227;
constraint task_labor[F056,10] = pushback_team_01;
constraint gate[F057] = G021;
constraint task_start[F057,1] = 67;
constraint task_labor[F057,1] = ramp_team_01;
constraint task_start[F057,2] = 69;
constraint task_labor[F057,2] = ramp_team_07;
constraint task_start[F057,3] = 69;
constraint task_labor[F057,3] = baggage_team_06;
constraint task_start[F057,4] = 76;
constraint task_labor[F057,4] = fuel_team_05;
constraint task_start[F057,5] = 76;
constraint task_labor[F057,5] = cabin_clean_team_04;
constraint task_start[F057,6] = 76;
constraint task_labor[F057,6] = water_waste_team_02;
constraint task_start[F057,7] = 76;
constraint task_labor[F057,7] = catering_team_04;
constraint task_start[F057,8] = 82;
constraint task_labor[F057,8] = baggage_team_09;
constraint task_start[F057,9] = 91;
constraint task_labor[F057,9] = ramp_team_12;
constraint task_start[F057,10] = 104;
constraint task_labor[F057,10] = pushback_team_05;
constraint gate[F058] = G018;
constraint task_start[F058,1] = 6;
constraint task_labor[F058,1] = ramp_team_01;
constraint task_start[F058,2] = 8;
constraint task_labor[F058,2] = ramp_team_06;
constraint task_start[F058,3] = 8;
constraint task_labor[F058,3] = baggage_team_06;
constraint task_start[F058,4] = 17;
constraint task_labor[F058,4] = fuel_team_06;
constraint task_start[F058,5] = 17;
constraint task_labor[F058,5] = cabin_clean_team_06;
constraint task_start[F058,6] = 17;
constraint task_labor[F058,6] = water_waste_team_04;
constraint task_start[F058,7] = 17;
constraint task_labor[F058,7] = catering_team_05;
constraint task_start[F058,8] = 19;
constraint task_labor[F058,8] = baggage_team_07;
constraint task_start[F058,9] = 34;
constraint task_labor[F058,9] = ramp_team_04;
constraint task_start[F058,10] = 49;
constraint task_labor[F058,10] = pushback_team_01;
constraint gate[F059] = G018;
constraint task_start[F059,1] = 536;
constraint task_labor[F059,1] = ramp_team_20;
constraint task_start[F059,2] = 539;
constraint task_labor[F059,2] = ramp_team_22;
constraint task_start[F059,3] = 539;
constraint task_labor[F059,3] = baggage_team_19;
constraint task_start[F059,4] = 549;
constraint task_labor[F059,4] = fuel_team_12;
constraint task_start[F059,5] = 549;
constraint task_labor[F059,5] = cabin_clean_team_12;
constraint task_start[F059,6] = 549;
constraint task_labor[F059,6] = water_waste_team_09;
constraint task_start[F059,7] = 549;
constraint task_labor[F059,7] = catering_team_12;
constraint task_start[F059,8] = 552;
constraint task_labor[F059,8] = baggage_team_21;
constraint task_start[F059,9] = 566;
constraint task_labor[F059,9] = ramp_team_31;
constraint task_start[F059,10] = 583;
constraint task_labor[F059,10] = pushback_team_09;
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
