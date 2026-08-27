param(
  [Parameter(Mandatory = $true)][string]$Instance,
  [Parameter(Mandatory = $true)][string]$Output,
  [string]$Model = 'airport_sched.mzn',
  [int]$StageTimeMs = 30000,
  [int]$LnsTimeMs = 15000,
  [int]$Iterations = 8,
  [int]$Seed = 1
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $MyInvocation.MyCommand.Path
$instancePath = (Resolve-Path $Instance).Path
$modelPath = (Resolve-Path $Model).Path
$outputPath = [IO.Path]::GetFullPath($Output)
$scratch = Join-Path $workspace ("tmp\staged_lns_" + [DateTime]::Now.ToString('yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Force $scratch | Out-Null
$baseModel = Get-Content -Raw -LiteralPath $modelPath
$instanceData = Get-Content -Raw -LiteralPath $instancePath | ConvertFrom-Json
$solvePattern = 'solve\s*::\s*seq_search\(\[.*?\]\)\s*minimize\s+cost;'
if (-not [regex]::IsMatch($baseModel, $solvePattern, 'Singleline')) {
  throw 'Cannot locate the solve item in the model.'
}
$random = [Random]::new($Seed)

function Read-Solution([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path) -or (Get-Item -LiteralPath $Path).Length -eq 0) { return $null }
  try {
    $value = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    if ($null -ne $value.cost -and [long]$value.cost -ge 0) { return $value }
  } catch { }
  return $null
}

function Stop-ProcessTree([int]$ProcessId) {
  # MiniZinc launches a FlatZinc child; killing only the parent leaks the solver.
  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = 'SilentlyContinue'
  & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null
  Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
  $ErrorActionPreference = $oldPreference
}

function Invoke-One([string]$Solver, [string]$ModelFile, [string]$Candidate, [int]$LimitMs) {
  if (Test-Path -LiteralPath $Candidate) { Clear-Content -LiteralPath $Candidate }
  $arguments = "--solver $Solver --time-limit $LimitMs --no-output-comments " +
    "--soln-sep `" `" --search-complete-msg `" `" " +
    "--output-to-file `"$Candidate`" `"$ModelFile`" `"$instancePath`""
  $process = Start-Process -FilePath minizinc -ArgumentList $arguments -PassThru -WindowStyle Hidden
  if (-not $process.WaitForExit($LimitMs + 10000)) { Stop-ProcessTree $process.Id }
  return Read-Solution $Candidate
}

function Invoke-Portfolio([string]$ModelFile, [string]$Tag, [int]$LimitMs) {
  $runs = foreach ($solver in @('chuffed', 'cp-sat', 'gecode')) {
    $candidate = Join-Path $scratch ($Tag + '_' + $solver.Replace('-', '_') + '.json')
    $arguments = "--solver $solver --time-limit $LimitMs --no-output-comments " +
      "--soln-sep `" `" --search-complete-msg `" `" " +
      "--output-to-file `"$candidate`" `"$ModelFile`" `"$instancePath`""
    $process = Start-Process -FilePath minizinc -ArgumentList $arguments -PassThru -WindowStyle Hidden
    [pscustomobject]@{ Solver = $solver; Candidate = $candidate; Process = $process }
  }
  $deadline = [DateTime]::UtcNow.AddMilliseconds($LimitMs + 10000)
  while ([DateTime]::UtcNow -lt $deadline -and ($runs.Process | Where-Object { -not $_.HasExited })) {
    Start-Sleep -Milliseconds 200
  }
  foreach ($run in $runs) { if (-not $run.Process.HasExited) { Stop-ProcessTree $run.Process.Id } }
  $valid = foreach ($run in $runs) {
    $solution = Read-Solution $run.Candidate
    if ($null -ne $solution) {
      [pscustomobject]@{ Solver = $run.Solver; Candidate = $run.Candidate; Solution = $solution; Cost = [long]$solution.cost }
    }
  }
  return $valid | Sort-Object Cost | Select-Object -First 1
}

function Invoke-Adaptive([string]$ModelFile, [string]$Tag, [int]$LimitMs) {
  # Three flattened copies of a large model can exhaust memory.  Small cases
  # benefit from a portfolio; large cases get the full budget on Gecode.
  if ($instanceData.FlightID.Count -le 100) {
    return Invoke-Portfolio $ModelFile $Tag $LimitMs
  }
  $candidate = Join-Path $scratch ($Tag + '_gecode.json')
  $solution = Invoke-One 'gecode' $ModelFile $candidate $LimitMs
  if ($null -eq $solution) { return $null }
  return [pscustomobject]@{
    Solver = 'gecode'; Candidate = $candidate
    Solution = $solution; Cost = [long]$solution.cost
  }
}

function Assert-Identifier([string]$Value) {
  if ($Value -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { throw "Unsafe MiniZinc identifier: $Value" }
  return $Value
}

function New-BoundedModel($Incumbent, [string]$Mode, [int]$RelaxPercent = 40) {
  $constraints = [Collections.Generic.List[string]]::new()
  $constraints.Add("constraint cost < $([long]$Incumbent.cost);")
  $flightCount = $instanceData.FlightID.Count

  if ($Mode -eq 'flight') {
    $relaxCount = [Math]::Max(1, [Math]::Floor($RelaxPercent * $flightCount / 100))
    $relaxed = @((0..($flightCount - 1) | Sort-Object { $random.Next() } | Select-Object -First $relaxCount))
    for ($i = 0; $i -lt $flightCount; $i++) {
      if ($i -in $relaxed) { continue }
      $f = Assert-Identifier $instanceData.FlightID[$i]
      $g = Assert-Identifier $Incumbent.gate[$i]
      $constraints.Add("constraint gate[$f] = $g;")
      for ($t = 0; $t -lt [int]$instanceData.flight_n_tasks[$i]; $t++) {
        $labor = Assert-Identifier $Incumbent.task_labor[$i][$t]
        $constraints.Add("constraint task_start[$f,$($t + 1)] = $($Incumbent.task_start[$i][$t]);")
        $constraints.Add("constraint task_labor[$f,$($t + 1)] = $labor;")
      }
    }
  } elseif ($Mode -eq 'team') {
    $kinds = @($Incumbent.task_labor | ForEach-Object { $_ } | ForEach-Object { $_ -replace '_\d+$','' } | Sort-Object -Unique)
    $selected = $kinds[$random.Next($kinds.Count)]
    for ($i = 0; $i -lt $flightCount; $i++) {
      $f = Assert-Identifier $instanceData.FlightID[$i]
      for ($t = 0; $t -lt [int]$instanceData.flight_n_tasks[$i]; $t++) {
        $labor = Assert-Identifier $Incumbent.task_labor[$i][$t]
        if (($labor -replace '_\d+$','') -ne $selected) {
          $constraints.Add("constraint task_labor[$f,$($t + 1)] = $labor;")
        }
      }
    }
  }
  $insertion = ($constraints -join [Environment]::NewLine) + [Environment]::NewLine
  return [regex]::Replace($baseModel, $solvePattern, { param($m) $insertion + $m.Value }, 'Singleline')
}

function New-EarliestStartModel {
  $preds = @{
    DISEMBARK=@('ARRIVE_SECURE'); BAG_UNLOAD=@('ARRIVE_SECURE')
    FUEL=@('DISEMBARK','CARGO_UNLOAD'); CABIN_CLEAN=@('DISEMBARK')
    WATER_LAV=@('DISEMBARK'); CATERING=@('DISEMBARK')
    BAG_LOAD=@('BAG_UNLOAD'); INTL_DOCS=@('CABIN_CLEAN','CATERING','FUEL','WATER_LAV')
    BOARDING=@('CABIN_CLEAN','CATERING','FUEL','WATER_LAV','INTL_DOCS')
    PUSHBACK=@('BOARDING','BAG_LOAD'); CARGO_LOAD=@('CARGO_UNLOAD')
    DEP_RELEASE=@('CARGO_LOAD','FUEL')
  }
  $teamOf = @{
    ARRIVE_SECURE='ramp_team'; DISEMBARK='ramp_team'; BAG_UNLOAD='baggage_team'
    FUEL='fuel_team'; CABIN_CLEAN='cabin_clean_team'; WATER_LAV='water_waste_team'
    CATERING='catering_team'; BAG_LOAD='baggage_team'; INTL_DOCS='ramp_team'
    BOARDING='ramp_team'; PUSHBACK='pushback_team'; CARGO_UNLOAD='baggage_team'
    CARGO_LOAD='baggage_team'; DEP_RELEASE='pushback_team'
  }
  $constraints = [Collections.Generic.List[string]]::new()
  for ($i = 0; $i -lt $instanceData.FlightID.Count; $i++) {
    $count = [int]$instanceData.flight_n_tasks[$i]
    $starts = @{}
    # The instance task list is topological, but repeat to tolerate variants.
    for ($pass = 0; $pass -lt $count; $pass++) {
      for ($t = 0; $t -lt $count; $t++) {
        $task = $instanceData.flight_tasks[$i][$t]
        $earliest = [int]$instanceData.flight_arr[$i]
        foreach ($p in @($preds[$task.kind])) {
          for ($q = 0; $q -lt $count; $q++) {
            $other = $instanceData.flight_tasks[$i][$q]
            if ($other.kind -eq $p -and $starts.ContainsKey($q)) {
              $earliest = [Math]::Max($earliest, [int]$starts[$q] + [int]$other.duration)
            }
          }
        }
        # Do not choose a time before every compatible shift starts.
        $shiftStart = [int]::MaxValue
        for ($l = 0; $l -lt $instanceData.LaborID.Count; $l++) {
          if ($instanceData.labor_kind[$l] -eq $teamOf[$task.kind] -and
              [int]$instanceData.labor_shift_start[$l] + [int]$task.duration -le [int]$instanceData.labor_shift_end[$l]) {
            $shiftStart = [Math]::Min($shiftStart, [int]$instanceData.labor_shift_start[$l])
          }
        }
        if ($shiftStart -ne [int]::MaxValue) { $earliest = [Math]::Max($earliest, $shiftStart) }
        $starts[$t] = $earliest
      }
    }
    $f = Assert-Identifier $instanceData.FlightID[$i]
    for ($t = 0; $t -lt $count; $t++) {
      $constraints.Add("constraint task_start[$f,$($t + 1)] = $($starts[$t]);")
    }
  }
  $insertion = ($constraints -join [Environment]::NewLine) + [Environment]::NewLine
  $text = [regex]::Replace($baseModel, $solvePattern, { param($m) $insertion + $m.Value }, 'Singleline')
  $objectivePattern = 'constraint\s+forall\(l in LaborID\)\(\s*used\[l\]\s*<->.*?\);\s*constraint\s+cost\s*=\s*sum\(l in LaborID\)\(.*?\);'
  $text = [regex]::Replace(
    $text, $objectivePattern,
    'constraint forall(l in LaborID)(not used[l]); constraint cost = 0;',
    'Singleline'
  )
  return [regex]::Replace($text, 'minimize\s+cost;', 'satisfy;', 'Singleline')
}

function Set-TrueCost($Run) {
  if ($null -eq $Run) { return $null }
  $usedNames = @($Run.Solution.task_labor | ForEach-Object { $_ } | Sort-Object -Unique)
  [long]$trueCost = 0
  for ($l = 0; $l -lt $instanceData.LaborID.Count; $l++) {
    if ($instanceData.LaborID[$l] -in $usedNames) { $trueCost += [long]$instanceData.labor_cost[$l] }
  }
  $Run.Solution.cost = $trueCost
  $Run.Cost = $trueCost
  $Run.Solution | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Run.Candidate -Encoding UTF8
  return $Run
}

$incumbent = Read-Solution $outputPath
if ($null -eq $incumbent) {
  # Fast constructive attempt: precedence-earliest times turn the hard joint
  # scheduling problem into resource assignment and gate coloring.
  $constructiveModel = Join-Path $scratch 'constructive.mzn'
  [IO.File]::WriteAllText($constructiveModel, (New-EarliestStartModel))
  $constructiveLimit = [Math]::Min(15000, $StageTimeMs)
  $best = Invoke-Adaptive $constructiveModel 'constructive' $constructiveLimit
  $best = Set-TrueCost $best

  $feasibleModel = Join-Path $scratch 'feasible.mzn'
  # Keep the model's carefully chosen variable/value order for feasibility.
  # Replacing the whole solve item would fall back to MiniZinc's default search.
  $feasibleText = [regex]::Replace(
    $baseModel, 'minimize\s+cost;', 'satisfy;', 'Singleline'
  )
  [IO.File]::WriteAllText($feasibleModel, $feasibleText)
  if ($null -eq $best) { $best = Invoke-Adaptive $feasibleModel 'feasible' $StageTimeMs }
  if ($null -eq $best) { Write-Error 'No feasible solution found; existing output preserved.' }
  New-Item -ItemType Directory -Force (Split-Path -Parent $outputPath) | Out-Null
  Copy-Item -LiteralPath $best.Candidate -Destination $outputPath -Force
  $incumbent = $best.Solution
}

$boundedModel = Join-Path $scratch 'bounded.mzn'
[IO.File]::WriteAllText($boundedModel, (New-BoundedModel $incumbent 'bound'))
$best = Invoke-Adaptive $boundedModel 'bounded' $StageTimeMs
if ($null -ne $best -and $best.Cost -lt [long]$incumbent.cost) {
  Copy-Item -LiteralPath $best.Candidate -Destination $outputPath -Force
  $incumbent = $best.Solution
  Write-Output "stage2 solver=$($best.Solver) cost=$($best.Cost)"
}

for ($iteration = 0; $iteration -lt $Iterations; $iteration++) {
  $mode = if ($iteration % 2 -eq 0) { 'flight' } else { 'team' }
  # Grow the flight neighborhood after each unsuccessful flight round.
  $flightRound = [Math]::Floor($iteration / 2)
  $relaxPercent = @(20, 40, 60)[$flightRound % 3]
  $lnsModel = Join-Path $scratch "lns_$iteration.mzn"
  $candidate = Join-Path $scratch "lns_$iteration.json"
  [IO.File]::WriteAllText($lnsModel, (New-BoundedModel $incumbent $mode $relaxPercent))
  $solution = Invoke-One 'chuffed' $lnsModel $candidate $LnsTimeMs
  if ($null -ne $solution -and [long]$solution.cost -lt [long]$incumbent.cost) {
    Copy-Item -LiteralPath $candidate -Destination $outputPath -Force
    $incumbent = $solution
    Write-Output "lns=$($iteration + 1) mode=$mode relax=$relaxPercent cost=$($incumbent.cost)"
  }
}
Write-Output "best cost=$($incumbent.cost) output=$outputPath"
