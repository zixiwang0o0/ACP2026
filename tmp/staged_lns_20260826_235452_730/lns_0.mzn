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
constraint cost < 22027;
constraint gate[F000] = G001;
constraint task_start[F000,1] = 440;
constraint task_labor[F000,1] = ramp_team_19;
constraint task_start[F000,2] = 443;
constraint task_labor[F000,2] = ramp_team_20;
constraint task_start[F000,3] = 443;
constraint task_labor[F000,3] = baggage_team_01;
constraint task_start[F000,4] = 450;
constraint task_labor[F000,4] = fuel_team_08;
constraint task_start[F000,5] = 450;
constraint task_labor[F000,5] = cabin_clean_team_01;
constraint task_start[F000,6] = 450;
constraint task_labor[F000,6] = water_waste_team_01;
constraint task_start[F000,7] = 450;
constraint task_labor[F000,7] = catering_team_01;
constraint task_start[F000,8] = 463;
constraint task_labor[F000,8] = baggage_team_17;
constraint task_start[F000,9] = 488;
constraint task_labor[F000,9] = ramp_team_21;
constraint task_start[F000,10] = 519;
constraint task_labor[F000,10] = pushback_team_07;
constraint gate[F002] = G003;
constraint task_start[F002,1] = 440;
constraint task_labor[F002,1] = ramp_team_02;
constraint task_start[F002,2] = 442;
constraint task_labor[F002,2] = ramp_team_02;
constraint task_start[F002,3] = 442;
constraint task_labor[F002,3] = baggage_team_03;
constraint task_start[F002,4] = 451;
constraint task_labor[F002,4] = fuel_team_10;
constraint task_start[F002,5] = 451;
constraint task_labor[F002,5] = cabin_clean_team_03;
constraint task_start[F002,6] = 451;
constraint task_labor[F002,6] = water_waste_team_03;
constraint task_start[F002,7] = 451;
constraint task_labor[F002,7] = catering_team_03;
constraint task_start[F002,8] = 464;
constraint task_labor[F002,8] = baggage_team_19;
constraint task_start[F002,9] = 495;
constraint task_labor[F002,9] = ramp_team_19;
constraint task_start[F002,10] = 528;
constraint task_labor[F002,10] = pushback_team_08;
constraint gate[F003] = G004;
constraint task_start[F003,1] = 440;
constraint task_labor[F003,1] = ramp_team_03;
constraint task_start[F003,2] = 443;
constraint task_labor[F003,2] = ramp_team_03;
constraint task_start[F003,3] = 443;
constraint task_labor[F003,3] = baggage_team_04;
constraint task_start[F003,4] = 451;
constraint task_labor[F003,4] = fuel_team_11;
constraint task_start[F003,5] = 451;
constraint task_labor[F003,5] = cabin_clean_team_04;
constraint task_start[F003,6] = 451;
constraint task_labor[F003,6] = water_waste_team_04;
constraint task_start[F003,7] = 451;
constraint task_labor[F003,7] = catering_team_04;
constraint task_start[F003,8] = 468;
constraint task_labor[F003,8] = baggage_team_20;
constraint task_start[F003,9] = 489;
constraint task_labor[F003,9] = ramp_team_22;
constraint task_start[F003,10] = 524;
constraint task_labor[F003,10] = pushback_team_09;
constraint gate[F004] = G011;
constraint task_start[F004,1] = 420;
constraint task_labor[F004,1] = ramp_team_01;
constraint task_start[F004,2] = 422;
constraint task_labor[F004,2] = ramp_team_01;
constraint task_start[F004,3] = 422;
constraint task_labor[F004,3] = baggage_team_01;
constraint task_start[F004,4] = 429;
constraint task_labor[F004,4] = fuel_team_01;
constraint task_start[F004,5] = 429;
constraint task_labor[F004,5] = cabin_clean_team_01;
constraint task_start[F004,6] = 429;
constraint task_labor[F004,6] = water_waste_team_01;
constraint task_start[F004,7] = 429;
constraint task_labor[F004,7] = catering_team_01;
constraint task_start[F004,8] = 439;
constraint task_labor[F004,8] = baggage_team_05;
constraint task_start[F004,9] = 443;
constraint task_labor[F004,9] = ramp_team_04;
constraint task_start[F004,10] = 456;
constraint task_labor[F004,10] = pushback_team_01;
constraint gate[F005] = G012;
constraint task_start[F005,1] = 420;
constraint task_labor[F005,1] = ramp_team_02;
constraint task_start[F005,2] = 422;
constraint task_labor[F005,2] = ramp_team_02;
constraint task_start[F005,3] = 422;
constraint task_labor[F005,3] = baggage_team_02;
constraint task_start[F005,4] = 429;
constraint task_labor[F005,4] = fuel_team_02;
constraint task_start[F005,5] = 429;
constraint task_labor[F005,5] = cabin_clean_team_02;
constraint task_start[F005,6] = 429;
constraint task_labor[F005,6] = water_waste_team_02;
constraint task_start[F005,7] = 429;
constraint task_labor[F005,7] = catering_team_02;
constraint task_start[F005,8] = 439;
constraint task_labor[F005,8] = baggage_team_06;
constraint task_start[F005,9] = 443;
constraint task_labor[F005,9] = ramp_team_05;
constraint task_start[F005,10] = 456;
constraint task_labor[F005,10] = pushback_team_02;
constraint gate[F006] = G013;
constraint task_start[F006,1] = 420;
constraint task_labor[F006,1] = ramp_team_03;
constraint task_start[F006,2] = 422;
constraint task_labor[F006,2] = ramp_team_03;
constraint task_start[F006,3] = 422;
constraint task_labor[F006,3] = baggage_team_03;
constraint task_start[F006,4] = 429;
constraint task_labor[F006,4] = fuel_team_03;
constraint task_start[F006,5] = 429;
constraint task_labor[F006,5] = cabin_clean_team_03;
constraint task_start[F006,6] = 429;
constraint task_labor[F006,6] = water_waste_team_03;
constraint task_start[F006,7] = 429;
constraint task_labor[F006,7] = catering_team_03;
constraint task_start[F006,8] = 439;
constraint task_labor[F006,8] = baggage_team_07;
constraint task_start[F006,9] = 443;
constraint task_labor[F006,9] = ramp_team_19;
constraint task_start[F006,10] = 456;
constraint task_labor[F006,10] = pushback_team_03;
constraint gate[F007] = G014;
constraint task_start[F007,1] = 420;
constraint task_labor[F007,1] = ramp_team_04;
constraint task_start[F007,2] = 422;
constraint task_labor[F007,2] = ramp_team_04;
constraint task_start[F007,3] = 422;
constraint task_labor[F007,3] = baggage_team_04;
constraint task_start[F007,4] = 429;
constraint task_labor[F007,4] = fuel_team_04;
constraint task_start[F007,5] = 429;
constraint task_labor[F007,5] = cabin_clean_team_04;
constraint task_start[F007,6] = 429;
constraint task_labor[F007,6] = water_waste_team_04;
constraint task_start[F007,7] = 429;
constraint task_labor[F007,7] = catering_team_04;
constraint task_start[F007,8] = 439;
constraint task_labor[F007,8] = baggage_team_08;
constraint task_start[F007,9] = 443;
constraint task_labor[F007,9] = ramp_team_22;
constraint task_start[F007,10] = 456;
constraint task_labor[F007,10] = pushback_team_04;
constraint gate[F009] = G005;
constraint task_start[F009,1] = 58;
constraint task_labor[F009,1] = ramp_team_01;
constraint task_start[F009,2] = 61;
constraint task_labor[F009,2] = ramp_team_01;
constraint task_start[F009,3] = 61;
constraint task_labor[F009,3] = baggage_team_01;
constraint task_start[F009,4] = 70;
constraint task_labor[F009,4] = fuel_team_01;
constraint task_start[F009,5] = 70;
constraint task_labor[F009,5] = cabin_clean_team_01;
constraint task_start[F009,6] = 70;
constraint task_labor[F009,6] = water_waste_team_01;
constraint task_start[F009,7] = 70;
constraint task_labor[F009,7] = catering_team_01;
constraint task_start[F009,8] = 90;
constraint task_labor[F009,8] = baggage_team_01;
constraint task_start[F009,9] = 115;
constraint task_labor[F009,9] = ramp_team_01;
constraint task_start[F009,10] = 121;
constraint task_labor[F009,10] = ramp_team_01;
constraint task_start[F009,11] = 152;
constraint task_labor[F009,11] = pushback_team_01;
constraint gate[F011] = G006;
constraint task_start[F011,1] = 54;
constraint task_labor[F011,1] = ramp_team_02;
constraint task_start[F011,2] = 59;
constraint task_labor[F011,2] = ramp_team_02;
constraint task_start[F011,3] = 59;
constraint task_labor[F011,3] = baggage_team_02;
constraint task_start[F011,4] = 68;
constraint task_labor[F011,4] = fuel_team_02;
constraint task_start[F011,5] = 68;
constraint task_labor[F011,5] = cabin_clean_team_02;
constraint task_start[F011,6] = 68;
constraint task_labor[F011,6] = water_waste_team_02;
constraint task_start[F011,7] = 68;
constraint task_labor[F011,7] = catering_team_02;
constraint task_start[F011,8] = 86;
constraint task_labor[F011,8] = baggage_team_02;
constraint task_start[F011,9] = 117;
constraint task_labor[F011,9] = ramp_team_02;
constraint task_start[F011,10] = 123;
constraint task_labor[F011,10] = ramp_team_02;
constraint task_start[F011,11] = 153;
constraint task_labor[F011,11] = pushback_team_02;
constraint gate[F012] = G005;
constraint task_start[F012,1] = 592;
constraint task_labor[F012,1] = ramp_team_19;
constraint task_start[F012,2] = 596;
constraint task_labor[F012,2] = ramp_team_19;
constraint task_start[F012,3] = 596;
constraint task_labor[F012,3] = baggage_team_17;
constraint task_start[F012,4] = 606;
constraint task_labor[F012,4] = fuel_team_08;
constraint task_start[F012,5] = 606;
constraint task_labor[F012,5] = cabin_clean_team_09;
constraint task_start[F012,6] = 606;
constraint task_labor[F012,6] = water_waste_team_09;
constraint task_start[F012,7] = 606;
constraint task_labor[F012,7] = catering_team_09;
constraint task_start[F012,8] = 621;
constraint task_labor[F012,8] = baggage_team_17;
constraint task_start[F012,9] = 653;
constraint task_labor[F012,9] = ramp_team_37;
constraint task_start[F012,10] = 661;
constraint task_labor[F012,10] = ramp_team_38;
constraint task_start[F012,11] = 697;
constraint task_labor[F012,11] = pushback_team_07;
constraint gate[F013] = G005;
constraint task_start[F013,1] = 749;
constraint task_labor[F013,1] = ramp_team_39;
constraint task_start[F013,2] = 752;
constraint task_labor[F013,2] = ramp_team_37;
constraint task_start[F013,3] = 752;
constraint task_labor[F013,3] = baggage_team_33;
constraint task_start[F013,4] = 760;
constraint task_labor[F013,4] = fuel_team_15;
constraint task_start[F013,5] = 760;
constraint task_labor[F013,5] = cabin_clean_team_17;
constraint task_start[F013,6] = 760;
constraint task_labor[F013,6] = water_waste_team_17;
constraint task_start[F013,7] = 760;
constraint task_labor[F013,7] = catering_team_17;
constraint task_start[F013,8] = 777;
constraint task_labor[F013,8] = baggage_team_33;
constraint task_start[F013,9] = 804;
constraint task_labor[F013,9] = ramp_team_37;
constraint task_start[F013,10] = 811;
constraint task_labor[F013,10] = ramp_team_37;
constraint task_start[F013,11] = 845;
constraint task_labor[F013,11] = pushback_team_15;
constraint gate[F014] = G007;
constraint task_start[F014,1] = 33;
constraint task_labor[F014,1] = ramp_team_01;
constraint task_start[F014,2] = 37;
constraint task_labor[F014,2] = ramp_team_01;
constraint task_start[F014,3] = 37;
constraint task_labor[F014,3] = baggage_team_03;
constraint task_start[F014,4] = 46;
constraint task_labor[F014,4] = fuel_team_03;
constraint task_start[F014,5] = 46;
constraint task_labor[F014,5] = cabin_clean_team_01;
constraint task_start[F014,6] = 46;
constraint task_labor[F014,6] = water_waste_team_01;
constraint task_start[F014,7] = 46;
constraint task_labor[F014,7] = catering_team_01;
constraint task_start[F014,8] = 65;
constraint task_labor[F014,8] = baggage_team_03;
constraint task_start[F014,9] = 92;
constraint task_labor[F014,9] = ramp_team_01;
constraint task_start[F014,10] = 100;
constraint task_labor[F014,10] = ramp_team_03;
constraint task_start[F014,11] = 130;
constraint task_labor[F014,11] = pushback_team_01;
constraint gate[F015] = G006;
constraint task_start[F015,1] = 446;
constraint task_labor[F015,1] = ramp_team_23;
constraint task_start[F015,2] = 448;
constraint task_labor[F015,2] = ramp_team_01;
constraint task_start[F015,3] = 448;
constraint task_labor[F015,3] = baggage_team_09;
constraint task_start[F015,4] = 458;
constraint task_labor[F015,4] = fuel_team_01;
constraint task_start[F015,5] = 458;
constraint task_labor[F015,5] = cabin_clean_team_05;
constraint task_start[F015,6] = 458;
constraint task_labor[F015,6] = water_waste_team_05;
constraint task_start[F015,7] = 458;
constraint task_labor[F015,7] = catering_team_05;
constraint task_start[F015,8] = 465;
constraint task_labor[F015,8] = baggage_team_01;
constraint task_start[F015,9] = 476;
constraint task_labor[F015,9] = ramp_team_01;
constraint task_start[F015,10] = 479;
constraint task_labor[F015,10] = ramp_team_19;
constraint task_start[F015,11] = 495;
constraint task_labor[F015,11] = pushback_team_07;
constraint gate[F016] = G007;
constraint task_start[F016,1] = 247;
constraint task_labor[F016,1] = ramp_team_01;
constraint task_start[F016,2] = 252;
constraint task_labor[F016,2] = ramp_team_02;
constraint task_start[F016,3] = 252;
constraint task_labor[F016,3] = baggage_team_03;
constraint task_start[F016,4] = 260;
constraint task_labor[F016,4] = fuel_team_01;
constraint task_start[F016,5] = 260;
constraint task_labor[F016,5] = cabin_clean_team_02;
constraint task_start[F016,6] = 260;
constraint task_labor[F016,6] = water_waste_team_01;
constraint task_start[F016,7] = 260;
constraint task_labor[F016,7] = catering_team_02;
constraint task_start[F016,8] = 275;
constraint task_labor[F016,8] = baggage_team_02;
constraint task_start[F016,9] = 310;
constraint task_labor[F016,9] = ramp_team_02;
constraint task_start[F016,10] = 316;
constraint task_labor[F016,10] = ramp_team_02;
constraint task_start[F016,11] = 348;
constraint task_labor[F016,11] = pushback_team_01;
constraint gate[F017] = G008;
constraint task_start[F017,1] = 123;
constraint task_labor[F017,1] = ramp_team_04;
constraint task_start[F017,2] = 126;
constraint task_labor[F017,2] = ramp_team_04;
constraint task_start[F017,3] = 126;
constraint task_labor[F017,3] = baggage_team_01;
constraint task_start[F017,4] = 134;
constraint task_labor[F017,4] = fuel_team_01;
constraint task_start[F017,5] = 134;
constraint task_labor[F017,5] = cabin_clean_team_01;
constraint task_start[F017,6] = 134;
constraint task_labor[F017,6] = water_waste_team_01;
constraint task_start[F017,7] = 134;
constraint task_labor[F017,7] = catering_team_01;
constraint task_start[F017,8] = 140;
constraint task_labor[F017,8] = baggage_team_01;
constraint task_start[F017,9] = 153;
constraint task_labor[F017,9] = ramp_team_01;
constraint task_start[F017,10] = 157;
constraint task_labor[F017,10] = ramp_team_01;
constraint task_start[F017,11] = 174;
constraint task_labor[F017,11] = pushback_team_01;
constraint gate[F018] = G006;
constraint task_start[F018,1] = 648;
constraint task_labor[F018,1] = ramp_team_19;
constraint task_start[F018,2] = 653;
constraint task_labor[F018,2] = ramp_team_19;
constraint task_start[F018,3] = 653;
constraint task_labor[F018,3] = baggage_team_17;
constraint task_start[F018,4] = 664;
constraint task_labor[F018,4] = fuel_team_08;
constraint task_start[F018,5] = 664;
constraint task_labor[F018,5] = cabin_clean_team_09;
constraint task_start[F018,6] = 664;
constraint task_labor[F018,6] = water_waste_team_09;
constraint task_start[F018,7] = 664;
constraint task_labor[F018,7] = catering_team_09;
constraint task_start[F018,8] = 676;
constraint task_labor[F018,8] = baggage_team_17;
constraint task_start[F018,9] = 709;
constraint task_labor[F018,9] = ramp_team_19;
constraint task_start[F018,10] = 717;
constraint task_labor[F018,10] = ramp_team_37;
constraint task_start[F018,11] = 751;
constraint task_labor[F018,11] = pushback_team_15;
constraint gate[F019] = G022;
constraint task_start[F019,1] = 282;
constraint task_labor[F019,1] = ramp_team_01;
constraint task_start[F019,2] = 284;
constraint task_labor[F019,2] = ramp_team_01;
constraint task_start[F019,3] = 284;
constraint task_labor[F019,3] = baggage_team_03;
constraint task_start[F019,4] = 292;
constraint task_labor[F019,4] = fuel_team_02;
constraint task_start[F019,5] = 292;
constraint task_labor[F019,5] = cabin_clean_team_01;
constraint task_start[F019,6] = 292;
constraint task_labor[F019,6] = water_waste_team_01;
constraint task_start[F019,7] = 292;
constraint task_labor[F019,7] = catering_team_01;
constraint task_start[F019,8] = 298;
constraint task_labor[F019,8] = baggage_team_01;
constraint task_start[F019,9] = 308;
constraint task_labor[F019,9] = ramp_team_03;
constraint task_start[F019,10] = 312;
constraint task_labor[F019,10] = ramp_team_03;
constraint task_start[F019,11] = 328;
constraint task_labor[F019,11] = pushback_team_02;
constraint gate[F020] = G005;
constraint task_start[F020,1] = 436;
constraint task_labor[F020,1] = ramp_team_01;
constraint task_start[F020,2] = 439;
constraint task_labor[F020,2] = ramp_team_21;
constraint task_start[F020,3] = 439;
constraint task_labor[F020,3] = baggage_team_17;
constraint task_start[F020,4] = 448;
constraint task_labor[F020,4] = fuel_team_12;
constraint task_start[F020,5] = 448;
constraint task_labor[F020,5] = cabin_clean_team_06;
constraint task_start[F020,6] = 448;
constraint task_labor[F020,6] = water_waste_team_06;
constraint task_start[F020,7] = 448;
constraint task_labor[F020,7] = catering_team_06;
constraint task_start[F020,8] = 461;
constraint task_labor[F020,8] = baggage_team_21;
constraint task_start[F020,9] = 489;
constraint task_labor[F020,9] = ramp_team_23;
constraint task_start[F020,10] = 497;
constraint task_labor[F020,10] = ramp_team_23;
constraint task_start[F020,11] = 530;
constraint task_labor[F020,11] = pushback_team_10;
constraint gate[F023] = G023;
constraint task_start[F023,1] = 340;
constraint task_labor[F023,1] = ramp_team_01;
constraint task_start[F023,2] = 343;
constraint task_labor[F023,2] = ramp_team_01;
constraint task_start[F023,3] = 343;
constraint task_labor[F023,3] = baggage_team_02;
constraint task_start[F023,4] = 354;
constraint task_labor[F023,4] = fuel_team_01;
constraint task_start[F023,5] = 354;
constraint task_labor[F023,5] = cabin_clean_team_01;
constraint task_start[F023,6] = 354;
constraint task_labor[F023,6] = water_waste_team_01;
constraint task_start[F023,7] = 354;
constraint task_labor[F023,7] = catering_team_01;
constraint task_start[F023,8] = 359;
constraint task_labor[F023,8] = baggage_team_01;
constraint task_start[F023,9] = 371;
constraint task_labor[F023,9] = ramp_team_02;
constraint task_start[F023,10] = 374;
constraint task_labor[F023,10] = ramp_team_02;
constraint task_start[F023,11] = 392;
constraint task_labor[F023,11] = pushback_team_01;
constraint gate[F024] = G000;
constraint task_start[F024,1] = 93;
constraint task_labor[F024,1] = baggage_team_03;
constraint task_start[F024,2] = 113;
constraint task_labor[F024,2] = fuel_team_03;
constraint task_start[F024,3] = 113;
constraint task_labor[F024,3] = baggage_team_03;
constraint task_start[F024,4] = 133;
constraint task_labor[F024,4] = pushback_team_02;
constraint gate[F026] = G000;
constraint task_start[F026,1] = 605;
constraint task_labor[F026,1] = baggage_team_18;
constraint task_start[F026,2] = 625;
constraint task_labor[F026,2] = fuel_team_09;
constraint task_start[F026,3] = 625;
constraint task_labor[F026,3] = baggage_team_18;
constraint task_start[F026,4] = 645;
constraint task_labor[F026,4] = pushback_team_07;
constraint gate[F027] = G009;
constraint task_start[F027,1] = 124;
constraint task_labor[F027,1] = baggage_team_02;
constraint task_start[F027,2] = 144;
constraint task_labor[F027,2] = fuel_team_02;
constraint task_start[F027,3] = 144;
constraint task_labor[F027,3] = baggage_team_02;
constraint task_start[F027,4] = 164;
constraint task_labor[F027,4] = pushback_team_03;
constraint gate[F028] = G000;
constraint task_start[F028,1] = 402;
constraint task_labor[F028,1] = baggage_team_01;
constraint task_start[F028,2] = 422;
constraint task_labor[F028,2] = fuel_team_05;
constraint task_start[F028,3] = 422;
constraint task_labor[F028,3] = baggage_team_09;
constraint task_start[F028,4] = 442;
constraint task_labor[F028,4] = pushback_team_01;
constraint gate[F029] = G000;
constraint task_start[F029,1] = 779;
constraint task_labor[F029,1] = baggage_team_34;
constraint task_start[F029,2] = 799;
constraint task_labor[F029,2] = fuel_team_16;
constraint task_start[F029,3] = 799;
constraint task_labor[F029,3] = baggage_team_33;
constraint task_start[F029,4] = 819;
constraint task_labor[F029,4] = pushback_team_15;
constraint gate[F030] = G001;
constraint task_start[F030,1] = 273;
constraint task_labor[F030,1] = ramp_team_01;
constraint task_start[F030,2] = 275;
constraint task_labor[F030,2] = ramp_team_03;
constraint task_start[F030,3] = 275;
constraint task_labor[F030,3] = baggage_team_04;
constraint task_start[F030,4] = 284;
constraint task_labor[F030,4] = fuel_team_04;
constraint task_start[F030,5] = 284;
constraint task_labor[F030,5] = cabin_clean_team_03;
constraint task_start[F030,6] = 284;
constraint task_labor[F030,6] = water_waste_team_01;
constraint task_start[F030,7] = 284;
constraint task_labor[F030,7] = catering_team_03;
constraint task_start[F030,8] = 287;
constraint task_labor[F030,8] = baggage_team_01;
constraint task_start[F030,9] = 299;
constraint task_labor[F030,9] = ramp_team_05;
constraint task_start[F030,10] = 312;
constraint task_labor[F030,10] = pushback_team_01;
constraint gate[F031] = G015;
constraint task_start[F031,1] = 385;
constraint task_labor[F031,1] = ramp_team_03;
constraint task_start[F031,2] = 387;
constraint task_labor[F031,2] = ramp_team_03;
constraint task_start[F031,3] = 387;
constraint task_labor[F031,3] = baggage_team_02;
constraint task_start[F031,4] = 395;
constraint task_labor[F031,4] = fuel_team_01;
constraint task_start[F031,5] = 395;
constraint task_labor[F031,5] = cabin_clean_team_01;
constraint task_start[F031,6] = 395;
constraint task_labor[F031,6] = water_waste_team_01;
constraint task_start[F031,7] = 395;
constraint task_labor[F031,7] = catering_team_01;
constraint task_start[F031,8] = 404;
constraint task_labor[F031,8] = baggage_team_02;
constraint task_start[F031,9] = 412;
constraint task_labor[F031,9] = ramp_team_05;
constraint task_start[F031,10] = 425;
constraint task_labor[F031,10] = pushback_team_01;
constraint gate[F032] = G016;
constraint task_start[F032,1] = 422;
constraint task_labor[F032,1] = ramp_team_19;
constraint task_start[F032,2] = 425;
constraint task_labor[F032,2] = ramp_team_05;
constraint task_start[F032,3] = 425;
constraint task_labor[F032,3] = baggage_team_18;
constraint task_start[F032,4] = 436;
constraint task_labor[F032,4] = fuel_team_05;
constraint task_start[F032,5] = 436;
constraint task_labor[F032,5] = cabin_clean_team_05;
constraint task_start[F032,6] = 436;
constraint task_labor[F032,6] = water_waste_team_01;
constraint task_start[F032,7] = 436;
constraint task_labor[F032,7] = catering_team_05;
constraint task_start[F032,8] = 441;
constraint task_labor[F032,8] = baggage_team_18;
constraint task_start[F032,9] = 452;
constraint task_labor[F032,9] = ramp_team_02;
constraint task_start[F032,10] = 468;
constraint task_labor[F032,10] = pushback_team_01;
constraint gate[F034] = G015;
constraint task_start[F034,1] = 528;
constraint task_labor[F034,1] = ramp_team_19;
constraint task_start[F034,2] = 530;
constraint task_labor[F034,2] = ramp_team_19;
constraint task_start[F034,3] = 530;
constraint task_labor[F034,3] = baggage_team_17;
constraint task_start[F034,4] = 541;
constraint task_labor[F034,4] = fuel_team_08;
constraint task_start[F034,5] = 541;
constraint task_labor[F034,5] = cabin_clean_team_09;
constraint task_start[F034,6] = 541;
constraint task_labor[F034,6] = water_waste_team_09;
constraint task_start[F034,7] = 541;
constraint task_labor[F034,7] = catering_team_09;
constraint task_start[F034,8] = 541;
constraint task_labor[F034,8] = baggage_team_17;
constraint task_start[F034,9] = 556;
constraint task_labor[F034,9] = ramp_team_19;
constraint task_start[F034,10] = 568;
constraint task_labor[F034,10] = pushback_team_07;
constraint gate[F035] = G017;
constraint task_start[F035,1] = 465;
constraint task_labor[F035,1] = ramp_team_01;
constraint task_start[F035,2] = 468;
constraint task_labor[F035,2] = ramp_team_02;
constraint task_start[F035,3] = 468;
constraint task_labor[F035,3] = baggage_team_02;
constraint task_start[F035,4] = 479;
constraint task_labor[F035,4] = fuel_team_13;
constraint task_start[F035,5] = 479;
constraint task_labor[F035,5] = cabin_clean_team_09;
constraint task_start[F035,6] = 479;
constraint task_labor[F035,6] = water_waste_team_09;
constraint task_start[F035,7] = 479;
constraint task_labor[F035,7] = catering_team_09;
constraint task_start[F035,8] = 479;
constraint task_labor[F035,8] = baggage_team_22;
constraint task_start[F035,9] = 495;
constraint task_labor[F035,9] = ramp_team_37;
constraint task_start[F035,10] = 510;
constraint task_labor[F035,10] = pushback_team_07;
constraint gate[F036] = G001;
constraint task_start[F036,1] = 802;
constraint task_labor[F036,1] = ramp_team_38;
constraint task_start[F036,2] = 805;
constraint task_labor[F036,2] = ramp_team_38;
constraint task_start[F036,3] = 805;
constraint task_labor[F036,3] = baggage_team_34;
constraint task_start[F036,4] = 812;
constraint task_labor[F036,4] = fuel_team_15;
constraint task_start[F036,5] = 812;
constraint task_labor[F036,5] = cabin_clean_team_17;
constraint task_start[F036,6] = 812;
constraint task_labor[F036,6] = water_waste_team_17;
constraint task_start[F036,7] = 812;
constraint task_labor[F036,7] = catering_team_17;
constraint task_start[F036,8] = 816;
constraint task_labor[F036,8] = baggage_team_34;
constraint task_start[F036,9] = 829;
constraint task_labor[F036,9] = ramp_team_38;
constraint task_start[F036,10] = 843;
constraint task_labor[F036,10] = pushback_team_16;
constraint gate[F038] = G004;
constraint task_start[F038,1] = 242;
constraint task_labor[F038,1] = ramp_team_03;
constraint task_start[F038,2] = 245;
constraint task_labor[F038,2] = ramp_team_05;
constraint task_start[F038,3] = 245;
constraint task_labor[F038,3] = baggage_team_04;
constraint task_start[F038,4] = 254;
constraint task_labor[F038,4] = fuel_team_02;
constraint task_start[F038,5] = 254;
constraint task_labor[F038,5] = cabin_clean_team_03;
constraint task_start[F038,6] = 254;
constraint task_labor[F038,6] = water_waste_team_02;
constraint task_start[F038,7] = 254;
constraint task_labor[F038,7] = catering_team_03;
constraint task_start[F038,8] = 262;
constraint task_labor[F038,8] = baggage_team_02;
constraint task_start[F038,9] = 270;
constraint task_labor[F038,9] = ramp_team_04;
constraint task_start[F038,10] = 285;
constraint task_labor[F038,10] = pushback_team_01;
constraint gate[F039] = G017;
constraint task_start[F039,1] = 372;
constraint task_labor[F039,1] = ramp_team_03;
constraint task_start[F039,2] = 374;
constraint task_labor[F039,2] = ramp_team_03;
constraint task_start[F039,3] = 374;
constraint task_labor[F039,3] = baggage_team_01;
constraint task_start[F039,4] = 382;
constraint task_labor[F039,4] = fuel_team_02;
constraint task_start[F039,5] = 382;
constraint task_labor[F039,5] = cabin_clean_team_02;
constraint task_start[F039,6] = 382;
constraint task_labor[F039,6] = water_waste_team_01;
constraint task_start[F039,7] = 382;
constraint task_labor[F039,7] = catering_team_01;
constraint task_start[F039,8] = 391;
constraint task_labor[F039,8] = baggage_team_03;
constraint task_start[F039,9] = 398;
constraint task_labor[F039,9] = ramp_team_01;
constraint task_start[F039,10] = 413;
constraint task_labor[F039,10] = pushback_team_01;
constraint gate[F040] = G018;
constraint task_start[F040,1] = 383;
constraint task_labor[F040,1] = ramp_team_04;
constraint task_start[F040,2] = 386;
constraint task_labor[F040,2] = ramp_team_04;
constraint task_start[F040,3] = 386;
constraint task_labor[F040,3] = baggage_team_04;
constraint task_start[F040,4] = 393;
constraint task_labor[F040,4] = fuel_team_03;
constraint task_start[F040,5] = 393;
constraint task_labor[F040,5] = cabin_clean_team_03;
constraint task_start[F040,6] = 393;
constraint task_labor[F040,6] = water_waste_team_02;
constraint task_start[F040,7] = 393;
constraint task_labor[F040,7] = catering_team_02;
constraint task_start[F040,8] = 398;
constraint task_labor[F040,8] = baggage_team_04;
constraint task_start[F040,9] = 408;
constraint task_labor[F040,9] = ramp_team_19;
constraint task_start[F040,10] = 422;
constraint task_labor[F040,10] = pushback_team_02;
constraint gate[F041] = G001;
constraint task_start[F041,1] = 177;
constraint task_labor[F041,1] = ramp_team_01;
constraint task_start[F041,2] = 180;
constraint task_labor[F041,2] = ramp_team_01;
constraint task_start[F041,3] = 180;
constraint task_labor[F041,3] = baggage_team_01;
constraint task_start[F041,4] = 191;
constraint task_labor[F041,4] = fuel_team_01;
constraint task_start[F041,5] = 191;
constraint task_labor[F041,5] = cabin_clean_team_01;
constraint task_start[F041,6] = 191;
constraint task_labor[F041,6] = water_waste_team_01;
constraint task_start[F041,7] = 191;
constraint task_labor[F041,7] = catering_team_01;
constraint task_start[F041,8] = 194;
constraint task_labor[F041,8] = baggage_team_02;
constraint task_start[F041,9] = 207;
constraint task_labor[F041,9] = ramp_team_04;
constraint task_start[F041,10] = 222;
constraint task_labor[F041,10] = pushback_team_01;
constraint gate[F042] = G001;
constraint task_start[F042,1] = 640;
constraint task_labor[F042,1] = ramp_team_19;
constraint task_start[F042,2] = 642;
constraint task_labor[F042,2] = ramp_team_21;
constraint task_start[F042,3] = 642;
constraint task_labor[F042,3] = baggage_team_19;
constraint task_start[F042,4] = 651;
constraint task_labor[F042,4] = fuel_team_10;
constraint task_start[F042,5] = 651;
constraint task_labor[F042,5] = cabin_clean_team_11;
constraint task_start[F042,6] = 651;
constraint task_labor[F042,6] = water_waste_team_09;
constraint task_start[F042,7] = 651;
constraint task_labor[F042,7] = catering_team_09;
constraint task_start[F042,8] = 656;
constraint task_labor[F042,8] = baggage_team_19;
constraint task_start[F042,9] = 666;
constraint task_labor[F042,9] = ramp_team_19;
constraint task_start[F042,10] = 682;
constraint task_labor[F042,10] = pushback_team_07;
constraint gate[F043] = G002;
constraint task_start[F043,1] = 721;
constraint task_labor[F043,1] = ramp_team_39;
constraint task_start[F043,2] = 724;
constraint task_labor[F043,2] = ramp_team_39;
constraint task_start[F043,3] = 724;
constraint task_labor[F043,3] = baggage_team_33;
constraint task_start[F043,4] = 733;
constraint task_labor[F043,4] = fuel_team_15;
constraint task_start[F043,5] = 733;
constraint task_labor[F043,5] = cabin_clean_team_17;
constraint task_start[F043,6] = 733;
constraint task_labor[F043,6] = water_waste_team_17;
constraint task_start[F043,7] = 733;
constraint task_labor[F043,7] = catering_team_17;
constraint task_start[F043,8] = 736;
constraint task_labor[F043,8] = baggage_team_33;
constraint task_start[F043,9] = 749;
constraint task_labor[F043,9] = ramp_team_40;
constraint task_start[F043,10] = 764;
constraint task_labor[F043,10] = pushback_team_15;
constraint gate[F044] = G011;
constraint task_start[F044,1] = 223;
constraint task_labor[F044,1] = ramp_team_01;
constraint task_start[F044,2] = 225;
constraint task_labor[F044,2] = ramp_team_02;
constraint task_start[F044,3] = 225;
constraint task_labor[F044,3] = baggage_team_04;
constraint task_start[F044,4] = 233;
constraint task_labor[F044,4] = fuel_team_02;
constraint task_start[F044,5] = 233;
constraint task_labor[F044,5] = cabin_clean_team_02;
constraint task_start[F044,6] = 233;
constraint task_labor[F044,6] = water_waste_team_01;
constraint task_start[F044,7] = 233;
constraint task_labor[F044,7] = catering_team_02;
constraint task_start[F044,8] = 241;
constraint task_labor[F044,8] = baggage_team_05;
constraint task_start[F044,9] = 250;
constraint task_labor[F044,9] = ramp_team_03;
constraint task_start[F044,10] = 263;
constraint task_labor[F044,10] = pushback_team_01;
constraint gate[F045] = G002;
constraint task_start[F045,1] = 98;
constraint task_labor[F045,1] = ramp_team_02;
constraint task_start[F045,2] = 101;
constraint task_labor[F045,2] = ramp_team_01;
constraint task_start[F045,3] = 101;
constraint task_labor[F045,3] = baggage_team_04;
constraint task_start[F045,4] = 112;
constraint task_labor[F045,4] = fuel_team_04;
constraint task_start[F045,5] = 112;
constraint task_labor[F045,5] = cabin_clean_team_01;
constraint task_start[F045,6] = 112;
constraint task_labor[F045,6] = water_waste_team_01;
constraint task_start[F045,7] = 112;
constraint task_labor[F045,7] = catering_team_01;
constraint task_start[F045,8] = 117;
constraint task_labor[F045,8] = baggage_team_04;
constraint task_start[F045,9] = 129;
constraint task_labor[F045,9] = ramp_team_05;
constraint task_start[F045,10] = 143;
constraint task_labor[F045,10] = pushback_team_01;
constraint gate[F046] = G001;
constraint task_start[F046,1] = 52;
constraint task_labor[F046,1] = ramp_team_01;
constraint task_start[F046,2] = 54;
constraint task_labor[F046,2] = ramp_team_03;
constraint task_start[F046,3] = 54;
constraint task_labor[F046,3] = baggage_team_04;
constraint task_start[F046,4] = 62;
constraint task_labor[F046,4] = fuel_team_04;
constraint task_start[F046,5] = 62;
constraint task_labor[F046,5] = cabin_clean_team_03;
constraint task_start[F046,6] = 62;
constraint task_labor[F046,6] = water_waste_team_02;
constraint task_start[F046,7] = 62;
constraint task_labor[F046,7] = catering_team_03;
constraint task_start[F046,8] = 69;
constraint task_labor[F046,8] = baggage_team_04;
constraint task_start[F046,9] = 79;
constraint task_labor[F046,9] = ramp_team_01;
constraint task_start[F046,10] = 91;
constraint task_labor[F046,10] = pushback_team_01;
constraint gate[F047] = G013;
constraint task_start[F047,1] = 183;
constraint task_labor[F047,1] = ramp_team_02;
constraint task_start[F047,2] = 186;
constraint task_labor[F047,2] = ramp_team_02;
constraint task_start[F047,3] = 186;
constraint task_labor[F047,3] = baggage_team_03;
constraint task_start[F047,4] = 196;
constraint task_labor[F047,4] = fuel_team_02;
constraint task_start[F047,5] = 196;
constraint task_labor[F047,5] = cabin_clean_team_02;
constraint task_start[F047,6] = 196;
constraint task_labor[F047,6] = water_waste_team_02;
constraint task_start[F047,7] = 196;
constraint task_labor[F047,7] = catering_team_02;
constraint task_start[F047,8] = 198;
constraint task_labor[F047,8] = baggage_team_04;
constraint task_start[F047,9] = 213;
constraint task_labor[F047,9] = ramp_team_05;
constraint task_start[F047,10] = 226;
constraint task_labor[F047,10] = pushback_team_02;
constraint gate[F048] = G002;
constraint task_start[F048,1] = 623;
constraint task_labor[F048,1] = ramp_team_19;
constraint task_start[F048,2] = 626;
constraint task_labor[F048,2] = ramp_team_19;
constraint task_start[F048,3] = 626;
constraint task_labor[F048,3] = baggage_team_19;
constraint task_start[F048,4] = 634;
constraint task_labor[F048,4] = fuel_team_10;
constraint task_start[F048,5] = 634;
constraint task_labor[F048,5] = cabin_clean_team_09;
constraint task_start[F048,6] = 634;
constraint task_labor[F048,6] = water_waste_team_09;
constraint task_start[F048,7] = 634;
constraint task_labor[F048,7] = catering_team_09;
constraint task_start[F048,8] = 639;
constraint task_labor[F048,8] = baggage_team_20;
constraint task_start[F048,9] = 650;
constraint task_labor[F048,9] = ramp_team_22;
constraint task_start[F048,10] = 666;
constraint task_labor[F048,10] = pushback_team_07;
constraint gate[F049] = G019;
constraint task_start[F049,1] = 377;
constraint task_labor[F049,1] = ramp_team_04;
constraint task_start[F049,2] = 380;
constraint task_labor[F049,2] = ramp_team_05;
constraint task_start[F049,3] = 380;
constraint task_labor[F049,3] = baggage_team_03;
constraint task_start[F049,4] = 391;
constraint task_labor[F049,4] = fuel_team_04;
constraint task_start[F049,5] = 391;
constraint task_labor[F049,5] = cabin_clean_team_04;
constraint task_start[F049,6] = 391;
constraint task_labor[F049,6] = water_waste_team_03;
constraint task_start[F049,7] = 391;
constraint task_labor[F049,7] = catering_team_03;
constraint task_start[F049,8] = 391;
constraint task_labor[F049,8] = baggage_team_05;
constraint task_start[F049,9] = 408;
constraint task_labor[F049,9] = ramp_team_20;
constraint task_start[F049,10] = 424;
constraint task_labor[F049,10] = pushback_team_03;
constraint gate[F050] = G016;
constraint task_start[F050,1] = 549;
constraint task_labor[F050,1] = ramp_team_19;
constraint task_start[F050,2] = 551;
constraint task_labor[F050,2] = ramp_team_20;
constraint task_start[F050,3] = 551;
constraint task_labor[F050,3] = baggage_team_18;
constraint task_start[F050,4] = 558;
constraint task_labor[F050,4] = fuel_team_08;
constraint task_start[F050,5] = 558;
constraint task_labor[F050,5] = cabin_clean_team_09;
constraint task_start[F050,6] = 558;
constraint task_labor[F050,6] = water_waste_team_09;
constraint task_start[F050,7] = 558;
constraint task_labor[F050,7] = catering_team_09;
constraint task_start[F050,8] = 562;
constraint task_labor[F050,8] = baggage_team_17;
constraint task_start[F050,9] = 574;
constraint task_labor[F050,9] = ramp_team_19;
constraint task_start[F050,10] = 591;
constraint task_labor[F050,10] = pushback_team_07;
constraint gate[F052] = G003;
constraint task_start[F052,1] = 804;
constraint task_labor[F052,1] = ramp_team_39;
constraint task_start[F052,2] = 806;
constraint task_labor[F052,2] = ramp_team_39;
constraint task_start[F052,3] = 806;
constraint task_labor[F052,3] = baggage_team_35;
constraint task_start[F052,4] = 816;
constraint task_labor[F052,4] = fuel_team_16;
constraint task_start[F052,5] = 816;
constraint task_labor[F052,5] = cabin_clean_team_18;
constraint task_start[F052,6] = 816;
constraint task_labor[F052,6] = water_waste_team_18;
constraint task_start[F052,7] = 816;
constraint task_labor[F052,7] = catering_team_18;
constraint task_start[F052,8] = 823;
constraint task_labor[F052,8] = baggage_team_33;
constraint task_start[F052,9] = 832;
constraint task_labor[F052,9] = ramp_team_39;
constraint task_start[F052,10] = 846;
constraint task_labor[F052,10] = pushback_team_17;
constraint gate[F053] = G002;
constraint task_start[F053,1] = 320;
constraint task_labor[F053,1] = ramp_team_04;
constraint task_start[F053,2] = 323;
constraint task_labor[F053,2] = ramp_team_04;
constraint task_start[F053,3] = 323;
constraint task_labor[F053,3] = baggage_team_02;
constraint task_start[F053,4] = 330;
constraint task_labor[F053,4] = fuel_team_01;
constraint task_start[F053,5] = 330;
constraint task_labor[F053,5] = cabin_clean_team_02;
constraint task_start[F053,6] = 330;
constraint task_labor[F053,6] = water_waste_team_01;
constraint task_start[F053,7] = 330;
constraint task_labor[F053,7] = catering_team_01;
constraint task_start[F053,8] = 337;
constraint task_labor[F053,8] = baggage_team_03;
constraint task_start[F053,9] = 346;
constraint task_labor[F053,9] = ramp_team_03;
constraint task_start[F053,10] = 361;
constraint task_labor[F053,10] = pushback_team_01;
constraint gate[F054] = G012;
constraint task_start[F054,1] = 218;
constraint task_labor[F054,1] = ramp_team_01;
constraint task_start[F054,2] = 220;
constraint task_labor[F054,2] = ramp_team_03;
constraint task_start[F054,3] = 220;
constraint task_labor[F054,3] = baggage_team_05;
constraint task_start[F054,4] = 227;
constraint task_labor[F054,4] = fuel_team_03;
constraint task_start[F054,5] = 227;
constraint task_labor[F054,5] = cabin_clean_team_04;
constraint task_start[F054,6] = 227;
constraint task_labor[F054,6] = water_waste_team_02;
constraint task_start[F054,7] = 227;
constraint task_labor[F054,7] = catering_team_03;
constraint task_start[F054,8] = 237;
constraint task_labor[F054,8] = baggage_team_03;
constraint task_start[F054,9] = 242;
constraint task_labor[F054,9] = ramp_team_04;
constraint task_start[F054,10] = 257;
constraint task_labor[F054,10] = pushback_team_01;
constraint gate[F056] = G003;
constraint task_start[F056,1] = 20;
constraint task_labor[F056,1] = ramp_team_01;
constraint task_start[F056,2] = 23;
constraint task_labor[F056,2] = ramp_team_02;
constraint task_start[F056,3] = 23;
constraint task_labor[F056,3] = baggage_team_02;
constraint task_start[F056,4] = 34;
constraint task_labor[F056,4] = fuel_team_02;
constraint task_start[F056,5] = 34;
constraint task_labor[F056,5] = cabin_clean_team_02;
constraint task_start[F056,6] = 34;
constraint task_labor[F056,6] = water_waste_team_01;
constraint task_start[F056,7] = 34;
constraint task_labor[F056,7] = catering_team_02;
constraint task_start[F056,8] = 36;
constraint task_labor[F056,8] = baggage_team_02;
constraint task_start[F056,9] = 50;
constraint task_labor[F056,9] = ramp_team_04;
constraint task_start[F056,10] = 64;
constraint task_labor[F056,10] = pushback_team_01;
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
