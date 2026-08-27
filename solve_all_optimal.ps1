param([string]$Solver = 'chuffed')

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $MyInvocation.MyCommand.Path
$model = Join-Path $workspace 'airport_sched.mzn'
$runDir = Join-Path $workspace 'tmp\optimal_run'
New-Item -ItemType Directory -Force $runDir | Out-Null

foreach ($index in 1..12) {
  $suffix = '{0:D2}' -f $index
  $instance = Join-Path $workspace "data\hackathon_$suffix.json"
  $output = Join-Path $workspace "sol\sol_$suffix.json"
  $stdout = Join-Path $runDir "data_$suffix.stdout"
  $stderr = Join-Path $runDir "data_$suffix.stderr"
  $status = Join-Path $runDir "data_$suffix.status"
  "RUNNING solver=$Solver started=$([DateTime]::Now.ToString('s'))" | Set-Content $status

  $arguments = @(
    '--solver', $Solver,
    '--soln-sep', '<<<SOLUTION_END>>>',
    '--search-complete-msg', '<<<OPTIMAL>>>',
    $model, $instance
  )
  $process = Start-Process minizinc -ArgumentList $arguments -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  $process.WaitForExit()

  $raw = if (Test-Path $stdout) { Get-Content -Raw $stdout } else { '' }
  $optimal = $raw.Contains('<<<OPTIMAL>>>')
  $bestText = $null
  $bestCost = [long]::MaxValue
  foreach ($piece in ($raw -split [regex]::Escape('<<<SOLUTION_END>>>'))) {
    $jsonText = $piece.Replace('<<<OPTIMAL>>>', '').Trim()
    if (-not $jsonText.StartsWith('{')) { continue }
    try {
      $solution = $jsonText | ConvertFrom-Json
      if ($null -ne $solution.cost -and [long]$solution.cost -ge 0 -and [long]$solution.cost -lt $bestCost) {
        $bestCost = [long]$solution.cost
        $bestText = $jsonText
      }
    } catch { }
  }

  if ($optimal -and $null -ne $bestText) {
    $bestText | Set-Content -LiteralPath $output -Encoding UTF8
    "OPTIMAL solver=$Solver cost=$bestCost finished=$([DateTime]::Now.ToString('s'))" | Set-Content $status
    Write-Output "data$suffix OPTIMAL cost=$bestCost"
  } else {
    "FAILED_OR_INCOMPLETE solver=$Solver exit=$($process.ExitCode) finished=$([DateTime]::Now.ToString('s'))" | Set-Content $status
    Write-Output "data$suffix incomplete; original preserved"
    break
  }
}
