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
constraint gate[F001] = G002;
constraint task_start[F001,1] = 440;
constraint task_labor[F001,1] = ramp_team_01;
constraint task_start[F001,2] = 442;
constraint task_labor[F001,2] = ramp_team_01;
constraint task_start[F001,3] = 442;
constraint task_labor[F001,3] = baggage_team_02;
constraint task_start[F001,4] = 448;
constraint task_labor[F001,4] = fuel_team_09;
constraint task_start[F001,5] = 448;
constraint task_labor[F001,5] = cabin_clean_team_02;
constraint task_start[F001,6] = 448;
constraint task_labor[F001,6] = water_waste_team_02;
constraint task_start[F001,7] = 448;
constraint task_labor[F001,7] = catering_team_02;
constraint task_start[F001,8] = 462;
constraint task_labor[F001,8] = baggage_team_18;
constraint task_start[F001,9] = 493;
constraint task_labor[F001,9] = ramp_team_20;
constraint task_start[F001,10] = 528;
constraint task_labor[F001,10] = pushback_team_07;
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
constraint gate[F024] = G000;
constraint task_start[F024,1] = 93;
constraint task_labor[F024,1] = baggage_team_03;
constraint task_start[F024,2] = 113;
constraint task_labor[F024,2] = fuel_team_03;
constraint task_start[F024,3] = 113;
constraint task_labor[F024,3] = baggage_team_03;
constraint task_start[F024,4] = 133;
constraint task_labor[F024,4] = pushback_team_02;
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
constraint gate[F051] = G018;
constraint task_start[F051,1] = 477;
constraint task_labor[F051,1] = ramp_team_03;
constraint task_start[F051,2] = 479;
constraint task_labor[F051,2] = ramp_team_20;
constraint task_start[F051,3] = 479;
constraint task_labor[F051,3] = baggage_team_23;
constraint task_start[F051,4] = 490;
constraint task_labor[F051,4] = fuel_team_08;
constraint task_start[F051,5] = 490;
constraint task_labor[F051,5] = cabin_clean_team_10;
constraint task_start[F051,6] = 490;
constraint task_labor[F051,6] = water_waste_team_09;
constraint task_start[F051,7] = 490;
constraint task_labor[F051,7] = catering_team_10;
constraint task_start[F051,8] = 496;
constraint task_labor[F051,8] = baggage_team_17;
constraint task_start[F051,9] = 504;
constraint task_labor[F051,9] = ramp_team_38;
constraint task_start[F051,10] = 521;
constraint task_labor[F051,10] = pushback_team_08;
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
constraint gate[F055] = G003;
constraint task_start[F055,1] = 292;
constraint task_labor[F055,1] = ramp_team_03;
constraint task_start[F055,2] = 295;
constraint task_labor[F055,2] = ramp_team_04;
constraint task_start[F055,3] = 295;
constraint task_labor[F055,3] = baggage_team_04;
constraint task_start[F055,4] = 306;
constraint task_labor[F055,4] = fuel_team_03;
constraint task_start[F055,5] = 306;
constraint task_labor[F055,5] = cabin_clean_team_02;
constraint task_start[F055,6] = 306;
constraint task_labor[F055,6] = water_waste_team_02;
constraint task_start[F055,7] = 306;
constraint task_labor[F055,7] = catering_team_02;
constraint task_start[F055,8] = 309;
constraint task_labor[F055,8] = baggage_team_02;
constraint task_start[F055,9] = 320;
constraint task_labor[F055,9] = ramp_team_05;
constraint task_start[F055,10] = 335;
constraint task_labor[F055,10] = pushback_team_02;
constraint gate[F057] = G013;
constraint task_start[F057,1] = 278;
constraint task_labor[F057,1] = ramp_team_01;
constraint task_start[F057,2] = 280;
constraint task_labor[F057,2] = ramp_team_05;
constraint task_start[F057,3] = 280;
constraint task_labor[F057,3] = baggage_team_05;
constraint task_start[F057,4] = 291;
constraint task_labor[F057,4] = fuel_team_05;
constraint task_start[F057,5] = 291;
constraint task_labor[F057,5] = cabin_clean_team_02;
constraint task_start[F057,6] = 291;
constraint task_labor[F057,6] = water_waste_team_02;
constraint task_start[F057,7] = 291;
constraint task_labor[F057,7] = catering_team_04;
constraint task_start[F057,8] = 292;
constraint task_labor[F057,8] = baggage_team_05;
constraint task_start[F057,9] = 307;
constraint task_labor[F057,9] = ramp_team_04;
constraint task_start[F057,10] = 320;
constraint task_labor[F057,10] = pushback_team_01;
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
